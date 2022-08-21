defmodule Oban.Met.Recorder do
  @moduledoc """
  Aggregate metrics via pubsub for querying and compaction.
  """

  use GenServer

  alias __MODULE__, as: State
  alias Oban.Met.Sketch
  alias Oban.Notifier

  @type name_or_table :: GenServer.name() | :ets.t()
  @type series :: atom() | String.t()
  @type value :: integer() | Sketch.t()
  @type label :: String.t() | nil
  @type labels :: %{optional(String.t()) => label()}
  @type ts :: integer()

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

  defstruct [
    :checkpoint,
    :checkpoint_timer,
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
    {:ok, table} = Registry.meta(Oban.Registry, name)

    since = Keyword.get(opts, :lookback, 5)
    match = {{to_string(series), :"$1", :"$2"}, :_, :_, :_}
    guard = filters_to_guards(opts[:filters], {:>=, :"$2", since})

    grouper = fn {{_, labels, _}, _, _, _} ->
      case opts[:group] do
        nil -> labels
        group -> labels[to_string(group)]
      end
    end

    table
    |> :ets.select_reverse([{match, [guard], [:"$_"]}])
    |> Enum.group_by(grouper)
    |> Enum.reduce(%{}, fn {group, [{_, _, _, value} | _]}, acc ->
      if is_binary(group) do
        Map.put(acc, group, value)
      else
        Map.update(acc, "all", value, &merge(&1, value))
      end
    end)
  end

  @spec timeslice(GenServer.name(), series(), Keyword.t()) :: [{ts(), value(), label()}]
  def timeslice(name, series, opts \\ []) do
    {:ok, table} = Registry.meta(Oban.Registry, name)

    slice = Keyword.get(opts, :by, 1)
    label = to_string(Keyword.get(opts, :label, :any))
    ntile = Keyword.get(opts, :quantile, 1.0)
    now = System.system_time(:second)

    table
    |> select(series, opts[:lookback])
    |> filter_metrics(opts[:filters])
    |> rewrite_deltas()
    |> Enum.map(fn {ts, value, labels} -> {ts, to_sketch(value), labels[label]} end)
    |> Enum.sort_by(&elem(&1, 2))
    |> Enum.chunk_by(fn {ts, _, label} -> {label, div(now - ts, slice)} end)
    |> Enum.map(&merge_metrics(&1, ntile))
  end

  @doc false
  def store(name_or_table, series, type, value, labels, opts \\ [])

  def store(table, series, type, value, labels, opts)
      when is_reference(table) and type in [:gauge, :delta, :sketch] do
    series = to_string(series)
    ts = Keyword.get(opts, :timestamp, System.system_time(:second))

    case {type, get_latest(table, series, labels)} do
      {_type, {{^series, ^labels, ^ts} = key, ^ts, ^type, old_value}} ->
        :ets.insert(table, {key, ts, type, merge(old_value, value)})

      {:delta, {{^series, ^labels, _max_ts}, _min_ts, :gauge, old_value}} ->
        :ets.insert(table, {{series, labels, ts}, ts, type, merge(old_value, value)})

      {:delta, nil} ->
        raise "missing gauge"

      {_type, _object} ->
        :ets.insert(table, {{series, labels, ts}, ts, type, value})
    end
  end

  def store(name, series, type, value, labels, opts) do
    with {:ok, table} <- Registry.meta(Oban.Registry, name) do
      store(table, series, type, value, labels, opts)
    end
  end

  defp get_latest(table, series, labels) do
    match = {{series, labels, :_}, :_, :_, :_}

    case :ets.select_reverse(table, [{match, [], [:"$_"]}], 1) do
      {[object], _cont} -> object
      _ -> nil
    end
  end

  defp merge(%Sketch{} = old, %Sketch{} = new), do: Sketch.merge(old, new)
  defp merge(%Sketch{} = old, new), do: Sketch.insert(old, new)
  defp merge(old, new), do: old + new

  @doc false
  def compact(table, periods) when is_reference(table) and is_list(periods) do
    delete_outdated(table, periods)

    Enum.reduce(periods, System.system_time(:second), fn {step, duration}, ts ->
      since = ts - duration
      match = {{:_, :_, :"$1"}, :"$2", :_, :_}
      guard = [{:andalso, {:>=, :"$2", since}, {:"=<", :"$1", ts}}]

      objects = :ets.select(table, [{match, guard, [:"$_"]}])
      _delete = :ets.select_delete(table, [{match, guard, [true]}])

      objects
      |> Enum.chunk_by(fn {{_, _, max_ts}, _, _, _} -> div(ts - max_ts - 1, step) end)
      |> Enum.map(&compact/1)
      |> then(&:ets.insert(table, &1))

      since
    end)
  end

  def compact(name, periods) do
    with {:ok, table} <- Registry.meta(Oban.Registry, name) do
      compact(table, periods)
    end
  end

  defp compact([{{series, labels, min_ts}, _, type, _} | _] = metrics) do
    max_ts = metrics |> List.last() |> elem(1)

    value =
      Enum.reduce(metrics, Sketch.new(), fn {_key, _min, _type, value}, acc ->
        value
        |> to_sketch()
        |> Sketch.merge(acc)
      end)

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
      |> schedule_checkpoint()
      |> schedule_compact()

    Registry.put_meta(Oban.Registry, state.name, table)

    {:ok, state}
  end

  @impl GenServer
  def handle_info({:notification, :gossip, %{"metrics" => metrics}}, %State{} = state) do
    for %{"name" => series, "type" => type, "value" => value} = labels <- metrics do
      type = String.to_existing_atom(type)
      labels = Map.drop(labels, ["name", "type", "value"])
      value = if match?(%{"data" => _}, value), do: Sketch.from_map(value), else: value

      store(state.table, series, type, value, labels)
    end

    {:noreply, state}
  end

  def handle_info({:notification, :gossip, _payload}, state) do
    {:noreply, state}
  end

  def handle_info(:checkpoint, %State{checkpoint: {mod, opts}, table: table} = state) do
    parent = self()

    Task.async(fn ->
      {metrics, opts} = mod.call(opts)

      for {series, value, labels} <- metrics, do: store(table, series, :gauge, value, labels)

      send(parent, {:schedule_checkpoint, opts})
    end)

    {:noreply, state}
  end

  def handle_info(:compact, %State{compact_periods: periods, table: table} = state) do
    Task.async(__MODULE__, :compact, [table, periods])

    {:noreply, schedule_compact(state)}
  end

  def handle_info({:schedule_checkpoint, opts}, %State{checkpoint: {mod, _}} = state) do
    state = %State{state | checkpoint: {mod, opts}}

    {:noreply, schedule_checkpoint(state)}
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

  defp schedule_checkpoint(%State{checkpoint: nil} = state), do: state

  defp schedule_checkpoint(%State{checkpoint: {mod, opts}} = state) do
    {interval, opts} = mod.interval(opts)

    timer = Process.send_after(self(), :checkpoint, interval)

    %State{state | checkpoint: {mod, opts}, checkpoint_timer: timer}
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

  # OLDER-DELETE THESE

  defp select(table, series, nil), do: select(table, series, 60)

  defp select(table, series, lookback) do
    since = System.system_time(:second) - lookback

    match = {series, :_, :"$1", :"$2", :"$3", :"$4"}
    guard = [{:>=, :"$1", since}]

    :ets.select(table, [{match, guard, [{{:"$1", :"$2", :"$3", :"$4"}}]}])
  end

  defp filter_metrics(metrics, nil), do: metrics

  defp filter_metrics(metrics, filters) do
    filters = Map.new(filters, fn {key, val} -> {to_string(key), List.wrap(val)} end)

    Enum.filter(metrics, fn {_max_ts, _type, _value, labels} ->
      Enum.all?(filters, fn {name, list} -> labels[name] in list end)
    end)
  end

  defp rewrite_deltas([{_, :sketch, _, _} | _] = metrics), do: metrics

  defp rewrite_deltas(metrics) do
    metrics
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce({0, []}, fn {ts, type, value, labels}, {sum, acc} ->
      case type do
        :gauge -> {value, [{ts, value, labels} | acc]}
        :delta -> {sum + value, [{ts, sum + value, labels} | acc]}
      end
    end)
    |> elem(1)
  end

  defp to_sketch(int) when is_integer(int), do: Sketch.new([int])
  defp to_sketch(sketch), do: sketch

  defp merge_metrics(metrics, ntile) do
    metrics
    |> Enum.reduce(fn {_, new, _}, {ts, acc, label} -> {ts, merge(new, acc), label} end)
    |> update_in([Access.elem(1)], &Sketch.quantile(&1, ntile))
  end
end
