defmodule Oban.Met.Test do
  use ExUnit.Case, async: true

  describe "initializing storage" do
    test "starting storage servers for oban instances on :init" do
      start_supervised!(
        {Oban, [notifier: Oban.Notifiers.PG, repo: Oban.Met.Repo, testing: :inline]}
      )

      with_backoff(fn ->
        assert %{active: 1} = Supervisor.count_children(Oban.Met.AppSup)
      end)
    end
  end

  defp with_backoff(opts \\ [], fun) do
    total = Keyword.get(opts, :total, 100)
    sleep = Keyword.get(opts, :sleep, 10)

    with_backoff(fun, 0, total, sleep)
  end

  defp with_backoff(fun, count, total, sleep) do
    fun.()
  rescue
    exception in [ExUnit.AssertionError] ->
      if count < total do
        Process.sleep(sleep)

        with_backoff(fun, count + 1, total, sleep)
      else
        reraise(exception, __STACKTRACE__)
      end
  end
end
