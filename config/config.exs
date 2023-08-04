import Config

config :oban_met, auto_start: false

config :oban_met, ecto_repos: [Oban.Pro.Repo]

config :oban_met, Oban.Met.Repo,
  priv: "test/support/",
  url: System.get_env("DATABASE_URL") || "postgres://localhost:5432/oban_met_test",
  pool: Ecto.Adapters.SQL.Sandbox

config :logger, level: :warning

config :stream_data, max_runs: 40
