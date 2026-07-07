defmodule Zigbee.EZSP.ASH.Connection do
  @moduledoc """
  Stateful ASH link over a serial port (`Circuits.UART`).

  Responsibilities:

    * open the UART and stream raw bytes in and out;
    * perform the RST → RSTACK reset handshake with the NCP;
    * split the incoming byte stream into ASH frames (honouring Cancel and
      flow-control bytes);
    * track frame/ack sequence numbers, ACK inbound DATA frames, and
      retransmit unacknowledged outbound DATA frames.

  This layer is transport for EZSP: it delivers de-randomized EZSP payloads to a
  subscriber process and accepts EZSP payloads to send. It knows nothing about
  EZSP frame contents.

  ## Send model

  A window of one outstanding DATA frame. `send_data/2` blocks until the NCP
  ACKs (or the retransmit budget is exhausted). EZSP is request/response, so a
  window of one costs nothing in practice and keeps the state machine small.

  ## Usage

      {:ok, conn} = Zigbee.EZSP.ASH.Connection.start_link(device: "/dev/cu.usbmodem2101")
      :ok = Zigbee.EZSP.ASH.Connection.reset(conn)        # RST/RSTACK handshake
      :ok = Zigbee.EZSP.ASH.Connection.subscribe(conn)    # receive {:ash_data, payload}
      :ok = Zigbee.EZSP.ASH.Connection.send_data(conn, ezsp_payload)
  """

  use GenServer
  require Logger

  alias Zigbee.EZSP.ASH
  alias Circuits.UART

  # ASH acknowledgement timeout and retransmit budget (UG101 defaults are
  # adaptive 0.4–3.2 s; a fixed 0.8 s with 4 retries is a fine starting point).
  @ack_timeout 800
  @max_retransmits 4
  @rstack_timeout 3_000

  defstruct [
    :uart,
    :device,
    :subscriber,
    buffer: <<>>,
    tx_seq: 0,
    rx_seq: 0,
    # outstanding unacked send: {from, payload, retries, timer_ref} | nil
    outstanding: nil,
    # waiter for the RSTACK during a reset: {from, timer_ref} | nil
    resetting: nil
  ]

  # ── Public API ──────────────────────────────────────────────────────────

  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Perform the RST/RSTACK reset handshake. Resets sequence numbers."
  def reset(conn, timeout \\ @rstack_timeout), do: GenServer.call(conn, :reset, timeout + 500)

  @doc "Register the calling process to receive `{:ash_data, payload}` messages."
  def subscribe(conn), do: GenServer.call(conn, {:subscribe, self()})

  @doc "Send an EZSP payload as a DATA frame; blocks until ACKed or it fails."
  def send_data(conn, payload) when is_binary(payload),
    do: GenServer.call(conn, {:send_data, payload}, @ack_timeout * (@max_retransmits + 2))

  # ── GenServer ───────────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    device = Keyword.fetch!(opts, :device)
    # ZBT-2 (EmberZNet EZSP over the ESP32-S3 USB-CDC bridge) runs at 460800.
    speed = Keyword.get(opts, :speed, 460_800)
    flow_control = Keyword.get(opts, :flow_control, :none)

    {:ok, uart} = UART.start_link()

    open_opts = [
      speed: speed,
      data_bits: 8,
      stop_bits: 1,
      parity: :none,
      flow_control: flow_control,
      active: true,
      framing: UART.Framing.None
    ]

    case UART.open(uart, device, open_opts) do
      :ok ->
        {:ok, %__MODULE__{uart: uart, device: device}}

      {:error, reason} ->
        {:stop, {:open_failed, reason}}
    end
  end

  @impl true
  def handle_call(:reset, from, state) do
    :ok = UART.write(state.uart, ASH.rst_frame())
    timer = Process.send_after(self(), :rstack_timeout, @rstack_timeout)
    {:noreply, %{state | resetting: {from, timer}, buffer: <<>>, outstanding: nil}}
  end

  def handle_call({:subscribe, pid}, _from, state) do
    {:reply, :ok, %{state | subscriber: pid}}
  end

  # Only one outstanding send at a time (window of one).
  def handle_call({:send_data, _payload}, _from, %{outstanding: o} = state) when o != nil do
    {:reply, {:error, :busy}, state}
  end

  def handle_call({:send_data, payload}, from, state) do
    frame = ASH.data_frame(state.tx_seq, state.rx_seq, payload, false)
    :ok = UART.write(state.uart, frame)
    timer = Process.send_after(self(), :ack_timeout, @ack_timeout)
    {:noreply, %{state | outstanding: {from, payload, 0, timer}}}
  end

  @impl true
  def handle_info({:circuits_uart, _port, data}, state) when is_binary(data) do
    {frames, buffer} = extract_frames(state.buffer <> data)
    state = Enum.reduce(frames, %{state | buffer: buffer}, &handle_frame(&2, &1))
    {:noreply, state}
  end

  def handle_info({:circuits_uart, _port, {:error, reason}}, state) do
    Logger.error("ASH: UART error #{inspect(reason)}")
    {:noreply, state}
  end

  def handle_info(:ack_timeout, %{outstanding: nil} = state), do: {:noreply, state}

  def handle_info(:ack_timeout, %{outstanding: {from, payload, retries, _}} = state) do
    if retries >= @max_retransmits do
      GenServer.reply(from, {:error, :no_ack})
      {:noreply, %{state | outstanding: nil}}
    else
      frame = ASH.data_frame(state.tx_seq, state.rx_seq, payload, true)
      :ok = UART.write(state.uart, frame)
      timer = Process.send_after(self(), :ack_timeout, @ack_timeout)
      {:noreply, %{state | outstanding: {from, payload, retries + 1, timer}}}
    end
  end

  def handle_info(:rstack_timeout, %{resetting: nil} = state), do: {:noreply, state}

  def handle_info(:rstack_timeout, %{resetting: {from, _}} = state) do
    GenServer.reply(from, {:error, :rstack_timeout})
    {:noreply, %{state | resetting: nil}}
  end

  # ── Frame handling ────────────────────────────────────────────────────────

  defp handle_frame(state, raw) do
    case ASH.decode(raw) do
      {:ok, frame} -> dispatch(state, frame)
      {:error, reason} -> nak_and_log(state, reason)
    end
  end

  # RSTACK completes a pending reset and zeroes the sequence numbers.
  defp dispatch(%{resetting: {from, timer}} = state, %{type: :rstack} = f) do
    Process.cancel_timer(timer)
    Logger.info("ASH: NCP reset, version #{f.version}, code #{f.reset_code}")
    GenServer.reply(from, :ok)
    %{state | resetting: nil, tx_seq: 0, rx_seq: 0}
  end

  defp dispatch(state, %{type: :rstack}), do: state

  # Inbound DATA: deliver payload, advance our rx sequence, ACK it.
  defp dispatch(state, %{type: :data} = f) do
    if f.frame_num == state.rx_seq do
      if state.subscriber, do: send(state.subscriber, {:ash_data, f.payload})
      state = %{state | rx_seq: rem(state.rx_seq + 1, 8)}
      :ok = UART.write(state.uart, ASH.ack_frame(state.rx_seq))
      state
    else
      # Out-of-sequence: re-ACK what we last accepted so the NCP resyncs.
      :ok = UART.write(state.uart, ASH.ack_frame(state.rx_seq))
      state
    end
  end

  # ACK for our outstanding DATA frame: advance tx sequence, unblock caller.
  defp dispatch(%{outstanding: {from, _payload, _retries, timer}} = state, %{type: :ack} = f) do
    if f.ack_num == rem(state.tx_seq + 1, 8) do
      Process.cancel_timer(timer)
      GenServer.reply(from, :ok)
      %{state | outstanding: nil, tx_seq: rem(state.tx_seq + 1, 8)}
    else
      state
    end
  end

  defp dispatch(state, %{type: :ack}), do: state

  # NAK: retransmit immediately if we have something outstanding.
  defp dispatch(%{outstanding: {from, payload, retries, timer}} = state, %{type: :nak}) do
    Process.cancel_timer(timer)
    frame = ASH.data_frame(state.tx_seq, state.rx_seq, payload, true)
    :ok = UART.write(state.uart, frame)
    new_timer = Process.send_after(self(), :ack_timeout, @ack_timeout)
    %{state | outstanding: {from, payload, retries + 1, new_timer}}
  end

  defp dispatch(state, %{type: :error} = f) do
    Logger.error("ASH: NCP ERROR frame, code #{f.error_code}, NCP needs a reset")
    state
  end

  defp dispatch(state, _frame), do: state

  defp nak_and_log(state, reason) do
    Logger.warning("ASH: dropping frame (#{inspect(reason)})")
    if reason == :crc_mismatch, do: UART.write(state.uart, ASH.nak_frame(state.rx_seq))
    state
  end

  # ── Byte-stream framing ───────────────────────────────────────────────────
  #
  # Split the raw stream into candidate frames delimited by the flag byte
  # (0x7E). A Cancel byte (0x1A) discards any partial frame accumulated so far;
  # XON/XOFF flow-control bytes are dropped. Returns completed frames plus the
  # trailing partial buffer.

  @flag 0x7E
  @cancel 0x1A
  @substitute 0x18
  @xon 0x11
  @xoff 0x13

  defp extract_frames(bytes), do: extract_frames(bytes, <<>>, [])

  defp extract_frames(<<>>, acc, frames), do: {Enum.reverse(frames), acc}

  defp extract_frames(<<@flag, rest::binary>>, acc, frames) do
    frames = if acc == <<>>, do: frames, else: [acc | frames]
    extract_frames(rest, <<>>, frames)
  end

  # Cancel / Substitute abort the in-progress frame.
  defp extract_frames(<<b, rest::binary>>, _acc, frames) when b in [@cancel, @substitute],
    do: extract_frames(rest, <<>>, frames)

  # Flow-control bytes are not part of frame content.
  defp extract_frames(<<b, rest::binary>>, acc, frames) when b in [@xon, @xoff],
    do: extract_frames(rest, acc, frames)

  defp extract_frames(<<b, rest::binary>>, acc, frames),
    do: extract_frames(rest, <<acc::binary, b>>, frames)
end
