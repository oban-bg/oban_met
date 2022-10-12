defmodule Oban.Met.Test do
  use Oban.Met.Case, async: false

  describe "initializing storage with :auto_mode enabled" do
    test "starting storage servers for oban instances on :init" do
      Application.put_env(:oban_met, :auto_start, true)

      on_exit(fn -> Application.put_env(:oban_met, :auto_start, false) end)

      start_supervised!(
        {Oban, [notifier: Oban.Notifiers.PG, repo: Oban.Met.Repo]}
      )

      with_backoff(fn ->
        assert %{active: active} = Supervisor.count_children(Oban.Met.AppSup)
        assert active >= 1
      end)
    end
  end
end
