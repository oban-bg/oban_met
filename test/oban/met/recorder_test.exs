defmodule Oban.Met.RecorderTest do
  use ExUnit.Case, async: true

  alias Oban.Met.Recorder

  @name Oban.Recorder
  @opts [name: @name, notifier: Oban.Notifiers.PG, repo: Oban.Met.Repo, testing: :inline]

  describe "storing and fetching" do
    test "fetching metrics stored through pubsub notifications" do
      start_supervised!({Oban, @opts})

      conf = Oban.config(@name)

      {:ok, pid} = start_supervised({Recorder, conf: conf, name: @name})

      metrics = [%{name: :available, queue: :default, type: :count, value: 1}]

      payload =
        %{node: conf.node, metrics: metrics}
        |> Jason.encode!()
        |> Jason.decode!()

      send(pid, {:notification, :gossip, payload})

      Process.sleep(10)

      assert [metric] = Recorder.fetch(@name, :available)

      assert "available" == elem(metric, 0)

      # [{"available", 1659452773, 1659452773, 1, %{"node" => "worker.1", "queue" => "default", "type" => "delta"}}]
    end
  end
end
