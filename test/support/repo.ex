defmodule Oban.Met.Repo do
  use Ecto.Repo, otp_app: :oban_met, adapter: Ecto.Adapters.Postgres
end
