defmodule Zigbee.EZSP do
  @moduledoc """
  EZSP application layer over `Zigbee.EZSP.ASH.Connection`.

  This is the **low-level** EmberZNet protocol client, a thin, synchronous
  command/response transport over the NCP. Most code should use the `Zigbee`
  facade with `Zigbee.EZSP.Adapter` instead, which adds the coordinator sequence
  (form, endpoints, unicast) and normalizes NCP callbacks into backend-neutral
  events. Reach for this module directly only for raw EZSP commands the adapter
  doesn't expose.

  On startup this server opens the serial port, performs the ASH reset
  handshake, then negotiates the EZSP protocol version (the mandatory first
  command). After that, `command/3` issues EZSP commands and blocks for the
  matching response; unsolicited NCP callbacks are forwarded to a subscriber.

  ## Example

      {:ok, ezsp} = Zigbee.EZSP.start_link(device: "/dev/cu.usbmodem1CDBD45F0F5C1")
      Zigbee.EZSP.info(ezsp)
      #=> %{protocol_version: 13, stack_type: 2, stack_version: "7.4.4.0"}

      {:ok, frame} = Zigbee.EZSP.command(ezsp, 0x0026, <<>>)  # getEui64
  """

  use GenServer
  require Logger

  alias Zigbee.EZSP.ASH.Connection
  alias Zigbee.EZSP.Frame

  # A handful of EZSP v13 frame IDs. This is not the full table, just what the
  # bring-up path needs. Add more as higher layers require them. IDs verified
  # against EmberZNet 7.4.4.0 firmware.
  @frame_ids %{
    version: 0x0000,
    set_manufacturer_code: 0x0015,
    add_endpoint: 0x0002,
    get_eui64: 0x0026,
    get_node_id: 0x0027,
    network_init: 0x0017,
    network_state: 0x0018,
    form_network: 0x001E,
    leave_network: 0x0020,
    permit_joining: 0x0022,
    # Trust-center: instruct a device to leave and drop it from the TC's tables.
    # (Frame id stable since pre-v8 EZSP; verify against firmware on new NCPs.)
    remove_device: 0x00A8,
    get_network_parameters: 0x0028,
    send_unicast: 0x0034,
    send_broadcast: 0x0036,
    set_configuration_value: 0x0053,
    get_configuration_value: 0x0052,
    set_policy: 0x0055,
    get_policy: 0x0056,
    set_initial_security_state: 0x0068,
    # Security Manager (EZSP v13). addTransientLinkKey was removed in v13; the
    # well-known join link key must be installed via importTransientKey.
    import_transient_key: 0x0111
  }

  # Callback (unsolicited) frame IDs the higher layers care about.
  @callback_ids %{
    0x0019 => :stack_status_handler,
    0x0024 => :trust_center_join_handler,
    0x003F => :message_sent_handler,
    0x0045 => :incoming_message_handler
  }

  @doc "Map a callback frame ID to a friendly name, or `nil` if unknown."
  def callback_name(frame_id), do: Map.get(@callback_ids, frame_id)

  @desired_version 13
  @response_timeout 3_000

  defstruct [:conn, :info, seq: 0, pending: %{}, subscriber: nil]

  # ── Public API ──────────────────────────────────────────────────────────

  def start_link(opts) do
    {name, opts} = Keyword.pop(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Version/stack info discovered during startup negotiation."
  def info(server), do: GenServer.call(server, :info)

  @doc "Register `pid` to receive `{:ezsp_callback, frame}` for unsolicited frames."
  def subscribe(server, pid \\ self()), do: GenServer.call(server, {:subscribe, pid})

  @doc """
  Send an EZSP command and wait for its response.

  `frame_id` may be an atom from the known table (e.g. `:get_eui64`) or a raw
  16-bit integer. Returns `{:ok, frame}` where `frame.params` holds the response
  bytes, or `{:error, reason}`.
  """
  def command(server, frame_id, params \\ <<>>)

  def command(server, name, params) when is_atom(name),
    do: command(server, Map.fetch!(@frame_ids, name), params)

  def command(server, frame_id, params) when is_integer(frame_id),
    do: GenServer.call(server, {:command, frame_id, params}, @response_timeout + 1_000)

  # ── GenServer ─────────────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    conn_opts = Keyword.take(opts, [:device, :speed, :flow_control])
    {:ok, conn} = Connection.start_link(conn_opts)
    Process.sleep(500)

    with :ok <- reset_with_retry(conn, 3),
         :ok <- Connection.subscribe(conn) do
      {:ok, %__MODULE__{conn: conn}, {:continue, :negotiate}}
    else
      err -> {:stop, {:startup_failed, err}}
    end
  end

  @impl true
  def handle_continue(:negotiate, state) do
    case negotiate_version(state, @desired_version) do
      {:ok, info, state} ->
        Logger.info(
          "EZSP: negotiated v#{info.protocol_version}, EmberZNet #{info.stack_version} " <>
            "(stack type #{info.stack_type})"
        )

        {:noreply, %{state | info: info}}

      {:error, reason} ->
        {:stop, {:version_negotiation_failed, reason}, state}
    end
  end

  @impl true
  def handle_call(:info, _from, state), do: {:reply, state.info, state}

  def handle_call({:subscribe, pid}, _from, state),
    do: {:reply, :ok, %{state | subscriber: pid}}

  def handle_call({:command, frame_id, params}, from, state) do
    seq = state.seq
    frame = Frame.encode_command(seq, frame_id, params)

    case Connection.send_data(state.conn, frame) do
      :ok ->
        pending = Map.put(state.pending, seq, {from, frame_id})
        {:noreply, %{state | seq: next_seq(seq), pending: pending}}

      err ->
        {:reply, err, %{state | seq: next_seq(seq)}}
    end
  end

  @impl true
  def handle_info({:ash_data, payload}, state) do
    case Frame.decode(payload) do
      {:ok, frame} -> {:noreply, route(frame, state)}
      {:error, _} -> {:noreply, state}
    end
  end

  # Correlate a response to its pending command by echoed sequence number; treat
  # anything else as an unsolicited callback.
  defp route(%{response?: true, seq: seq} = frame, state) do
    case Map.pop(state.pending, seq) do
      {{from, _frame_id}, pending} ->
        GenServer.reply(from, {:ok, frame})
        %{state | pending: pending}

      {nil, _} ->
        deliver_callback(frame, state)
    end
  end

  defp route(frame, state), do: deliver_callback(frame, state)

  defp deliver_callback(frame, state) do
    if state.subscriber, do: send(state.subscriber, {:ezsp_callback, frame})
    state
  end

  # ── Startup helpers (run in the GenServer process, before the loop) ───────

  defp reset_with_retry(_conn, 0), do: {:error, :reset_failed}

  defp reset_with_retry(conn, attempts) do
    case Connection.reset(conn) do
      :ok ->
        :ok

      _err ->
        Process.sleep(300)
        reset_with_retry(conn, attempts - 1)
    end
  end

  # The version command must be the first EZSP command after reset. Negotiation:
  # ask for our desired version; the NCP replies with the version it will speak.
  # If it differs, re-send with that version so both ends agree.
  defp negotiate_version(state, desired) do
    with {:ok, info, state} <- send_version(state, desired) do
      if info.protocol_version == desired do
        {:ok, info, state}
      else
        send_version(state, info.protocol_version)
      end
    end
  end

  defp send_version(state, desired) do
    seq = state.seq
    frame = Frame.encode_command(seq, @frame_ids.version, <<desired>>)

    with :ok <- Connection.send_data(state.conn, frame),
         {:ok, payload} <- await_response() do
      case Frame.decode(payload) do
        {:ok, %{frame_id: 0x0000, params: <<pv, st, sv::little-16>>}} ->
          info = %{
            protocol_version: pv,
            stack_type: st,
            stack_version: format_stack_version(sv)
          }

          {:ok, info, %{state | seq: next_seq(seq)}}

        other ->
          {:error, {:unexpected_version_response, other}}
      end
    end
  end

  # Pull the version response directly from the mailbox (Connection delivers it
  # as {:ash_data, _}); used only during startup, before the receive loop runs.
  defp await_response do
    receive do
      {:ash_data, payload} -> {:ok, payload}
    after
      @response_timeout -> {:error, :response_timeout}
    end
  end

  defp format_stack_version(v) do
    <<a::4, b::4, c::4, d::4>> = <<v::16>>
    "#{a}.#{b}.#{c}.#{d}"
  end

  defp next_seq(seq), do: rem(seq + 1, 256)
end
