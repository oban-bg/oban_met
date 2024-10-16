defmodule Oban.Met.MixProject do
  use Mix.Project

  @version "0.1.11"

  def project do
    [
      app: :oban_met,
      version: @version,
      elixir: "~> 1.13",
      elixirc_paths: elixirc_paths(Mix.env()),
      prune_code_paths: false,
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

  defp aliases do
    [
      release: [
        "cmd rm -r doc",
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
      {:oban, "~> 2.15"},
      {:telemetry, "~> 1.1"},
      {:postgrex, "~> 0.19", only: [:test, :dev]},
      {:stream_data, "~> 1.1", only: [:test, :dev]},
      {:benchee, "~> 1.3", only: [:test, :dev], runtime: false},
      {:credo, "~> 1.7", only: [:test, :dev], runtime: false},
      {:dialyxir, "~> 1.3", only: [:test, :dev], runtime: false},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:makeup_diff, "~> 0.1", only: :dev, runtime: false},
      {:lys_publish, "~> 0.1", only: :dev, path: "../lys_publish", optional: true, runtime: false}
    ]
  end

  defp docs do
    [
      main: "overview",
      source_ref: "v#{@version}",
      formatters: ["html"],
      api_reference: false,
      extra_section: "GUIDES",
      extras: extras(),
      groups_for_extras: groups_for_extras(),
      groups_for_modules: groups_for_modules(),
      homepage_url: "/",
      skip_undefined_reference_warnings_on: ["CHANGELOG.md"],
      before_closing_body_tag: fn _ ->
        """
        <script>document.querySelector('footer.footer p').remove()</script>
        """
      end
    ]
  end

  defp extras do
    [
      "guides/introduction/overview.md",
      "guides/introduction/installation.md",
      "CHANGELOG.md": [filename: "changelog", title: "Changelog"]
    ]
  end

  defp groups_for_extras do
    [Introduction: ~r/guides\/introduction\/.?/]
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
end
