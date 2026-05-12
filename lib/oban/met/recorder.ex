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

  @periods [{1, 300}, {5, 1_200}, {30, 3_600}, {60, 7_200}]

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
    :latest,
    :name,
    :table,
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

    :ets.select_reverse(table(name), [{match, [], [:"$_"]}])
  end

  @spec labels(GenServer.name(), label(), keyword()) :: [label()]
  def labels(name, label, opts \\ []) when is_binary(label) do
    opts = Keyword.validate!(opts, [:lookback, :since])

    stime = Keyword.get(opts, :since, System.system_time(:second))
    lookback = Keyword.get(opts, :lookback, 120)
    match = {{:_, :_}, :"$2", :"$1", :_}
    guard = [{:andalso, {:is_map_key, label, :"$1"}, {:>=, :"$2", stime - lookback}}]
    value = [{:map_get, label, :"$1"}]

    name
    |> table(:latest)
    |> :ets.select([{match, guard, value}])
    |> :lists.usort()
  end

  @spec latest(GenServer.name(), series(), keyword()) :: %{optional(String.t()) => value()}
  def latest(name, series, opts \\ []) do
    opts = Keyword.validate!(opts, @default_latest_opts)

    group = Keyword.fetch!(opts, :group)
    lookback = Keyword.fetch!(opts, :lookback)
    filters = Keyword.fetch!(opts, :filters)

    name
    |> table(:latest)
    |> select_latest(series, lookback, filters)
    |> Enum.group_by(fn {{_, _}, _, labels, _} -> labels[group] || "all" end)
    |> Map.new(fn {group, metrics} ->
      total =
        metrics
        |> Enum.map(&elem(&1, 3))
        |> Enum.reduce(&Value.merge/2)
        |> Value.sum()

      {group, total}
    end)
  end

  @spec series(GenServer.name()) :: [map()]
  def series(name) do
    match = {{:"$1", :_}, :_, :"$2", :"$3"}

    name
    |> table(:latest)
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
    |> table()
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

  defp merge_group({{_, _, ts}, _, labels, value}, acc, group) do
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
    table =
      :ets.new(:metrics, [
        :compressed,
        :ordered_set,
        :protected,
        read_concurrency: true
      ])

    latest =
      :ets.new(:latest_metrics, [
        :compressed,
        :protected,
        read_concurrency: true
      ])

    state =
      State
      |> struct!(opts |> Keyword.put(:latest, latest) |> Keyword.put(:table, table))
      |> schedule_compact()

    Registry.register(Oban.Registry, state.name, %{latest: latest, metrics: table})

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
  def handle_call({:compact, periods}, _from, %State{latest: latest, table: table} = state) do
    inner_compact(table, latest, periods)

    {:reply, :ok, state}
  end

  def handle_call({:store, params}, _from, %State{latest: latest, table: table} = state) do
    {series, value, labels, time} = params

    inner_store(table, latest, series, value, labels, time)

    {:reply, :ok, state}
  end

  @impl GenServer
  def handle_info({:notification, :handoff, %{"syn" => _}}, state) do
    if Peer.leader?(state.conf) do
      data =
        %{latest: :ets.tab2list(state.latest), metrics: :ets.tab2list(state.table)}
        |> :erlang.term_to_binary()
        |> Base.encode64()

      payload = %{
        ack: true,
        module: __MODULE__,
        data: data,
        node: state.conf.node,
        name: inspect(state.conf.name)
      }

      Notifier.notify(state.conf, :handoff, payload)
    end

    {:noreply, state}
  end

  def handle_info({:notification, :handoff, %{"ack" => _, "data" => data}}, %State{} = state) do
    if state.handoff == :awaiting and not Peer.leader?(state.conf) do
      data
      |> Base.decode64!()
      |> :erlang.binary_to_term()
      |> then(fn %{latest: latest, metrics: metrics} ->
        :ets.insert(state.latest, latest)
        :ets.insert(state.table, metrics)
      end)
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

      inner_store(state.table, state.latest, series, from_map(value), labels, time)
    end

    {:noreply, state}
  end

  def handle_info({:notification, _channel, _payload}, state) do
    {:noreply, state}
  end

  def handle_info(:compact, %State{compact_periods: periods, latest: latest, table: table} = state) do
    inner_compact(table, latest, periods)

    :erlang.garbage_collect()

    {:noreply, schedule_compact(state), :hibernate}
  end

  defp from_map(%{"size" => _} = value), do: Sketch.from_map(value)
  defp from_map(value), do: Gauge.from_map(value)

  # Table

  defp table(name, which \\ :metrics) do
    case Registry.lookup(Oban.Registry, name) do
      [{_pid, tables}] ->
        Map.fetch!(tables, which)

      _ ->
        raise RuntimeError, "no table registered for #{inspect(name)}"
    end
  end

  defp inner_compact(table, latest, periods) do
    delete_outdated(table, latest, periods)

    Enum.reduce(periods, System.system_time(:second), fn {step, duration}, ts ->
      since = ts - duration
      match = {{:_, :_, :"$1"}, :"$2", :_, :_}
      guard = [{:andalso, {:>=, :"$2", since}, {:"=<", :"$1", ts}}]

      objects = :ets.select(table, [{match, guard, [:"$_"]}])
      _delete = :ets.select_delete(table, [{match, guard, [true]}])

      compacted =
        objects
        |> Enum.chunk_by(fn {{ser, lab, max}, _, _, _} -> {ser, lab, div(ts - max - 1, step)} end)
        |> Enum.map(&compact_object/1)

      :ets.insert(table, compacted)
      Enum.each(compacted, &put_latest_row(latest, &1))

      since
    end)
  end

  defp compact_object([{{series, lab_key, _}, _, labels, _} | _] = metrics) do
    {min_ts, max_ts} =
      metrics
      |> Enum.flat_map(fn {{_, _, max_ts}, min_ts, _, _} -> [max_ts, min_ts] end)
      |> Enum.min_max()

    value =
      metrics
      |> Enum.map(&elem(&1, 3))
      |> Enum.reduce(&Value.merge/2)

    {{series, lab_key, max_ts}, min_ts, labels, value}
  end

  defp delete_outdated(table, latest, periods) do
    systime = System.system_time(:second)
    maximum = Enum.reduce(periods, 0, fn {_, duration}, acc -> duration + acc end)

    since = systime - maximum
    match = {{:_, :_, :"$1"}, :_, :_, :_}
    guard = [{:<, :"$1", since}]

    :ets.select_delete(table, [{match, guard, [true]}])
    :ets.select_delete(latest, [{{{:_, :_}, :"$1", :_, :_}, [{:<, :"$1", since}], [true]}])
  end

  defp inner_store(table, latest, series, value, labels, time) do
    key = {to_string(series), label_key(labels), time}

    row =
      case :ets.lookup(table, key) do
        [{_key, _time, _labels, old_value}] -> {key, time, labels, Value.union(old_value, value)}
        _ -> {key, time, labels, value}
      end

    :ets.insert(table, row)
    put_latest_row(latest, row)
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

  defp select(table, series, lookback, filters) do
    stime = System.system_time(:second)
    match = {{to_string(series), :_, :"$2"}, :_, :"$1", :_}
    guard = filters_to_guards(filters, :"$1", {:>=, :"$2", stime - lookback})

    :ets.select_reverse(table, [{match, [guard], [:"$_"]}])
  end

  defp select_latest(table, series, lookback, filters) do
    stime = System.system_time(:second)
    match = {{to_string(series), :_}, :"$2", :"$1", :_}
    guard = filters_to_guards(filters, :"$1", {:>=, :"$2", stime - lookback})

    :ets.select(table, [{match, [guard], [:"$_"]}])
  end

  defp put_latest_row(latest, {{series, lab_key, time}, _min_time, labels, value}) do
    key = {series, lab_key}

    case :ets.lookup(latest, key) do
      [{^key, latest_time, _, _}] when latest_time > time -> :ok
      _ -> :ets.insert(latest, {key, time, labels, value})
    end
  end

  defp label_key(labels), do: :erlang.phash2(labels)

  defp filters_to_guards(nil, _labels, base), do: base

  defp filters_to_guards(filters, labels, base) do
    Enum.reduce(filters, base, fn {field, values}, and_acc ->
      and_guard =
        values
        |> List.wrap()
        |> Enum.map(fn value -> {:==, {:map_get, to_string(field), labels}, value} end)
        |> Enum.reduce(fn or_guard, or_acc -> {:orelse, or_guard, or_acc} end)

      {:andalso, and_guard, and_acc}
    end)
  end
end
