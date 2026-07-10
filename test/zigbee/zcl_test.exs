defmodule Zigbee.ZCLTest do
  use ExUnit.Case, async: true

  alias Zigbee.ZCL

  describe "encoding" do
    test "read_attributes builds a global read for the given attr ids" do
      assert ZCL.read_attributes(0x05, [0x0000, 0x0021]) ==
               <<0x00, 0x05, 0x00, 0x00, 0x00, 0x21, 0x00>>
    end

    test "configure_reporting encodes an analog record with its reportable change" do
      rec = %{attr_id: 0x0000, type: 0x29, min: 30, max: 300, change: 10}

      assert ZCL.configure_reporting(0x05, [rec]) ==
               <<0x00, 0x05, 0x06, 0x00, 0x00, 0x00, 0x29, 0x1E, 0x00, 0x2C, 0x01, 0x0A, 0x00>>
    end

    test "configure_reporting omits the change field for discrete attributes" do
      rec = %{attr_id: 0x0000, type: 0x10, min: 1, max: 60, change: nil}

      assert ZCL.configure_reporting(0x01, [rec]) ==
               <<0x00, 0x01, 0x06, 0x00, 0x00, 0x00, 0x10, 0x01, 0x00, 0x3C, 0x00>>
    end

    test "write_attributes builds a plain global write" do
      # write attr 0x0009 uint8 = 1
      assert ZCL.write_attributes(0x01, [%{attr_id: 0x0009, type: 0x20, value: 1}]) ==
               <<0x00, 0x01, 0x02, 0x09, 0x00, 0x20, 0x01>>
    end

    test "write_attributes sets the MS bit and inserts the manufacturer code" do
      # manufacturer-specific write of octet-string "AB" to attr 0xFFF2, code 0x115F
      rec = %{attr_id: 0xFFF2, type: 0x41, value: "AB"}

      assert ZCL.write_attributes(0x07, [rec], manufacturer_code: 0x115F) ==
               <<0x04, 0x5F, 0x11, 0x07, 0x02, 0xF2, 0xFF, 0x41, 0x02, 0x41, 0x42>>
    end

    test "encode_value handles octet strings (0x41)" do
      assert ZCL.encode_value(0x41, "xy") == <<0x02, 0x78, 0x79>>
    end
  end

  describe "decoding reports" do
    test "decodes a temperature Report Attributes frame" do
      # frame control 0x18 (server→client, disable default response), cmd 0x0A,
      # attr 0x0000, type int16 (0x29), value 2350 = 23.50 °C
      frame = <<0x18, 0x42, 0x0A, 0x00, 0x00, 0x29, 0x2E, 0x09>>

      assert {:ok, decoded} = ZCL.decode(frame)
      assert decoded.command_name == :report_attributes
      assert decoded.direction == 1
      assert decoded.manufacturer == nil
      assert [%{attr_id: 0x0000, type: 0x29, value: 2350}] = decoded.payload
      assert ZCL.temperature_c(2350) == 23.5
    end

    test "decodes a negative temperature (signed int16)" do
      frame = <<0x18, 0x01, 0x0A, 0x00, 0x00, 0x29, 0xE6, 0xFB>>
      assert {:ok, %{payload: [%{value: -1050}]}} = ZCL.decode(frame)
      assert ZCL.temperature_c(-1050) == -10.5
    end

    test "decodes a humidity report (unsigned uint16)" do
      # attr 0x0000, type uint16 (0x21), value 5678 = 56.78 %
      frame = <<0x18, 0x01, 0x0A, 0x00, 0x00, 0x21, 0x2E, 0x16>>
      assert {:ok, %{payload: [%{value: 5678}]}} = ZCL.decode(frame)
      assert ZCL.humidity_pct(5678) == 56.78
    end

    test "decodes a manufacturer-specific frame (skips the mfr code)" do
      # MS bit set (0x04) → manufacturer code 0x115F (Lumi/Aqara) follows fc
      frame = <<0x1C, 0x5F, 0x11, 0x07, 0x0A, 0x00, 0x00, 0x29, 0x2E, 0x09>>
      assert {:ok, decoded} = ZCL.decode(frame)
      assert decoded.manufacturer == 0x115F
      assert decoded.seq == 0x07
    end
  end

  describe "decoding read responses" do
    test "decodes a successful and a failed attribute in one response" do
      # attr 0x0000 ok int16 2350; attr 0x0021 unsupported (status 0x86)
      frame = <<0x18, 0x01, 0x01, 0x00, 0x00, 0x00, 0x29, 0x2E, 0x09, 0x21, 0x00, 0x86>>

      assert {:ok, %{payload: payload}} = ZCL.decode(frame)

      assert [
               %{attr_id: 0x0000, status: 0x00, type: 0x29, value: 2350},
               %{attr_id: 0x0021, status: 0x86}
             ] = payload
    end
  end

  describe "value codec" do
    test "round-trips signed and unsigned integers" do
      assert ZCL.encode_value(0x29, -1050) == <<0xE6, 0xFB>>
      assert ZCL.decode_value(0x29, <<0xE6, 0xFB>>) == {-1050, <<>>}
      assert ZCL.decode_value(0x21, <<0x2E, 0x16>>) == {5678, <<>>}
    end

    test "decodes booleans and strings, leaving the remainder" do
      assert ZCL.decode_value(0x10, <<0x01, 0xAA>>) == {true, <<0xAA>>}
      assert ZCL.decode_value(0x42, <<0x03, "abc", 0xBB>>) == {"abc", <<0xBB>>}
    end
  end
end
