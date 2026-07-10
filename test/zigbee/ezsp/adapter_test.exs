defmodule Zigbee.EZSP.AdapterTest do
  use ExUnit.Case, async: true

  alias Zigbee.EZSP.Adapter
  alias Zigbee.FakeEZSP

  # EZSP frame ids used in assertions.
  @set_config 0x53
  @add_endpoint 0x02
  @set_policy 0x55
  @set_initial_security_state 0x68
  @form_network 0x1E
  @network_init 0x17
  @permit_joining 0x22
  @import_transient_key 0x0111
  @set_manufacturer_code 0x15
  @join_frame 0x0024
  @incoming_frame 0x0045

  @not_joined 0x93
  @lumi_eui <<0x21, 0x2A, 0x28, 0x01, 0x10, 0x44, 0xEF, 0x54>>

  setup do
    {:ok, fake} = FakeEZSP.start_link()
    {:ok, adapter} = Adapter.start_link(ezsp: fake)
    :ok = Adapter.subscribe(adapter, self())
    %{fake: fake, adapter: adapter}
  end

  defp config_pairs(calls), do: for({@set_config, <<id, v::little-16>>} <- calls, do: {id, v})
  defp policy_pairs(calls), do: for({@set_policy, <<id, d>>} <- calls, do: {id, d})
  defp frame_ids(calls), do: Enum.map(calls, &elem(&1, 0))

  # A trustCenterJoinHandler payload: node_id, eui64, update, decision, parent.
  defp join_params(node_id, eui64, update),
    do: <<node_id::little-16, eui64::binary-8, update, 0x00, 0x00, 0x00>>

  describe "form_network" do
    test "applies config + endpoint + security + policies, then forms", %{
      fake: fake,
      adapter: adapter
    } do
      assert {:ok, params} =
               Adapter.form_network(adapter,
                 channel: 15,
                 network_key: <<0::128>>,
                 tc_link_key: <<1::128>>
               )

      assert params.channel == 15
      assert params.pan_id == 0xABCD

      calls = FakeEZSP.calls(fake)
      config = config_pairs(calls)
      # Base config + the TC/end-device suite (TC address cache is the key one).
      assert {0x0C, 2} in config
      assert {0x0D, 5} in config
      assert {0x19, 2} in config
      assert {0x12, 7680} in config
      assert {0x13, 8} in config
      assert {0x36, 300} in config
      assert {0x11, 32} in config

      # The corrected policy ids + decisions (the crown-jewel fix).
      policies = policy_pairs(calls)
      assert {0x00, 0x03} in policies
      assert {0x05, 0x51} in policies
      assert {0x06, 0x61} in policies
      # Guard against the old, broken values sneaking back.
      refute Enum.any?(policies, fn {id, _} -> id in [0x09, 0x0A] end)

      # Security state: hashed-link-key bitmask + our keys.
      assert <<bitmask::little-16, tclk::binary-16, nwk::binary-16, _seq, _tc::binary-8>> =
               FakeEZSP.call_params(fake, @set_initial_security_state)

      assert bitmask == 0x0B84
      assert tclk == <<1::128>>
      assert nwk == <<0::128>>

      # Endpoint registered before forming; form actually issued.
      ids = frame_ids(calls)
      assert @add_endpoint in ids
      assert @form_network in ids

      assert Enum.find_index(ids, &(&1 == @add_endpoint)) <
               Enum.find_index(ids, &(&1 == @form_network))
    end
  end

  describe "reestablish_network" do
    test "re-applies config + policies and inits the stored network", %{
      fake: fake,
      adapter: adapter
    } do
      assert {:ok, params} = Adapter.reestablish_network(adapter, endpoints: :default)
      assert params.channel == 15

      calls = FakeEZSP.calls(fake)
      assert {0x05, 0x51} in policy_pairs(calls)
      assert {0x06, 0x61} in policy_pairs(calls)
      assert {0x19, 2} in config_pairs(calls)

      ids = frame_ids(calls)
      assert @network_init in ids
      refute @form_network in ids
      # Keys persist in NCP tokens across reboots — don't rewrite the security state.
      refute @set_initial_security_state in ids
    end

    test "returns {:error, :no_network} when nothing is stored" do
      {:ok, fake} = FakeEZSP.start_link(responses: %{@network_init => <<@not_joined>>})
      {:ok, adapter} = Adapter.start_link(ezsp: fake)

      assert {:error, :no_network} = Adapter.reestablish_network(adapter, [])
    end
  end

  describe "permit_joining" do
    test "installs the well-known transient key before opening the window", %{
      fake: fake,
      adapter: adapter
    } do
      assert :ok = Adapter.permit_joining(adapter, 60)

      # importTransientKey: wildcard EUI64 + 'ZigBeeAlliance09' + flags byte.
      assert FakeEZSP.call_params(fake, @import_transient_key) ==
               <<0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF>> <>
                 "ZigBeeAlliance09" <> <<0x00>>

      assert FakeEZSP.call_params(fake, @permit_joining) == <<60>>

      ids = frame_ids(FakeEZSP.calls(fake))

      assert Enum.find_index(ids, &(&1 == @import_transient_key)) <
               Enum.find_index(ids, &(&1 == @permit_joining))
    end
  end

  describe "join handling (Lumi manufacturer-code workaround)" do
    test "sets the coordinator manufacturer code to Lumi's on a Lumi join", %{
      fake: fake,
      adapter: adapter
    } do
      send(
        adapter,
        {:ezsp_callback, %{frame_id: @join_frame, params: join_params(0xE46E, @lumi_eui, 1)}}
      )

      assert_receive {:zigbee, :device_joined, %{eui64: @lumi_eui, node_id: 0xE46E}}
      # 0x115F little-endian
      assert FakeEZSP.call_params(fake, @set_manufacturer_code) == <<0x5F, 0x11>>
    end

    test "leaves the manufacturer code alone for a non-Lumi join", %{fake: fake, adapter: adapter} do
      other = <<0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08>>

      send(
        adapter,
        {:ezsp_callback, %{frame_id: @join_frame, params: join_params(0x1234, other, 1)}}
      )

      assert_receive {:zigbee, :device_joined, %{eui64: ^other}}
      refute Enum.any?(FakeEZSP.calls(fake), &match?({@set_manufacturer_code, _}, &1))
    end

    test "skips the workaround on a device-left (update=2) event", %{fake: fake, adapter: adapter} do
      send(
        adapter,
        {:ezsp_callback, %{frame_id: @join_frame, params: join_params(0xE46E, @lumi_eui, 2)}}
      )

      assert_receive {:zigbee, :device_joined, _}
      refute Enum.any?(FakeEZSP.calls(fake), &match?({@set_manufacturer_code, _}, &1))
    end
  end

  describe "incoming message decode (EZSP v13)" do
    # A real captured Device_annce (cluster 0x0013) incomingMessageHandler payload —
    # note the trailing 0x02 byte v13 firmware appends after the APS payload.
    @incoming_v13 <<4, 0, 0, 19, 0, 0, 0, 0, 4, 0, 0, 101, 255, 226, 110, 228, 255, 255, 12, 129,
                    110, 228, 33, 42, 40, 1, 16, 68, 239, 84, 128, 2>>

    test "decodes a frame that has the v13 trailing byte", %{adapter: adapter} do
      send(adapter, {:ezsp_callback, %{frame_id: @incoming_frame, params: @incoming_v13}})

      assert_receive {:zigbee, :message, msg}
      assert msg.source == 0xE46E
      assert msg.cluster == 0x0013
      assert msg.src_endpoint == 0
      assert byte_size(msg.payload) == 12
    end

    test "still decodes a frame with no trailing byte", %{adapter: adapter} do
      no_trailer = binary_part(@incoming_v13, 0, byte_size(@incoming_v13) - 1)
      send(adapter, {:ezsp_callback, %{frame_id: @incoming_frame, params: no_trailer}})

      assert_receive {:zigbee, :message, msg}
      assert msg.source == 0xE46E
      assert byte_size(msg.payload) == 12
    end
  end
end
