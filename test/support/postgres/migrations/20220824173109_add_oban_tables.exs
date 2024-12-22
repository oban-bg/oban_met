defmodule Oban.Met.Repo.Migrations.AddObanTables do
  use Ecto.Migration

  def up do
    Oban.Migrations.up()
    Oban.Migrations.up(prefix: "private")
  end

  def down do
    Oban.Migrations.down()
    Oban.Migrations.down(prefix: "private")
  end
end
