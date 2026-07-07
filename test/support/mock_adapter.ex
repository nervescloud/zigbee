defmodule Zigbee.MockAdapter do
  @moduledoc """
  An in-memory `Zigbee.Adapter` backend for tests — a tiny fake device with no
  hardware. It answers ZDO interview requests (active endpoints, simple
  descriptor, bind) by emitting the matching `{:zigbee, :message, %Zigbee.Message{}}`
  to its subscriber, so `Zigbee.Interview` can be exercised end-to-end without a
  radio. `emit_join/3` fakes a device-join event.

  Configure via `start_link/1` opts: `:node_id`, `:eui64`, and `:descriptors`
  (`%{endpoint => %{profile, device, in_clusters, out_clusters}}`).
  """

  @behaviour Zigbee.Adapter
  use GenServer

  alias Zigbee.Message

  # ── behaviour ──────────────────────────────────────────────────────────────
  @impl Zigbee.Adapter
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
  @impl Zigbee.Adapter
  def info(a), do: GenServer.call(a, :info)
  @impl Zigbee.Adapter
  def subscribe(a, pid), do: GenServer.call(a, {:subscribe, pid})
  @impl Zigbee.Adapter
  def form_network(a, _opts), do: GenServer.call(a, :form_network)
  @impl Zigbee.Adapter
  def reestablish_network(a, _opts), do: GenServer.call(a, :reestablish_network)
  @impl Zigbee.Adapter
  def permit_joining(_a, _seconds), do: :ok
  @impl Zigbee.Adapter
  def add_endpoint(_a, _ep, _profile, _device, _ins, _outs), do: :ok
  @impl Zigbee.Adapter
  def send_aps(a, node_id, profile, cluster, dst_ep, payload, opts),
    do: GenServer.call(a, {:send_aps, node_id, profile, cluster, dst_ep, payload, opts})

  @impl Zigbee.Adapter
  def identifier(a), do: GenServer.call(a, :identifier)
  @impl Zigbee.Adapter
  def reset_network(_a), do: :ok

  @doc "Fake a device-join event to the subscriber."
  def emit_join(a, node_id, eui64), do: GenServer.call(a, {:emit_join, node_id, eui64})

  # ── GenServer ──────────────────────────────────────────────────────────────
  @impl GenServer
  def init(opts) do
    {:ok,
     %{
       subscriber: nil,
       node_id: Keyword.get(opts, :node_id, 0x1234),
       eui64: Keyword.get(opts, :eui64, <<1, 2, 3, 4, 5, 6, 7, 8>>),
       descriptors: Keyword.get(opts, :descriptors, %{}),
       # when true, reestablish_network/2 succeeds (a network is "stored"); else none
       has_network: Keyword.get(opts, :has_network, false)
     }}
  end

  @impl GenServer
  def handle_call(:info, _from, s), do: {:reply, %{backend: :mock}, s}
  def handle_call({:subscribe, pid}, _from, s), do: {:reply, :ok, %{s | subscriber: pid}}

  def handle_call(:form_network, _from, s),
    do: {:reply, {:ok, %{channel: 15, pan_id: 0x1234, source: :formed}}, s}

  def handle_call(:reestablish_network, _from, s) do
    if s.has_network,
      do: {:reply, {:ok, %{channel: 15, pan_id: 0xABCD, source: :reestablished}}, s},
      else: {:reply, {:error, :no_network}, s}
  end

  def handle_call(:identifier, _from, s),
    do: {:reply, {:ok, <<0xAA, 0xBB, 0xCC, 0xDD, 0, 0, 0, 0>>}, s}

  def handle_call({:emit_join, node_id, eui64}, _from, s) do
    send(s.subscriber, {:zigbee, :device_joined, %{node_id: node_id, eui64: eui64}})
    {:reply, :ok, s}
  end

  # ZDO requests get a synchronous fake reply emitted to the subscriber.
  def handle_call({:send_aps, _node, 0x0000, cluster, _dst, payload, _opts}, _from, s) do
    if resp = zdo_reply(cluster, payload, s), do: send(s.subscriber, {:zigbee, :message, resp})
    {:reply, {:ok, 0x00}, s}
  end

  # Non-ZDO (e.g. ZCL configure reporting): just acknowledge.
  def handle_call({:send_aps, _node, _profile, _cluster, _dst, _payload, _opts}, _from, s),
    do: {:reply, {:ok, 0x00}, s}

  # ── fake ZDO device ──────────────────────────────────────────────────────
  # Active Endpoints request (0x0005) → response (0x8005).
  defp zdo_reply(0x0005, <<seq, _node::little-16>>, s) do
    eps = Map.keys(s.descriptors) |> Enum.sort()
    payload = <<seq, 0x00, s.node_id::little-16, length(eps)>> <> :binary.list_to_bin(eps)
    zdo_message(0x8005, payload)
  end

  # Simple Descriptor request (0x0004) → response (0x8004).
  defp zdo_reply(0x0004, <<seq, _node::little-16, ep>>, s) do
    d = Map.fetch!(s.descriptors, ep)
    ins = for c <- d.in_clusters, into: <<>>, do: <<c::little-16>>
    outs = for c <- d.out_clusters, into: <<>>, do: <<c::little-16>>

    desc =
      <<ep, d.profile::little-16, d.device::little-16, 0x01, length(d.in_clusters)>> <>
        ins <> <<length(d.out_clusters)>> <> outs

    zdo_message(0x8004, <<seq, 0x00, s.node_id::little-16, byte_size(desc)>> <> desc)
  end

  # Bind request (0x0021) → response (0x8021) success.
  defp zdo_reply(0x0021, <<seq, _rest::binary>>, _s), do: zdo_message(0x8021, <<seq, 0x00>>)
  defp zdo_reply(_cluster, _payload, _s), do: nil

  defp zdo_message(cluster, payload) do
    %Message{
      source: 0x1234,
      profile: 0x0000,
      cluster: cluster,
      src_endpoint: 0,
      dst_endpoint: 0,
      payload: payload
    }
  end
end
