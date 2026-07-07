defmodule Zigbee.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/nervescloud/zigbee"

  def project do
    [
      app: :zigbee,
      version: @version,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: "A Zigbee stack built in pure Elixir",
      name: "zigbee",
      source_url: @source_url,
      docs: docs(),
      package: package()
    ]
  end

  def application do
    # Library only, no supervision tree. Callers start the pieces they need
    # (e.g. Zigbee.EZSP.start_link/1).
    [extra_applications: [:logger]]
  end

  defp deps do
    [
      # Serial transport for the EZSP backend (ASH over UART). Works identically
      # on macOS (dev) and Nerves (deploy).
      {:circuits_uart, "~> 1.5"},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      extras: ["README.md", "CHANGELOG.md"],
      groups_for_modules: [
        "Core API": [Zigbee, Zigbee.Adapter, Zigbee.Message, Zigbee.Interview],
        Codecs: [Zigbee.ZCL, Zigbee.ZDO],
        "EmberZNet backend": [
          Zigbee.EZSP.Adapter,
          Zigbee.EZSP,
          Zigbee.EZSP.Frame,
          Zigbee.EZSP.Status,
          Zigbee.EZSP.ASH,
          Zigbee.EZSP.ASH.Connection,
          Zigbee.EZSP.Diagnostics
        ]
      ]
    ]
  end

  defp package do
    [
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib examples mix.exs README.md CHANGELOG.md .formatter.exs)
    ]
  end

  # The test-only fake backend (Zigbee.MockAdapter) lives in test/support.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]
end
