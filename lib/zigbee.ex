defmodule Zigbee do
  @moduledoc """
  A from-scratch, pure-Elixir Zigbee stack.

  This module is the backend-agnostic public API. You open a chip backend (which
  implements `Zigbee.Adapter`) and then drive it through these functions. The
  same calls work no matter which radio is underneath.

  ## Quick start

  Open the radio, form a coordinator network, then pair and read a sensor:

      # 1. open the dongle (Silicon Labs EmberZNet backend) and become its subscriber
      {:ok, zb} = Zigbee.start_link(Zigbee.EZSP.Adapter, device: "/dev/ttyACM0", speed: 460_800)
      :ok = Zigbee.subscribe(zb, self())

      # 2. form a coordinator network (also registers the default HA endpoint)
      {:ok, params} = Zigbee.form_network(zb, channel: 15)

      # 3. open joining and wait for a device (put the device into pairing mode now)
      {:ok, dev} = Zigbee.Interview.open_and_wait(zb)

      # 4. interview it: enumerate endpoints, bind + configure reporting for temp/humidity
      {:ok, _report} = Zigbee.Interview.run(zb, dev.node_id, dev.eui64)

      # 5. watch the readings roll in (°C / %)
      Zigbee.Interview.collect(zb, 60_000)
      #=> [%{cluster: 0x0402, endpoint: 1, value: 21.4, unit: "°C"}, ...]

  ## Events

  The subscriber (set with `subscribe/2`) receives backend-neutral events:

      {:zigbee, :device_joined, %{node_id: _, eui64: _}}
      {:zigbee, :device_left,   %{node_id: _, eui64: _}}
      {:zigbee, :message, %Zigbee.Message{}}

  `Zigbee.Interview` consumes these for you; consume them yourself only for custom
  flows. See `Zigbee.Interview` for pairing, `Zigbee.ZCL` / `Zigbee.ZDO` for the
  wire codecs, and `Zigbee.Adapter` for writing a new radio backend.
  """

  alias Zigbee.Adapter

  @doc """
  Start a radio `backend` (a module implementing `Zigbee.Adapter`, e.g.
  `Zigbee.EZSP.Adapter`) and wrap it in a handle used by every other function here.

  `opts` are passed to the backend. For `Zigbee.EZSP.Adapter`: `:device` (serial
  port) and `:speed` (baud, 460_800 for the ZBT-2).
  """
  @spec start_link(module(), keyword()) :: {:ok, Adapter.t()} | {:error, term()}
  def start_link(backend, opts \\ []) when is_atom(backend) do
    with {:ok, ref} <- backend.start_link(opts) do
      {:ok, %Adapter{module: backend, ref: ref}}
    end
  end

  @doc "Wrap an already-started backend process in a handle."
  @spec wrap(module(), Adapter.ref()) :: Adapter.t()
  def wrap(backend, ref), do: %Adapter{module: backend, ref: ref}

  @doc "Radio/stack info (e.g. `%{protocol_version: 13, stack_version: \"7.5.1.0\"}`)."
  def info(%Adapter{module: m, ref: r}), do: m.info(r)

  @doc """
  Register `pid` (default: the caller) to receive the normalized `{:zigbee, _}`
  events. Do this before `Zigbee.Interview` calls so join/message events reach it.
  """
  def subscribe(%Adapter{module: m, ref: r}, pid \\ self()), do: m.subscribe(r, pid)

  @doc """
  Form a centralized (trust-center) coordinator network and return its parameters.

  Options (all optional): `:channel` (11..26, default 15), `:pan_id`,
  `:extended_pan_id` (8 bytes), `:tx_power` (dBm), `:network_key` (16 bytes),
  `:tc_link_key` (16 bytes, the trust-center link-key derivation master; random by
  default), `:endpoints` (`:default` registers HA endpoint 1, `:none`, or a
  list of `{endpoint, profile, device_id, in_clusters, out_clusters}`), and
  `:indirect_transmission_timeout` (see below). Endpoints are registered here because
  they must exist before the network comes up.

  ## `:indirect_transmission_timeout`

  Milliseconds the coordinator buffers a unicast for a *sleepy* end device to collect
  on its next poll before discarding it (0..65535, default `7680` — the Zigbee MAC
  spec's `macTransactionPersistenceTime`). Raise it so buffered frames (attribute
  reads, binds, configure-reporting, leaves) survive longer poll gaps on very sleepy
  devices, at the cost of holding NCP packet buffers longer. It's volatile NCP config,
  re-applied on every `form_network/2` and `reestablish_network/2`, so pass it on both.
  """
  def form_network(%Adapter{module: m, ref: r}, opts \\ []), do: m.form_network(r, opts)

  @doc """
  Re-establish the network already stored on the radio (via networkInit),
  re-registering endpoints first. Returns `{:ok, params}`, or `{:error, :no_network}`
  if nothing is stored. Use this on restart (not `form_network/2`): forming makes a
  *new* network (new key) and orphans already-paired devices.

  Accepts the same volatile-config options as `form_network/2` (e.g. `:endpoints`,
  `:indirect_transmission_timeout`), which are re-applied to the NCP on each restart.
  """
  def reestablish_network(%Adapter{module: m, ref: r}, opts \\ []),
    do: m.reestablish_network(r, opts)

  @doc """
  Re-establish the stored network, or form a fresh one if there is none. The right
  bring-up for a long-running coordinator: rejoins existing devices when possible,
  forms only on first run. See "Persistence & restart" in the README.
  """
  def reestablish_or_form_network(%Adapter{} = handle, opts \\ []) do
    case reestablish_network(handle, opts) do
      {:error, :no_network} -> form_network(handle, opts)
      other -> other
    end
  end

  @doc "Open the network for joining for `seconds` (0..254; 255 = no timeout)."
  def permit_joining(%Adapter{module: m, ref: r}, seconds \\ 180),
    do: m.permit_joining(r, seconds)

  @doc """
  Register an application endpoint. Rarely needed directly; `form_network/2`
  registers the default endpoint. Must be called before the network is up.
  """
  def add_endpoint(
        %Adapter{module: m, ref: r},
        endpoint,
        profile,
        device_id,
        in_clusters,
        out_clusters
      ),
      do: m.add_endpoint(r, endpoint, profile, device_id, in_clusters, out_clusters)

  @doc """
  Send a direct APS unicast to `node_id` and return `{:ok, aps_seq}`. `payload` is
  a raw APS payload. Build it with `Zigbee.ZCL` (on an application profile like
  `0x0104`) or `Zigbee.ZDO` (on profile `0x0000`). `opts`: `:src_endpoint`
  (default 1). `Zigbee.Interview` uses this under the hood.
  """
  def send_aps(
        %Adapter{module: m, ref: r},
        node_id,
        profile,
        cluster,
        dst_endpoint,
        payload,
        opts \\ []
      ),
      do: m.send_aps(r, node_id, profile, cluster, dst_endpoint, payload, opts)

  @doc """
  Remove (unpair) a paired device: instruct it to leave the network and drop it
  from the coordinator. `node_id` is the device's 16-bit network address and
  `eui64` its raw 8-byte little-endian IEEE address (both known from the join /
  interview, e.g. the `%{node_id, eui64}` from `Zigbee.Interview.open_and_wait/3`).

  Returns `:ok` once the radio accepts the request. This is coordinator-driven and
  authenticated with the trust-center link key, so it's more robust than an
  app-level leave; the device's actual departure arrives asynchronously as a
  `{:zigbee, :device_left, %{node_id: _, eui64: _}}` event to the subscriber. A
  device that is offline when removed is dropped from the coordinator's tables and
  will not be readmitted with its old key, but won't leave over the air until it is
  reachable again.
  """
  def remove_device(%Adapter{module: m, ref: r}, node_id, eui64),
    do: m.remove_device(r, node_id, eui64)

  @doc """
  The coordinator's own identifier: its 64-bit IEEE 802.15.4 extended address
  (EUI64), the radio's permanent, globally-unique hardware address, like a MAC
  address. Returned as a raw 8-byte little-endian binary (wire order).

  Unlike a node's 16-bit network address (the coordinator's is always `0x0000`),
  the identifier never changes. Devices bind their clusters to it, so it's the
  stable identity that lets `reestablish_network/2` bring paired devices back after
  a restart with no re-pairing.
  """
  def identifier(%Adapter{module: m, ref: r}), do: m.identifier(r)

  @doc """
  Reset the coordinator: leave / tear down the current network, clearing the
  network state stored on the radio. The next bring-up must `form_network/2`.
  """
  def reset_network(%Adapter{module: m, ref: r}), do: m.reset_network(r)
end
