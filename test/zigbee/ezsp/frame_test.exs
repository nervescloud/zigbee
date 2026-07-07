defmodule Zigbee.EZSP.FrameTest do
  use ExUnit.Case, async: true

  alias Zigbee.EZSP.Frame

  describe "encode_command/3" do
    test "encodes the version command exactly as the NCP accepts it" do
      # Verified on hardware: this is the byte sequence the ZBT-2 answered.
      assert Frame.encode_command(0, 0x0000, <<13>>) == <<0x00, 0x00, 0x01, 0x00, 0x00, 0x0D>>
    end

    test "encodes frame id as little-endian u16" do
      assert Frame.encode_command(5, 0x0026, <<>>) == <<0x05, 0x00, 0x01, 0x26, 0x00>>
    end
  end

  describe "decode/1" do
    test "decodes the captured version response" do
      # Real ZBT-2 response: EZSP v13, stack type 2, EmberZNet 7.4.4.0.
      assert {:ok, frame} = Frame.decode(<<0x00, 0x80, 0x01, 0x00, 0x00, 0x0D, 0x02, 0x40, 0x74>>)
      assert frame.seq == 0
      assert frame.response? == true
      assert frame.frame_id == 0x0000
      assert frame.params == <<0x0D, 0x02, 0x40, 0x74>>
    end

    test "flags a command frame (response bit clear) as not a response" do
      assert {:ok, %{response?: false}} = Frame.decode(<<0x03, 0x00, 0x01, 0x26, 0x00>>)
    end

    test "rejects a frame shorter than the header" do
      assert {:error, :short_frame} = Frame.decode(<<0x00, 0x80>>)
    end
  end
end
