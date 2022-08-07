defmodule Oban.Met.ReporterTest do
  use ExUnit.Case, async: true

  alias Oban.{Job, Notifier}
  alias Oban.Met.{Reporter, Sketch}

  import :telemetry, only: [execute: 3]

  @opts [
    node: "worker.1",
    notifier: Oban.Notifiers.PG,
    prefix: "reporter",
    repo: Oban.Met.Repo,
    testing: :inline
  ]
  @name Oban.Reporter

  describe "capturing" do
    setup :start_supervised_reporter

    test "capturing job start counts", %{conf: conf, pid: pid} do
      meta = %{conf: conf, job: %Job{queue: "default"}}

      execute([:oban, :job, :start], %{}, meta)
      execute([:oban, :job, :start], %{}, meta)
      execute([:oban, :job, :start], %{}, meta)

      metrics = Reporter.all_metrics(pid)

      assert +3 == find_metric(metrics, name: :executing)
      assert -3 == find_metric(metrics, name: :available)
    end

    test "capturing job stop and exception counts", %{conf: conf, pid: pid} do
      meta = %{conf: conf, job: %Job{queue: "default"}, state: :success}
      measure = %{duration: 100000, queue_time: 50000}

      execute([:oban, :job, :stop], measure, meta)
      execute([:oban, :job, :stop], measure, meta)
      execute([:oban, :job, :stop], measure, %{meta | state: :cancelled})
      execute([:oban, :job, :stop], measure, %{meta | state: :snoozed})
      execute([:oban, :job, :exception], measure, %{meta | state: :failure})
      execute([:oban, :job, :exception], measure, %{meta | state: :discard})

      metrics = Reporter.all_metrics(pid)

      assert -6 = find_metric(metrics, name: :executing)
      assert 1 = find_metric(metrics, name: :cancelled)
      assert 2 = find_metric(metrics, name: :completed)
      assert 1 = find_metric(metrics, name: :discarded)
      assert 1 = find_metric(metrics, name: :retryable)
      assert 1 = find_metric(metrics, name: :scheduled)
    end

    test "capturing counts separately for every queue", %{conf: conf, pid: pid} do
      meta_1 = %{conf: conf, job: %Job{queue: "alpha"}}
      meta_2 = %{conf: conf, job: %Job{queue: "gamma"}}

      execute([:oban, :job, :start], %{}, meta_1)
      execute([:oban, :job, :start], %{}, meta_2)
      execute([:oban, :job, :start], %{}, meta_1)

      metrics = Reporter.all_metrics(pid)

      assert 2 == find_metric(metrics, name: :executing, queue: "alpha")
      assert 1 == find_metric(metrics, name: :executing, queue: "gamma")
    end

    test "capturing job stop measurements", %{conf: conf, pid: pid} do
      meta = %{conf: conf, job: %Job{queue: "default"}, state: :success}

      execute([:oban, :job, :stop], %{duration: 10000, queue_time: 10000}, meta)
      execute([:oban, :job, :stop], %{duration: 15000, queue_time: 20000}, meta)
      execute([:oban, :job, :stop], %{duration: 10000, queue_time: 10000}, meta)

      metrics = Reporter.all_metrics(pid)

      assert %Sketch{size: 3} = find_metric(metrics, name: :exec_time)
      assert %Sketch{size: 3} = find_metric(metrics, name: :wait_time)
    end
  end

  describe "reporting" do
    setup :start_supervised_reporter

    test "reporting captured metrics", %{conf: conf, pid: pid} do
      :ok = Notifier.listen(conf.name, [:gossip])

      for _ <- 1..3 do
        meta = %{conf: conf, job: %Job{queue: "default", worker: "Worker.A"}, state: :success}

        execute([:oban, :job, :start], %{}, meta)
        execute([:oban, :job, :stop], %{duration: 100000, queue_time: 10000}, meta)
      end

      assert_receive {:notification, :gossip, payload}

      assert %{"name" => _, "node" => "worker.1", "metrics" => metrics} = payload

      metrics = Map.new(metrics, fn map -> {map["name"], map} end)

      assert %{"queue" => "default", "type" => "count", "value" => 0} = metrics["executing"]
      assert %{"queue" => "default", "type" => "count", "value" => -3} = metrics["available"]
      assert %{"queue" => "default", "type" => "count", "value" => 3} = metrics["completed"]

      assert %{
               "queue" => "default",
               "worker" => "Worker.A",
               "type" => "sketch",
               "value" => %{"size" => 3}
             } = metrics["exec_time"]

      assert %{
               "queue" => "default",
               "worker" => "Worker.A",
               "type" => "sketch",
               "value" => %{"size" => 3}
             } = metrics["wait_time"]

      assert [] = Reporter.all_metrics(pid)
    end
  end

  defp find_metric(metrics, fields) do
    metrics
    |> Enum.find(fn {labels, _} ->
      Enum.all?(fields, fn {key, val} -> Map.get(labels, key) == val end)
    end)
    |> elem(1)
  end

  defp start_supervised_reporter(_context) do
    name = make_ref()
    start_supervised!({Oban, Keyword.put(@opts, :name, name)})

    conf = Oban.config(name)
    pid = start_supervised!({Reporter, conf: conf, interval: 10, name: @name})

    {:ok, conf: conf, pid: pid}
  end
end
