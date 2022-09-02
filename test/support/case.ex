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

  def start_supervised_oban(context) do
    oban_opts = Map.get(context, :oban_opts, [])

    name = make_ref()

    opts =
      Keyword.merge(oban_opts,
        name: name,
        node: "worker.1",
        notifier: Oban.Notifiers.PG,
        repo: Oban.Met.Repo,
        testing: :manual
      )

    start_supervised!({Oban, opts})

    conf = Oban.config(name)

    {:ok, conf: conf}
  end

  def with_backoff(opts \\ [], fun) do
    total = Keyword.get(opts, :total, 100)
    sleep = Keyword.get(opts, :sleep, 1)

    with_backoff(fun, 0, total, sleep)
  end

  def with_backoff(fun, count, total, sleep) do
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
