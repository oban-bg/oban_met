defmodule Oban.Met.ReporterTest do
  use Oban.Met.Case

  import :telemetry, only: [execute: 3]

  alias Oban.{Job, Notifier}
  alias Oban.Met.{Gauge, Repo, Reporter, Sketch}

  @name Oban.Reporter

  describe "checkpoints" do
    setup :start_supervised_oban

    test "broadcasting current queue and state gauges", %{conf: conf} do
      pid = start_supervised!({Reporter, conf: conf, name: @name})

      queues = ~w(alpha gamma delta)
      states = Job.states()

      for queue <- queues, state <- states do
        %{}
        |> Job.new(queue: queue, state: to_string(state), worker: "Bogus")
        |> Repo.insert!()
      end

      send(pid, :checkpoint)

      Process.sleep(10)

      metrics = Reporter.all_metrics(pid)

      assert length(metrics) == length(states) * length(queues)

      assert [:gauge] = for({%{type: type}, _} <- metrics, uniq: true, do: type)
      assert [%Gauge{}] = for({_, value} <- metrics, uniq: true, do: value)
    end
  end

  describe "capturing" do
    setup [:start_supervised_oban, :start_supervised_reporter]

    test "capturing job start counts", %{conf: conf, pid: pid} do
      meta = %{conf: conf, job: %Job{queue: "default"}}

      execute([:oban, :job, :start], %{}, meta)
      execute([:oban, :job, :start], %{}, meta)
      execute([:oban, :job, :start], %{}, meta)

      metrics = Reporter.all_metrics(pid)

      assert +3 == find_metric(metrics, series: :executing)
      assert -3 == find_metric(metrics, series: :available)
    end

    test "capturing job stop and exception counts", %{conf: conf, pid: pid} do
      meta = %{conf: conf, job: %Job{queue: "default"}, state: :success}
      measure = %{duration: 100_000, queue_time: 50_000}

      execute([:oban, :job, :stop], measure, meta)
      execute([:oban, :job, :stop], measure, meta)
      execute([:oban, :job, :stop], measure, %{meta | state: :cancelled})
      execute([:oban, :job, :stop], measure, %{meta | state: :snoozed})
      execute([:oban, :job, :exception], measure, %{meta | state: :failure})
      execute([:oban, :job, :exception], measure, %{meta | state: :discard})

      metrics = Reporter.all_metrics(pid)

      assert -6 = find_metric(metrics, series: :executing)
      assert 1 = find_metric(metrics, series: :cancelled)
      assert 2 = find_metric(metrics, series: :completed)
      assert 1 = find_metric(metrics, series: :discarded)
      assert 1 = find_metric(metrics, series: :retryable)
      assert 1 = find_metric(metrics, series: :scheduled)
    end

    test "capturing counts separately for every queue", %{conf: conf, pid: pid} do
      meta_1 = %{conf: conf, job: %Job{queue: "alpha"}}
      meta_2 = %{conf: conf, job: %Job{queue: "gamma"}}

      execute([:oban, :job, :start], %{}, meta_1)
      execute([:oban, :job, :start], %{}, meta_2)
      execute([:oban, :job, :start], %{}, meta_1)

      metrics = Reporter.all_metrics(pid)

      assert 2 == find_metric(metrics, series: :executing, queue: "alpha")
      assert 1 == find_metric(metrics, series: :executing, queue: "gamma")
    end

    test "capturing job stop measurements", %{conf: conf, pid: pid} do
      meta = %{conf: conf, job: %Job{queue: "default"}, state: :success}

      execute([:oban, :job, :stop], %{duration: 10_000, queue_time: 10_000}, meta)
      execute([:oban, :job, :stop], %{duration: 15_000, queue_time: 20_000}, meta)
      execute([:oban, :job, :stop], %{duration: 10_000, queue_time: 10_000}, meta)

      metrics = Reporter.all_metrics(pid)

      assert %Sketch{size: 3} = find_metric(metrics, series: :exec_time)
      assert %Sketch{size: 3} = find_metric(metrics, series: :wait_time)
    end

    @tag :engine_events
    test "capturing single insertion counts", %{conf: conf, pid: pid} do
      event = [:oban, :engine, :insert_job, :stop]

      execute(event, %{}, %{conf: conf, job: %Job{queue: "alpha", state: "available"}})
      execute(event, %{}, %{conf: conf, job: %Job{queue: "gamma", state: "available"}})
      execute(event, %{}, %{conf: conf, job: %Job{queue: "gamma", state: "available"}})
      execute(event, %{}, %{conf: conf, job: %Job{queue: "alpha", state: "scheduled"}})

      metrics = Reporter.all_metrics(pid)

      assert 1 == find_metric(metrics, series: :available, queue: "alpha")
      assert 2 == find_metric(metrics, series: :available, queue: "gamma")
      assert 1 == find_metric(metrics, series: :scheduled, queue: "alpha")
    end

    @tag :engine_events
    test "capturing bulk insertion counts", %{conf: conf, pid: pid} do
      event = [:oban, :engine, :insert_all_jobs, :stop]

      jobs = [
        %Job{queue: "alpha", state: "available"},
        %Job{queue: "alpha", state: "scheduled"},
        %Job{queue: "gamma", state: "available"},
        %Job{queue: "gamma", state: "retryable"},
        %Job{queue: "gamma", state: "available"}
      ]

      execute(event, %{}, %{conf: conf, jobs: jobs})

      metrics = Reporter.all_metrics(pid)

      assert 1 == find_metric(metrics, series: :available, queue: "alpha")
      assert 2 == find_metric(metrics, series: :available, queue: "gamma")
      assert 1 == find_metric(metrics, series: :retryable, queue: "gamma")
      assert 1 == find_metric(metrics, series: :scheduled, queue: "alpha")
    end

    @tag :engine_events
    test "capturing bulk cancellation counts", %{conf: conf, pid: pid} do
      jobs = [
        %Job{queue: "alpha", state: "executing"},
        %Job{queue: "alpha", state: "scheduled"},
        %Job{queue: "gamma", state: "retryable"},
        %Job{queue: "gamma", state: "available"}
      ]

      event = [:oban, :engine, :cancel_all_jobs, :stop]

      insert_tracked(conf, jobs)

      execute(event, %{}, %{conf: conf, jobs: jobs})

      metrics = Reporter.all_metrics(pid)

      assert 2 == find_metric(metrics, series: :cancelled, queue: "alpha")
      assert 2 == find_metric(metrics, series: :cancelled, queue: "gamma")

      assert 0 == find_metric(metrics, series: :executing, queue: "alpha")
      assert 0 == find_metric(metrics, series: :scheduled, queue: "alpha")
      assert 0 == find_metric(metrics, series: :retryable, queue: "gamma")
      assert 0 == find_metric(metrics, series: :available, queue: "gamma")
    end

    @tag :engine_events
    test "capturing bulk retry counts", %{conf: conf, pid: pid} do
      jobs = [
        %Job{queue: "alpha", state: "retryable"},
        %Job{queue: "alpha", state: "retryable"},
        %Job{queue: "gamma", state: "completed"},
        %Job{queue: "gamma", state: "cancelled"}
      ]

      event = [:oban, :engine, :retry_all_jobs, :stop]

      insert_tracked(conf, jobs)

      execute(event, %{}, %{conf: conf, jobs: jobs})

      metrics = Reporter.all_metrics(pid)

      assert 2 == find_metric(metrics, series: :available, queue: "alpha")
      assert 2 == find_metric(metrics, series: :available, queue: "gamma")

      assert 0 == find_metric(metrics, series: :retryable, queue: "alpha")
      assert 0 == find_metric(metrics, series: :retryable, queue: "alpha")
      assert 0 == find_metric(metrics, series: :completed, queue: "gamma")
      assert 0 == find_metric(metrics, series: :cancelled, queue: "gamma")
    end

    @tag :plugin_events
    test "capturing pruned_job counts", %{conf: conf, pid: pid} do
      insert_tracked(conf, [
        %Job{queue: "alpha", state: "completed"},
        %Job{queue: "alpha", state: "completed"},
        %Job{queue: "alpha", state: "cancelled"},
        %Job{queue: "alpha", state: "cancelled"},
        %Job{queue: "alpha", state: "discarded"},
        %Job{queue: "gamma", state: "completed"}
      ])

      jobs = [
        %Job{queue: "alpha", state: "completed"},
        %Job{queue: "alpha", state: "cancelled"},
        %Job{queue: "alpha", state: "discarded"},
        %Job{queue: "gamma", state: "completed"}
      ]

      execute([:oban, :plugin, :stop], %{}, %{conf: conf, pruned_jobs: jobs})

      metrics = Reporter.all_metrics(pid)

      assert 1 == find_metric(metrics, series: :completed, queue: "alpha")
      assert 1 == find_metric(metrics, series: :cancelled, queue: "alpha")
      assert 0 == find_metric(metrics, series: :discarded, queue: "alpha")
      assert 0 == find_metric(metrics, series: :completed, queue: "gamma")
    end

    @tag :plugin_events
    test "capturing staged_job counts", %{conf: conf, pid: pid} do
      insert_tracked(conf, [
        %Job{queue: "alpha", state: "scheduled"},
        %Job{queue: "alpha", state: "scheduled"},
        %Job{queue: "alpha", state: "retryable"},
        %Job{queue: "gamma", state: "scheduled"}
      ])

      jobs = [
        %Job{queue: "alpha", state: "scheduled"},
        %Job{queue: "alpha", state: "retryable"},
        %Job{queue: "gamma", state: "scheduled"}
      ]

      execute([:oban, :plugin, :stop], %{}, %{conf: conf, staged_jobs: jobs})

      metrics = Reporter.all_metrics(pid)

      assert 1 == find_metric(metrics, series: :scheduled, queue: "alpha")
      assert 0 == find_metric(metrics, series: :retryable, queue: "alpha")
      assert 2 == find_metric(metrics, series: :available, queue: "alpha")

      assert 0 == find_metric(metrics, series: :scheduled, queue: "gamma")
      assert 1 == find_metric(metrics, series: :available, queue: "gamma")
    end

    @tag :plugin_events
    test "capturing rescued and discarded counts", %{conf: conf, pid: pid} do
      insert_tracked(conf, [
        %Job{queue: "alpha", state: "executing"},
        %Job{queue: "alpha", state: "executing"},
        %Job{queue: "alpha", state: "executing"},
        %Job{queue: "gamma", state: "executing"},
        %Job{queue: "gamma", state: "executing"}
      ])

      rescued_jobs = [
        %Job{queue: "alpha", state: "executing"},
        %Job{queue: "gamma", state: "executing"}
      ]

      discarded_jobs = [
        %Job{queue: "alpha", state: "executing"},
        %Job{queue: "gamma", state: "executing"}
      ]

      meta = %{conf: conf, rescued_jobs: rescued_jobs, discarded_jobs: discarded_jobs}

      execute([:oban, :plugin, :stop], %{}, meta)

      metrics = Reporter.all_metrics(pid)

      assert 1 == find_metric(metrics, series: :executing, queue: "alpha")
      assert 1 == find_metric(metrics, series: :available, queue: "alpha")
      assert 1 == find_metric(metrics, series: :discarded, queue: "alpha")
      assert 0 == find_metric(metrics, series: :executing, queue: "gamma")
      assert 1 == find_metric(metrics, series: :available, queue: "gamma")
      assert 1 == find_metric(metrics, series: :discarded, queue: "gamma")
    end
  end

  describe "reporting" do
    setup [:start_supervised_oban, :start_supervised_reporter]

    test "reporting captured metrics", %{conf: conf, pid: pid} do
      :ok = Notifier.listen(conf.name, [:gossip])

      for _ <- 1..3 do
        meta = %{conf: conf, job: %Job{queue: "default", worker: "Worker.A"}, state: :success}

        execute([:oban, :job, :start], %{}, meta)
        execute([:oban, :job, :stop], %{duration: 100_000, queue_time: 10_000}, meta)
      end

      assert_receive {:notification, :gossip, payload}

      assert %{"name" => _, "metrics" => metrics} = payload

      metrics = Map.new(metrics, fn map -> {map["series"], map} end)

      assert %{"queue" => "default", "type" => "delta", "value" => 0} = metrics["executing"]
      assert %{"queue" => "default", "type" => "delta", "value" => -3} = metrics["available"]
      assert %{"queue" => "default", "type" => "delta", "value" => 3} = metrics["completed"]

      assert %{
               "node" => "worker.1",
               "queue" => "default",
               "worker" => "Worker.A",
               "type" => "sketch",
               "value" => %{"size" => 3}
             } = metrics["exec_time"]

      assert %{
               "node" => "worker.1",
               "queue" => "default",
               "worker" => "Worker.A",
               "type" => "sketch",
               "value" => %{"size" => 3}
             } = metrics["wait_time"]

      assert [] = Reporter.all_metrics(pid)
    end
  end

  defp insert_tracked(conf, jobs) do
    execute([:oban, :engine, :insert_all_jobs, :stop], %{}, %{conf: conf, jobs: jobs})
  end

  defp find_metric(metrics, fields) do
    finder = fn {labels, _} ->
      Enum.all?(fields, fn {key, val} -> Map.get(labels, key) == val end)
    end

    case Enum.find(metrics, finder) do
      {_label, count} -> count
      nil -> :error
    end
  end

  defp start_supervised_reporter(%{conf: conf}) do
    pid = start_supervised!({Reporter, conf: conf, report_interval: 10, name: @name})

    {:ok, conf: conf, pid: pid}
  end
end
