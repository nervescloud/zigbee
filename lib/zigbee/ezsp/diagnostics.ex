defmodule Zigbee.EZSP.Diagnostics do
  @moduledoc """
  Low-level probing helpers for bringing up a new NCP over serial.

  These bypass `Zigbee.EZSP.ASH.Connection` and talk to the port directly so you can
  see exactly what (if anything) the dongle sends back, which helps when the
  reset handshake times out and you don't yet know the right baud rate, flow
  control, or even whether the firmware speaks EZSP at all.

  Run from IEx:

      Zigbee.EZSP.Diagnostics.sweep("/dev/cu.usbmodem2101")
  """

  alias Zigbee.EZSP.ASH
  alias Circuits.UART

  @default_bauds [115_200, 460_800, 230_400, 57_600]

  @doc """
  Send an ASH RST at one baud/flow-control setting and dump whatever comes back.

  Options: `:speed` (default 115200), `:flow_control` (`:none` | `:hardware`,
  default `:none`), `:listen_ms` (default 1500).
  """
  def probe(device, opts \\ []) do
    speed = Keyword.get(opts, :speed, 115_200)
    flow = Keyword.get(opts, :flow_control, :none)
    listen_ms = Keyword.get(opts, :listen_ms, 1_500)

    {:ok, uart} = UART.start_link()

    :ok =
      UART.open(uart, device,
        speed: speed,
        data_bits: 8,
        stop_bits: 1,
        parity: :none,
        flow_control: flow,
        active: true,
        framing: UART.Framing.None
      )

    # Let any power-on / DTR-toggle noise settle, then clear the mailbox.
    Process.sleep(250)
    flush_mailbox()

    :ok = UART.write(uart, ASH.rst_frame())
    bytes = collect(listen_ms, <<>>)

    UART.close(uart)
    UART.stop(uart)

    report(speed, flow, bytes)
  end

  @doc """
  Probe a list of baud rates (default #{inspect(@default_bauds)}) at `flow_control: :none`
  and report which, if any, yields a valid RSTACK.
  """
  def sweep(device, bauds \\ @default_bauds) do
    IO.puts("\nProbing #{device}, sending ASH RST (1A C0 38 BC 7E) at each baud:\n")

    result =
      Enum.find_value(bauds, fn baud ->
        case probe(device, speed: baud) do
          {:rstack, _} = ok -> {baud, ok}
          _ -> nil
        end
      end)

    case result do
      {baud, {:rstack, info}} ->
        IO.puts("\n✅ NCP responded with a valid RSTACK at #{baud} baud: #{inspect(info)}")
        IO.puts("   → start the connection with `speed: #{baud}`.")
        {:ok, baud}

      nil ->
        IO.puts("\n❌ No valid RSTACK at any baud. Likely causes, in order:")
        IO.puts("   1. Dongle is NOT running EmberZNet EZSP firmware (e.g. it's on")
        IO.puts("      Thread/multiprotocol RCP), flash EZSP with universal-silabs-flasher.")
        IO.puts("   2. Try `flow_control: :hardware`.")
        IO.puts("   3. Wrong device path, or another program holds the port.")
        :error
    end
  end

  # ── internals ─────────────────────────────────────────────────────────────

  defp collect(remaining_ms, acc) when remaining_ms <= 0, do: acc

  defp collect(remaining_ms, acc) do
    start = System.monotonic_time(:millisecond)

    receive do
      {:circuits_uart, _port, data} when is_binary(data) ->
        elapsed = System.monotonic_time(:millisecond) - start
        collect(remaining_ms - elapsed, acc <> data)

      {:circuits_uart, _port, _other} ->
        elapsed = System.monotonic_time(:millisecond) - start
        collect(remaining_ms - elapsed, acc)
    after
      remaining_ms -> acc
    end
  end

  defp flush_mailbox do
    receive do
      {:circuits_uart, _, _} -> flush_mailbox()
    after
      0 -> :ok
    end
  end

  defp report(speed, flow, <<>>) do
    IO.puts("  #{pad(speed)} flow=#{flow}: (no bytes received)")
    :no_response
  end

  defp report(speed, flow, bytes) do
    IO.puts("  #{pad(speed)} flow=#{flow}: #{byte_size(bytes)} bytes  #{hex(bytes)}")

    # Split on the flag byte (0x7E) *and* the Cancel byte (0x1A), the NCP emits
    # power-on noise then a Cancel to flush it before the real RSTACK, so a
    # naive flag-only split would fold the noise into the frame and fail CRC.
    decoded =
      bytes
      |> :binary.split([<<0x7E>>, <<0x1A>>], [:global])
      |> Enum.reject(&(&1 == <<>>))
      |> Enum.map(&ASH.decode/1)

    case Enum.find(decoded, &match?({:ok, %{type: :rstack}}, &1)) do
      {:ok, info} ->
        IO.puts("       → valid RSTACK: #{inspect(info)}")
        {:rstack, info}

      nil ->
        IO.puts("       → decoded: #{inspect(decoded)}")
        :garbled
    end
  end

  defp hex(bytes),
    do: bytes |> :binary.bin_to_list() |> Enum.map_join(" ", &Integer.to_string(&1, 16))

  defp pad(speed), do: String.pad_leading("#{speed}", 7)
end
