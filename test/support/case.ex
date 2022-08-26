defmodule Oban.Met.Case do
  @moduledoc false

  use ExUnit.CaseTemplate

  alias Ecto.Adapters.SQL.Sandbox

  using do
    quote do
      import Oban.Met.Case
    end
  end

  setup tags do
    pid = Sandbox.start_owner!(Oban.Met.Repo, shared: not tags[:async])

    on_exit(fn -> Sandbox.stop_owner(pid) end)

    :ok
  end
end
