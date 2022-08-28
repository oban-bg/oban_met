defmodule Oban.Met.Test do
  use Oban.Met.Case, async: false

  describe "initializing storage with :auto_mode enabled" do
    setup do
      Application.stop(:oban_met)
      Application.put_env(:oban_met, :auto_mode, true)
      Application.ensure_started(:oban_met)

      on_exit(fn ->
        Application.stop(:oban_met)
        Application.put_env(:oban_met, :auto_mode, false)
        Application.ensure_started(:oban_met)
      end)
    end

    test "starting storage servers for oban instances on :init" do
      start_supervised!(
        {Oban, [notifier: Oban.Notifiers.PG, repo: Oban.Met.Repo, testing: :inline]}
      )

      with_backoff(fn ->
        assert %{active: active} = Supervisor.count_children(Oban.Met.AppSup)
        assert active >= 1
      end)
    end
  end
end
