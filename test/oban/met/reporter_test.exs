defmodule Oban.Met.ReporterTest do
  use ExUnit.Case, async: true

  alias Oban.{Config, Job}
  alias Oban.Notifiers.PG, as: Notifier
  alias Oban.Met.Reporter

  import :telemetry, only: [execute: 3]

  @conf %Config{name: Oban, node: "worker.1", notifier: Notifier, prefix: "public", repo: nil}

  describe "capturing" do
    test "capturing job start counts" do
      {:ok, pid} = start_supervised({Reporter, conf: @conf})

      meta = %{conf: @conf, job: %Job{queue: "default"}}

      execute([:oban, :job, :start], %{}, meta)
      execute([:oban, :job, :start], %{}, meta)
      execute([:oban, :job, :start], %{}, meta)

      metrics = Reporter.all_metrics(pid)

      assert {{:count, :executing}, 3, _} = find_metric(metrics, {:count, :executing})
      assert {{:count, :available}, -3, _} = find_metric(metrics, {:count, :available})
    end

    test "capturing job stop and exception counts" do
      {:ok, pid} = start_supervised({Reporter, conf: @conf})

      meta = %{conf: @conf, job: %Job{queue: "default"}, state: :success}
      measure = %{duration: 1000, queue_time: 500}

      execute([:oban, :job, :stop], measure, meta)
      execute([:oban, :job, :stop], measure, meta)
      execute([:oban, :job, :stop], measure, %{meta | state: :cancelled})
      execute([:oban, :job, :stop], measure, %{meta | state: :snoozed})
      execute([:oban, :job, :exception], measure, %{meta | state: :failure})
      execute([:oban, :job, :exception], measure, %{meta | state: :discard})

      metrics = Reporter.all_metrics(pid)

      assert {{:count, :executing}, -6, _} = find_metric(metrics, {:count, :executing})
      assert {{:count, :cancelled}, 1, _} = find_metric(metrics, {:count, :cancelled})
      assert {{:count, :completed}, 2, _} = find_metric(metrics, {:count, :completed})
      assert {{:count, :discarded}, 1, _} = find_metric(metrics, {:count, :discarded})
      assert {{:count, :retryable}, 1, _} = find_metric(metrics, {:count, :retryable})
      assert {{:count, :scheduled}, 1, _} = find_metric(metrics, {:count, :scheduled})
    end
  end

  describe "reporting" do
    test "reporting captured metrics" do
      name = Oban.Registry.via(@conf.name, Oban.Notifier)

      {:ok, pgn} = start_supervised({Notifier, conf: @conf, name: name})
      {:ok, pid} = start_supervised({Reporter, conf: @conf, interval: 10})

      :ok = Notifier.listen(pgn, [:gossip])

      for _ <- 1..9 do
        execute([:oban, :job, :start], %{}, %{conf: @conf, job: %Job{queue: "default"}})
      end

      assert_receive {:notification, :gossip, payload}

      assert %{"name" => "Oban", "node" => "worker.1", "metrics" => metrics} = payload
      assert [["count", "executing"], 9, %{"queue" => "default"}] in metrics
      assert [["count", "available"], -9, %{"queue" => "default"}] in metrics

      assert [] = Reporter.all_metrics(pid)
    end
  end

  defp find_metric(metrics, key) do
    Enum.find(metrics, & elem(&1, 0) == key)
  end
end
