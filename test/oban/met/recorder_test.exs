defmodule Oban.Met.RecorderTest do
  use Oban.Met.Case, async: true
  use ExUnitProperties

  alias Oban.Met.{Gauge, Recorder, Sketch, Value}

  @name Oban.Recorder
  @node "worker.1"

  describe "store/5" do
    setup [:start_supervised_oban, :start_supervised_recorder]

    test "gauges never drop below 0 with negative deltas" do
      store(:a, :gauge, +1, %{"queue" => "alpha"})
      store(:a, :delta, -1, %{"queue" => "alpha"})
      store(:a, :delta, -1, %{"queue" => "alpha"})

      assert %{"all" => 0} = latest(:a)
    end

    test "positive deltas are converted to gauge without anything historical" do
      store(:a, :delta, +1, %{"queue" => "alpha"})
      store(:b, :delta, -1, %{"queue" => "alpha"})

      assert %{"all" => 1} = latest(:a)
      assert %{"all" => 0} = latest(:b)
    end
  end

  describe "lookup/2" do
    setup [:start_supervised_oban, :start_supervised_recorder]

    test "fetching metrics stored with pubsub notifications", %{pid: pid} do
      metrics = [
        %{series: :a, node: @node, queue: :default, type: :gauge, value: Gauge.new([1])},
        %{series: :b, node: @node, queue: :default, type: :sketch, value: Sketch.new([1])},
        %{series: :c, node: @node, queue: :default, type: :delta, value: 1}
      ]

      payload =
        %{node: @node, metrics: metrics}
        |> Jason.encode!()
        |> Jason.decode!()

      send(pid, {:notification, :gossip, payload})

      ts = System.system_time(:second)

      Process.sleep(10)

      assert [{{"a", labels, ^ts}, ^ts, :gauge, _}] = lookup(:a)
      assert [{{"b", _label, ^ts}, ^ts, :sketch, _}] = lookup(:b)
      assert %{"node" => @node, "queue" => "default"} = labels
    end
  end

  describe "latest/3" do
    setup [:start_supervised_oban, :start_supervised_recorder]

    test "fetching the latest value for stored gauges" do
      store(:a, :gauge, 3, %{"queue" => "alpha"}, timestamp: ts())
      store(:a, :gauge, 3, %{"queue" => "gamma"}, timestamp: ts())
      store(:a, :gauge, 2, %{"queue" => "alpha"}, timestamp: ts(-1))
      store(:a, :gauge, 2, %{"queue" => "gamma"}, timestamp: ts(-1))
      store(:a, :gauge, 1, %{"queue" => "alpha"}, timestamp: ts(-2))
      store(:a, :gauge, 1, %{"queue" => "gamma"}, timestamp: ts(-2))

      assert %{"all" => 6} = latest(:a)
    end

    test "fetching the latest value for stored sketches" do
      store(:a, :sketch, [1, 2], %{"queue" => "alpha"}, timestamp: ts())
      store(:a, :sketch, [2, 3], %{"queue" => "gamma"}, timestamp: ts())
      store(:a, :sketch, [3, 4], %{"queue" => "alpha"}, timestamp: ts(-1))
      store(:a, :sketch, [3, 4], %{"queue" => "gamma"}, timestamp: ts(-1))

      assert %{"all" => ntile} = latest(:a)

      assert_in_delta ntile, 3.0, 0.2
    end

    test "grouping the latest values by a label" do
      store(:a, :gauge, 4, %{"node" => "web.2", "queue" => "alpha"})
      store(:a, :gauge, 3, %{"node" => "web.2", "queue" => "gamma"})
      store(:a, :gauge, 4, %{"node" => "web.1", "queue" => "alpha"})
      store(:a, :gauge, 3, %{"node" => "web.1", "queue" => "gamma"})

      assert %{"alpha" => 8, "gamma" => 6} = latest(:a, group: "queue")
      assert %{"web.1" => 7, "web.2" => 7} = latest(:a, group: "node")
    end

    test "filtering the latest values by a label" do
      store(:a, :gauge, 4, %{"node" => "web.1", "queue" => "alpha"})
      store(:a, :gauge, 3, %{"node" => "web.2", "queue" => "gamma"})
      store(:a, :gauge, 2, %{"node" => "web.2", "queue" => "alpha"})

      assert %{"all" => 4} == latest(:a, filters: [node: "web.1"])
      assert %{"all" => 5} == latest(:a, filters: [node: ["web.2"]])
      assert %{"all" => 9} == latest(:a, filters: [node: ["web.1", "web.2"]])
      assert %{"all" => 4} == latest(:a, filters: [node: ["web.1"], queue: ["alpha"]])
      assert %{} == latest(:a, filters: [node: ["web.1"], queue: ["gamma"]])
    end
  end

  describe "timeslice/3" do
    setup [:start_supervised_oban, :start_supervised_recorder]

    test "slicing gauges by small periods" do
      store(:a, :gauge, 1, %{"queue" => "alpha"}, timestamp: ts(-1))
      store(:a, :gauge, 1, %{"queue" => "alpha"}, timestamp: ts(-2))
      store(:a, :gauge, 4, %{"queue" => "alpha"}, timestamp: ts(-3))
      store(:a, :gauge, 1, %{"queue" => "alpha"}, timestamp: ts(-4))
      store(:a, :gauge, 5, %{"queue" => "alpha"}, timestamp: ts(-5))

      assert [{ts, value, label} | _] = timeslice(:a)

      assert is_integer(ts)
      assert is_integer(value)
      refute label

      assert [5, 1, 4, 1, 1] = timeslice_values(:a)
      assert [5, 4, 1] = timeslice_values(:a, by: 2)
      assert [5, 4] = timeslice_values(:a, by: 3)
      assert [5] = timeslice_values(:a, by: 6)
    end

    test "slicing gauges by groups" do
      for value <- [1, 2], queue <- ~w(alpha gamma delta), ts <- [-1, -2] do
        labels = %{"queue" => queue}

        store(:a, :gauge, value, labels, timestamp: ts(ts))
      end

      assert [{_, _, "alpha"}, {_, _, "alpha"} | _] = timeslice(:a, label: "queue")
    end

    test "interpolating slices over the duration of the lookback" do
      store(:a, :gauge, 6, %{"queue" => "alpha", "node" => "a"}, timestamp: ts(-6))
      store(:a, :gauge, 6, %{"queue" => "alpha", "node" => "b"}, timestamp: ts(-6))
      store(:a, :gauge, 6, %{"queue" => "gamma", "node" => "a"}, timestamp: ts(-6))

      store(:a, :gauge, 4, %{"queue" => "alpha", "node" => "a"}, timestamp: ts(-4))
      store(:a, :gauge, 4, %{"queue" => "alpha", "node" => "b"}, timestamp: ts(-4))
      store(:a, :gauge, 4, %{"queue" => "gamma", "node" => "b"}, timestamp: ts(-4))

      store(:a, :gauge, 2, %{"queue" => "alpha", "node" => "a"}, timestamp: ts(-2))
      store(:a, :gauge, 2, %{"queue" => "alpha", "node" => "b"}, timestamp: ts(-2))
      store(:a, :gauge, 2, %{"queue" => "gamma", "node" => "b"}, timestamp: ts(-2))

      slices = timeslice(:a, label: "queue", by: 1)

      slices
      |> Enum.chunk_by(&elem(&1, 2))
      |> Enum.each(fn slice ->
        timestamps = Enum.map(slice, &elem(&1, 0))

        assert [1, 1, 1, 1] = Enum.zip_with([timestamps, tl(timestamps)], fn [x, y] -> y - x end)
      end)

      for label <- ~w(alpha gamma) do
        assert [6, 6, 4, 4, 2] =
                 slices
                 |> Enum.filter(&(elem(&1, 2) == label))
                 |> Enum.map(&elem(&1, 1))
      end
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
                 |> Enum.map(fn {_, _, _, value} -> Value.size(value) end)
                 |> Enum.sum()

        get_queues = fn metrics ->
          metrics
          |> Enum.map(&get_in(&1, [Access.elem(0), Access.elem(1), :queue]))
          |> Enum.uniq()
          |> Enum.sort()
        end

        assert get_queues.(originals) == get_queues.(compacted)
      end
    end

    test "compacted intervals contain a range from min to max timestamps" do
      for offset <- 1..30 do
        store(:a, :gauge, 1, %{queue: :alpha}, timestamp: ts(-offset))
      end

      assert length(lookup(:a)) == 30

      compact([{10, 30}])

      assert [9, 9, 9] =
               :a
               |> lookup()
               |> Enum.map(fn {{_key, _lab, max_ts}, min_ts, _, _} -> max_ts - min_ts end)
    end

    test "compacted values are separated by series and labels" do
      for series <- [:a, :b], offset <- [1, 2] do
        store(series, :gauge, 1, %{queue: :alpha}, timestamp: ts(-offset))
        store(series, :gauge, 2, %{queue: :gamma}, timestamp: ts(-offset))
      end

      assert length(lookup(:a)) == 4
      assert length(lookup(:b)) == 4

      compact([{5, 30}])

      assert length(lookup(:a)) == 2
      assert length(lookup(:b)) == 2
    end

    test "sketches within periods of time are compacted by interval" do
      for offset <- [1, 4, 5, 6, 7] do
        store(:a, :sketch, [1, 2, 3], %{queue: :alpha}, timestamp: ts(-offset))
      end

      compact([{5, 60}])

      assert [6, 9] =
               :a
               |> lookup()
               |> Enum.map(fn {_, _, _, sketch} -> Sketch.size(sketch) end)
    end

    test "compacting metrics multiple times is idempotent" do
      for queue <- [:alpha, :gamma], offset <- 1..61 do
        store(:a, :gauge, 1, %{"queue" => queue}, timestamp: ts(-offset))
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

      assert [:alpha, :gamma] =
               :a
               |> lookup()
               |> Enum.map(&get_in(&1, [Access.elem(0), Access.elem(1), :queue]))
    end

    test "applying a delta after gauge compaction" do
      store(:a, :gauge, 4, %{queue: :alpha}, timestamp: ts(-1))
      store(:a, :gauge, 3, %{queue: :alpha}, timestamp: ts(-2))
      store(:a, :gauge, 2, %{queue: :alpha}, timestamp: ts(-3))

      compact([{5, 60}])

      assert %{"all" => 4} = latest(:a)

      store(:a, :delta, 1, %{queue: :alpha})
      store(:a, :delta, 1, %{queue: :alpha})

      assert %{"all" => 6} = latest(:a)
    end
  end

  describe "automatic compaction" do
    setup :start_supervised_oban

    test "compacting on an interval", %{conf: conf} do
      pid = start_supervised!({Recorder, conf: conf, name: @name, compact_periods: [{5, 60}]})

      store(:a, :gauge, 4, %{queue: :alpha}, timestamp: ts(-3))
      store(:a, :gauge, 3, %{queue: :alpha}, timestamp: ts(-4))
      store(:a, :gauge, 2, %{queue: :alpha}, timestamp: ts(-6))
      store(:a, :gauge, 1, %{queue: :alpha}, timestamp: ts(-7))

      store(:b, :sketch, [4, 3], %{queue: :alpha}, timestamp: ts(-3))
      store(:b, :sketch, [3, 2], %{queue: :alpha}, timestamp: ts(-4))
      store(:b, :sketch, [2, 1], %{queue: :alpha}, timestamp: ts(-6))

      assert length(lookup(:a)) == 4
      assert length(lookup(:b)) == 3

      send(pid, :compact)

      Process.sleep(10)

      assert length(lookup(:a)) == 2
      assert length(lookup(:b)) == 2

      assert %{"all" => 4} = latest(:a)

      assert 4 ==
               :b
               |> latest()
               |> Map.fetch!("all")
               |> round()
    end
  end

  defp start_supervised_recorder(%{conf: conf}) do
    pid = start_supervised!({Recorder, conf: conf, name: @name})

    {:ok, pid: pid}
  end

  defp compact(periods) do
    Recorder.compact(@name, periods)
  end

  defp store(series, type, value, labels, opts \\ []) do
    value =
      case type do
        :gauge -> Gauge.new(value)
        :sketch -> Sketch.new(value)
        :delta -> value
      end

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

  defp ts(offset \\ 0) do
    System.system_time(:second) + offset
  end
end
