defmodule Oban.Met.MixProject do
  use Mix.Project

  @source_url "https://github.com/oban-bg/oban_met"
  @version "1.0.3"

  def project do
    [
      app: :oban_met,
      version: @version,
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      docs: docs(),
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

  def application do
    [
      extra_applications: [:logger],
      mod: {Oban.Met.Application, []},
      env: [auto_start: true, auto_testing_modes: [:disabled]]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp package do
    [
      maintainers: ["Parker Selbert"],
      licenses: ["Apache-2.0"],
      files: ~w(lib .formatter.exs mix.exs README* CHANGELOG* LICENSE*),
      links: %{
        Website: "https://oban.pro",
        Changelog: "#{@source_url}/blob/main/CHANGELOG.md",
        GitHub: @source_url
      }
    ]
  end

  defp docs do
    [
      main: "Oban.Met",
      source_ref: "v#{@version}",
      source_url: @source_url,
      formatters: ["html"],
      api_reference: false,
      extra_section: "GUIDES",
      extras: extras(),
      groups_for_modules: groups_for_modules(),
      skip_undefined_reference_warnings_on: ["CHANGELOG.md"]
    ]
  end

  defp extras do
    [
      "CHANGELOG.md": [filename: "changelog", title: "Changelog"]
    ]
  end

  defp groups_for_modules do
    [
      Values: [
        Oban.Met.Value,
        Oban.Met.Values.Gauge,
        Oban.Met.Values.Sketch
      ]
    ]
  end

  defp deps do
    [
      {:oban, "~> 2.19"},
      {:ecto_sqlite3, "~> 0.18", only: [:test, :dev]},
      {:postgrex, "~> 0.19", only: [:test, :dev]},
      {:stream_data, "~> 1.1", only: [:test, :dev]},
      {:benchee, "~> 1.3", only: [:test, :dev], runtime: false},
      {:credo, "~> 1.7", only: [:test, :dev], runtime: false},
      {:dialyxir, "~> 1.3", only: [:test, :dev], runtime: false},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:makeup_diff, "~> 0.1", only: :dev, runtime: false}
    ]
  end

  defp aliases do
    [
      release: [
        "cmd git tag v#{@version} -f",
        "cmd git push",
        "cmd git push --tags",
        "hex.publish --yes"
      ],
      "test.reset": ["ecto.drop --quiet", "test.setup"],
      "test.setup": ["ecto.create --quiet", "ecto.migrate --quiet"],
      "test.ci": [
        "format --check-formatted",
        "deps.unlock --check-unused",
        "credo",
        "test --raise",
        "dialyzer"
      ]
    ]
  end
end
