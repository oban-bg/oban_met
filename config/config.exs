import Config

config :logger, level: :warning

config :oban_met, auto_start: false, reporter: [estimate_limit: 1000]

config :oban_met, Oban.Met.Repo,
  priv: "test/support/postgres",
  url: System.get_env("DATABASE_URL") || "postgres://localhost:5432/oban_met_test",
  pool: Ecto.Adapters.SQL.Sandbox

config :oban_met, Oban.Met.LiteRepo,
  database: "priv/oban.db",
  priv: "test/support/sqlite",
  stacktrace: true,
  temp_store: :memory

config :oban_met, ecto_repos: [Oban.Met.Repo, Oban.Met.LiteRepo]

config :stream_data, max_runs: 40
