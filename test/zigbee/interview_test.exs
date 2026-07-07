defmodule Zigbee.InterviewTest do
  use ExUnit.Case, async: true

  alias Zigbee.{Interview, MockAdapter, Message}

  # A fake sensor: one HA endpoint exposing temperature + humidity clusters.
  @descriptors %{
    1 => %{
      profile: 0x0104,
      device: 0x0302,
      in_clusters: [0x0000, 0x0402, 0x0405],
      out_clusters: []
    }
  }

  defp start_device(opts \\ []) do
    {:ok, zb} =
      Zigbee.start_link(
        MockAdapter,
        Keyword.merge([node_id: 0x1234, descriptors: @descriptors], opts)
      )

    :ok = Zigbee.subscribe(zb, self())
    zb
  end

  test "open_and_wait returns the joined device from a normalized event" do
    zb = start_device()
    :ok = MockAdapter.emit_join(zb.ref, 0x1234, <<8, 7, 6, 5, 4, 3, 2, 1>>)

    assert {:ok, %{node_id: 0x1234, eui64: <<8, 7, 6, 5, 4, 3, 2, 1>>}} =
             Interview.open_and_wait(zb)
  end

  test "run interviews the device through the adapter (no EZSP involved)" do
    zb = start_device()

    assert {:ok, result} = Interview.run(zb, 0x1234, <<8, 7, 6, 5, 4, 3, 2, 1>>)
    assert result.endpoints == [1]
    assert [%{endpoint: 1, in_clusters: in_clusters}] = result.descriptors
    assert 0x0402 in in_clusters and 0x0405 in in_clusters

    # a binding was attempted for both the temperature and humidity clusters
    bound = for %{cluster: c} <- result.bindings, do: c
    assert Enum.sort(bound) == [0x0402, 0x0405]
    assert Enum.all?(result.bindings, &match?({:ok, <<_seq, 0x00>>}, &1.bind))
  end

  test "collect decodes an incoming temperature report into °C" do
    zb = start_device()

    # ZCL Report Attributes: attr 0x0000, int16 2350 = 23.50 °C
    report = <<0x18, 0x01, 0x0A, 0x00, 0x00, 0x29, 0x2E, 0x09>>

    send(
      self(),
      {:zigbee, :message,
       %Message{
         source: 0x1234,
         profile: 0x0104,
         cluster: 0x0402,
         src_endpoint: 1,
         dst_endpoint: 1,
         payload: report
       }}
    )

    assert [%{cluster: 0x0402, endpoint: 1, value: 23.5, unit: "°C"}] = Interview.collect(zb, 50)
  end
end
