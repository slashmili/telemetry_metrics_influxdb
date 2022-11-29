defmodule InfluxTelemetryReporter.MixProject do
  use Mix.Project

  @version "0.1.2"
  @description "A generic Telemetry reporter for InfluxDB/Telegraf backend"

  def project do
    [
      app: :influx_telemetry_reporter,
      version: @version,
      elixir: "~> 1.12",
      description: @description,
      docs: docs(),
      start_permanent: Mix.env() == :prod,
      package: package(),
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:telemetry, "~> 0.4 or ~> 1.0"},
      {:ex_doc, ">= 0.19.0", only: :dev},
      {:fluxter, "~> 0.10", only: :dev},
      {:telemetry_metrics, "~> 0.6", only: [:dev, :test]}
    ]
  end

  defp docs do
    [
      main: "InfluxTelemetryReporter",
      source_ref: "v#{@version}",
      source_url: "https://github.com/slashmili/influx_telemetry_reporter"
    ]
  end

  defp package do
    %{
      licenses: ["Apache-2.0"],
      maintainers: ["Milad Rastian"],
      links: %{"GitHub" => "https://github.com/slashmili/influx_telemetry_reporter"}
    }
  end
end
