defmodule Zigbee.ZCL do
  @moduledoc """
  Zigbee Cluster Library (ZCL) frame codec: the application payload that rides
  inside an APS unicast on a Home Automation endpoint (profile 0x0104).

  This is pure, transport-agnostic encoding/decoding: build the global commands
  we need to interview and configure a sensor (Read Attributes, Configure
  Reporting) and decode what it sends back (Read Attributes Response, Report
  Attributes). It is deliberately independent of EZSP; `Zigbee.EZSP.Adapter` wraps
  these bytes in an `EmberApsFrame` and hands them to the NCP.

  ## ZCL frame layout

      [frame control : 1]
      [manufacturer code : 2 LE]   # only if the MS bit is set
      [transaction seq : 1]
      [command id : 1]
      [payload ...]

  Frame-control bits: type (0 = global/profile-wide, 1 = cluster-specific),
  bit2 manufacturer-specific, bit3 direction (0 = to-server, 1 = to-client),
  bit4 disable-default-response.
  """

  import Bitwise

  # Global (profile-wide) command ids.
  @cmd_read_attributes 0x00
  @cmd_read_attributes_response 0x01
  @cmd_configure_reporting 0x06
  @cmd_configure_reporting_response 0x07
  @cmd_report_attributes 0x0A
  @cmd_default_response 0x0B

  # ── Encoding ──────────────────────────────────────────────────────────────

  @doc """
  Build a **Read Attributes** (global cmd 0x00) frame for `attr_ids`.

  `seq` is the ZCL transaction sequence number (echoed in the response).
  """
  @spec read_attributes(byte(), [0..0xFFFF]) :: binary()
  def read_attributes(seq, attr_ids) when is_list(attr_ids) do
    body = for id <- attr_ids, into: <<>>, do: <<id::little-16>>
    frame(0x00, seq, @cmd_read_attributes, body)
  end

  @doc """
  Build a **Configure Reporting** (global cmd 0x06) frame.

  Each record is `%{attr_id, type, min, max, change}`. For analog attributes
  `change` (the reportable delta, same data type as the attribute) is required;
  for discrete attributes pass `change: nil`. `min`/`max` are the reporting
  interval bounds in seconds.
  """
  @spec configure_reporting(byte(), [map()]) :: binary()
  def configure_reporting(seq, records) when is_list(records) do
    body =
      for %{attr_id: id, type: type, min: min, max: max} = r <- records, into: <<>> do
        change =
          case Map.get(r, :change) do
            nil -> <<>>
            value -> encode_value(type, value)
          end

        # direction 0x00 = configure how the *server* reports to us
        <<0x00, id::little-16, type, min::little-16, max::little-16, change::binary>>
      end

    frame(0x00, seq, @cmd_configure_reporting, body)
  end

  # Assemble a profile-wide (global) ZCL frame with the default frame control
  # (to-server, default response enabled).
  defp frame(frame_control, seq, command, body) do
    <<frame_control, seq, command, body::binary>>
  end

  # ── Decoding ────────────────────────────────────────────────────────────────

  @doc """
  Decode a ZCL frame into a map: `%{frame_type, direction, manufacturer, seq,
  command, command_name, payload}` where `payload` is command-specific
  (a list of attribute records for reads/reports).
  """
  @spec decode(binary()) :: {:ok, map()} | {:error, term()}
  def decode(<<fc, rest::binary>>) do
    ms? = (fc &&& 0x04) != 0

    {manufacturer, <<seq, command, payload::binary>>} =
      if ms? do
        <<mc::little-16, tail::binary>> = rest
        {mc, tail}
      else
        {nil, rest}
      end

    {:ok,
     %{
       frame_type: fc &&& 0x01,
       direction: fc >>> 3 &&& 0x01,
       manufacturer: manufacturer,
       seq: seq,
       command: command,
       command_name: command_name(command),
       payload: decode_payload(command, payload)
     }}
  rescue
    e -> {:error, {:zcl_decode, e}}
  end

  # Read Attributes Response (0x01): records of {id, status, [type, value]}.
  defp decode_payload(@cmd_read_attributes_response, bin), do: decode_read_response(bin, [])
  # Report Attributes (0x0A): records of {id, type, value} (no status field).
  defp decode_payload(@cmd_report_attributes, bin), do: decode_reports(bin, [])

  defp decode_payload(@cmd_default_response, <<command, status>>),
    do: %{command: command, status: status}

  defp decode_payload(@cmd_configure_reporting_response, <<0x00>>), do: %{status: :success}
  defp decode_payload(@cmd_configure_reporting_response, bin), do: %{status: :partial, raw: bin}
  defp decode_payload(_command, bin), do: bin

  defp decode_read_response(<<>>, acc), do: Enum.reverse(acc)

  defp decode_read_response(<<id::little-16, 0x00, type, rest::binary>>, acc) do
    {value, rest} = decode_value(type, rest)
    decode_read_response(rest, [%{attr_id: id, status: 0x00, type: type, value: value} | acc])
  end

  defp decode_read_response(<<id::little-16, status, rest::binary>>, acc) do
    decode_read_response(rest, [%{attr_id: id, status: status} | acc])
  end

  defp decode_reports(<<>>, acc), do: Enum.reverse(acc)

  defp decode_reports(<<id::little-16, type, rest::binary>>, acc) do
    {value, rest} = decode_value(type, rest)
    decode_reports(rest, [%{attr_id: id, type: type, value: value} | acc])
  end

  # ── Attribute value codec (little-endian, ZCL data types) ───────────────────

  @doc "Encode a value given its ZCL data type id (little-endian)."
  @spec encode_value(byte(), term()) :: binary()
  def encode_value(0x10, true), do: <<0x01>>
  def encode_value(0x10, false), do: <<0x00>>
  def encode_value(0x42, s) when is_binary(s), do: <<byte_size(s), s::binary>>

  def encode_value(type, value) when is_integer(value) do
    size = type_size(type)
    <<value::little-signed-size(size)-unit(8)>>
  end

  @doc """
  Decode one attribute value of ZCL `type` from the front of `bin`.
  Returns `{value, rest}`.
  """
  @spec decode_value(byte(), binary()) :: {term(), binary()}
  def decode_value(0x00, bin), do: {nil, bin}
  def decode_value(0x10, <<v, rest::binary>>), do: {v == 0x01, rest}
  def decode_value(0x42, <<len, s::binary-size(len), rest::binary>>), do: {s, rest}
  def decode_value(0x41, <<len, s::binary-size(len), rest::binary>>), do: {s, rest}

  def decode_value(type, bin) do
    size = type_size(type)
    <<raw::binary-size(^size), rest::binary>> = bin

    value =
      if signed?(type) do
        <<v::little-signed-size(^size)-unit(8)>> = raw
        v
      else
        <<v::little-unsigned-size(^size)-unit(8)>> = raw
        v
      end

    {value, rest}
  end

  # Discrete/analog helpers used by callers to interpret common sensor readings.

  @doc "Temperature attribute (int16, hundredths of a degree C) → float °C."
  def temperature_c(raw_int) when is_integer(raw_int), do: raw_int / 100.0

  @doc "Relative-humidity attribute (uint16, hundredths of a percent) → float %."
  def humidity_pct(raw_int) when is_integer(raw_int), do: raw_int / 100.0

  defp signed?(type), do: type in 0x28..0x2F

  defp type_size(type) do
    case type do
      t when t in [0x08, 0x10, 0x18, 0x20, 0x28, 0x30] -> 1
      t when t in [0x09, 0x19, 0x21, 0x29, 0x31] -> 2
      t when t in [0x0A, 0x22, 0x2A] -> 3
      t when t in [0x0B, 0x23, 0x2B] -> 4
      t when t in [0x25, 0x2D] -> 6
      t when t in [0x27, 0x2F] -> 8
      _ -> raise ArgumentError, "unsupported/variable ZCL type 0x#{Integer.to_string(type, 16)}"
    end
  end

  defp command_name(0x00), do: :read_attributes
  defp command_name(0x01), do: :read_attributes_response
  defp command_name(0x06), do: :configure_reporting
  defp command_name(0x07), do: :configure_reporting_response
  defp command_name(0x0A), do: :report_attributes
  defp command_name(0x0B), do: :default_response
  defp command_name(_), do: :unknown
end
