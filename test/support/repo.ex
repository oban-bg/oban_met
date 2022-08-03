defmodule Oban.Met.Repo do
  @moduledoc """
  This is a mock Ecto repo with only the functions necessary to fake out Oban's config check.
  """

  def config, do: []
end

