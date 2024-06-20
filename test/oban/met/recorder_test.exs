defmodule Oban.Met.RecorderTest do
  use Oban.Met.Case, async: true
  use ExUnitProperties

  alias Oban.Met.Recorder
  alias Oban.Met.Values.{Gauge, Sketch}
  alias Oban.Notifier

  @name Oban.Recorder
  @node "worker.1"

  describe "lookup/2" do
    setup [:start_supervised_oban, :start_supervised_recorder]

    test "fetching metrics stored with pubsub notifications", %{conf: conf} do
      metrics = [
        %{series: :a, queue: :default, value: Sketch.new(1), worker: "A"},
        %{series: :b, queue: :default, value: Sketch.new(1), worker: "A"},
        %{series: :c, queue: :default, value: Gauge.new(1), worker: "A"}
      ]

      time = System.system_time(:second)

      Notifier.notify(conf.name, :metrics, %{node: @node, metrics: metrics, time: time})

      labels = %{"node" => @node, "queue" => "default", "worker" => "A"}

      with_backoff(fn ->
        assert [{{"a", _, ^time}, ^time, ^labels, _}] = lookup(:a)
        assert [{{"b", _, ^time}, ^time, ^labels, _}] = lookup(:b)
        assert [{{"c", _, ^time}, ^time, ^labels, _}] = lookup(:c)
      end)
    end
  end

  describe "labels/2" do
    setup [:start_supervised_oban, :start_supervised_recorder]

    test "fetching all values for a particular label" do
      store(:a, 3, %{"queue" => "alpha"}, time: ts())
      store(:b, 3, %{"queue" => "gamma"}, time: ts())
      store(:c, 3, %{"queue" => "delta"}, time: ts())
      store(:d, 3, %{"queue" => "delta"}, time: ts())
      store(:e, 3, %{"other" => "omega"}, time: ts())

      assert ~w(alpha delta gamma) = Recorder.labels(@name, "queue")
      assert ~w(omega) = Recorder.labels(@name, "other")
      assert [] = Recorder.labels(@name, "unknown")
    end

    test "fetching all values for a particular label with a lookback period" do
      store(:a, 3, %{"queue" => "alpha"}, time: ts(-1))
      store(:b, 3, %{"queue" => "gamma"}, time: ts(-3))
      store(:c, 3, %{"queue" => "delta"}, time: ts(-5))
      store(:d, 3, %{"queue" => "delta"}, time: ts(-7))

      assert ~w(alpha) = Recorder.labels(@name, "queue", lookback: 2)
      assert ~w(alpha gamma) = Recorder.labels(@name, "queue", lookback: 4)
      assert ~w(alpha delta gamma) = Recorder.labels(@name, "queue", lookback: 6)
    end
  end

  describe "series/1" do
    setup [:start_supervised_oban, :start_supervised_recorder]

    test "fetching details about all stored series" do
      store(:b, 3, %{"queue" => "gamma"}, time: ts())
      store(:c, 3, %{"other" => "omega"}, time: ts())
      store(:a, 3, %{"queue" => "alpha"}, time: ts())
      store(:c, 3, %{"queue" => "delta"}, time: ts())

      assert [series_a, series_b, series_c] = Recorder.series(@name)

      assert %{series: "a", labels: ["queue"], type: Gauge} = series_a
      assert %{series: "b", labels: ["queue"], type: Gauge} = series_b
      assert %{series: "c", labels: ["other", "queue"], type: Gauge} = series_c
    end
  end

  describe "latest/3" do
    setup [:start_supervised_oban, :start_supervised_recorder]

    test "fetching the latest value for stored gauges" do
      store(:a, 3, %{"queue" => "alpha"}, time: ts())
      store(:a, 3, %{"queue" => "gamma"}, time: ts())
      store(:a, 2, %{"queue" => "alpha"}, time: ts(-1))
      store(:a, 2, %{"queue" => "gamma"}, time: ts(-1))
      store(:a, 1, %{"queue" => "alpha"}, time: ts(-2))
      store(:a, 1, %{"queue" => "gamma"}, time: ts(-2))

      assert %{"all" => 6} = latest(:a)
    end

    test "grouping the latest values by a label" do
      store(:a, 4, %{"node" => "web.2", "queue" => "alpha"})
      store(:a, 3, %{"node" => "web.2", "queue" => "gamma"})
      store(:a, 4, %{"node" => "web.1", "queue" => "alpha"})
      store(:a, 3, %{"node" => "web.1", "queue" => "gamma"})

      assert %{"alpha" => 8, "gamma" => 6} = latest(:a, group: "queue")
      assert %{"web.1" => 7, "web.2" => 7} = latest(:a, group: "node")
    end

    test "filtering the latest values by a label" do
      store(:a, 4, %{"node" => "web.1", "queue" => "alpha"})
      store(:a, 3, %{"node" => "web.2", "queue" => "gamma"})
      store(:a, 2, %{"node" => "web.2", "queue" => "alpha"})

      assert %{"all" => 4} == latest(:a, filters: [node: "web.1"])
      assert %{"all" => 5} == latest(:a, filters: [node: ["web.2"]])
      assert %{"all" => 9} == latest(:a, filters: [node: ["web.1", "web.2"]])
      assert %{"all" => 4} == latest(:a, filters: [node: ["web.1"], queue: ["alpha"]])
      assert %{} == latest(:a, filters: [node: ["web.1"], queue: ["gamma"]])
    end
  end

  describe "timeslice/3" do
    setup [:start_supervised_oban, :start_supervised_recorder]

    test "slicing gagues by small periods" do
      store(:a, 1, %{"queue" => "alpha"}, time: ts(-1))
      store(:a, 1, %{"queue" => "alpha"}, time: ts(-2))
      store(:a, 4, %{"queue" => "alpha"}, time: ts(-3))
      store(:a, 1, %{"queue" => "alpha"}, time: ts(-4))
      store(:a, 5, %{"queue" => "alpha"}, time: ts(-5))

      assert [{ts, value, label} | _] = timeslice(:a)

      assert is_integer(ts)
      assert is_integer(value)
      refute label

      assert [5, 1, 4, 1, 1] = timeslice_values(:a)
      assert [5, 5, 2] = timeslice_values(:a, by: 2)
      assert [6, 6] = timeslice_values(:a, by: 3)
      assert [12] = timeslice_values(:a, by: 6)
    end

    test "grouping gagues while preserving max value over time" do
      store(:a, 4, %{"queue" => "alpha"}, time: ts(-1))
      store(:a, 4, %{"queue" => "alpha"}, time: ts(-1))
      store(:a, 4, %{"queue" => "gamma"}, time: ts(-1))
      store(:a, 2, %{"queue" => "gamma"}, time: ts(-1))
      store(:a, 2, %{"queue" => "alpha"}, time: ts(-0))
      store(:a, 2, %{"queue" => "alpha"}, time: ts(-0))
      store(:a, 2, %{"queue" => "gamma"}, time: ts(-0))
      store(:a, 1, %{"queue" => "gamma"}, time: ts(-0))

      values_for = fn slices, group ->
        slices
        |> Enum.filter(&(elem(&1, 2) == group))
        |> Enum.map(&elem(&1, 1))
      end

      slices = timeslice(:a, group: "queue", operation: :max, by: 2)

      assert [8] = values_for.(slices, "alpha")
      assert [6] = values_for.(slices, "gamma")

      slices = timeslice(:a, group: "queue", operation: :sum, by: 2)

      assert [12] = values_for.(slices, "alpha")
      assert [09] = values_for.(slices, "gamma")
    end

    test "merging grouped gagues through the lookback" do
      store(:a, 6, %{"queue" => "alpha", "node" => "a"}, time: ts(-6))
      store(:a, 6, %{"queue" => "alpha", "node" => "b"}, time: ts(-6))
      store(:a, 6, %{"queue" => "gamma", "node" => "a"}, time: ts(-6))

      store(:a, 4, %{"queue" => "alpha", "node" => "a"}, time: ts(-4))
      store(:a, 4, %{"queue" => "alpha", "node" => "b"}, time: ts(-4))
      store(:a, 4, %{"queue" => "gamma", "node" => "b"}, time: ts(-4))

      store(:a, 2, %{"queue" => "alpha", "node" => "a"}, time: ts(-2))
      store(:a, 2, %{"queue" => "alpha", "node" => "b"}, time: ts(-2))
      store(:a, 2, %{"queue" => "gamma", "node" => "b"}, time: ts(-2))

      values_for = fn slices, group ->
        slices
        |> Enum.filter(&(elem(&1, 2) == group))
        |> Enum.map(&elem(&1, 1))
      end

      slices = timeslice(:a, group: "queue", by: 1)

      assert [12, 8, 4] = values_for.(slices, "alpha")
      assert [6, 4, 2] = values_for.(slices, "gamma")

      slices = timeslice(:a, group: "queue", by: 3)

      assert [20, 4] = values_for.(slices, "alpha")
      assert [10, 2] = values_for.(slices, "gamma")
    end

    test "merging sketch data across labels for the same timestamp" do
      store(:a, Sketch.new([1]), %{"queue" => "alpha", "node" => "a"}, time: ts(-2))
      store(:a, Sketch.new([3]), %{"queue" => "alpha", "node" => "b"}, time: ts(-2))
      store(:a, Sketch.new([1]), %{"queue" => "alpha", "node" => "a"}, time: ts(-1))
      store(:a, Sketch.new([3]), %{"queue" => "alpha", "node" => "b"}, time: ts(-1))

      assert [3, 3] = timeslice_values(:a, operation: {:pct, 1.0})
    end
  end

  describe "compact/2" do
    setup [:start_supervised_oban, :start_supervised_recorder]

    test "gauges within periods of time are compacted by interval" do
      for series <- [:a, :b], queue <- [:alpha, :gamma, :delta], off <- [1, 5, 6, 9] do
        store(series, 1, %{queue: queue}, time: ts(-off))
      end

      originals_a = lookup(:a)
      originals_b = lookup(:b)

      compact([{5, 60}])

      compacted_a = lookup(:a)
      compacted_b = lookup(:b)

      for {originals, compacted} <- [{originals_a, compacted_a}, {originals_b, compacted_b}] do
        assert length(originals) > length(compacted)

        get_queues = fn metrics ->
          metrics
          |> get_in([Access.all(), Access.elem(2), :queue])
          |> :lists.usort()
        end

        assert get_queues.(originals) == get_queues.(compacted)
      end
    end

    test "compacted intervals contain a range from min to max time" do
      for offset <- 1..30 do
        store(:a, 1, %{queue: :alpha}, time: ts(-offset))
      end

      assert length(lookup(:a)) == 30

      compact([{10, 30}])

      assert [9, 9, 9] =
               :a
               |> lookup()
               |> Enum.map(fn {{_, _, max_ts}, min_ts, _, _} -> max_ts - min_ts end)
    end

    test "compacted values are separated by series and labels" do
      for series <- [:a, :b], offset <- [1, 2] do
        store(series, 1, %{queue: :alpha}, time: ts(-offset))
        store(series, 2, %{queue: :gamma}, time: ts(-offset))
      end

      assert length(lookup(:a)) == 4
      assert length(lookup(:b)) == 4

      compact([{5, 30}])

      assert length(lookup(:a)) == 2
      assert length(lookup(:b)) == 2
    end

    test "sketches within periods of time are compacted by interval" do
      for offset <- [1, 4, 5, 6, 7] do
        store(:a, Sketch.new([1, 2, 3]), %{queue: :alpha}, time: ts(-offset))
      end

      compact([{5, 60}])

      assert [9, 6] =
               :a
               |> lookup()
               |> Enum.map(fn {_, _, _, sketch} -> Sketch.size(sketch) end)
    end

    test "compacting metrics multiple times is idempotent" do
      for queue <- [:alpha, :gamma], offset <- 1..61 do
        store(:a, 1, %{"queue" => queue}, time: ts(-offset))
      end

      compact([{5, 60}])
      compacted_1 = lookup(:a)

      compact([{5, 60}])
      compacted_2 = lookup(:a)

      assert compacted_1 == compacted_2
    end

    test "deleting metrics beyond the final period" do
      store(:a, 1, %{queue: :alpha}, time: ts(-119))
      store(:a, 1, %{queue: :gamma}, time: ts(-120))
      store(:a, 1, %{queue: :delta}, time: ts(-121))

      compact([{1, 60}, {1, 60}])

      assert [:alpha, :gamma] =
               :a
               |> lookup()
               |> get_in([Access.all(), Access.elem(2), :queue])
               |> Enum.sort()
    end
  end

  describe "automatic compaction" do
    setup :start_supervised_oban

    test "compacting on an interval", %{conf: conf} do
      pid = start_supervised!({Recorder, conf: conf, name: @name, compact_periods: [{5, 60}]})

      store(:a, 4, %{queue: :alpha}, time: ts(-3))
      store(:a, 3, %{queue: :alpha}, time: ts(-4))
      store(:a, 2, %{queue: :alpha}, time: ts(-6))
      store(:a, 1, %{queue: :alpha}, time: ts(-7))

      store(:b, Sketch.new([4, 3]), %{queue: :alpha}, time: ts(-3))
      store(:b, Sketch.new([3, 2]), %{queue: :alpha}, time: ts(-4))
      store(:b, Sketch.new([2, 1]), %{queue: :alpha}, time: ts(-6))

      assert length(lookup(:a)) == 4
      assert length(lookup(:b)) == 3

      {:heap_size, heap_1} = :erlang.process_info(pid, :heap_size)

      send(pid, :compact)

      Process.sleep(10)

      {:heap_size, heap_2} = :erlang.process_info(pid, :heap_size)

      assert heap_1 >= heap_2

      assert length(lookup(:a)) == 2
      assert length(lookup(:b)) == 2

      assert %{"all" => 7} = latest(:a, lookback: 5)
    end
  end

  describe "handoffs" do
    setup :start_supervised_oban

    test "broadcasting an online announcement after init", %{conf: conf} do
      Notifier.listen(conf.name, :handoff)

      start_supervised!({Recorder, conf: conf, name: @name})

      assert_receive {:notification, :handoff, %{"syn" => true, "module" => _}}
    end

    @tag oban_opts: [peer: Oban.Peers.Isolated, testing: :disabled]
    test "replying with a handoff message from a leader", %{conf: conf} do
      Notifier.listen(conf.name, :handoff)

      start_supervised!({Recorder, conf: conf, name: @name})

      assert_receive {:notification, :handoff, %{"syn" => true}}

      # Fake a response from another node
      Notifier.notify(conf, :handoff, %{syn: true, module: Recorder})

      assert_receive {:notification, :handoff, %{"ack" => true, "data" => _}}
    end

    @tag oban_opts: [notifier: Oban.Notifiers.PG, peer: Oban.Peers.Isolated, testing: :disabled]
    test "replicating the leader's table from the handoff", %{conf: conf} do
      Notifier.listen(conf.name, :handoff)

      start_supervised!({Recorder, conf: conf, name: @name})

      assert_receive {:notification, :handoff, %{"syn" => true}}

      store(:a, 1, %{"queue" => "alpha"}, time: ts())
      store(:a, 1, %{"queue" => "gamma"}, time: ts())
      store(:a, 1, %{"queue" => "delta"}, time: ts())

      {:ok, [conf: conf]} = start_supervised_oban(%{oban_opts: [notifier: Oban.Notifiers.PG]})
      start_supervised!({Recorder, conf: conf, name: Recorder.B})

      assert_receive {:notification, :handoff, %{"ack" => true, "data" => _}}
    end
  end

  defp start_supervised_recorder(%{conf: conf}) do
    pid = start_supervised!({Recorder, conf: conf, name: @name})

    Process.sleep(10)

    {:ok, pid: pid}
  end

  defp compact(periods) do
    Recorder.compact(@name, periods)
  end

  defp store(series, value, labels, opts \\ [])

  defp store(series, value, labels, opts) when is_integer(value) do
    store(series, Gauge.new(value), labels, opts)
  end

  defp store(series, value, labels, opts) do
    Recorder.store(@name, series, value, labels, opts)
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
