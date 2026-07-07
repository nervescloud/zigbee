defmodule Zigbee.Adapter do
  @moduledoc """
  Behaviour for a Zigbee chip backend: a radio + NCP protocol presented as a
  normalized coordinator interface.

  `Zigbee.EZSP.Adapter` implements it for Silicon Labs EmberZNet; a future
  `Zigbee.ZNP.Adapter` would do the same for TI Z-Stack. Everything above this
  boundary (`Zigbee.Interview`, `Zigbee.ZCL`, `Zigbee.ZDO`) depends only on this
  behaviour and the normalized events below, never on a specific chip.

  A backend is a process that delivers normalized events to its subscriber:

      {:zigbee, :device_joined, %{node_id: _, eui64: _}}
      {:zigbee, :message, %Zigbee.Message{}}

  Callers usually go through the `Zigbee` facade, which pairs a backend module
  with its process in a `%Zigbee.Adapter{}` handle and dispatches to it.
  """

  @type ref :: pid() | GenServer.name()
  @type t :: %__MODULE__{module: module(), ref: ref()}
  defstruct [:module, :ref]

  @doc "Start the backend process, returning its ref (a pid)."
  @callback start_link(opts :: keyword()) :: {:ok, pid()} | {:error, term()}

  @doc "Version/stack info for the connected radio."
  @callback info(ref()) :: map()

  @doc "Register `pid` to receive the normalized `{:zigbee, _}` events."
  @callback subscribe(ref(), pid()) :: :ok

  @doc "Form a coordinator network. Returns the resulting network parameters."
  @callback form_network(ref(), opts :: keyword()) :: {:ok, map()} | {:error, term()}

  @doc """
  Re-establish the network already stored on the radio (rather than forming a new
  one), re-registering endpoints first. Returns `{:ok, params}` if a network was
  restored, or `{:error, :no_network}` if the radio has none stored.
  """
  @callback reestablish_network(ref(), opts :: keyword()) ::
              {:ok, map()} | {:error, :no_network | term()}

  @doc "Open the network for joining for `seconds` (0xFF = no timeout)."
  @callback permit_joining(ref(), seconds :: non_neg_integer()) :: :ok | {:error, term()}

  @doc "Register an application endpoint (must happen before the network is up)."
  @callback add_endpoint(
              ref(),
              endpoint :: 0..0xFF,
              profile :: 0..0xFFFF,
              device_id :: 0..0xFFFF,
              in_clusters :: [0..0xFFFF],
              out_clusters :: [0..0xFFFF]
            ) :: :ok | {:error, term()}

  @doc "Send a direct APS unicast; returns the APS sequence number."
  @callback send_aps(
              ref(),
              node_id :: 0..0xFFFF,
              profile :: 0..0xFFFF,
              cluster :: 0..0xFFFF,
              dst_endpoint :: 0..0xFF,
              payload :: binary(),
              opts :: keyword()
            ) :: {:ok, 0..0xFF} | {:error, term()}

  @doc """
  The coordinator's own identifier: its 64-bit IEEE 802.15.4 extended address
  (EUI64), the radio's permanent globally-unique hardware address. Raw 8-byte LE.
  """
  @callback identifier(ref()) :: {:ok, binary()} | {:error, term()}

  @doc "Reset the coordinator: leave / tear down the current network, clearing stored state."
  @callback reset_network(ref()) :: :ok | {:error, term()}
end
