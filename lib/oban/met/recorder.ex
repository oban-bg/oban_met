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

  @periods [{1, 120}, {5, 600}, {60, 7_200}]

  @default_latest_opts [
    filters: [],
    group: nil,
    ntile: 1.0,
    lookback: 5,
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

  @spec labels(GenServer.name(), label()) :: [label()]
  def labels(name, label) when is_binary(label) do
    match = {{:_, :_, :"$1", :_}, :_, :_}
    guard = [{:is_map_key, label, :"$1"}]
    value = [{:map_get, label, :"$1"}]

    name
    |> table()
    |> :ets.select([{match, guard, value}])
    |> :lists.usort()
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
    |> Enum.group_by(fn {{_, _, labels, _}, _, _} -> labels[group] || "all" end)
    |> Map.new(fn {group, metrics} ->
      merged =
        metrics
        |> get_in([Access.all(), Access.elem(2)])
        |> Enum.reduce(&Value.merge/2)
        |> Value.quantile(ntile)

      {group, merged}
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
    time = Keyword.get(opts, :time, System.system_time(:second))

    GenServer.call(name, {:store, {series, type, value, labels, time}})
  end

  @doc false
  def compact(name, periods) when is_list(periods) do
    GenServer.call(name, {:compact, periods})
  end

  defp compact_object([{{series, type, labels, _}, _, _} | _] = metrics) do
    {min_ts, max_ts} =
      metrics
      |> Enum.flat_map(fn {{_, _, _, max_ts}, min_ts, _} -> [max_ts, min_ts] end)
      |> Enum.min_max()

    value =
      metrics
      |> Enum.map(&elem(&1, 2))
      |> Enum.reduce(&Value.compact/2)

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
        :protected,
        read_concurrency: true
      ])

    state =
      State
      |> struct!(Keyword.put(opts, :table, table))
      |> schedule_compact()

    Notifier.listen(state.conf.name, [:gossip])

    Registry.register(Oban.Registry, state.name, table)

    {:ok, state}
  end

  @impl GenServer
  def handle_call({:store, params}, _from, %State{table: table} = state) do
    {series, type, value, labels, time} = params

    inner_store(table, series, type, value, labels, time)

    {:reply, :ok, state}
  end

  def handle_call({:compact, periods}, _from, %State{table: table} = state) do
    inner_compact(table, periods)

    {:reply, :ok, state}
  end

  @impl GenServer
  def handle_info({:notification, :gossip, %{"metrics" => _} = payload}, %State{} = state) do
    %{"metrics" => metrics, "node" => node, "time" => time} = payload

    for %{"series" => series, "type" => type, "value" => value} = labels <- metrics do
      type = String.to_existing_atom(type)

      labels =
        labels
        |> Map.drop(["type", "value"])
        |> Map.put("node", node)

      value =
        case type do
          :count -> Count.from_map(value)
          :gauge -> Gauge.from_map(value)
          :sketch -> Sketch.from_map(value)
          _ -> value
        end

      inner_store(state.table, series, type, value, labels, time)
    end

    {:noreply, state}
  end

  def handle_info({:notification, :gossip, _payload}, state) do
    {:noreply, state}
  end

  def handle_info(:compact, %State{compact_periods: periods, table: table} = state) do
    inner_compact(table, periods)

    {:noreply, schedule_compact(state)}
  end

  # Table

  defp table(name) do
    [{_pid, table}] = Registry.lookup(Oban.Registry, name)

    table
  end

  defp inner_store(table, series, type, value, labels, ts) do
    series = to_string(series)
    lookup = if type == :delta, do: :gauge, else: type

    case {type, get_latest(table, series, lookup, labels)} do
      {:delta, {{^series, :gauge, ^labels, _max_ts}, _min_ts, old_value}} ->
        :ets.insert(table, {{series, :gauge, labels, ts}, ts, Gauge.add(old_value, value)})

      {:delta, nil} ->
        :ets.insert(table, {{series, :gauge, labels, ts}, ts, Gauge.new(value)})

      {_type, {{^series, ^lookup, ^labels, ^ts} = key, ^ts, old_value}} ->
        :ets.insert(table, {key, ts, Value.merge(old_value, value)})

      {_other, _object} ->
        :ets.insert(table, {{series, lookup, labels, ts}, ts, value})
    end
  end

  defp get_latest(table, series, type, labels) do
    match = {{series, type, labels, :_}, :_, :_}

    case :ets.select_reverse(table, [{match, [], [:"$_"]}], 1) do
      {[object], _cont} -> object
      _ -> nil
    end
  end

  defp inner_compact(table, periods) do
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
