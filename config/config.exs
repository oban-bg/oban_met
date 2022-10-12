import Config

config :oban_met, auto_start: false

config :oban_met, ecto_repos: [Oban.Pro.Repo]

config :oban_met, Oban.Met.Repo,
  database: "oban_met_test",
  pool: Ecto.Adapters.SQL.Sandbox

config :logger, level: :warn

config :stream_data, max_runs: 40
