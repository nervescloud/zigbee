defmodule Zigbee.ZDO do
  @moduledoc """
  Zigbee Device Objects (ZDO) codec, the device-management protocol that runs on
  endpoint 0, profile 0x0000. Used to *interview* a freshly-joined device
  (enumerate its endpoints and their clusters) and to *bind* a cluster so the
  device reports to us.

  Every ZDO payload begins with a 1-byte transaction sequence number. The APS
  cluster id **is** the ZDO command; responses use `request_cluster ||| 0x8000`.
  EUI64 addresses are little-endian on the wire (same order EZSP hands them to
  us), so we pass the raw 8-byte binaries straight through.
  """

  import Bitwise

  @active_endpoints_req 0x0005
  @simple_descriptor_req 0x0004
  @bind_req 0x0021

  @doc "Cluster id for the Active Endpoints request (0x0005)."
  def active_endpoints_cluster, do: @active_endpoints_req
  @doc "Cluster id for the Simple Descriptor request (0x0004)."
  def simple_descriptor_cluster, do: @simple_descriptor_req
  @doc "Cluster id for the Bind request (0x0021)."
  def bind_cluster, do: @bind_req

  @doc "The response cluster id for a given request cluster (sets bit 15)."
  def response_cluster(request_cluster), do: request_cluster ||| 0x8000

  # ── Requests ────────────────────────────────────────────────────────────────

  @doc "Active Endpoints request: which endpoints does `node_id` expose?"
  @spec active_endpoints_request(byte(), 0..0xFFFF) :: binary()
  def active_endpoints_request(seq, node_id) do
    <<seq, node_id::little-16>>
  end

  @doc "Simple Descriptor request: what profile/device/clusters live on `endpoint`?"
  @spec simple_descriptor_request(byte(), 0..0xFFFF, byte()) :: binary()
  def simple_descriptor_request(seq, node_id, endpoint) do
    <<seq, node_id::little-16, endpoint>>
  end

  @doc """
  Bind request: make the device's `cluster` on `src_endpoint` deliver to us.

  `src_eui64` is the device's address, `dst_eui64` the coordinator's, both raw
  8-byte little-endian binaries. Destination addressing mode is fixed to 64-bit
  unicast (0x03).
  """
  @spec bind_request(byte(), binary(), byte(), 0..0xFFFF, binary(), byte()) :: binary()
  def bind_request(seq, src_eui64, src_endpoint, cluster, dst_eui64, dst_endpoint)
      when byte_size(src_eui64) == 8 and byte_size(dst_eui64) == 8 do
    <<seq, src_eui64::binary-8, src_endpoint, cluster::little-16, 0x03, dst_eui64::binary-8,
      dst_endpoint>>
  end

  # ── Response decoding ───────────────────────────────────────────────────────

  @doc """
  Decode an Active Endpoints response (cluster 0x8005) into
  `%{seq, status, node_id, endpoints}`.
  """
  @spec decode_active_endpoints_response(binary()) :: {:ok, map()} | {:error, term()}
  def decode_active_endpoints_response(
        <<seq, status, node_id::little-16, count, eps::binary-size(count)>>
      ) do
    {:ok, %{seq: seq, status: status, node_id: node_id, endpoints: :binary.bin_to_list(eps)}}
  end

  def decode_active_endpoints_response(<<seq, status, _::binary>>),
    do: {:ok, %{seq: seq, status: status, endpoints: []}}

  def decode_active_endpoints_response(other), do: {:error, {:bad_active_endpoints, other}}

  @doc """
  Decode a Simple Descriptor response (cluster 0x8004) into
  `%{seq, status, node_id, endpoint, profile, device, version, in_clusters,
  out_clusters}`.
  """
  @spec decode_simple_descriptor_response(binary()) :: {:ok, map()} | {:error, term()}
  def decode_simple_descriptor_response(<<seq, status, node_id::little-16, _len, desc::binary>>)
      when status == 0x00 do
    <<endpoint, profile::little-16, device::little-16, version, in_count, rest::binary>> = desc
    in_bytes = in_count * 2

    <<in_raw::binary-size(^in_bytes), out_count, out_raw::binary-size(out_count * 2), _::binary>> =
      rest

    {:ok,
     %{
       seq: seq,
       status: status,
       node_id: node_id,
       endpoint: endpoint,
       profile: profile,
       device: device,
       version: version,
       in_clusters: le16_list(in_raw),
       out_clusters: le16_list(out_raw)
     }}
  end

  def decode_simple_descriptor_response(<<seq, status, _::binary>>),
    do: {:ok, %{seq: seq, status: status}}

  def decode_simple_descriptor_response(other), do: {:error, {:bad_simple_descriptor, other}}

  @doc "Decode a Bind response (cluster 0x8021) into `%{seq, status}`."
  @spec decode_bind_response(binary()) :: {:ok, map()} | {:error, term()}
  def decode_bind_response(<<seq, status, _::binary>>), do: {:ok, %{seq: seq, status: status}}
  def decode_bind_response(other), do: {:error, {:bad_bind_response, other}}

  defp le16_list(<<>>), do: []
  defp le16_list(<<v::little-16, rest::binary>>), do: [v | le16_list(rest)]
end
