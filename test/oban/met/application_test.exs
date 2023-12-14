defmodule Oban.Met.Test do
  use Oban.Met.Case

  @opts [notifier: Oban.Notifiers.PG, repo: Oban.Met.Repo]

  setup do
    Application.put_env(:oban_met, :auto_start, true)

    on_exit(fn -> Application.put_env(:oban_met, :auto_start, false) end)
  end

  describe "initializing storage with :auto_mode enabled" do
    test "starting supervision for oban instances on :init" do
      start_supervised!({Oban, @opts})

      with_backoff(fn -> assert 1 == count_supervised() end)
    end

    test "stopping supervised instances when Oban shuts down" do
      start_supervised!({Oban, @opts})

      with_backoff(fn -> assert 1 == count_supervised() end)

      stop_supervised!(Oban)

      with_backoff(fn -> assert 0 == count_supervised() end)
    end

    test "starting supervision for already running oban instances" do
      Application.stop(:oban_met)

      start_supervised!({Oban, @opts})

      Application.start(:oban_met)

      with_backoff(fn -> assert 1 == count_supervised() end)
    end

    defp count_supervised do
      Oban.Met.Supervisor
      |> Supervisor.which_children()
      |> Enum.filter(fn {_id, _pid, _mode, [mod]} -> mod == Oban.Met end)
      |> length()
    end
  end
end
