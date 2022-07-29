defmodule Oban.Met.MixProject do
  use Mix.Project

  def project do
    [
      app: :oban_met,
      version: "0.1.0",
      elixir: "~> 1.13",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Oban.Met.Application, []}
    ]
  end

  defp deps do
    [
      {:oban, "~> 2.13"},
      {:telemetry, "~> 1.1"}
    ]
  end
end
