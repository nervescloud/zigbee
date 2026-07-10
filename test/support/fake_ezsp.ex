defmodule Zigbee.FakeEZSP do
  @moduledoc """
  A stand-in for `Zigbee.EZSP` used to drive `Zigbee.EZSP.Adapter` in tests without
  a radio. It speaks the same GenServer protocol the adapter uses (`{:command,
  frame_id, params}`, `{:subscribe, pid}`, `:info`), records every command, and
  returns canned responses.

  Inject it via `Zigbee.EZSP.Adapter.start_link(ezsp: fake_pid)`.

  To let `form_network`/`reestablish_network` complete, it emits the NETWORK_UP
  stack-status callback (`0x0019`/`0x90`) to its subscriber right after it handles
  the `form_network` (`0x1E`) or a successful `network_init` (`0x17`) command — the
  same moment a real NCP would.

  Per-frame responses can be overridden via `start_link(responses: %{0x17 => <<0x93>>})`.
  """

  use GenServer

  @form_network 0x1E
  @network_init 0x17
  @get_network_parameters 0x28
  @import_transient_key 0x0111
  @stack_status_frame 0x0019
  @network_up 0x90

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts)

  @doc "The recorded command stream, oldest first, as `[{frame_id, params}]`."
  def calls(pid), do: GenServer.call(pid, :__calls)

  @doc "Params of the first recorded command with `frame_id`, or nil."
  def call_params(pid, frame_id) do
    Enum.find_value(calls(pid), fn {id, params} -> if id == frame_id, do: params end)
  end

  @impl true
  def init(opts) do
    {:ok,
     %{
       subscriber: nil,
       calls: [],
       responses: Keyword.get(opts, :responses, %{}),
       net_params: Keyword.get(opts, :net_params, default_net_params())
     }}
  end

  @impl true
  def handle_call({:subscribe, pid}, _from, s), do: {:reply, :ok, %{s | subscriber: pid}}

  def handle_call(:info, _from, s),
    do: {:reply, %{protocol_version: 13, stack_version: "7.5.1.0", stack_type: 2}, s}

  def handle_call(:__calls, _from, s), do: {:reply, Enum.reverse(s.calls), s}

  def handle_call({:command, frame_id, params}, _from, s) do
    s = %{s | calls: [{frame_id, params} | s.calls]}
    resp = response_for(frame_id, s)
    maybe_signal_network_up(frame_id, resp, s)
    {:reply, {:ok, %{params: resp}}, s}
  end

  # Emit NETWORK_UP after a form, or a network_init that reports "coming up" (0x00).
  # The message queues while the adapter is still inside its (deferred) handle_call,
  # so it's processed once `up_from` is armed — exactly like a real NCP.
  defp maybe_signal_network_up(@form_network, _resp, s), do: signal_network_up(s)
  defp maybe_signal_network_up(@network_init, <<0x00>>, s), do: signal_network_up(s)
  defp maybe_signal_network_up(_frame_id, _resp, _s), do: :ok

  defp signal_network_up(%{subscriber: pid}) when is_pid(pid) do
    send(pid, {:ezsp_callback, %{frame_id: @stack_status_frame, params: <<@network_up>>}})
  end

  defp signal_network_up(_s), do: :ok

  defp response_for(frame_id, s) do
    Map.get_lazy(s.responses, frame_id, fn -> default_response(frame_id, s) end)
  end

  defp default_response(@get_network_parameters, s), do: s.net_params
  # importTransientKey returns a 4-byte sl_status; 0 = success.
  defp default_response(@import_transient_key, _s), do: <<0x00, 0x00, 0x00, 0x00>>
  # Everything else: a one-byte status, 0x00 = success.
  defp default_response(_frame_id, _s), do: <<0x00>>

  # A valid EmberNetworkParameters payload (status 0x00 + params) for
  # get_network_parameters: pan 0xABCD, tx 8 dBm, channel 15.
  defp default_net_params do
    <<0x00, 1, 1, 2, 3, 4, 5, 6, 7, 8, 0xCD, 0xAB, 8, 15, 0, 0, 0, 0, 0, 0, 0, 0>>
  end
end
