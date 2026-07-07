defmodule Zigbee.EZSP.Status do
  @moduledoc """
  Decoding for `EmberStatus`, the 1-byte status code returned by most EZSP
  commands and carried in `stackStatusHandler` callbacks.

  Only the codes relevant to the bring-up / network path are named; anything
  else decodes to `{:unknown, byte}` so nothing is silently swallowed.
  """

  @statuses %{
    0x00 => :success,
    0x01 => :err_fatal,
    0x04 => :bad_argument,
    0x70 => :invalid_call,
    0x72 => :max_message_limit_reached,
    0x74 => :message_too_long,
    0x90 => :network_up,
    0x91 => :network_down,
    0x93 => :not_joined,
    0x94 => :join_failed,
    0x96 => :move_failed,
    0x98 => :cannot_form_network,
    0x9C => :network_opened,
    0x9D => :network_closed,
    0xA8 => :network_busy,
    0xAB => :security_state_not_set
  }

  @doc "Decode a single EmberStatus byte to a friendly atom."
  @spec decode(byte()) :: atom() | {:unknown, byte()}
  def decode(byte), do: Map.get(@statuses, byte, {:unknown, byte})

  @doc "True if the status byte is EMBER_SUCCESS (0x00)."
  @spec success?(byte()) :: boolean()
  def success?(0x00), do: true
  def success?(_), do: false
end
