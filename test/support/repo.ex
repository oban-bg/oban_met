defmodule Oban.Met.Repo do
  @moduledoc false

  use Ecto.Repo, otp_app: :oban_met, adapter: Ecto.Adapters.Postgres
end

defmodule Oban.Met.LiteRepo do
  @moduledoc false

  use Ecto.Repo, otp_app: :oban_met, adapter: Ecto.Adapters.SQLite3
end
