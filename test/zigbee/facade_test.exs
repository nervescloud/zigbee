defmodule Zigbee.FacadeTest do
  use ExUnit.Case, async: true

  alias Zigbee.MockAdapter

  test "reestablish_network/2 restores a stored network" do
    {:ok, zb} = Zigbee.start_link(MockAdapter, has_network: true)
    assert {:ok, %{source: :reestablished}} = Zigbee.reestablish_network(zb)
  end

  test "reestablish_network/2 reports :no_network on a fresh radio" do
    {:ok, zb} = Zigbee.start_link(MockAdapter, has_network: false)
    assert {:error, :no_network} = Zigbee.reestablish_network(zb)
  end

  test "reestablish_or_form_network/2 re-establishes when a network is stored" do
    {:ok, zb} = Zigbee.start_link(MockAdapter, has_network: true)
    assert {:ok, %{source: :reestablished}} = Zigbee.reestablish_or_form_network(zb)
  end

  test "reestablish_or_form_network/2 forms when there is no stored network" do
    {:ok, zb} = Zigbee.start_link(MockAdapter, has_network: false)
    assert {:ok, %{source: :formed}} = Zigbee.reestablish_or_form_network(zb)
  end
end
