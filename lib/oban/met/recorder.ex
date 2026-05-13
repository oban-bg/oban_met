defmodule Oban.Met.Recorder do
  @moduledoc false

  # Aggregate metrics via pubsub for querying and compaction.

  use GenServer

  alias __MODULE__, as: State
  alias Oban.Met.{Value, Values.Gauge, Values.Sketch}
  alias Oban.{Notifier, Peer}

  @type series :: atom() | String.t()
  @type value :: Value.t()
  @type label :: String.t()
  @type labels :: %{optional(String.t()) => label()}
  @type ts :: integer()
  @type period :: {pos_integer(), pos_integer()}

  @chunk_size 500

  @periods [{1, 120}, {5, 900}, {30, 2_000}, {60, 9_300}]

  @default_latest_opts [filters: [], group: nil, lookback: 2]

  @default_timeslice_opts [
    by: 1,
    filters: [],
    group: nil,
    lookback: 60,
    operation: :sum
  ]

  defstruct [
    :compact_timer,
    :conf,
    :latest_table,
    :name,
    :series_table,
    compact_periods: @periods,
    handoff: :awaiting
  ]

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    name = Keyword.get(opts, :name, __MODULE__)

    %{super(opts) | id: name}
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: opts[:name])
  end

  @spec lookup(GenServer.name(), series()) :: [term()]
  def lookup(name, series) do
    match = {{to_string(series), :_, :_}, :_, :_, :_}

    name
    |> series_table()
    |> :ets.select_reverse([{match, [], [:"$_"]}])
  end

  @spec labels(GenServer.name(), label(), keyword()) :: [label()]
  def labels(name, label, opts \\ []) when is_binary(label) do
    opts = Keyword.validate!(opts, [:lookback, :since])

    stime = Keyword.get(opts, :since, System.system_time(:second))
    lookback = Keyword.get(opts, :lookback, 120)
    match = {{:_, :_}, :"$1", :_, :"$2"}
    guard = [{:andalso, {:is_map_key, label, :"$1"}, {:>=, :"$2", stime - lookback}}]
    value = [{:map_get, label, :"$1"}]

    name
    |> latest_table()
    |> :ets.select([{match, guard, value}])
    |> :lists.usort()
  end

  @spec latest(GenServer.name(), series(), keyword()) :: %{optional(String.t()) => value()}
  def latest(name, series, opts \\ []) do
    opts = Keyword.validate!(opts, @default_latest_opts)

    group = Keyword.fetch!(opts, :group)
    lookback = Keyword.fetch!(opts, :lookback)
    filters = Keyword.fetch!(opts, :filters)

    stime = System.system_time(:second)
    match = {{to_string(series), :_}, :"$1", :"$2", :"$3"}
    guard = filters_to_guards(filters, {:>=, :"$3", stime - lookback})
    body = [{{:"$1", :"$2"}}]

    name
    |> latest_table()
    |> :ets.select([{match, [guard], body}])
    |> Enum.reduce(%{}, fn {labels, value}, acc ->
      Map.update(acc, labels[group] || "all", value, &Value.merge(&1, value))
    end)
    |> Map.new(fn {group, merged} -> {group, Value.sum(merged)} end)
  end

  @spec series(GenServer.name()) :: [map()]
  def series(name) do
    match = {{:"$1", :_}, :"$2", :"$3", :_}

    name
    |> latest_table()
    |> :ets.select([{match, [], [:"$$"]}])
    |> Enum.group_by(&hd/1)
    |> Enum.map(fn {series, [[_series, _labels, %vtype{}] | _] = metrics} ->
      labels =
        for [_series, labels, _value] <- metrics,
            key <- Map.keys(labels),
            uniq: true,
            do: key

      %{series: series, labels: labels, type: vtype}
    end)
    |> Enum.sort_by(& &1.series)
  end

  @spec timeslice(GenServer.name(), series(), keyword()) :: [{ts(), value(), label()}]
  def timeslice(name, series, opts \\ []) do
    opts = Keyword.validate!(opts, [:since] ++ @default_timeslice_opts)

    by = Keyword.fetch!(opts, :by)
    group = Keyword.fetch!(opts, :group)
    lookback = Keyword.fetch!(opts, :lookback)
    operation = Keyword.fetch!(opts, :operation)
    since = Keyword.get(opts, :since, System.system_time(:second))

    name
    |> series_table()
    |> select(series, lookback, opts[:filters])
    |> Enum.reduce(%{}, &merge_group(&1, &2, group))
    |> Enum.reduce(%{}, &merge_chunk(&1, &2, since, by))
    |> Enum.sort_by(fn {{label, chunk}, _} -> {label, -chunk} end)
    |> Enum.map(fn {{label, chunk}, value} ->
      value =
        case operation do
          :sum -> Value.sum(value)
          :max -> Value.quantile(value, 1.0)
          {:pct, ntile} -> Value.quantile(value, ntile)
        end

      {chunk, value, label}
    end)
  end

  defp merge_group({{_, ts, _}, _, labels, value}, acc, group) do
    Map.update(acc, {labels[group], ts}, value, &Value.union(&1, value))
  end

  defp merge_chunk({{label, ts}, value}, acc, since, by) do
    chunk = div(since - ts - 1, by)

    Map.update(acc, {label, chunk}, value, &Value.merge(&1, value))
  end

  def compact(name, periods) when is_list(periods) do
    GenServer.call(name, {:compact, periods})
  end

  def store(name, series, value, labels, opts \\ []) do
    time = Keyword.get(opts, :time, System.system_time(:second))

    GenServer.call(name, {:store, {series, value, labels, time}})
  end

  # Callbacks

  @impl GenServer
  def init(opts) do
    series_table =
      :ets.new(:metrics_series, [
        :ordered_set,
        :public,
        read_concurrency: true,
        write_concurrency: true
      ])

    latest_table =
      :ets.new(:metrics_latest, [
        :ordered_set,
        :public,
        read_concurrency: true,
        write_concurrency: true
      ])

    state =
      opts
      |> Keyword.put(:series_table, series_table)
      |> Keyword.put(:latest_table, latest_table)
      |> then(&struct!(State, &1))
      |> schedule_compact()

    Registry.register(Oban.Registry, state.name, {series_table, latest_table})

    {:ok, state, {:continue, :start}}
  end

  @impl GenServer
  def handle_continue(:start, %State{conf: conf} = state) do
    payload = %{
      syn: true,
      module: __MODULE__,
      name: inspect(conf.name),
      node: conf.node
    }

    Notifier.notify(conf.name, :handoff, payload)
    Notifier.listen(conf.name, [:gossip, :handoff, :metrics])

    {:noreply, state}
  end

  @impl GenServer
  def handle_call({:compact, periods}, _from, %State{} = state) do
    inner_compact(state.series_table, state.latest_table, periods, System.system_time(:second))

    {:reply, :ok, state}
  end

  def handle_call({:store, params}, _from, %State{} = state) do
    {series, value, labels, time} = params

    inner_store(state.series_table, state.latest_table, series, value, labels, time)

    {:reply, :ok, state}
  end

  @impl GenServer
  def handle_info({:notification, :handoff, %{"syn" => _}}, state) do
    if Peer.leader?(state.conf) do
      %{conf: conf, series_table: series_table} = state

      Task.start_link(fn ->
        data =
          series_table
          |> :ets.tab2list()
          |> :erlang.term_to_binary([:compressed])
          |> Base.encode64()

        payload = %{
          ack: true,
          module: __MODULE__,
          data: data,
          node: conf.node,
          name: inspect(conf.name)
        }

        Notifier.notify(conf, :handoff, payload)
      end)
    end

    {:noreply, state}
  end

  def handle_info({:notification, :handoff, %{"ack" => _, "data" => data}}, %State{} = state) do
    if state.handoff == :awaiting and not Peer.leader?(state.conf) do
      data
      |> Base.decode64!()
      |> :erlang.binary_to_term()
      |> then(&:ets.insert(state.series_table, &1))

      rebuild_latest(state.series_table, state.latest_table)
    end

    {:noreply, %{state | handoff: :complete}}
  end

  def handle_info({:notification, :metrics, %{"metrics" => _} = payload}, state) do
    %{"metrics" => metrics, "node" => node, "time" => time} = payload

    for %{"series" => series, "value" => value} = metric <- metrics do
      labels =
        metric
        |> Map.drop(~w(series value))
        |> Map.put("node", node)

      inner_store(state.series_table, state.latest_table, series, from_map(value), labels, time)
    end

    {:noreply, state}
  end

  def handle_info({:notification, _channel, _payload}, state) do
    {:noreply, state}
  end

  def handle_info(:compact, %State{} = state) do
    %{compact_periods: periods, series_table: series_table, latest_table: latest_table} = state

    # Window shifted back 2s so concurrent writes (at time=now) can't race the delete.
    Task.start(fn ->
      inner_compact(series_table, latest_table, periods, System.system_time(:second) - 2)
    end)

    {:noreply, schedule_compact(state)}
  end

  defp from_map(%{"size" => _} = value), do: Sketch.from_map(value)
  defp from_map(value), do: Gauge.from_map(value)

  # Table

  defp latest_table(name), do: name |> tables() |> elem(1)

  defp series_table(name), do: name |> tables() |> elem(0)

  defp tables(name) do
    case Registry.lookup(Oban.Registry, name) do
      [{_pid, {_series, _latest} = pair}] ->
        pair

      _ ->
        raise RuntimeError, "no table registered for #{inspect(name)}"
    end
  end

  defp inner_compact(series_table, latest_table, periods, now) do
    delete_outdated_series(series_table, periods, now)
    delete_outdated_latest(latest_table, periods, now)

    Enum.reduce(periods, now, fn {step, duration}, ts ->
      since = ts - duration
      match = {{:_, :"$1", :_}, :"$2", :_, :_}
      guard = [{:andalso, {:>=, :"$2", since}, {:"=<", :"$1", ts}}]

      objects = :ets.select(series_table, [{match, guard, [:"$_"]}])
      _delete = :ets.select_delete(series_table, [{match, guard, [true]}])

      objects
      |> Enum.group_by(fn {{ser, max, lab}, _, _, _} -> {ser, lab, div(ts - max - 1, step)} end)
      |> Enum.map(fn {_chunk, metrics} -> compact_object(metrics) end)
      |> then(&:ets.insert(series_table, &1))

      since
    end)
  end

  defp compact_object([{{series, _, lab_key}, _, labels, _} | _] = metrics) do
    {min_ts, max_ts} =
      metrics
      |> Enum.flat_map(fn {{_, max_ts, _}, min_ts, _, _} -> [max_ts, min_ts] end)
      |> Enum.min_max()

    value =
      metrics
      |> Enum.map(&elem(&1, 3))
      |> Enum.reduce(&Value.merge/2)

    {{series, max_ts, lab_key}, min_ts, labels, value}
  end

  defp delete_outdated_series(table, periods, now) do
    maximum = Enum.reduce(periods, 0, fn {_, duration}, acc -> duration + acc end)

    since = now - maximum
    match = {{:_, :"$1", :_}, :_, :_, :_}
    guard = [{:<, :"$1", since}]

    :ets.select_delete(table, [{match, guard, [true]}])
  end

  defp inner_store(series_table, latest_table, series, value, labels, time) do
    series = to_string(series)
    hash = :erlang.phash2(labels)
    key = {series, time, hash}

    merged =
      case :ets.lookup(series_table, key) do
        [{_key, _time, _labels, old_value}] -> Value.union(old_value, value)
        _ -> value
      end

    :ets.insert(series_table, {key, time, labels, merged})

    case :ets.lookup(latest_table, {series, hash}) do
      [{_, _, _, prev_time}] when prev_time > time ->
        :ok

      [{_, _, prev_value, ^time}] ->
        :ets.insert(latest_table, {{series, hash}, labels, Value.union(prev_value, value), time})

      _ ->
        :ets.insert(latest_table, {{series, hash}, labels, value, time})
    end
  end

  defp delete_outdated_latest(latest_table, periods, now) do
    maximum = Enum.reduce(periods, 0, fn {_, duration}, acc -> duration + acc end)
    since = now - maximum
    match = {{:_, :_}, :_, :_, :"$1"}
    guard = [{:<, :"$1", since}]

    :ets.select_delete(latest_table, [{match, guard, [true]}])
  end

  defp rebuild_latest(series_table, latest_table) do
    :ets.delete_all_objects(latest_table)

    fun = fn {{series, max_ts, hash}, _min_ts, labels, value}, acc ->
      Map.update(acc, {series, hash}, {labels, value, max_ts}, fn
        {_, _, prev_ts} = entry when prev_ts >= max_ts -> entry
        _ -> {labels, value, max_ts}
      end)
    end

    fun
    |> :ets.foldl(%{}, series_table)
    |> Enum.each(fn {key, {labels, value, max_ts}} ->
      :ets.insert(latest_table, {key, labels, value, max_ts})
    end)
  end

  # Scheduling

  defp schedule_compact(state) do
    time = Time.utc_now()

    interval =
      time
      |> Time.add(60)
      |> Map.put(:second, 0)
      |> Time.diff(time)
      |> Integer.mod(86_400)
      |> System.convert_time_unit(:second, :millisecond)

    timer = Process.send_after(self(), :compact, interval)

    %{state | compact_timer: timer}
  end

  # Fetching & Filtering

  defp select(table, series, since, filters) do
    cutoff = System.system_time(:second) - since
    match = {{to_string(series), :_, :_}, :_, :"$1", :_}

    conditions =
      case filters do
        [_ | _] -> [filters_to_guards(filters, true)]
        _ -> []
      end

    case :ets.select_reverse(table, [{match, conditions, [:"$_"]}], @chunk_size) do
      {rows, cont} -> collect_until(rows, cont, cutoff, [])
      :"$end_of_table" -> []
    end
  end

  defp collect_until(rows, cont, cutoff, acc) do
    case take_recent(rows, cutoff, acc) do
      {:done, acc} ->
        acc

      {:continue, acc} ->
        case :ets.select(cont) do
          {more, more_cont} -> collect_until(more, more_cont, cutoff, acc)
          :"$end_of_table" -> acc
        end
    end
  end

  defp take_recent([], _cutoff, acc), do: {:continue, acc}

  defp take_recent([{{_, max_ts, _}, _, _, _} = row | rest], cutoff, acc) when max_ts >= cutoff do
    take_recent(rest, cutoff, [row | acc])
  end

  defp take_recent(_, _cutoff, acc), do: {:done, acc}

  defp filters_to_guards(nil, base), do: base

  defp filters_to_guards(filters, base) do
    Enum.reduce(filters, base, fn {field, values}, and_acc ->
      and_guard =
        values
        |> List.wrap()
        |> Enum.map(fn value -> {:==, {:map_get, to_string(field), :"$1"}, value} end)
        |> Enum.reduce(fn or_guard, or_acc -> {:orelse, or_guard, or_acc} end)

      {:andalso, and_guard, and_acc}
    end)
  end
end
