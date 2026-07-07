defmodule Zigbee.ZDOTest do
  use ExUnit.Case, async: true

  alias Zigbee.ZDO

  describe "requests" do
    test "active endpoints request" do
      assert ZDO.active_endpoints_request(0x01, 0x1234) == <<0x01, 0x34, 0x12>>
    end

    test "simple descriptor request" do
      assert ZDO.simple_descriptor_request(0x02, 0x1234, 0x01) == <<0x02, 0x34, 0x12, 0x01>>
    end

    test "bind request pins destination addressing mode to 64-bit unicast" do
      src = <<1, 2, 3, 4, 5, 6, 7, 8>>
      dst = <<8, 7, 6, 5, 4, 3, 2, 1>>

      assert ZDO.bind_request(0x03, src, 0x01, 0x0402, dst, 0x01) ==
               <<0x03, 1, 2, 3, 4, 5, 6, 7, 8, 0x01, 0x02, 0x04, 0x03, 8, 7, 6, 5, 4, 3, 2, 1,
                 0x01>>
    end

    test "response_cluster sets bit 15" do
      assert ZDO.response_cluster(0x0005) == 0x8005
      assert ZDO.response_cluster(0x0021) == 0x8021
    end
  end

  describe "response decoding" do
    test "active endpoints response lists the endpoints" do
      frame = <<0x01, 0x00, 0x34, 0x12, 0x02, 0x01, 0x02>>

      assert {:ok, %{seq: 0x01, status: 0x00, node_id: 0x1234, endpoints: [0x01, 0x02]}} =
               ZDO.decode_active_endpoints_response(frame)
    end

    test "simple descriptor response parses profile, device and cluster lists" do
      # ep 1, profile 0x0104, device 0x0302, ver 1, in [0x0000,0x0402,0x0405], out [0x0019]
      desc =
        <<0x01, 0x04, 0x01, 0x02, 0x03, 0x01, 0x03, 0x00, 0x00, 0x02, 0x04, 0x05, 0x04, 0x01,
          0x19, 0x00>>

      frame = <<0x05, 0x00, 0x34, 0x12, byte_size(desc), desc::binary>>

      assert {:ok, desc_map} = ZDO.decode_simple_descriptor_response(frame)
      assert desc_map.endpoint == 0x01
      assert desc_map.profile == 0x0104
      assert desc_map.device == 0x0302
      assert desc_map.in_clusters == [0x0000, 0x0402, 0x0405]
      assert desc_map.out_clusters == [0x0019]
    end

    test "simple descriptor response with a non-success status returns just status" do
      assert {:ok, %{seq: 0x05, status: 0x84}} =
               ZDO.decode_simple_descriptor_response(<<0x05, 0x84, 0x34, 0x12>>)
    end

    test "bind response" do
      assert {:ok, %{seq: 0x03, status: 0x00}} = ZDO.decode_bind_response(<<0x03, 0x00>>)
    end
  end
end
