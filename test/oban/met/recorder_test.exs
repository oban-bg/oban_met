defmodule Oban.Met.RecorderTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Oban.Met.{Recorder, Sketch}

  @name ObanRecorder
  @node "worker.1"
  @opts [
    node: @node,
    notifier: Oban.Notifiers.PG,
    repo: Oban.Met.Repo,
    testing: :inline
  ]

  defmodule Checkpoint do
    @behaviour Oban.Met.Checkpoint

    alias Oban.Met.Checkpoint

    @impl Checkpoint
    def call(conf) do
      metrics = [
        {:available, 7, %{queue: "alpha"}},
        {:available, 8, %{queue: "gamma"}},
        {:available, 9, %{queue: "delta"}}
      ]

      send(conf[:pid], :checkpoint)

      {metrics, conf}
    end

    @impl Checkpoint
    def interval(conf), do: {conf[:interval], conf}
  end

  describe "lookup/2" do
    setup [:start_supervised_oban, :start_supervised_recorder]

    test "fetching metrics stored with pubsub notifications", %{pid: pid} do
      metrics = [%{name: :available, queue: :default, type: :delta, value: 1}]

      payload =
        %{node: @node, metrics: metrics}
        |> Jason.encode!()
        |> Jason.decode!()

      send(pid, {:notification, :gossip, payload})

      ts = System.system_time(:second)

      Process.sleep(10)

      assert [{"available", ^ts, ^ts, :delta, 1, labels}] = Recorder.lookup(@name, :available)

      assert %{"queue" => "default"} = labels
    end
  end

  describe "latest/3" do
    setup [:start_supervised_oban, :start_supervised_recorder]

    test "fetching the latest value for stored gauges" do
      labels = %{"queue" => "default"}
      store(:available, :delta, +1, labels, timestamp: ts())
      store(:available, :delta, -2, labels, timestamp: ts(-10))
      store(:available, :delta, +5, labels, timestamp: ts(-20))
      store(:available, :gauge, 20, labels, timestamp: ts(-25))
      store(:available, :gauge, 25, labels, timestamp: ts(-30))

      assert %{"all" => 24} = latest(:available)
      assert %{"all" => -1} = latest(:available, lookback: 10)
      assert %{"all" => +4} = latest(:available, lookback: 20)
      assert %{"all" => 24} = latest(:available, lookback: 30)
    end

    test "fetching the latest value for stored sketches" do
      labels = %{"queue" => "default"}

      store(:exec_time, :sketch, sketch([1, 2]), labels, timestamp: ts())
      store(:exec_time, :sketch, sketch([2, 3]), labels, timestamp: ts(-10))
      store(:exec_time, :sketch, sketch([1, 3]), labels, timestamp: ts(-20))
      store(:exec_time, :sketch, sketch([1, 3]), labels, timestamp: ts(-90))

      assert %{"all" => sketch} = latest(:exec_time)

      assert 6 == Sketch.size(sketch)
      assert_in_delta Sketch.quantile(sketch, 0.0), 1.0, 0.2
      assert_in_delta Sketch.quantile(sketch, 1.0), 3.0, 0.2
    end

    test "grouping the latest values by a label" do
      store(:executing, :delta, 4, %{"node" => "web.1", "queue" => "alpha"})
      store(:executing, :delta, 3, %{"node" => "web.1", "queue" => "gamma"})
      store(:executing, :gauge, 4, %{"node" => "web.2", "queue" => "alpha"})
      store(:executing, :gauge, 3, %{"node" => "web.2", "queue" => "gamma"})

      assert %{"alpha" => 8, "gamma" => 6} = latest(:executing, group: :queue)
      assert %{"web.1" => 7, "web.2" => 7} = latest(:executing, group: :node)
    end

    test "filtering the latest values by a label" do
      store(:executing, :delta, 4, %{"node" => "web.1", "queue" => "alpha"})
      store(:executing, :delta, 3, %{"node" => "web.2", "queue" => "gamma"})
      store(:executing, :delta, 2, %{"node" => "web.2", "queue" => "alpha"})

      assert %{"all" => 4} = latest(:executing, filters: [node: "web.1"])
      assert %{"all" => 5} = latest(:executing, filters: [node: ["web.2"]])
      assert %{"all" => 9} = latest(:executing, filters: [node: ["web.1", "web.2"]])
      assert %{"all" => 4} = latest(:executing, filters: [node: ["web.1"], queue: ["alpha"]])
      assert %{"all" => _} = latest(:executing, filters: [node: ["web.1"], queue: ["gamma"]])
    end
  end

  describe "timeslice/3" do
    setup [:start_supervised_oban, :start_supervised_recorder]

    test "slicing gauges by small periods" do
      store(:executing, :delta, +1, %{"queue" => "alpha"}, timestamp: ts(-1))
      store(:executing, :delta, -1, %{"queue" => "alpha"}, timestamp: ts(-2))
      store(:executing, :gauge, +4, %{"queue" => "alpha"}, timestamp: ts(-3))
      store(:executing, :delta, -1, %{"queue" => "alpha"}, timestamp: ts(-4))
      store(:executing, :delta, -1, %{"queue" => "alpha"}, timestamp: ts(-5))
      store(:executing, :gauge, +5, %{"queue" => "alpha"}, timestamp: ts(-6))

      assert [{ts, value, label} | _] = timeslice(:executing)

      assert is_integer(ts)
      assert is_float(value)
      refute label

      assert [4, 3, 4, 3, 4, 5] = timeslice_values(:executing)
      assert [4, 4, 4, 5] = timeslice_values(:executing, by: 2)
      assert [4, 4, 5] = timeslice_values(:executing, by: 3)
      assert [4, 5] = timeslice_values(:executing, by: 5)
    end

    test "slicing gauges by groups" do
      for value <- [1, 2], queue <- ~w(alpha gamma delta), ts <- [-1, -2] do
        labels = %{"queue" => queue}

        store(:exec_time, :gauge, value, labels, timestamp: ts(ts))
      end

      assert [{_, _, "alpha"}, {_, _, "alpha"} | _] = timeslice(:exec_time, label: :queue)
    end
  end

  describe "checkpoints" do
    setup :start_supervised_oban

    test "storing checkpoint output as guages", %{conf: conf} do
      start_supervised!(
        {Recorder, conf: conf, name: @name, checkpoint: {Checkpoint, interval: 1, pid: self()}}
      )

      assert_receive :checkpoint

      assert metrics = Recorder.lookup(@name, :available)

      assert 3 == length(metrics)
    end
  end

  describe "compact/2" do
    setup [:start_supervised_oban, :start_supervised_recorder]

    test "gauges within periods of time are compacted by interval" do
      for series <- [:a, :b], queue <- [:alpha, :gamma, :delta], off <- [1, 5, 6, 9] do
        store(series, :gauge, 1, %{queue: queue}, timestamp: ts(-off))
      end

      originals_a = lookup(:a)
      originals_b = lookup(:b)

      compact([{5, 60}])

      compacted_a = lookup(:a)
      compacted_b = lookup(:b)

      for {originals, compacted} <- [{originals_a, compacted_a}, {originals_b, compacted_b}] do
        assert length(originals) > length(compacted)

        assert length(originals) ==
                 compacted
                 |> Enum.map(fn {_, _, _, _, sketch, _} -> Sketch.size(sketch) end)
                 |> Enum.sum()

        get_queues = fn metrics ->
          metrics
          |> Enum.map(&get_in(&1, [Access.elem(5), :queue]))
          |> Enum.uniq()
          |> Enum.sort()
        end

        assert get_queues.(originals) == get_queues.(compacted)
      end
    end

    test "sketches within periods of time are compacted by interval" do
      sketch = Sketch.new([1, 2, 3])

      for offset <- [1, 4, 5, 6, 7] do
        store(:a, :sketch, sketch, %{queue: :alpha}, timestamp: ts(-offset))
      end

      compact([{5, 60}])

      assert [6, 9] =
               :a
               |> lookup()
               |> Enum.map(fn {_, _, _, _, sketch, _} -> Sketch.size(sketch) end)
    end

    test "compacting metrics multiple times is idempotent" do
      for queue <- [:alpha, :gamma], offset <- 1..61 do
        store(:a, :gauge, 1, %{queue: queue}, timestamp: ts(-offset))
      end

      compact([{5, 60}])
      compacted_1 = lookup(:a)

      compact([{5, 60}])
      compacted_2 = lookup(:a)

      assert compacted_1 == compacted_2
    end

    test "deleting metrics beyond the final period" do
      store(:a, :gauge, 1, %{queue: :alpha}, timestamp: ts(-119))
      store(:a, :gauge, 1, %{queue: :gamma}, timestamp: ts(-120))
      store(:a, :gauge, 1, %{queue: :delta}, timestamp: ts(-121))

      compact([{1, 60}, {1, 60}])

      assert [:gamma, :alpha] =
               :a
               |> lookup()
               |> Enum.map(&get_in(&1, [Access.elem(5), :queue]))
    end
  end

  describe "automatic compaction" do
    setup :start_supervised_oban

    test "automatically compacting on an interval", %{conf: conf} do
      pid = start_supervised!({Recorder, conf: conf, name: @name, compact_periods: [{5, 60}]})

      store(:a, :gauge, 4, %{queue: :alpha}, timestamp: ts(-3))
      store(:a, :gauge, 3, %{queue: :alpha}, timestamp: ts(-4))
      store(:a, :gauge, 2, %{queue: :alpha}, timestamp: ts(-6))
      store(:a, :gauge, 1, %{queue: :alpha}, timestamp: ts(-7))

      assert length(lookup(:a)) == 4

      send(pid, :compact)

      Process.sleep(5)

      assert length(lookup(:a)) == 2
    end
  end

  defp start_supervised_oban(_context) do
    name = make_ref()
    start_supervised!({Oban, Keyword.put(@opts, :name, name)})

    conf = Oban.config(name)

    {:ok, conf: conf}
  end

  defp start_supervised_recorder(%{conf: conf}) do
    pid = start_supervised!({Recorder, conf: conf, name: @name})

    {:ok, pid: pid}
  end

  defp compact(periods) do
    Recorder.compact(@name, periods)
  end

  defp store(series, type, value, labels, opts \\ []) do
    Recorder.store(@name, series, type, value, labels, opts)
  end

  defp latest(series, opts \\ []) do
    Recorder.latest(@name, series, opts)
  end

  defp lookup(series) do
    Recorder.lookup(@name, series)
  end

  defp timeslice(series, opts \\ []) do
    Recorder.timeslice(@name, series, opts)
  end

  defp timeslice_values(series, opts \\ []) do
    for {_, value, _} <- timeslice(series, opts), do: round(value)
  end

  defp sketch(values) do
    Enum.reduce(values, Sketch.new(), &Sketch.insert(&2, &1))
  end

  defp ts(offset \\ 0) do
    System.system_time(:second) + offset
  end
end
