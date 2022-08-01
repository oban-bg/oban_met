defmodule Oban.Met.ReporterTest do
  use ExUnit.Case, async: true

  alias Oban.{Config, Job}
  alias Oban.Notifiers.PG, as: Notifier
  alias Oban.Met.Reporter

  import :telemetry, only: [execute: 3]

  @conf %Config{name: Oban, node: "worker.1", notifier: Notifier, prefix: "public", repo: nil}
  @name Oban.Reporter

  describe "capturing" do
    test "capturing job start counts" do
      {:ok, pid} = start_supervised({Reporter, conf: @conf, name: @name})

      meta = %{conf: @conf, job: %Job{queue: "default"}}

      execute([:oban, :job, :start], %{}, meta)
      execute([:oban, :job, :start], %{}, meta)
      execute([:oban, :job, :start], %{}, meta)

      metrics = Reporter.all_metrics(pid)

      assert +3 == find_metric(metrics, name: :executing)
      assert -3 == find_metric(metrics, name: :available)
    end

    test "capturing queues separately" do
      {:ok, pid} = start_supervised({Reporter, conf: @conf, name: @name})

      meta_1 = %{conf: @conf, job: %Job{queue: "alpha"}}
      meta_2 = %{conf: @conf, job: %Job{queue: "gamma"}}

      execute([:oban, :job, :start], %{}, meta_1)
      execute([:oban, :job, :start], %{}, meta_2)
      execute([:oban, :job, :start], %{}, meta_1)

      metrics = Reporter.all_metrics(pid)

      assert 2 == find_metric(metrics, name: :executing, queue: "alpha")
      assert 1 == find_metric(metrics, name: :executing, queue: "gamma")
    end

    test "capturing job stop and exception counts" do
      {:ok, pid} = start_supervised({Reporter, conf: @conf, name: @name})

      meta = %{conf: @conf, job: %Job{queue: "default"}, state: :success}
      measure = %{duration: 1000, queue_time: 500}

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
  end

  describe "reporting" do
    test "reporting captured metrics" do
      name = Oban.Registry.via(@conf.name, Oban.Notifier)

      {:ok, pgn} = start_supervised({Notifier, conf: @conf, name: name})
      {:ok, pid} = start_supervised({Reporter, conf: @conf, interval: 10, name: @name})

      :ok = Notifier.listen(pgn, [:gossip])

      for _ <- 1..3 do
        execute([:oban, :job, :start], %{}, %{conf: @conf, job: %Job{queue: "default"}})
      end

      assert_receive {:notification, :gossip, payload}

      assert %{"name" => "Oban", "node" => "worker.1", "metrics" => metrics} = payload

      assert %{"name" => "executing", "queue" => "default", "type" => "count", "value" => 3} in metrics
      assert %{"name" => "available", "queue" => "default", "type" => "count", "value" => -3} in metrics

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
end
