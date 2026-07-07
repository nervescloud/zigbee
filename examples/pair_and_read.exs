# pair_and_read.exs, end-to-end Zigbee demo
#
# Opens an EmberZNet dongle, forms a coordinator network, pairs ONE device, then
# prints its temperature / humidity reports live.
#
# Run it from the library root:
#
#     mix run examples/pair_and_read.exs
#
# Configure with env vars (defaults shown):
#
#     ZBT_DEVICE=/dev/ttyACM0   # serial port (macOS ZBT-2: /dev/cu.usbmodem…)
#     ZBT_SPEED=460800          # baud (460800 for the ZBT-2; often 115200 elsewhere)
#     ZBT_CHANNEL=15            # Zigbee channel, 11..26
#     ZBT_WATCH=120             # seconds to watch for reports after pairing

device = System.get_env("ZBT_DEVICE", "/dev/ttyACM0")
speed = String.to_integer(System.get_env("ZBT_SPEED", "460800"))
channel = String.to_integer(System.get_env("ZBT_CHANNEL", "15"))
watch_ms = String.to_integer(System.get_env("ZBT_WATCH", "120")) * 1000

hex = fn bin ->
  bin |> :binary.bin_to_list() |> Enum.map_join(":", &String.pad_leading(Integer.to_string(&1, 16), 2, "0"))
end

# 1. Open the radio (Silicon Labs EmberZNet backend) and subscribe for events.
IO.puts("Opening #{device} @ #{speed} baud…")
{:ok, zb} = Zigbee.start_link(Zigbee.EZSP.Adapter, device: device, speed: speed)
:ok = Zigbee.subscribe(zb, self())
IO.inspect(Zigbee.info(zb), label: "radio")

# 2. Form a coordinator network (also registers the default HA endpoint).
IO.puts("\nForming network on channel #{channel}…")
{:ok, params} = Zigbee.form_network(zb, channel: channel)
IO.puts("  network up: pan_id=0x#{Integer.to_string(params.pan_id, 16)} channel=#{params.channel}")

# 3. Open joining and wait for a device to join.
IO.puts("\n>>> Put your device into pairing mode now (join window open)…")

case Zigbee.Interview.open_and_wait(zb) do
  {:ok, dev} ->
    IO.puts("  joined: node=0x#{Integer.to_string(dev.node_id, 16)} eui64=#{hex.(dev.eui64)}")

    # 4. Interview it: enumerate endpoints, bind + configure temp/humidity reporting.
    IO.puts("\nInterviewing device…")

    case Zigbee.Interview.run(zb, dev.node_id, dev.eui64) do
      {:ok, summary} ->
        IO.puts("  endpoints=#{inspect(summary.endpoints)}  bindings=#{length(summary.bindings)}")

        # 5. Print reports as they arrive (collect/2 returns a batch each window).
        IO.puts("\nWatching reports for #{div(watch_ms, 1000)}s (Ctrl-C to stop)…")
        deadline = System.monotonic_time(:millisecond) + watch_ms

        stream = fn stream ->
          if System.monotonic_time(:millisecond) < deadline do
            for r <- Zigbee.Interview.collect(zb, 5_000) do
              IO.puts("  #{Integer.to_string(r.cluster, 16)} ep#{r.endpoint}: #{r.value}#{r.unit}")
            end

            stream.(stream)
          end
        end

        stream.(stream)
        IO.puts("\nDone.")

      err ->
        IO.inspect(err, label: "interview failed")
    end

  {:error, :timeout} ->
    IO.puts("  no device joined within the window, try again and press pair sooner.")
end
