defmodule Zigbee.EZSP.ASHTest do
  use ExUnit.Case, async: true

  alias Zigbee.EZSP.ASH

  describe "crc/1 (CRC-16-CCITT, init 0xFFFF)" do
    test "matches the RST frame vector from UG101" do
      # The canonical RST frame on the wire is C0 38 BC 7E, so CRC(0xC0) = 0x38BC.
      assert ASH.crc(<<0xC0>>) == 0x38BC
    end

    test "matches the RSTACK frame vector" do
      # RSTACK for version 2 / reset code 2: C1 02 02 9B 7B 7E → CRC = 0x9B7B.
      assert ASH.crc(<<0xC1, 0x02, 0x02>>) == 0x9B7B
    end
  end

  describe "stuff/1 and unstuff/1" do
    test "escapes each reserved byte with 0x7D + (byte ^ 0x20)" do
      assert ASH.stuff(<<0x7E>>) == <<0x7D, 0x5E>>
      assert ASH.stuff(<<0x7D>>) == <<0x7D, 0x5D>>
      assert ASH.stuff(<<0x11>>) == <<0x7D, 0x31>>
      assert ASH.stuff(<<0x13>>) == <<0x7D, 0x33>>
      assert ASH.stuff(<<0x18>>) == <<0x7D, 0x38>>
      assert ASH.stuff(<<0x1A>>) == <<0x7D, 0x3A>>
    end

    test "leaves non-reserved bytes untouched" do
      assert ASH.stuff(<<0x00, 0x42, 0xFF>>) == <<0x00, 0x42, 0xFF>>
    end

    test "round-trips arbitrary data" do
      for _ <- 1..200 do
        data = :crypto.strong_rand_bytes(:rand.uniform(64))
        assert {:ok, ^data} = ASH.unstuff(ASH.stuff(data))
      end
    end

    test "rejects a dangling escape byte" do
      assert {:error, :bad_escape} = ASH.unstuff(<<0x7D>>)
    end
  end

  describe "randomize/1" do
    test "XORs the first byte with the 0x42 seed" do
      assert ASH.randomize(<<0x00>>) == <<0x42>>
    end

    test "is its own inverse" do
      data = :crypto.strong_rand_bytes(50)
      assert ASH.randomize(ASH.randomize(data)) == data
    end
  end

  describe "rst_frame/0" do
    test "produces the exact UG101 byte sequence (Cancel + RST + CRC + flag)" do
      assert ASH.rst_frame() == <<0x1A, 0xC0, 0x38, 0xBC, 0x7E>>
    end
  end

  describe "decode/1" do
    test "decodes an RSTACK frame" do
      # Frame body + CRC, without the trailing flag.
      raw = <<0xC1, 0x02, 0x02, 0x9B, 0x7B>>
      assert {:ok, %{type: :rstack, version: 2, reset_code: 2}} = ASH.decode(raw)
    end

    test "decodes an ACK frame" do
      raw = strip_flag(ASH.ack_frame(3))
      assert {:ok, %{type: :ack, ack_num: 3, not_ready?: false}} = ASH.decode(raw)
    end

    test "decodes a NAK frame with not-ready set" do
      raw = strip_flag(ASH.nak_frame(5, true))
      assert {:ok, %{type: :nak, ack_num: 5, not_ready?: true}} = ASH.decode(raw)
    end

    test "reports a CRC mismatch" do
      assert {:error, :crc_mismatch} = ASH.decode(<<0xC1, 0x02, 0x02, 0x00, 0x00>>)
    end

    test "reports a truncated frame" do
      assert {:error, :truncated} = ASH.decode(<<0xC1>>)
    end
  end

  describe "DATA frame round-trip" do
    test "encode then decode recovers the payload, numbers and flags" do
      payload = <<0x00, 0x01, 0x02, 0xAB, 0xCD, 0xEF>>
      raw = strip_flag(ASH.data_frame(4, 2, payload, true))

      assert {:ok, decoded} = ASH.decode(raw)
      assert decoded.type == :data
      assert decoded.frame_num == 4
      assert decoded.ack_num == 2
      assert decoded.retransmit? == true
      assert decoded.payload == payload
    end

    test "survives a payload full of reserved bytes" do
      payload = <<0x7E, 0x7D, 0x11, 0x13, 0x18, 0x1A>>
      raw = strip_flag(ASH.data_frame(0, 0, payload))
      assert {:ok, %{payload: ^payload}} = ASH.decode(raw)
    end
  end

  # The encoders append the frame flag; decode/1 expects the bytes between flags.
  defp strip_flag(frame) do
    size = byte_size(frame) - 1
    <<body::binary-size(size), 0x7E>> = frame
    body
  end
end
