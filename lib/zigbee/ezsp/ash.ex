defmodule Zigbee.EZSP.ASH do
  @moduledoc """
  ASH (Asynchronous Serial Host) protocol codec for the EmberZNet NCP-UART
  interface, per Silicon Labs UG101.

  ASH is the reliable data-link layer that sits directly on top of the raw
  serial byte stream and carries EZSP frames. This module is pure: it turns
  EZSP payloads (and control frames) into on-the-wire byte sequences and back,
  with no I/O and no connection state. The stateful concerns (reset handshake,
  frame/ack numbering, retransmission) live in `Zigbee.EZSP.ASH.Connection`.

  ## Frame anatomy (on the wire)

      [ control byte ][ data field ][ CRC-16 hi ][ CRC-16 lo ][ 0x7E flag ]
      \\_____________ byte-stuffed ________________/

  * The **control byte** identifies the frame type and carries frame/ack numbers.
  * The **data field** is present only on DATA frames; it is the (randomized)
    EZSP payload.
  * The **CRC** (CRC-16-CCITT, init 0xFFFF) is computed over control byte + data
    field, transmitted high byte first.
  * Everything except the trailing flag is then **byte-stuffed** to escape
    reserved control bytes.
  """

  import Bitwise

  # Reserved bytes, control characters that must never appear literally inside
  # a frame body and are therefore escaped via byte stuffing.
  @flag 0x7E
  @escape 0x7D
  @xon 0x11
  @xoff 0x13
  @substitute 0x18
  @cancel 0x1A

  @reserved [@flag, @escape, @xon, @xoff, @substitute, @cancel]
  @escape_bit 0x20

  # LFSR seed for DATA-field randomization (UG101 §4.3).
  @rand_seed 0x42
  @rand_poly 0xB8

  @doc "The frame delimiter byte (0x7E)."
  def flag, do: @flag

  @doc "The cancel byte (0x1A); sent before RST to flush a partial frame."
  def cancel, do: @cancel

  # ── CRC-16-CCITT ────────────────────────────────────────────────────────

  @doc """
  CRC-16-CCITT (a.k.a. CRC-16/CCITT-FALSE): initial value 0xFFFF, polynomial
  0x1021, no reflection, no final XOR. Returned as a 16-bit integer.

  For example `crc(<<0xC0>>)` is `0x38BC`, which is why the RST frame ends in
  `38 BC` before the flag.
  """
  @spec crc(binary()) :: 0..0xFFFF
  def crc(data) when is_binary(data) do
    data
    |> :binary.bin_to_list()
    |> Enum.reduce(0xFFFF, fn byte, crc ->
      crc = bxor(crc, byte <<< 8)

      Enum.reduce(1..8, crc, fn _, crc ->
        if (crc &&& 0x8000) != 0 do
          (crc <<< 1) |> bxor(0x1021) |> band(0xFFFF)
        else
          crc <<< 1 &&& 0xFFFF
        end
      end)
    end)
  end

  # ── Byte stuffing (escaping) ────────────────────────────────────────────

  @doc """
  Escape reserved bytes. Each reserved byte is replaced by the escape byte
  (0x7D) followed by the original byte XORed with 0x20.
  """
  @spec stuff(binary()) :: binary()
  def stuff(data) when is_binary(data) do
    for <<byte <- data>>, into: <<>> do
      if byte in @reserved do
        <<@escape, bxor(byte, @escape_bit)>>
      else
        <<byte>>
      end
    end
  end

  @doc "Reverse of `stuff/1`. Returns `{:ok, binary}` or `{:error, :bad_escape}`."
  @spec unstuff(binary()) :: {:ok, binary()} | {:error, :bad_escape}
  def unstuff(data) when is_binary(data), do: unstuff(data, <<>>)

  defp unstuff(<<>>, acc), do: {:ok, acc}

  defp unstuff(<<@escape, byte, rest::binary>>, acc),
    do: unstuff(rest, <<acc::binary, bxor(byte, @escape_bit)>>)

  defp unstuff(<<@escape>>, _acc), do: {:error, :bad_escape}
  defp unstuff(<<byte, rest::binary>>, acc), do: unstuff(rest, <<acc::binary, byte>>)

  # ── Data randomization ──────────────────────────────────────────────────

  @doc """
  Randomize (or de-randomize, the operation is its own inverse) a DATA field
  by XORing it with an LFSR pseudo-random sequence seeded at 0x42.

  Only the EZSP payload of DATA frames is randomized; control bytes and CRC are
  never randomized.
  """
  @spec randomize(binary()) :: binary()
  def randomize(data) when is_binary(data), do: randomize(data, @rand_seed, <<>>)

  defp randomize(<<>>, _rand, acc), do: acc

  defp randomize(<<byte, rest::binary>>, rand, acc) do
    next =
      if (rand &&& 1) == 1 do
        bxor(rand >>> 1, @rand_poly)
      else
        rand >>> 1
      end

    randomize(rest, next, <<acc::binary, bxor(byte, rand)>>)
  end

  # ── Frame encoding ──────────────────────────────────────────────────────

  @doc """
  Encode a DATA frame carrying an EZSP payload.

  * `frame_num`: this frame's sequence number (0..7)
  * `ack_num`: the next frame number we expect from the NCP (0..7)
  * `payload`: the EZSP frame bytes (will be randomized)
  * `retransmit?`: set on retransmissions so the NCP can detect duplicates
  """
  @spec data_frame(0..7, 0..7, binary(), boolean()) :: binary()
  def data_frame(frame_num, ack_num, payload, retransmit? \\ false) do
    control =
      (frame_num &&& 0x07) <<< 4 |||
        if(retransmit?, do: 1, else: 0) <<< 3 |||
        (ack_num &&& 0x07)

    frame(control, randomize(payload))
  end

  @doc "Encode an ACK frame acknowledging up to (but not including) `ack_num`."
  @spec ack_frame(0..7, boolean()) :: binary()
  def ack_frame(ack_num, not_ready? \\ false),
    do: frame(0x80 ||| if(not_ready?, do: 1, else: 0) <<< 3 ||| (ack_num &&& 0x07), <<>>)

  @doc "Encode a NAK frame requesting retransmission from `ack_num`."
  @spec nak_frame(0..7, boolean()) :: binary()
  def nak_frame(ack_num, not_ready? \\ false),
    do: frame(0xA0 ||| if(not_ready?, do: 1, else: 0) <<< 3 ||| (ack_num &&& 0x07), <<>>)

  @doc """
  Encode the RST (reset) frame, prefixed with a Cancel byte to flush any
  partial frame the NCP may be mid-way through. The result is always the fixed
  sequence `1A C0 38 BC 7E`.
  """
  @spec rst_frame() :: binary()
  def rst_frame, do: <<@cancel>> <> frame(0xC0, <<>>)

  # Assemble a frame body: prepend CRC (big-endian), byte-stuff, append flag.
  defp frame(control, data_field) do
    body = <<control>> <> data_field
    crc = crc(body)
    (body <> <<crc::16>>) |> stuff() |> Kernel.<>(<<@flag>>)
  end

  # ── Frame decoding ──────────────────────────────────────────────────────

  @doc """
  Decode a single raw frame (the bytes *between* flags, without the trailing
  0x7E) into a structured map.

  Returns `{:ok, frame}` where `frame` is one of:

      %{type: :data, frame_num: 0..7, ack_num: 0..7, retransmit?: bool, payload: binary}
      %{type: :ack,  ack_num: 0..7, not_ready?: bool}
      %{type: :nak,  ack_num: 0..7, not_ready?: bool}
      %{type: :rstack, version: byte, reset_code: byte}
      %{type: :error,  version: byte, error_code: byte}
      %{type: :rst}

  or `{:error, reason}` on a CRC mismatch, bad escape, or truncated frame.
  """
  @spec decode(binary()) :: {:ok, map()} | {:error, atom()}
  def decode(raw) when is_binary(raw) do
    with {:ok, unstuffed} <- unstuff(raw),
         {:ok, body} <- verify_crc(unstuffed) do
      decode_body(body)
    end
  end

  defp verify_crc(unstuffed) when byte_size(unstuffed) < 3, do: {:error, :truncated}

  defp verify_crc(unstuffed) do
    body_len = byte_size(unstuffed) - 2
    <<body::binary-size(body_len), crc::16>> = unstuffed

    if crc(body) == crc, do: {:ok, body}, else: {:error, :crc_mismatch}
  end

  # DATA frame: high bit of control is 0.
  defp decode_body(<<0::1, frame_num::3, retransmit::1, ack_num::3, payload::binary>>) do
    {:ok,
     %{
       type: :data,
       frame_num: frame_num,
       ack_num: ack_num,
       retransmit?: retransmit == 1,
       payload: randomize(payload)
     }}
  end

  # ACK: 100x xnnn
  defp decode_body(<<0b100::3, _::1, not_ready::1, ack_num::3>>),
    do: {:ok, %{type: :ack, ack_num: ack_num, not_ready?: not_ready == 1}}

  # NAK: 101x xnnn
  defp decode_body(<<0b101::3, _::1, not_ready::1, ack_num::3>>),
    do: {:ok, %{type: :nak, ack_num: ack_num, not_ready?: not_ready == 1}}

  defp decode_body(<<0xC0>>), do: {:ok, %{type: :rst}}

  defp decode_body(<<0xC1, version, reset_code>>),
    do: {:ok, %{type: :rstack, version: version, reset_code: reset_code}}

  defp decode_body(<<0xC2, version, error_code>>),
    do: {:ok, %{type: :error, version: version, error_code: error_code}}

  defp decode_body(_), do: {:error, :unknown_frame}
end
