defmodule Oban.Met.Recorder do
  @moduledoc false

  # Aggregate metrics via pubsub for querying and compaction.

  use GenServer

  alias __MODULE__, as: State
  alias Oban.Met.{Value, Values.Count, Values.Gauge, Values.Sketch}
  alias Oban.Notifier

  @type name_or_table :: GenServer.name() | :ets.tid()
  @type series :: atom() | String.t()
  @type value :: Value.t()
  @type label :: String.t()
  @type labels :: %{optional(String.t()) => label()}
  @type ts :: integer()
  @type period :: {pos_integer(), pos_integer()}

  @periods [
    # 1s for 2m
    {1, 120},
    # 5s for 10m
    {5, 600},
    # 60s for 120m
    {60, 7_200},
    # 5m for 1d
    {300, 86_400}
  ]

  @default_latest_opts [
    filters: [],
    group: nil,
    ntile: 1.0,
    lookback: 60,
    type: :gauge
  ]

  @default_timeslice_opts [
    by: 1,
    filters: [],
    group: nil,
    lookback: 60,
    ntile: 1.0,
    type: :count
  ]

  @types ~w(count gauge delta sketch)a

  defstruct [
    :compact_timer,
    :conf,
    :name,
    :table,
    compact_periods: @periods
  ]

  @spec child_spec(Keyword.t()) :: Supervisor.child_spec()
  def child_spec(opts) do
    name = Keyword.get(opts, :name, __MODULE__)

    opts
    |> super()
    |> Map.put(:id, name)
  end

  @spec start_link(Keyword.t()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: opts[:name])
  end

  @spec lookup(GenServer.name(), series()) :: [term()]
  def lookup(name, series) do
    match = {{to_string(series), :_, :_, :_}, :_, :_}

    :ets.select_reverse(table(name), [{match, [], [:"$_"]}])
  end

  @spec latest(GenServer.name(), series(), Keyword.t()) :: %{optional(String.t()) => value()}
  def latest(name, series, opts \\ []) do
    opts = Keyword.validate!(opts, @default_latest_opts)

    since = Keyword.fetch!(opts, :lookback)
    group = Keyword.fetch!(opts, :group)
    ntile = Keyword.fetch!(opts, :ntile)
    vtype = Keyword.fetch!(opts, :type)

    name
    |> table()
    |> select(series, vtype, since, opts[:filters])
    |> Enum.dedup_by(fn {{_, _, labels, _}, _, _} -> labels end)
    |> Enum.group_by(fn {{_, _, labels, _}, _, _} -> labels[group] end)
    |> Map.new(fn {group, [{{_, type, _, _}, _, _} | _] = metrics} ->
      merged =
        case type do
          :gauge ->
            metrics
            |> get_in([Access.all(), Access.elem(2)])
            |> Enum.map(&Gauge.first/1)
            |> Enum.sum()

          :sketch ->
            metrics
            |> get_in([Access.all(), Access.elem(2)])
            |> Enum.reduce(&Sketch.merge/2)
            |> Sketch.quantile(ntile)
        end

      {group || "all", merged}
    end)
  end

  @spec timeslice(GenServer.name(), series(), Keyword.t()) :: [{ts(), value(), label()}]
  def timeslice(name, series, opts \\ []) do
    opts = Keyword.validate!(opts, @default_timeslice_opts)

    group = Keyword.fetch!(opts, :group)
    ntile = Keyword.fetch!(opts, :ntile)
    since = Keyword.fetch!(opts, :lookback)
    slice = Keyword.fetch!(opts, :by)
    vtype = Keyword.fetch!(opts, :type)
    stime = System.system_time(:second)

    name
    |> table()
    |> select(series, vtype, since, opts[:filters])
    |> Enum.reduce(%{}, fn {{_, _, labels, ts}, _, value}, acc ->
      label = labels[group]
      chunk = div(stime - ts - 1, slice)

      Map.update(acc, {label, chunk}, value, &Value.merge(&1, value))
    end)
    |> Enum.sort_by(fn {{label, chunk}, _} -> {label, -chunk} end)
    |> Enum.map(fn {{label, chunk}, value} ->
      {chunk, Value.quantile(value, ntile), label}
    end)
  end

  @doc false
  def store(name, series, type, value, labels, opts \\ []) when type in @types do
    ts = Keyword.get(opts, :timestamp, System.system_time(:second))

    name
    |> table()
    |> inner_store(series, type, value, labels, ts)
  end

  defp inner_store(table, series, type, value, labels, ts) do
    series = to_string(series)

    case {type, get_latest(table, series, type, labels)} do
      {_type, {{^series, ^type, ^labels, ^ts} = key, ^ts, old_value}} ->
        :ets.insert(table, {key, ts, Value.merge(old_value, value)})

      {:delta, {{^series, :gauge, ^labels, _max_ts}, _min_ts, old_value}} ->
        :ets.insert(table, {{series, :gauge, labels, ts}, ts, Gauge.add(old_value, value)})

      {:delta, nil} ->
        :ets.insert(table, {{series, :gauge, labels, ts}, ts, Gauge.new(value)})

      {_other, _object} ->
        :ets.insert(table, {{series, type, labels, ts}, ts, value})
    end
  end

  defp get_latest(table, series, type, labels) do
    match = {{series, type, labels, :_}, :_, :_}

    case :ets.select_reverse(table, [{match, [], [:"$_"]}], 1) do
      {[object], _cont} -> object
      _ -> nil
    end
  end

  @doc false
  def compact(name, periods) when is_list(periods) do
    name
    |> table()
    |> inner_compact(periods)
  end

  @doc false
  def inner_compact(table, periods) do
    delete_outdated(table, periods)

    Enum.reduce(periods, System.system_time(:second), fn {step, duration}, ts ->
      since = ts - duration
      match = {{:_, :_, :_, :"$1"}, :"$2", :_}
      guard = [{:andalso, {:>=, :"$2", since}, {:"=<", :"$1", ts}}]

      objects = :ets.select(table, [{match, guard, [:"$_"]}])
      _delete = :ets.select_delete(table, [{match, guard, [true]}])

      objects
      |> Enum.chunk_by(fn {{ser, typ, lab, max}, _, _} -> {ser, typ, lab, div(ts - max - 1, step)} end)
      |> Enum.map(&compact_object/1)
      |> then(&:ets.insert(table, &1))

      since
    end)
  end

  defp compact_object([{{series, type, labels, _}, _, _} | _] = metrics) do
    {min_ts, max_ts} =
      metrics
      |> Enum.flat_map(fn {{_, _, _, max_ts}, min_ts, _} -> [max_ts, min_ts] end)
      |> Enum.min_max()

    value =
      metrics
      |> Enum.map(&elem(&1, 2))
      |> Enum.reduce(&Value.merge/2)

    {{series, type, labels, max_ts}, min_ts, value}
  end

  defp delete_outdated(table, periods) do
    systime = System.system_time(:second)
    maximum = Enum.reduce(periods, 0, fn {_, duration}, acc -> duration + acc end)

    since = systime - maximum
    match = {{:_, :_, :_, :"$1"}, :_, :_}
    guard = [{:<, :"$1", since}]

    :ets.select_delete(table, [{match, guard, [true]}])
  end

  # Callbacks

  @impl GenServer
  def init(opts) do
    table =
      :ets.new(:metrics, [
        :ordered_set,
        :public,
        read_concurrency: true,
        write_concurrency: true
      ])

    state =
      State
      |> struct!(Keyword.put(opts, :table, table))
      |> subscribe_gossip()
      |> schedule_compact()

    Registry.register(Oban.Registry, state.name, table)

    {:ok, state}
  end

  @impl GenServer
  def handle_info({:notification, :gossip, %{"metrics" => metrics}}, %State{} = state) do
    ts = System.system_time(:second)

    for %{"series" => series, "type" => type, "value" => value} = labels <- metrics do
      labels = Map.drop(labels, ["name", "type", "value"])
      type = String.to_existing_atom(type)

      value =
        case type do
          :count -> Count.from_map(value)
          :gauge -> Gauge.from_map(value)
          :sketch -> Sketch.from_map(value)
          _ -> value
        end

      inner_store(state.table, series, type, value, labels, ts)
    end

    {:noreply, state}
  end

  def handle_info({:notification, :gossip, _payload}, state) do
    {:noreply, state}
  end

  def handle_info(:compact, %State{compact_periods: periods, table: table} = state) do
    Task.start(__MODULE__, :inner_compact, [table, periods])

    {:noreply, schedule_compact(state)}
  end

  # Table Meta

  defp table(name) do
    [{_pid, table}] = Registry.lookup(Oban.Registry, name)

    table
  end

  # Scheduling

  defp subscribe_gossip(%State{conf: conf} = state) do
    Notifier.listen(conf.name, [:gossip])

    state
  end

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

    %State{state | compact_timer: timer}
  end

  # Fetching & Filtering

  defp select(table, series, type, since, filters) do
    stime = System.system_time(:second)
    match = {{to_string(series), type, :"$1", :"$2"}, :_, :_}
    guard = filters_to_guards(filters, {:>=, :"$2", stime - since})

    :ets.select_reverse(table, [{match, [guard], [:"$_"]}])
  end

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
