defmodule Zigbee.EZSP.Adapter do
  @moduledoc """
  `Zigbee.Adapter` backend for Silicon Labs EmberZNet dongles (EZSP over ASH).

  Owns a `Zigbee.EZSP` connection, runs the EmberZNet-specific coordinator
  sequence (config, security/keys, endpoints, policies, form/reestablish,
  unicast), and normalizes the NCP's unsolicited callbacks into the
  backend-neutral events `Zigbee.Adapter` promises:

      {:zigbee, :device_joined, %{node_id: _, eui64: _}}   # trustCenterJoinHandler
      {:zigbee, :message, %Zigbee.Message{}}                # incomingMessageHandler

  Start it through the `Zigbee` facade:

      {:ok, zb} = Zigbee.start_link(Zigbee.EZSP.Adapter, device: "/dev/ttyACM0", speed: 460_800)

  Tests may inject a pre-started EZSP process with the `:ezsp` option instead of a
  serial `:device` (see `Zigbee.FakeEZSP`).
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
  # TC / end-device config suite (mirrors zigbee-herdsman's ember driver). The TC
  # address cache is REQUIRED for the trust center to track joining devices' security
  # state — without it devices fail commissioning and rejoin-loop.
  @config_max_end_device_children 0x11
  @config_indirect_transmission_timeout 0x12
  @config_end_device_poll_timeout 0x13
  @config_tc_address_cache_size 0x19
  @config_transient_key_timeout_s 0x36
  # Zigbee MAC macTransactionPersistenceTime default (ms); overridable per network.
  @default_indirect_transmission_timeout 7680
  # EZSP policy IDs (EzspPolicyId). NOTE the correct values: TC_KEY_REQUEST is 0x05
  # and APP_KEY_REQUEST is 0x06. (Earlier this file used 0x09/0x0A — 0x09 is actually
  # TC_REJOINS_USING_WELL_KNOWN_KEY and 0x0A is a removed RF4CE policy that returns
  # ERROR_INVALID_ID, so the key-request policies were never actually applied.)
  @policy_trust_center 0x00
  @policy_tc_key_request 0x05
  @policy_app_key_request 0x06
  # EzspDecisionBitmask for the trust-center policy: ALLOW_JOINS|ALLOW_UNSECURED_REJOINS.
  @decision_allow_joins 0x03
  # EzspDecisionId for the key-request policies. 0x50 is DENY_TC_KEY_REQUESTS (the old
  # value here was wrong); 0x51 = ALLOW_TC_KEY_REQUESTS_AND_SEND_CURRENT_KEY.
  @decision_allow_tc_key_requests 0x51
  @decision_allow_app_key_requests 0x61
  # HAVE_PRECONFIGURED_KEY(0x0100) | HAVE_NETWORK_KEY(0x0200) |
  # REQUIRE_ENCRYPTED_KEY(0x0800) | TRUST_CENTER_USES_HASHED_LINK_KEY(0x0084).
  # Matches zigbee-herdsman's forming bitmask.
  #
  # Hashed link key (0x0084 = global-link-key 0x0004 + hashed 0x0080): the TC derives
  # each device's link key on the fly (no key-table storage; the ZBT-2 firmware has
  # KEY_TABLE_SIZE=0, which is normal for EmberZNet 7.x — keys live in the Security
  # Manager). Must NOT set GET_LINK_KEY_WHEN_JOINING (0x0400) — a joining-node flag
  # that is wrong on a coordinator.
  @security_bitmask 0x0B84
  @global_tc_link_key "ZigBeeAlliance09"
  # Wildcard EUI64 (all 0xFF) = a transient key usable by ANY joining device.
  @wildcard_eui64 <<0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF>>
  @sec_man_flag_none 0x00

  # Lumi/Aqara devices read the coordinator's Node Descriptor manufacturer code
  # during commissioning and LEAVE if it isn't Lumi's, causing a rejoin loop. When
  # a device with a Lumi OUI joins, set the coordinator's manufacturer code to match
  # (mirrors zigbee-herdsman's WORKAROUND_JOIN_MANUF_IEEE_PREFIX_TO_CODE). OUIs are
  # big-endian (the high 3 bytes of the EUI64).
  @lumi_manufacturer_code 0x115F
  @lumi_ouis [<<0x54, 0xEF, 0x44>>, <<0x04, 0xCF, 0x8C>>]
  # EmberApsOption: RETRY (0x0040) | ENABLE_ROUTE_DISCOVERY (0x0100).
  @aps_default_options 0x0140
  @ha_profile 0x0104

  @stack_status_frame 0x0019
  @join_frame 0x0024
  @incoming_frame 0x0045
  # EmberDeviceUpdate value in a trustCenterJoinHandler meaning the device LEFT the
  # network (0=secured rejoin, 1=unsecured join, 2=device left, 3=unsecured rejoin).
  @device_left 2
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
  def remove_device(a, node_id, eui64), do: GenServer.call(a, {:remove_device, node_id, eui64})

  @impl Zigbee.Adapter
  def identifier(a), do: GenServer.call(a, :identifier)

  @impl Zigbee.Adapter
  def reset_network(a), do: GenServer.call(a, :reset_network)

  # ── GenServer ─────────────────────────────────────────────────────────────

  @impl GenServer
  def init(opts) do
    case start_or_use_ezsp(opts) do
      {:ok, ezsp} ->
        :ok = EZSP.subscribe(ezsp, self())
        {:ok, %{ezsp: ezsp, subscriber: nil, up_from: nil, up_timer: nil}}

      err ->
        {:stop, err}
    end
  end

  # Use a caller-supplied EZSP process when `:ezsp` is given (e.g. a test double);
  # otherwise start a real one for the configured serial device.
  defp start_or_use_ezsp(opts) do
    case Keyword.get(opts, :ezsp) do
      nil -> EZSP.start_link(Keyword.take(opts, [:device, :speed, :flow_control]))
      ezsp -> {:ok, ezsp}
    end
  end

  @impl GenServer
  def handle_call(:info, _from, s), do: {:reply, EZSP.info(s.ezsp), s}
  def handle_call({:subscribe, pid}, _from, s), do: {:reply, :ok, %{s | subscriber: pid}}

  def handle_call({:permit_joining, seconds}, _from, s) do
    _ = import_well_known_transient_key(s.ezsp)
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

  def handle_call({:remove_device, node_id, eui64}, _from, s),
    do: {:reply, do_remove_device(s.ezsp, node_id, eui64), s}

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

  # Join frames get the Lumi manufacturer-code workaround applied before the
  # device_joined event is delivered.
  def handle_info({:ezsp_callback, %{frame_id: @join_frame, params: params} = frame}, s) do
    _ = maybe_apply_manuf_workaround(s.ezsp, decode_join(params))

    case normalize(frame) do
      {:ok, event} -> if s.subscriber, do: send(s.subscriber, event)
      :ignore -> :ok
    end

    {:noreply, s}
  end

  def handle_info({:ezsp_callback, frame}, s) do
    case normalize(frame) do
      {:ok, event} ->
        if s.subscriber, do: send(s.subscriber, event)

      :ignore ->
        # Unhandled NCP callback — logged at debug for troubleshooting (key updates,
        # route errors, etc). Add a dedicated clause above to handle one for real.
        Logger.debug(
          "EZSP cb 0x#{Integer.to_string(frame.frame_id, 16)} params=#{inspect(frame.params, base: :hex, limit: :infinity)}"
        )
    end

    {:noreply, s}
  end

  def handle_info(_msg, s), do: {:noreply, s}

  # ── Normalization: EZSP callback → neutral event ──────────────────────────

  defp normalize(%{frame_id: @join_frame, params: params}) do
    j = decode_join(params)
    # update = EmberDeviceUpdate (0=secured rejoin, 1=unsecured join, 2=device LEFT,
    # 3=unsecured rejoin); decision = the TC join decision. Handy for spotting
    # leave/rejoin loops.
    Logger.debug(
      "trustCenterJoin node=0x#{Integer.to_string(j.node_id, 16)} update=#{j.update} decision=#{j.decision}"
    )

    # A DEVICE_LEFT update is a departure, not a join — surface it as :device_left.
    event = if j.update == @device_left, do: :device_left, else: :device_joined
    {:ok, {:zigbee, event, Map.take(j, [:node_id, :eui64])}}
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
           _address_index, len, payload::binary-size(len), _rest::binary>>
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

  # removeDevice(destShort, destLong, targetLong): tell `node_id` (dest = the device
  # itself) to leave, using the trust-center link key. We're removing the device
  # itself, so destLong and targetLong are both its EUI64. The device's departure
  # comes back later as a trustCenterJoinHandler with update == DEVICE_LEFT, which we
  # normalize to a {:zigbee, :device_left, _} event.
  defp do_remove_device(ezsp, node_id, eui64) do
    params = <<node_id::little-16, eui64::binary-8, eui64::binary-8>>
    {:ok, %{params: <<status>>}} = EZSP.command(ezsp, :remove_device, params)
    check(status, :remove_device)
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

    with :ok <- apply_config(ezsp, opts),
         :ok <- register_endpoints(ezsp, endpoints),
         :ok <- apply_policies(ezsp) do
      {:ok, %{params: <<status>>}} = EZSP.command(ezsp, :network_init, <<0x0000::little-16>>)
      {:ok, status}
    end
  end

  # Trust-center + key-request policies. These are volatile (lost on every NCP
  # reset, like config and endpoints), so BOTH form and reestablish must set them.
  # App-key requests must be ALLOWED: Zigbee 3.0 devices (e.g. Aqara) request an
  # application link key from the TC after joining, and if it's denied they fail the
  # key update and — with REQUIRE_ENCRYPTED_KEY set — get removed, looping forever.
  defp apply_policies(ezsp) do
    with :ok <- set_policy(ezsp, @policy_trust_center, @decision_allow_joins) do
      best_effort_policy(ezsp, @policy_tc_key_request, @decision_allow_tc_key_requests)
      best_effort_policy(ezsp, @policy_app_key_request, @decision_allow_app_key_requests)
      :ok
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
    # The TC link key is the hashed-derivation master — it must be RANDOM and
    # distinct from the well-known join key (imported separately as a transient),
    # or the two collide in the NCP's key handling. Persisted in NCP tokens, so
    # reestablish restores it. Matches zigbee-herdsman's random tcLinkKey.
    tc_link_key = Keyword.get(opts, :tc_link_key, :crypto.strong_rand_bytes(16))
    endpoints = Keyword.get(opts, :endpoints, :default)

    with :ok <- apply_config(ezsp, opts),
         :ok <- register_endpoints(ezsp, endpoints),
         :ok <- set_security_state(ezsp, tc_link_key, network_key),
         :ok <- apply_policies(ezsp) do
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

  # Apply the base + TC/end-device config suite. Strict on stack profile + security
  # level (form fails without them); best-effort on the rest (some are fixed in NCP
  # firmware and can't be changed). Must run before form_network / network_init.
  defp apply_config(ezsp, opts) do
    with :ok <- set_config(ezsp, @config_stack_profile, 2),
         :ok <- set_config(ezsp, @config_security_level, 5) do
      best_effort_config(ezsp, @config_tc_address_cache_size, 2)
      best_effort_config(ezsp, @config_indirect_transmission_timeout, indirect_timeout(opts))
      best_effort_config(ezsp, @config_end_device_poll_timeout, 8)
      best_effort_config(ezsp, @config_transient_key_timeout_s, 300)
      best_effort_config(ezsp, @config_max_end_device_children, 32)
      :ok
    end
  end

  # Indirect transmission timeout (ms): how long the coordinator buffers a unicast for a sleepy
  # end device to collect on its next poll before discarding it. Defaults to the Zigbee MAC spec's
  # `macTransactionPersistenceTime` (7680 ms); raise it (via the `:indirect_transmission_timeout`
  # option to form/reestablish) so buffered frames survive longer poll gaps on very sleepy devices.
  # Clamped to the EZSP field's uint16 range.
  defp indirect_timeout(opts) do
    case Keyword.get(opts, :indirect_transmission_timeout, @default_indirect_transmission_timeout) do
      v when is_integer(v) -> v |> max(0) |> min(0xFFFF)
      _ -> @default_indirect_transmission_timeout
    end
  end

  defp best_effort_config(ezsp, id, value) do
    case set_config(ezsp, id, value) do
      :ok ->
        :ok

      {:error, {_, status}} ->
        Logger.debug("config 0x#{Integer.to_string(id, 16)} not set (#{inspect(status)})")
    end
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

  # Install the well-known 'ZigBeeAlliance09' key as a transient link key so a
  # joining device can authenticate its initial join. REQUIRED in hashed-link-key
  # mode: the preconfigured key is only the derivation master, so without the plain
  # well-known key present the TC can't authenticate the join and the device
  # rejoin-loops. Mirrors zigbee-herdsman's importTransientKey on permit-join.
  defp import_well_known_transient_key(ezsp) do
    params = @wildcard_eui64 <> @global_tc_link_key <> <<@sec_man_flag_none>>

    case EZSP.command(ezsp, :import_transient_key, params) do
      {:ok, %{params: <<0x00, 0x00, 0x00, 0x00>>}} ->
        :ok

      {:ok, %{params: <<status::little-32>>}} ->
        Logger.warning("importTransientKey sl_status 0x#{Integer.to_string(status, 16)}")

      other ->
        Logger.warning("importTransientKey failed: #{inspect(other)}")
    end
  end

  # Skip on DEVICE_LEFT (update == 2); otherwise set the coordinator's manufacturer
  # code to Lumi's if the joining device has a Lumi OUI. eui64 is wire order (LE), so
  # the OUI is the last 3 bytes reversed.
  defp maybe_apply_manuf_workaround(_ezsp, %{update: @device_left}), do: :ok

  defp maybe_apply_manuf_workaround(ezsp, %{eui64: <<_::binary-5, b6, b7, b8>>}) do
    oui = <<b8, b7, b6>>

    if oui in @lumi_ouis do
      case EZSP.command(ezsp, :set_manufacturer_code, <<@lumi_manufacturer_code::little-16>>) do
        {:ok, _} ->
          Logger.info(
            "[workaround] coordinator manufacturer code -> 0x#{Integer.to_string(@lumi_manufacturer_code, 16)} for Lumi/Aqara join"
          )

        other ->
          Logger.warning("setManufacturerCode failed: #{inspect(other)}")
      end
    else
      :ok
    end
  end

  defp set_security_state(ezsp, tc_link_key, network_key) do
    state =
      <<@security_bitmask::little-16, tc_link_key::binary-16, network_key::binary-16, 0x00,
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
