defmodule Oban.Met.RecorderTest do
  use ExUnit.Case, async: true

  alias Oban.Met.{Recorder, Sketch}

  @name ObanRecorder
  @node "worker.1"
  @opts [
    node: @node,
    notifier: Oban.Notifiers.PG,
    repo: Oban.Met.Repo,
    testing: :inline
  ]

  describe "lookup/2" do
    setup :start_supervised_recorder

    test "fetching metrics stored with pubsub notifications", %{pid: pid} do
      metrics = [%{name: :available, queue: :default, type: :count, value: 1}]

      payload =
        %{node: @node, metrics: metrics}
        |> Jason.encode!()
        |> Jason.decode!()

      send(pid, {:notification, :gossip, payload})

      Process.sleep(10)

      assert [{"available", _, _, 1, labels}] = Recorder.lookup(@name, :available)

      assert %{"node" => @node, "queue" => "default", "type" => "delta"} = labels
    end
  end

  describe "latest/3" do
    setup :start_supervised_recorder

    test "fetching the latest value for stored counts" do
      labels = %{"queue" => "default", "type" => "delta"}
      store(:available, +1, labels, timestamp: ts())
      store(:available, -2, labels, timestamp: ts(-10))
      store(:available, +5, labels, timestamp: ts(-20))
      store(:available, 20, %{labels | "type" => "count"}, timestamp: ts(-25))
      store(:available, 25, %{labels | "type" => "count"}, timestamp: ts(-30))

      assert %{"all" => 24} = latest(:available)
      assert %{"all" => -1} = latest(:available, lookback: 10)
      assert %{"all" => +4} = latest(:available, lookback: 20)
      assert %{"all" => 24} = latest(:available, lookback: 30)
    end

    test "fetching the latest value for stored sketches" do
      labels = %{"queue" => "default", "type" => "sketch"}

      store(:exec_time, sketch([1, 2]), labels, timestamp: ts())
      store(:exec_time, sketch([2, 3]), labels, timestamp: ts(-10))
      store(:exec_time, sketch([1, 3]), labels, timestamp: ts(-20))
      store(:exec_time, sketch([1, 3]), labels, timestamp: ts(-90))

      assert %{"all" => sketch} = latest(:exec_time)

      assert 6 == Sketch.size(sketch)
      assert_in_delta Sketch.quantile(sketch, 0.0), 1.0, 0.2
      assert_in_delta Sketch.quantile(sketch, 1.0), 3.0, 0.2
    end

    test "grouping the latest values by a label" do
      store(:executing, 4, %{"node" => "web.1", "queue" => "alpha", "type" => "delta"})
      store(:executing, 3, %{"node" => "web.1", "queue" => "gamma", "type" => "delta"})
      store(:executing, 4, %{"node" => "web.2", "queue" => "alpha", "type" => "count"})
      store(:executing, 3, %{"node" => "web.2", "queue" => "gamma", "type" => "count"})

      assert %{"alpha" => 8, "gamma" => 6} = latest(:executing, group: :queue)
      assert %{"web.1" => 7, "web.2" => 7} = latest(:executing, group: :node)
    end

    test "filtering the latest values by a label" do
      store(:executing, 4, %{"node" => "web.1", "queue" => "alpha", "type" => "delta"})
      store(:executing, 3, %{"node" => "web.2", "queue" => "gamma", "type" => "delta"})
      store(:executing, 2, %{"node" => "web.2", "queue" => "alpha", "type" => "delta"})

      assert %{"all" => 4} = latest(:executing, filters: [node: "web.1"])
      assert %{"all" => 5} = latest(:executing, filters: [node: ["web.2"]])
      assert %{"all" => 9} = latest(:executing, filters: [node: ["web.1", "web.2"]])
      assert %{"all" => 4} = latest(:executing, filters: [node: ["web.1"], queue: ["alpha"]])
      assert %{"all" => _} = latest(:executing, filters: [node: ["web.1"], queue: ["gamma"]])
    end
  end

  defp start_supervised_recorder(_context) do
    name = make_ref()
    start_supervised!({Oban, Keyword.put(@opts, :name, name)})

    conf = Oban.config(name)
    pid = start_supervised!({Recorder, conf: conf, name: @name})

    {:ok, conf: conf, pid: pid}
  end

  defp store(series, value, labels, opts \\ []) do
    Recorder.store(@name, series, value, labels, opts)
  end

  defp latest(series, opts \\ []) do
    Recorder.latest(@name, series, opts)
  end

  defp sketch(values) do
    Enum.reduce(values, Sketch.new(), &Sketch.insert(&2, &1))
  end

  defp ts(offset \\ 0) do
    System.system_time(:second) + offset
  end
end
