defmodule Oban.Met.MixProject do
  use Mix.Project

  def project do
    [
      app: :oban_met,
      version: "0.1.0",
      elixir: "~> 1.13",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  def application do
    [
      extra_applications: [:logger],
      mod: {Oban.Met.Application, []}
    ]
  end

  defp deps do
    [
      {:oban, "~> 2.13"},
      {:telemetry, "~> 1.1"},
      {:benchee, "~> 1.0", only: [:test, :dev], runtime: false},
      {:stream_data, "~> 0.5", only: [:test, :dev]}
    ]
  end
end
