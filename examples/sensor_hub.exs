defmodule SensorHub do
  @moduledoc """
  Example: driving the `zigbee` library from a supervised GenServer.

  A long-running "sensor hub" that owns the radio, opens joining on demand, and
  keeps the latest temperature/humidity reading for every device that joins.

  ## What this shows

    * hold the `%Zigbee.Adapter{}` handle in the GenServer's state
    * make the GenServer the event **subscriber**, so `{:zigbee, _}` events land in
      `handle_info/2`
    * do slow start-up work in `handle_continue/2`, not `init/1`
    * **re-establish** the network stored on the dongle across restarts, rather than
      re-forming, which would make a new network and orphan already-paired devices
    * handle joins and reports **reactively**

  ## Important

  Do **not** call the blocking `Zigbee.Interview.*` helpers from inside a
  GenServer, they run their own `receive` loop and would swallow the process's
  messages. Instead, react to `{:zigbee, :device_joined, _}` by firing the
  bind + configure-reporting requests with `Zigbee.send_aps/7` (fire-and-forget),
  and let the resulting `{:zigbee, :message, _}` reports flow into `handle_info/2`.
  (If you need the synchronous `Interview` flow, run it in its own task/process
  that is the subscriber, one process owns the event stream at a time.)

  ## Usage

      children = [{SensorHub, device: "/dev/ttyACM0", speed: 460_800, channel: 15}]
      Supervisor.start_link(children, strategy: :one_for_one)

      SensorHub.open_joining(120)   # then put a device into pairing mode
      SensorHub.readings()
      #=> %{0xA1B2 => %{0x0402 => %{value: 21.4, unit: "°C", at: ~U[...]}, ...}}
      SensorHub.unpair(0xA1B2)      # tell it to leave and forget it
  """

  use GenServer
  require Logger

  alias Zigbee.{ZCL, ZDO, Message}

  @temperature 0x0402
  @humidity 0x0405
  @report_clusters [@temperature, @humidity]
  @ha_profile 0x0104
  @zdo_profile 0x0000

  # ── Client API ─────────────────────────────────────────────────────────────

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Open the join window for `seconds`; then put a device into pairing mode."
  def open_joining(server \\ __MODULE__, seconds \\ 180),
    do: GenServer.call(server, {:open_joining, seconds})

  @doc "Unpair a device: tell it to leave the network and forget it."
  def unpair(server \\ __MODULE__, node_id),
    do: GenServer.call(server, {:unpair, node_id})

  @doc "Latest readings, as `%{node_id => %{cluster => %{value, unit, at}}}`."
  def readings(server \\ __MODULE__), do: GenServer.call(server, :readings)

  @doc "Devices seen, as `%{node_id => %{eui64: _}}`."
  def devices(server \\ __MODULE__), do: GenServer.call(server, :devices)

  # ── Server ─────────────────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    {:ok, zb} =
      Zigbee.start_link(Zigbee.EZSP.Adapter,
        device: Keyword.fetch!(opts, :device),
        speed: Keyword.get(opts, :speed, 460_800)
      )

    # This GenServer is the event subscriber → events arrive in handle_info/2.
    :ok = Zigbee.subscribe(zb)

    state = %{
      zb: zb,
      channel: Keyword.get(opts, :channel, 15),
      coord_eui64: nil,
      devices: %{},
      readings: %{},
      seq: 0
    }

    # Bringing the network up blocks until NETWORK_UP, do it off the init path.
    {:ok, state, {:continue, :bring_up}}
  end

  @impl true
  def handle_continue(:bring_up, s) do
    # Re-establish the network already stored on the dongle; only form a NEW one if
    # there is none. Forming on every restart would make a new network (new key) and
    # orphan already-paired devices. Paired devices reconnect on their own once the
    # network is re-established, their bindings + reporting config live on the
    # device, not here.
    {origin, params} =
      case Zigbee.reestablish_network(s.zb) do
        {:ok, p} ->
          {"re-established", p}

        {:error, :no_network} ->
          {:ok, p} = Zigbee.form_network(s.zb, channel: s.channel)
          {"formed", p}
      end

    {:ok, coord_eui64} = Zigbee.identifier(s.zb)
    Logger.info("SensorHub: #{origin} network on channel #{params.channel}")
    {:noreply, %{s | coord_eui64: coord_eui64}}
  end

  @impl true
  def handle_call({:open_joining, seconds}, _from, s),
    do: {:reply, Zigbee.permit_joining(s.zb, seconds), s}

  def handle_call(:readings, _from, s), do: {:reply, s.readings, s}
  def handle_call(:devices, _from, s), do: {:reply, s.devices, s}

  # Ask the radio to remove the device; the actual departure comes back as a
  # {:zigbee, :device_left, _} event (handled below), where we prune our own state.
  def handle_call({:unpair, node}, _from, s) do
    reply =
      case Map.fetch(s.devices, node) do
        {:ok, %{eui64: eui}} -> Zigbee.remove_device(s.zb, node, eui)
        _ -> {:error, :unknown_device}
      end

    {:reply, reply, s}
  end

  @impl true
  # A device joined, remember it and set up temperature/humidity reporting.
  def handle_info({:zigbee, :device_joined, %{node_id: node, eui64: eui}}, s) do
    Logger.info("SensorHub: device 0x#{Integer.to_string(node, 16)} joined")
    s = %{s | devices: Map.put(s.devices, node, %{eui64: eui})}
    {:noreply, configure_sensor(s, node, eui)}
  end

  # A report arrived, decode it and store the latest reading.
  def handle_info(
        {:zigbee, :message, %Message{profile: @ha_profile, source: node, cluster: cluster, payload: payload}},
        s
      )
      when cluster in @report_clusters do
    {:noreply, store_report(s, node, cluster, payload)}
  end

  # A device left (unpaired, or it left on its own), forget it and its readings.
  def handle_info({:zigbee, :device_left, %{node_id: node}}, s) do
    Logger.info("SensorHub: device 0x#{Integer.to_string(node, 16)} left")
    {:noreply, %{s | devices: Map.delete(s.devices, node), readings: Map.delete(s.readings, node)}}
  end

  # ZDO acks and anything else we don't care about.
  def handle_info({:zigbee, :message, _msg}, s), do: {:noreply, s}
  def handle_info(_other, s), do: {:noreply, s}

  # ── Internals ──────────────────────────────────────────────────────────────

  # Fire-and-forget bind + configure-reporting for each report cluster. Assumes
  # the sensor is on endpoint 1, a fuller hub would ZDO-interview the endpoints
  # first (see Zigbee.Interview for that logic).
  defp configure_sensor(s, node, eui) do
    Enum.reduce(@report_clusters, s, fn cluster, s ->
      # bind: make the device deliver this cluster to us (ZDO, profile 0x0000)
      {bind_seq, s} = next(s)
      bind = ZDO.bind_request(bind_seq, eui, 1, cluster, s.coord_eui64, 1)
      _ = Zigbee.send_aps(s.zb, node, @zdo_profile, ZDO.bind_cluster(), 0, bind, src_endpoint: 0)

      # configure reporting: temperature is int16 (0x29), humidity uint16 (0x21)
      {cfg_seq, s} = next(s)
      type = if cluster == @temperature, do: 0x29, else: 0x21
      rec = %{attr_id: 0x0000, type: type, min: 30, max: 300, change: 10}
      _ = Zigbee.send_aps(s.zb, node, @ha_profile, cluster, 1, ZCL.configure_reporting(cfg_seq, [rec]))

      s
    end)
  end

  defp store_report(s, node, cluster, payload) do
    # After re-establishing, devices reconnect without a fresh join event, track any
    # node we hear a report from so `devices/0` reflects it. (A fuller hub could instead
    # read the NCP's child/address table on restart to repopulate the list eagerly.)
    s = %{s | devices: Map.put_new(s.devices, node, %{})}

    case ZCL.decode(payload) do
      {:ok, %{command_name: :report_attributes, payload: reports}} ->
        Enum.reduce(reports, s, fn %{value: raw}, s ->
          {value, unit} =
            case cluster do
              @temperature -> {ZCL.temperature_c(raw), "°C"}
              @humidity -> {ZCL.humidity_pct(raw), "%"}
            end

          Logger.info("SensorHub: 0x#{Integer.to_string(node, 16)} #{value}#{unit}")
          reading = %{value: value, unit: unit, at: DateTime.utc_now()}
          per_node = s.readings |> Map.get(node, %{}) |> Map.put(cluster, reading)
          %{s | readings: Map.put(s.readings, node, per_node)}
        end)

      _ ->
        s
    end
  end

  # A tiny transaction-sequence source (wraps at 255) held in state.
  defp next(s), do: {rem(s.seq, 256), %{s | seq: s.seq + 1}}
end

# Loading this file just defines the module. To try it live:
#
#     {:ok, _pid} = SensorHub.start_link(device: "/dev/ttyACM0", speed: 460_800, channel: 15)
#     SensorHub.open_joining(120)   # put a device into pairing mode
#     Process.sleep(60_000)
#     SensorHub.readings()
