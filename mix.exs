defmodule Oban.Met.MixProject do
  use Mix.Project

  @version "0.1.0"

  def project do
    [
      app: :oban_met,
      version: @version,
      elixir: "~> 1.13",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      package: package(),
      preferred_cli_env: [
        "ecto.gen.migration": :test,
        "test.ci": :test,
        "test.reset": :test,
        "test.setup": :test
      ],

      # Description
      name: "Oban Met",
      description:
        "A distributed, compacting, multidimensional, telemetry-powered time series datastore",

      # Dialyzer
      dialyzer: [
        plt_add_apps: [:ex_unit],
        plt_core_path: "_build/#{Mix.env()}",
        flags: [:error_handling, :underspecs]
      ]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  def application do
    [
      extra_applications: [:logger],
      mod: {Oban.Met.Application, []},
      env: [auto_start: true, auto_testing_modes: [:disabled]]
    ]
  end

  def package do
    [
      organization: "oban",
      files: ~w(lib/met.ex lib/oban mix.exs),
      licenses: ["Commercial"],
      links: []
    ]
  end

  def aliases do
    [
      release: [
        "cmd git tag v#{@version}",
        "cmd git push",
        "cmd git push --tags",
        "hex.publish package --yes",
        "lys.publish"
      ],
      "test.reset": ["ecto.drop -r Oban.Met.Repo", "test.setup"],
      "test.setup": ["ecto.create -r Oban.Met.Repo --quiet", "ecto.migrate -r Oban.Met.Repo"],
      "test.ci": [
        "format --check-formatted",
        "deps.unlock --check-unused",
        "credo",
        "test --raise",
        "dialyzer"
      ]
    ]
  end

  defp deps do
    [
      {:oban, "~> 2.14", github: "sorentwo/oban"},
      {:telemetry, "~> 1.1"},
      {:benchee, "~> 1.0", only: [:test, :dev], runtime: false},
      {:credo, "~> 1.6", only: [:test, :dev], runtime: false},
      {:dialyxir, "~> 1.0", only: [:test, :dev], runtime: false},
      {:postgrex, "~> 0.16", only: [:test, :dev]},
      {:stream_data, "~> 0.5", only: [:test, :dev]},
      {:lys_publish, "~> 0.1",
       only: [:dev], optional: true, runtime: false, path: "../lys_publish"}
    ]
  end
end
