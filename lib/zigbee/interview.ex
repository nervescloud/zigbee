defmodule Zigbee.Interview do
  @moduledoc """
  Orchestrates the join → interview → bind → report flow for a device that has
  joined the coordinator's network.

  It is **backend-agnostic**: it drives a `Zigbee.Adapter` through the `Zigbee`
  facade and consumes only normalized events, so it works over any radio. The
  calling process must be the adapter's subscriber (`Zigbee.subscribe/2`) so
  `{:zigbee, :device_joined, _}` and `{:zigbee, :message, %Zigbee.Message{}}`
  arrive here.

  Typical use:

      {:ok, zb} = Zigbee.start_link(Zigbee.EZSP.Adapter, device: "/dev/ttyACM0", speed: 460_800)
      {:ok, _} = Zigbee.form_network(zb)   # registers the default HA endpoint too
      :ok = Zigbee.subscribe(zb, self())

      {:ok, dev} = Zigbee.Interview.open_and_wait(zb)          # press pair on the sensor
      {:ok, report} = Zigbee.Interview.run(zb, dev.node_id, dev.eui64)
      Zigbee.Interview.collect(zb, 60_000)                     # watch temp/humidity reports

  NOTE: the flow is written against the spec but has not yet been exercised
  against live Zigbee end-devices, so expect to tune Aqara-specific quirks (some
  devices need a Basic-cluster read after binding before they report).
  """

  alias Zigbee.{ZDO, ZCL, Message}

  # Zigbee application profiles (spec constants).
  @zdo_profile 0x0000
  @ha_profile 0x0104

  @temperature_cluster 0x0402
  @humidity_cluster 0x0405
  @report_clusters [@temperature_cluster, @humidity_cluster]

  @doc """
  Open the network for joining and block until a device joins, returning
  `%{node_id, eui64}` (or `{:error, :timeout}`).
  """
  def open_and_wait(zb, duration \\ 180, timeout \\ 180_000) do
    :ok = Zigbee.permit_joining(zb, duration)

    receive do
      {:zigbee, :device_joined, dev} -> {:ok, Map.take(dev, [:node_id, :eui64])}
    after
      timeout -> {:error, :timeout}
    end
  end

  @doc """
  Interview `node_id`: enumerate endpoints, read each simple descriptor, then
  bind + configure reporting for every temperature/humidity cluster found.
  """
  def run(zb, node_id, device_eui64, opts \\ []) do
    {:ok, coord_eui64} = Zigbee.identifier(zb)
    seq = :counters.new(1, [])

    with {:ok, endpoints} <- active_endpoints(zb, node_id, next(seq)),
         {:ok, descriptors} <- descriptors(zb, node_id, endpoints, seq),
         bindings <-
           bind_and_report(zb, node_id, device_eui64, coord_eui64, descriptors, seq, opts) do
      {:ok, %{endpoints: endpoints, descriptors: descriptors, bindings: bindings}}
    end
  end

  @doc """
  Collect and decode incoming Report Attributes for `duration_ms`, returning a
  list of `%{cluster, endpoint, attr_id, value, unit}` (temperature in °C,
  humidity in %).
  """
  def collect(_zb, duration_ms \\ 60_000) do
    deadline = System.monotonic_time(:millisecond) + duration_ms
    do_collect(deadline, [])
  end

  # ── ZDO steps ───────────────────────────────────────────────────────────────

  defp active_endpoints(zb, node_id, zdo_seq) do
    payload = ZDO.active_endpoints_request(zdo_seq, node_id)

    with {:ok, _} <- zdo_send(zb, node_id, ZDO.active_endpoints_cluster(), payload),
         {:ok, resp} <- await_zdo(ZDO.response_cluster(ZDO.active_endpoints_cluster()), zdo_seq),
         {:ok, decoded} <- ZDO.decode_active_endpoints_response(resp) do
      {:ok, decoded.endpoints}
    end
  end

  defp descriptors(zb, node_id, endpoints, seq) do
    Enum.reduce_while(endpoints, {:ok, []}, fn ep, {:ok, acc} ->
      zdo_seq = next(seq)
      payload = ZDO.simple_descriptor_request(zdo_seq, node_id, ep)

      with {:ok, _} <- zdo_send(zb, node_id, ZDO.simple_descriptor_cluster(), payload),
           {:ok, resp} <-
             await_zdo(ZDO.response_cluster(ZDO.simple_descriptor_cluster()), zdo_seq),
           {:ok, desc} <- ZDO.decode_simple_descriptor_response(resp) do
        {:cont, {:ok, [desc | acc]}}
      else
        err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, list} -> {:ok, Enum.reverse(list)}
      err -> err
    end
  end

  # For every reportable cluster present on an endpoint, bind it to us then ask
  # the device to report it.
  defp bind_and_report(zb, node_id, dev_eui64, coord_eui64, descriptors, seq, opts) do
    min = Keyword.get(opts, :min_interval, 30)
    max = Keyword.get(opts, :max_interval, 300)

    for %{endpoint: ep, in_clusters: in_clusters} <- descriptors,
        cluster <- @report_clusters,
        cluster in in_clusters do
      bind_seq = next(seq)
      bind_payload = ZDO.bind_request(bind_seq, dev_eui64, ep, cluster, coord_eui64, 0x01)
      _ = zdo_send(zb, node_id, ZDO.bind_cluster(), bind_payload)
      bind_status = await_zdo(ZDO.response_cluster(ZDO.bind_cluster()), bind_seq)

      # int16 for temperature, uint16 for humidity; reportable change of ~0.1 unit.
      {type, change} = if cluster == @temperature_cluster, do: {0x29, 10}, else: {0x21, 10}
      rec = %{attr_id: 0x0000, type: type, min: min, max: max, change: change}
      zcl = ZCL.configure_reporting(next_byte(seq), [rec])
      _ = Zigbee.send_aps(zb, node_id, @ha_profile, cluster, ep, zcl)

      %{endpoint: ep, cluster: cluster, bind: bind_status}
    end
  end

  # ── Send / await helpers ─────────────────────────────────────────────────────

  # ZDO requests: profile 0x0000, source + destination endpoint 0.
  defp zdo_send(zb, node_id, cluster, payload) do
    Zigbee.send_aps(zb, node_id, @zdo_profile, cluster, 0x00, payload, src_endpoint: 0x00)
  end

  # Await an incoming ZDO response on the ZDO profile matching cluster + seq.
  defp await_zdo(response_cluster, zdo_seq, timeout \\ 5_000) do
    receive do
      {:zigbee, :message,
       %Message{
         profile: @zdo_profile,
         cluster: ^response_cluster,
         payload: <<^zdo_seq, _::binary>> = payload
       }} ->
        {:ok, payload}

      {:zigbee, :message, _other} ->
        await_zdo(response_cluster, zdo_seq, timeout)
    after
      timeout -> {:error, {:zdo_timeout, response_cluster}}
    end
  end

  defp do_collect(deadline, acc) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      Enum.reverse(acc)
    else
      receive do
        {:zigbee, :message, %Message{} = msg} -> do_collect(deadline, interpret(msg) ++ acc)
      after
        remaining -> Enum.reverse(acc)
      end
    end
  end

  # Turn a Report Attributes frame into engineering-unit readings.
  defp interpret(%Message{
         profile: @ha_profile,
         cluster: cluster,
         src_endpoint: ep,
         payload: payload
       }) do
    case ZCL.decode(payload) do
      {:ok, %{command_name: :report_attributes, payload: reports}} ->
        for %{attr_id: attr, value: value} <- reports do
          {v, unit} =
            case cluster do
              @temperature_cluster -> {ZCL.temperature_c(value), "°C"}
              @humidity_cluster -> {ZCL.humidity_pct(value), "%"}
              _ -> {value, nil}
            end

          %{cluster: cluster, endpoint: ep, attr_id: attr, value: v, unit: unit}
        end

      _ ->
        []
    end
  end

  defp interpret(_), do: []

  # A tiny sequence source shared by ZDO transaction numbers and ZCL frames.
  defp next(counter) do
    :counters.add(counter, 1, 1)
    rem(:counters.get(counter, 1), 256)
  end

  defp next_byte(counter), do: next(counter)
end
