defmodule Oban.Met.Recorder do
  @moduledoc false

  # Aggregate metrics via pubsub for querying and compaction.

  use GenServer

  alias __MODULE__, as: State
  alias Oban.Met.{Gauge, Sketch, Value}
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

  @default_timeslice_opts [filters: [], label: :any, ntile: 1.0, lookback: 5, by: 1]

  @default_latest_opts [filters: [], group: nil, ntile: 1.0, lookback: 5]

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
    {:ok, table} = Registry.meta(Oban.Registry, name)

    match = {{to_string(series), :_, :_}, :_, :_, :_}

    :ets.select(table, [{match, [], [:"$_"]}])
  end

  @spec latest(GenServer.name(), series(), Keyword.t()) :: %{optional(String.t()) => value()}
  def latest(name, series, opts \\ []) do
    opts = Keyword.validate!(opts, @default_latest_opts)

    {:ok, table} = Registry.meta(Oban.Registry, name)

    since = Keyword.fetch!(opts, :lookback)
    group = Keyword.fetch!(opts, :group)
    ntile = Keyword.fetch!(opts, :ntile)
    systm = System.system_time(:second)
    match = {{to_string(series), :"$1", :"$2"}, :_, :_, :_}
    guard = filters_to_guards(opts[:filters], {:>=, :"$2", systm - since})

    table
    |> :ets.select_reverse([{match, [guard], [:"$_"]}])
    |> Enum.dedup_by(fn {{_, labels, _}, _, _, _} -> labels end)
    |> Enum.group_by(fn {{_, labels, _}, _, _, _} -> labels[group] end)
    |> Map.new(fn {group, [{_, _, type, _} | _] = metrics} ->
      merged =
        case type do
          :gauge ->
            metrics
            |> get_in([Access.all(), Access.elem(3)])
            |> Enum.map(&Value.quantile(&1, 1.0))
            |> Enum.sum()

          :sketch ->
            metrics
            |> get_in([Access.all(), Access.elem(3)])
            |> Enum.reduce(&Sketch.merge/2)
            |> Sketch.quantile(ntile)
        end

      {group || "all", merged}
    end)
  end

  @spec timeslice(GenServer.name(), series(), Keyword.t()) :: [{ts(), value(), label()}]
  def timeslice(name, series, opts \\ []) do
    opts = Keyword.validate!(opts, @default_timeslice_opts)

    {:ok, table} = Registry.meta(Oban.Registry, name)

    label = Keyword.fetch!(opts, :label)
    ntile = Keyword.fetch!(opts, :ntile)
    since = Keyword.fetch!(opts, :lookback)
    slice = Keyword.fetch!(opts, :by)
    systm = System.system_time(:second)

    match = {{to_string(series), :"$1", :"$2"}, :_, :_, :_}
    guard = filters_to_guards(opts[:filters], {:>=, :"$2", systm - since})

    table
    |> :ets.select_reverse([{match, [guard], [:"$_"]}])
    |> Enum.map(fn {{_, labels, ts}, _, _, value} -> {ts, value, labels[label]} end)
    |> Enum.sort_by(fn {ts, _, label} -> {label, ts} end)
    |> Enum.chunk_by(fn {ts, _, label} -> {label, div(systm - ts - 1, slice)} end)
    |> Enum.map(&merge_into_ntile(&1, ntile))
  end

  @doc false
  def store(name, series, type, value, labels, opts \\ [])
      when type in [:gauge, :delta, :sketch] do
    with {:ok, table} <- Registry.meta(Oban.Registry, name) do
      inner_store(table, series, type, value, labels, opts)
    end
  end

  defp inner_store(table, series, type, value, labels, opts) do
    ts = Keyword.get(opts, :timestamp, System.system_time(:second))

    series = to_string(series)

    case {type, get_latest(table, series, labels)} do
      {_type, {{^series, ^labels, ^ts} = key, ^ts, ^type, old_value}} ->
        :ets.insert(table, {key, ts, type, Value.merge(old_value, value)})

      {:delta, {{^series, ^labels, _max_ts}, _min_ts, :gauge, old_value}} ->
        :ets.insert(table, {{series, labels, ts}, ts, :gauge, Value.add(old_value, value)})

      {:delta, nil} ->
        :ets.insert(table, {{series, labels, ts}, ts, :gauge, Gauge.new(value)})

      {:gauge, _object} ->
        :ets.insert(table, {{series, labels, ts}, ts, type, value})

      {_type, _object} ->
        :ets.insert(table, {{series, labels, ts}, ts, type, value})
    end
  end

  defp get_latest(table, series, labels) do
    match = {{series, labels, :_}, :_, :_, :_}

    case :ets.select_reverse(table, [{match, [], [:"$_"]}], 1) do
      {[object], _cont} -> object
      _ -> nil
    end
  end

  @doc false
  def compact(name, periods) when is_list(periods) do
    with {:ok, table} <- Registry.meta(Oban.Registry, name) do
      inner_compact(table, periods)
    end
  end

  @doc false
  def inner_compact(table, periods) do
    delete_outdated(table, periods)

    Enum.reduce(periods, System.system_time(:second), fn {step, duration}, ts ->
      since = ts - duration
      match = {{:_, :_, :"$1"}, :"$2", :_, :_}
      guard = [{:andalso, {:>=, :"$2", since}, {:"=<", :"$1", ts}}]

      objects = :ets.select(table, [{match, guard, [:"$_"]}])
      _delete = :ets.select_delete(table, [{match, guard, [true]}])

      objects
      |> Enum.chunk_by(fn {{ser, lab, max}, _, _, _} -> {ser, lab, div(ts - max - 1, step)} end)
      |> Enum.map(&compact_object/1)
      |> then(&:ets.insert(table, &1))

      since
    end)
  end

  defp compact_object([{{series, labels, _}, _, type, _} | _] = metrics) do
    {min_ts, max_ts} =
      metrics
      |> Enum.flat_map(fn {{_, _, max_ts}, min_ts, _, _} -> [max_ts, min_ts] end)
      |> Enum.min_max()

    value =
      metrics
      |> Enum.map(&elem(&1, 3))
      |> Enum.reduce(&Value.merge/2)

    {{series, labels, max_ts}, min_ts, type, value}
  end

  defp delete_outdated(table, periods) do
    systime = System.system_time(:second)
    maximum = Enum.reduce(periods, 0, fn {_, duration}, acc -> duration + acc end)

    since = systime - maximum
    match = {{:_, :_, :"$1"}, :_, :_, :_}
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

    Registry.put_meta(Oban.Registry, state.name, table)

    {:ok, state}
  end

  @impl GenServer
  def handle_info({:notification, :gossip, %{"metrics" => metrics}}, %State{} = state) do
    for %{"series" => series, "type" => type, "value" => value} = labels <- metrics do
      labels = Map.drop(labels, ["name", "type", "value"])
      type = String.to_existing_atom(type)

      value =
        case type do
          :gauge -> Gauge.from_map(value)
          :sketch -> Sketch.from_map(value)
          _ -> value
        end

      inner_store(state.table, series, type, value, labels, [])
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

  defp merge_into_ntile(metrics, ntile) do
    metrics
    |> Enum.reduce(fn {_, new, _}, {ts, acc, label} -> {ts, Value.merge(new, acc), label} end)
    |> update_in([Access.elem(1)], &Value.quantile(&1, ntile))
  end
end
