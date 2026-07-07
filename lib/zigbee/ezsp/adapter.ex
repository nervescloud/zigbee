defmodule Zigbee.EZSP.Adapter do
  @moduledoc """
  `Zigbee.Adapter` backend for Silicon Labs EmberZNet dongles (EZSP over ASH).

  Owns a `Zigbee.EZSP` connection, runs the EmberZNet-specific coordinator
  sequence (form, endpoints, unicast), and normalizes the NCP's unsolicited
  callbacks into the backend-neutral events `Zigbee.Adapter` promises:

      {:zigbee, :device_joined, %{node_id: _, eui64: _}}   # trustCenterJoinHandler
      {:zigbee, :message, %Zigbee.Message{}}                # incomingMessageHandler

  Start it through the `Zigbee` facade:

      {:ok, zb} = Zigbee.start_link(Zigbee.EZSP.Adapter, device: "/dev/ttyACM0", speed: 460_800)
  """

  @behaviour Zigbee.Adapter
  use GenServer
  import Bitwise
  require Logger

  alias Zigbee.EZSP
  alias Zigbee.EZSP.Status
  alias Zigbee.Message

  # ── EZSP enum constants (EmberZNet) ───────────────────────────────────────
  @config_stack_profile 0x0C
  @config_security_level 0x0D
  @policy_trust_center 0x00
  @policy_tc_key_request 0x09
  @policy_app_key_request 0x0A
  @decision_allow_joins 0x03
  @decision_allow_tc_key_requests 0x50
  @decision_deny_app_key_requests 0x60
  # HAVE_PRECONFIGURED_KEY|HAVE_NETWORK_KEY|REQUIRE_ENCRYPTED_KEY|TC_GLOBAL_LINK_KEY
  @security_bitmask 0x0F04
  @global_tc_link_key "ZigBeeAlliance09"
  # EmberApsOption: RETRY (0x0040) | ENABLE_ROUTE_DISCOVERY (0x0100).
  @aps_default_options 0x0140
  @ha_profile 0x0104

  @stack_status_frame 0x0019
  @join_frame 0x0024
  @incoming_frame 0x0045
  @network_up 0x90
  # EmberStatus NOT_JOINED, networkInit's answer when no network is stored.
  @not_joined 0x93
  @network_up_timeout 10_000

  # ── Zigbee.Adapter API ────────────────────────────────────────────────────

  @impl Zigbee.Adapter
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl Zigbee.Adapter
  def info(a), do: GenServer.call(a, :info)

  @impl Zigbee.Adapter
  def subscribe(a, pid), do: GenServer.call(a, {:subscribe, pid})

  @impl Zigbee.Adapter
  def form_network(a, opts), do: GenServer.call(a, {:form_network, opts}, 20_000)

  @impl Zigbee.Adapter
  def reestablish_network(a, opts), do: GenServer.call(a, {:reestablish_network, opts}, 20_000)

  @impl Zigbee.Adapter
  def permit_joining(a, seconds), do: GenServer.call(a, {:permit_joining, seconds})

  @impl Zigbee.Adapter
  def add_endpoint(a, endpoint, profile, device_id, in_clusters, out_clusters),
    do:
      GenServer.call(a, {:add_endpoint, endpoint, profile, device_id, in_clusters, out_clusters})

  @impl Zigbee.Adapter
  def send_aps(a, node_id, profile, cluster, dst_endpoint, payload, opts),
    do: GenServer.call(a, {:send_aps, node_id, profile, cluster, dst_endpoint, payload, opts})

  @impl Zigbee.Adapter
  def identifier(a), do: GenServer.call(a, :identifier)

  @impl Zigbee.Adapter
  def reset_network(a), do: GenServer.call(a, :reset_network)

  # ── GenServer ─────────────────────────────────────────────────────────────

  @impl GenServer
  def init(opts) do
    ezsp_opts = Keyword.take(opts, [:device, :speed, :flow_control])

    case EZSP.start_link(ezsp_opts) do
      {:ok, ezsp} ->
        :ok = EZSP.subscribe(ezsp, self())
        {:ok, %{ezsp: ezsp, subscriber: nil, up_from: nil, up_timer: nil}}

      err ->
        {:stop, err}
    end
  end

  @impl GenServer
  def handle_call(:info, _from, s), do: {:reply, EZSP.info(s.ezsp), s}
  def handle_call({:subscribe, pid}, _from, s), do: {:reply, :ok, %{s | subscriber: pid}}

  def handle_call({:permit_joining, seconds}, _from, s) do
    {:ok, %{params: <<status>>}} = EZSP.command(s.ezsp, :permit_joining, <<seconds>>)
    {:reply, check(status, :permit_joining), s}
  end

  def handle_call(:reset_network, _from, s) do
    {:ok, %{params: <<status>>}} = EZSP.command(s.ezsp, :leave_network, <<>>)
    {:reply, check(status, :reset_network), s}
  end

  def handle_call(:identifier, _from, s) do
    {:ok, %{params: <<eui::binary-8>>}} = EZSP.command(s.ezsp, :get_eui64, <<>>)
    {:reply, {:ok, eui}, s}
  end

  def handle_call({:add_endpoint, ep, profile, device_id, ins, outs}, _from, s),
    do: {:reply, do_add_endpoint(s.ezsp, ep, profile, device_id, ins, outs), s}

  def handle_call({:send_aps, node_id, profile, cluster, dst_ep, payload, opts}, _from, s),
    do: {:reply, do_send_aps(s.ezsp, node_id, profile, cluster, dst_ep, payload, opts), s}

  # form_network / reestablish_network defer their reply until NETWORK_UP arrives (or times out).
  def handle_call({:form_network, opts}, from, s) do
    case run_form_setup(s.ezsp, opts) do
      :ok -> {:noreply, await_network_up(s, from)}
      {:error, _} = err -> {:reply, err, s}
    end
  end

  def handle_call({:reestablish_network, opts}, from, s) do
    case prepare_reestablish(s.ezsp, opts) do
      # networkInit accepted: the stored network is coming up, wait for NETWORK_UP.
      {:ok, 0x00} -> {:noreply, await_network_up(s, from)}
      # nothing stored, the caller can decide to form instead.
      {:ok, @not_joined} -> {:reply, {:error, :no_network}, s}
      {:ok, other} -> {:reply, {:error, {:network_init, Status.decode(other)}}, s}
      {:error, _} = err -> {:reply, err, s}
    end
  end

  @impl GenServer
  def handle_info(
        {:ezsp_callback, %{frame_id: @stack_status_frame, params: <<@network_up>>}},
        %{up_from: from} = s
      )
      when from != nil do
    _ = Process.cancel_timer(s.up_timer)
    GenServer.reply(from, params(s.ezsp))
    {:noreply, %{s | up_from: nil, up_timer: nil}}
  end

  def handle_info(
        {:ezsp_callback, %{frame_id: @stack_status_frame, params: <<other>>}},
        %{up_from: from} = s
      )
      when from != nil do
    _ = Process.cancel_timer(s.up_timer)
    GenServer.reply(from, {:error, {:network_up, Status.decode(other)}})
    {:noreply, %{s | up_from: nil, up_timer: nil}}
  end

  def handle_info(:up_timeout, %{up_from: from} = s) when from != nil do
    GenServer.reply(from, {:error, {:network_up, :timeout}})
    {:noreply, %{s | up_from: nil, up_timer: nil}}
  end

  def handle_info({:ezsp_callback, frame}, s) do
    case normalize(frame) do
      {:ok, event} -> if s.subscriber, do: send(s.subscriber, event)
      :ignore -> :ok
    end

    {:noreply, s}
  end

  def handle_info(_msg, s), do: {:noreply, s}

  # ── Normalization: EZSP callback → neutral event ──────────────────────────

  defp normalize(%{frame_id: @join_frame, params: params}) do
    {:ok, {:zigbee, :device_joined, Map.take(decode_join(params), [:node_id, :eui64])}}
  end

  defp normalize(%{frame_id: @incoming_frame, params: params}) do
    {:ok, {:zigbee, :message, decode_incoming(params)}}
  end

  defp normalize(_frame), do: :ignore

  # trustCenterJoinHandler params.
  defp decode_join(<<node_id::little-16, eui64::binary-8, update, decision, parent::little-16>>) do
    %{node_id: node_id, eui64: eui64, update: update, decision: decision, parent_id: parent}
  end

  # incomingMessageHandler (0x0045) → %Zigbee.Message{}. NOTE: field order after
  # apsFrame is EZSP-version dependent (matches EZSP v9–v13); verify live.
  defp decode_incoming(
         <<_type, profile::little-16, cluster::little-16, src_ep, dst_ep, _options::little-16,
           group::little-16, aps_seq, lqi, rssi::signed-8, sender::little-16, _binding_index,
           _address_index, len, payload::binary-size(len)>>
       ) do
    %Message{
      source: sender,
      profile: profile,
      cluster: cluster,
      src_endpoint: src_ep,
      dst_endpoint: dst_ep,
      group: group,
      aps_seq: aps_seq,
      lqi: lqi,
      rssi: rssi,
      payload: payload
    }
  end

  # ── EZSP-specific coordinator sequence ────────────────────────────────────

  defp do_add_endpoint(ezsp, endpoint, profile, device_id, in_clusters, out_clusters) do
    in_list = for c <- in_clusters, into: <<>>, do: <<c::little-16>>
    out_list = for c <- out_clusters, into: <<>>, do: <<c::little-16>>

    params =
      <<endpoint, profile::little-16, device_id::little-16, 0x00, length(in_clusters),
        length(out_clusters), in_list::binary, out_list::binary>>

    {:ok, %{params: <<status>>}} = EZSP.command(ezsp, :add_endpoint, params)
    # addEndpoint returns EzspStatus (0x00 = success), not EmberStatus.
    if status == 0x00, do: :ok, else: {:error, {:add_endpoint, status}}
  end

  defp do_send_aps(ezsp, node_id, profile, cluster, dst_endpoint, payload, opts) do
    src_ep = Keyword.get(opts, :src_endpoint, 0x01)
    options = Keyword.get(opts, :options, @aps_default_options)
    tag = Keyword.get(opts, :tag, 0x00)

    aps =
      <<profile::little-16, cluster::little-16, src_ep, dst_endpoint, options::little-16,
        0x0000::little-16, 0x00>>

    params = <<0x00, node_id::little-16, aps::binary, tag, byte_size(payload), payload::binary>>

    {:ok, %{params: <<status, aps_seq>>}} = EZSP.command(ezsp, :send_unicast, params)
    if status == 0x00, do: {:ok, aps_seq}, else: {:error, {:send_unicast, Status.decode(status)}}
  end

  # Arm the deferred reply that form_network/reestablish_network complete on when NETWORK_UP arrives.
  defp await_network_up(s, from) do
    timer = Process.send_after(self(), :up_timeout, @network_up_timeout)
    %{s | up_from: from, up_timer: timer}
  end

  # Re-establish the stored network: (re)apply the per-boot config + endpoints (EZSP
  # config and endpoints are NOT persisted across NCP reboots), then networkInit.
  # Returns `{:ok, status}`, 0x00 = network coming up, 0x93 (NOT_JOINED) = none stored.
  defp prepare_reestablish(ezsp, opts) do
    endpoints = Keyword.get(opts, :endpoints, :default)

    with :ok <- set_config(ezsp, @config_stack_profile, 2),
         :ok <- set_config(ezsp, @config_security_level, 5),
         :ok <- register_endpoints(ezsp, endpoints) do
      {:ok, %{params: <<status>>}} = EZSP.command(ezsp, :network_init, <<0x0000::little-16>>)
      {:ok, status}
    end
  end

  # Everything except awaiting NETWORK_UP (which the GenServer does via a deferred
  # reply). Endpoints MUST be registered before form_network (addEndpoint after is
  # EzspStatus 0x38).
  defp run_form_setup(ezsp, opts) do
    ext_pan_id = Keyword.get(opts, :extended_pan_id, :crypto.strong_rand_bytes(8))
    pan_id = Keyword.get(opts, :pan_id, :rand.uniform(0xFFF0))
    tx_power = Keyword.get(opts, :tx_power, 8)
    channel = Keyword.get(opts, :channel, 15)
    network_key = Keyword.get(opts, :network_key, :crypto.strong_rand_bytes(16))
    endpoints = Keyword.get(opts, :endpoints, :default)

    with :ok <- set_config(ezsp, @config_stack_profile, 2),
         :ok <- set_config(ezsp, @config_security_level, 5),
         :ok <- register_endpoints(ezsp, endpoints),
         :ok <- set_security_state(ezsp, network_key),
         :ok <- set_policy(ezsp, @policy_trust_center, @decision_allow_joins),
         _ <- best_effort_policy(ezsp, @policy_tc_key_request, @decision_allow_tc_key_requests),
         _ <- best_effort_policy(ezsp, @policy_app_key_request, @decision_deny_app_key_requests) do
      do_form(ezsp, ext_pan_id, pan_id, tx_power, channel)
    end
  end

  defp register_endpoints(_ezsp, :none), do: :ok

  defp register_endpoints(ezsp, :default),
    do:
      do_add_endpoint(
        ezsp,
        0x01,
        @ha_profile,
        0x0005,
        [0x0000, 0x0001, 0x0402, 0x0405, 0x0006],
        []
      )

  defp register_endpoints(ezsp, list) when is_list(list) do
    Enum.reduce_while(list, :ok, fn {ep, profile, device_id, ins, outs}, :ok ->
      case do_add_endpoint(ezsp, ep, profile, device_id, ins, outs) do
        :ok -> {:cont, :ok}
        err -> {:halt, err}
      end
    end)
  end

  defp set_config(ezsp, config_id, value) do
    {:ok, %{params: <<status>>}} =
      EZSP.command(ezsp, :set_configuration_value, <<config_id, value::little-16>>)

    check(status, {:set_config, config_id})
  end

  defp set_policy(ezsp, policy_id, decision) do
    {:ok, %{params: <<status>>}} = EZSP.command(ezsp, :set_policy, <<policy_id, decision>>)
    check(status, {:set_policy, policy_id})
  end

  defp best_effort_policy(ezsp, policy_id, decision) do
    case set_policy(ezsp, policy_id, decision) do
      :ok ->
        :ok

      {:error, {_, status}} ->
        Logger.debug("policy 0x#{Integer.to_string(policy_id, 16)} not set (#{inspect(status)})")
    end
  end

  defp set_security_state(ezsp, network_key) do
    state =
      <<@security_bitmask::little-16, @global_tc_link_key::binary, network_key::binary-16, 0x00,
        0::64>>

    {:ok, %{params: <<status>>}} = EZSP.command(ezsp, :set_initial_security_state, state)
    check(status, :set_initial_security_state)
  end

  defp do_form(ezsp, ext_pan_id, pan_id, tx_power, channel) do
    params =
      <<ext_pan_id::binary-8, pan_id::little-16, tx_power::signed-8, channel, 0x00,
        0x0000::little-16, 0x00, 1 <<< channel::little-32>>

    {:ok, %{params: <<status>>}} = EZSP.command(ezsp, :form_network, params)
    check(status, :form_network)
  end

  defp params(ezsp) do
    {:ok, %{params: p}} = EZSP.command(ezsp, :get_network_parameters, <<>>)

    case p do
      <<0x00, node_type, ext::binary-8, pan_id::little-16, tx::signed-8, channel, _join_method,
        nwk_manager::little-16, nwk_update_id, channels::little-32>> ->
        {:ok,
         %{
           node_type: node_type,
           extended_pan_id: ext,
           pan_id: pan_id,
           tx_power: tx,
           channel: channel,
           nwk_manager_id: nwk_manager,
           nwk_update_id: nwk_update_id,
           channel_mask: channels
         }}

      <<status, _::binary>> ->
        {:error, {:get_network_parameters, Status.decode(status)}}
    end
  end

  defp check(0x00, _step), do: :ok
  defp check(status, step), do: {:error, {step, Status.decode(status)}}
end
