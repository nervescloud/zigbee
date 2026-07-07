defmodule Zigbee.Message do
  @moduledoc """
  A normalized inbound Zigbee APS message.

  Every `Zigbee.Adapter` backend emits these as `{:zigbee, :message, %Zigbee.Message{}}`
  regardless of the underlying radio/NCP, so the application layer (`Zigbee.Interview`,
  `Zigbee.ZCL`, `Zigbee.ZDO`) never sees chip-specific frame formats. The `payload`
  is the raw APS payload (a ZCL frame on an application profile, or a ZDO frame on
  profile 0x0000), decoded by `Zigbee.ZCL` / `Zigbee.ZDO`.
  """

  @enforce_keys [:source, :profile, :cluster, :src_endpoint, :dst_endpoint, :payload]
  defstruct [
    :source,
    :profile,
    :cluster,
    :src_endpoint,
    :dst_endpoint,
    :payload,
    :lqi,
    :rssi,
    :group,
    :aps_seq
  ]

  @type t :: %__MODULE__{
          source: 0..0xFFFF,
          profile: 0..0xFFFF,
          cluster: 0..0xFFFF,
          src_endpoint: 0..0xFF,
          dst_endpoint: 0..0xFF,
          payload: binary(),
          lqi: 0..0xFF | nil,
          rssi: integer() | nil,
          group: 0..0xFFFF | nil,
          aps_seq: 0..0xFF | nil
        }
end
