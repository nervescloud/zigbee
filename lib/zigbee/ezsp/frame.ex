defmodule Zigbee.EZSP.Frame do
  @moduledoc """
  EZSP (EmberZNet Serial Protocol) frame encoding/decoding for the **v8+ frame
  format** (frame format version 1), as used by EZSP v13 firmware on the ZBT-2.

  ## Command frame

      [ seq ][ FC low = 0x00 ][ FC high = 0x01 ][ frame id : u16-le ][ params… ]

  ## Response frame

      [ seq ][ FC low (bit7=1) ][ FC high = 0x01 ][ frame id : u16-le ][ params… ]

  The NCP echoes the command's sequence number in its response, which is how the
  `Zigbee.EZSP` server correlates the two. Unsolicited **callbacks** (e.g. a device
  joining, an incoming message) arrive as frames whose sequence number does not
  match any outstanding command; the response bit in the frame-control low byte
  distinguishes a command response from a callback.
  """

  import Bitwise

  # FC high byte: bits 0-1 carry the frame format version (0b01 = the v8+ format).
  @frame_format_version 0x01
  @response_bit 0x80

  @type t :: %{
          seq: 0..255,
          frame_control_low: byte(),
          frame_control_high: byte(),
          response?: boolean(),
          frame_id: 0..0xFFFF,
          params: binary()
        }

  @doc """
  Encode a command frame.

    * `seq`: EZSP sequence number (0..255), assigned by the caller
    * `frame_id`: 16-bit EZSP command ID
    * `params`: already-encoded parameter bytes
  """
  @spec encode_command(0..255, 0..0xFFFF, binary()) :: binary()
  def encode_command(seq, frame_id, params \\ <<>>) do
    <<seq, 0x00, @frame_format_version, frame_id::little-16, params::binary>>
  end

  @doc "Decode a raw EZSP payload (the de-randomized ASH DATA field) into a frame."
  @spec decode(binary()) :: {:ok, t()} | {:error, :short_frame}
  def decode(<<seq, fc_low, fc_high, frame_id::little-16, params::binary>>) do
    {:ok,
     %{
       seq: seq,
       frame_control_low: fc_low,
       frame_control_high: fc_high,
       response?: (fc_low &&& @response_bit) != 0,
       frame_id: frame_id,
       params: params
     }}
  end

  def decode(_), do: {:error, :short_frame}
end
