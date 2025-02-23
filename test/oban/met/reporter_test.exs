defmodule Oban.Met.ReporterTest do
  use Oban.Met.Case

  alias Oban.Met.{Repo, Reporter}
  alias Oban.{Job, Notifier}

  @name Oban.Reporter

  setup :start_supervised_oban

  describe "checkups" do
    @tag oban_opts: [peer: Oban.Peers.Isolated, testing: :disabled]
    test "reporting queried counts", %{conf: conf} do
      pid = start_supervised!({Reporter, conf: conf, name: @name})

      changesets =
        for queue <- ~w(alpha gamma), worker <- ~w(Worker.A Worker.B) do
          Job.new(%{}, queue: queue, worker: worker)
        end

      Oban.insert_all(conf.name, changesets)

      Notifier.listen(conf.name, [:metrics])
      send(pid, :checkpoint)

      assert_receive {:notification, :metrics, payload}

      assert %{"name" => _, "node" => "worker.1"} = payload
      assert %{"metrics" => metrics, "time" => _} = payload

      assert ~w(full_count) = utake(metrics, "series")
      assert ~w(available) = utake(metrics, "state")
      assert ~w(alpha gamma) = utake(metrics, "queue")
    end

    @tag oban_opts: [peer: Oban.Peers.Isolated, prefix: "private", testing: :disabled]
    test "reporting queried counts for an alternate prefix", %{conf: conf} do
      Repo.query!("ALTER TABLE oban_jobs RENAME TO _oban_jobs", [])

      pid = start_supervised!({Reporter, conf: conf, name: @name, estimate_limit: 0})

      Oban.insert!(conf.name, Job.new(%{}, queue: "alpha", worker: "Worker.A"))
      Oban.insert!(conf.name, Job.new(%{}, queue: "gamma", worker: "Worker.B"))

      Notifier.listen(conf.name, [:metrics])

      send(pid, :checkpoint)

      assert_receive {:notification, :metrics, %{"metrics" => metrics}}

      assert "available" in utake(metrics, "state")
      assert ~w(alpha gamma) = utake(metrics, "queue")
    after
      Repo.query!("ALTER TABLE _oban_jobs RENAME TO oban_jobs", [])
    end

    @tag oban_opts: [peer: Oban.Peers.Isolated, testing: :disabled]
    test "resetting checks without any updated counts", %{conf: conf} do
      pid = start_supervised!({Reporter, conf: conf, name: @name})

      Notifier.listen(conf.name, [:metrics])

      job = Oban.insert!(conf.name, Job.new(%{}, queue: :alpha, worker: Worker.A))

      send(pid, :checkpoint)
      assert_receive {:notification, :metrics, %{"metrics" => metrics}}

      assert [%{"data" => [1]}] = utake(metrics, "value")

      Oban.Repo.delete!(conf, job)

      send(pid, :checkpoint)

      assert_receive {:notification, :metrics, %{"metrics" => []}}
    end

    @tag oban_opts: [peer: Oban.Peers.Disabled]
    test "skipping checks when the instance is a follower", %{conf: conf} do
      pid = start_supervised!({Reporter, conf: conf, name: @name})

      Notifier.listen(conf.name, [:metrics])
      send(pid, :checkpoint)

      refute_receive {:notification, :metrics, _}, 20
    end

    @tag oban_opts: [peer: Oban.Peers.Isolated, testing: :disabled]
    test "skipping estimate function creation without auto_migrate", %{conf: conf} do
      pid = start_supervised!({Reporter, conf: conf, name: @name, auto_migrate: false})

      Notifier.listen(conf.name, [:metrics])
      send(pid, :checkpoint)

      assert_receive {:notification, :metrics, _}

      assert %{rows: [[false]]} =
               Repo.query!(
                 "SELECT EXISTS(SELECT * FROM pg_proc WHERE proname = 'oban_count_estimate')",
                 []
               )
    end

    @tag lite: true
    @tag oban_opts: [engine: Oban.Engines.Lite, repo: Oban.Met.LiteRepo, testing: :disabled]
    test "reporting estimates for the Lite engine", %{conf: conf} do
      pid = start_supervised!({Reporter, conf: conf, name: @name, estimate_limit: 0})

      Oban.insert!(conf.name, Job.new(%{}, queue: "alpha", worker: "Worker.A"))
      Oban.insert!(conf.name, Job.new(%{}, queue: "gamma", worker: "Worker.B"))

      Notifier.listen(conf.name, [:metrics])
      send(pid, :checkpoint)

      assert_receive {:notification, :metrics, %{"metrics" => metrics}}

      assert "available" in utake(metrics, "state")
      assert ~w(alpha gamma) = utake(metrics, "queue")
    end
  end

  defp utake(metrics, key) do
    metrics
    |> Enum.map(& &1[key])
    |> :lists.usort()
  end
end
