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

  @periods [{1, 120}, {5, 600}, {60, 7_200}]

  @default_latest_opts [filters: [], group: nil, lookback: 5]

  @default_timeslice_opts [
    by: 1,
    filters: [],
    group: nil,
    lookback: 60,
    ntile: 1.0
  ]

  defstruct [
    :compact_timer,
    :conf,
    :name,
    :table,
    compact_periods: @periods,
    handoff: :awaiting
  ]

  @spec child_spec(Keyword.t()) :: Supervisor.child_spec()
  def child_spec(opts) do
    name = Keyword.get(opts, :name, __MODULE__)

    %{super(opts) | id: name}
  end

  @spec start_link(Keyword.t()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: opts[:name])
  end

  @spec lookup(GenServer.name(), series()) :: [term()]
  def lookup(name, series) do
    match = {{to_string(series), :_, :_}, :_, :_}

    :ets.select_reverse(table(name), [{match, [], [:"$_"]}])
  end

  @spec labels(GenServer.name(), label()) :: [label()]
  def labels(name, label) when is_binary(label) do
    match = {{:_, :"$1", :_}, :_, :_}
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

    group = Keyword.fetch!(opts, :group)
    since = Keyword.fetch!(opts, :lookback)
    filters = Keyword.fetch!(opts, :filters)

    name
    |> table()
    |> select(series, since, filters)
    |> Enum.dedup_by(fn {{_, labels, _}, _, _} -> labels end)
    |> Enum.group_by(fn {{_, labels, _}, _, _} -> labels[group] || "all" end)
    |> Map.new(fn {group, metrics} ->
      merged = Enum.reduce(metrics, 0, fn {_key, _mts, val}, acc -> acc + val.data end)

      {group, merged}
    end)
  end

  @spec series(GenServer.name()) :: [map()]
  def series(name) do
    match = {{:"$1", :"$2", :_}, :_, :"$3"}

    name
    |> table()
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

  @spec timeslice(GenServer.name(), series(), Keyword.t()) :: [{ts(), value(), label()}]
  def timeslice(name, series, opts \\ []) do
    opts = Keyword.validate!(opts, @default_timeslice_opts)

    group = Keyword.fetch!(opts, :group)
    ntile = Keyword.fetch!(opts, :ntile)
    since = Keyword.fetch!(opts, :lookback)
    slice = Keyword.fetch!(opts, :by)
    stime = System.system_time(:second)

    name
    |> table()
    |> select(series, since, opts[:filters])
    |> Enum.reduce(%{}, fn {{_, labels, ts}, _, value}, acc ->
      label = labels[group]
      chunk = div(stime - ts - 1, slice)

      Map.update(acc, {label, chunk}, value, &Value.merge(&1, value))
    end)
    |> Enum.sort_by(fn {{label, chunk}, _} -> {label, -chunk} end)
    |> Enum.map(fn {{label, chunk}, value} ->
      {chunk, Value.quantile(value, ntile), label}
    end)
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
        :ordered_set,
        :protected,
        read_concurrency: true
      ])

    state =
      State
      |> struct!(Keyword.put(opts, :table, table))
      |> schedule_compact()

    Registry.register(Oban.Registry, state.name, table)

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
    Notifier.listen(conf.name, [:gossip, :handoff])

    {:noreply, state}
  end

  @impl GenServer
  def handle_call({:compact, periods}, _from, %State{table: table} = state) do
    inner_compact(table, periods)

    {:reply, :ok, state}
  end

  def handle_call({:store, params}, _from, %State{table: table} = state) do
    {series, value, labels, time} = params

    inner_store(table, series, value, labels, time)

    {:reply, :ok, state}
  end

  @impl GenServer
  def handle_info({:notification, :handoff, %{"syn" => _}}, state) do
    if Peer.leader?(state.conf) do
      data =
        state.table
        |> :ets.tab2list()
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
      |> then(&:ets.insert(state.table, &1))
    end

    {:noreply, %{state | handoff: :complete}}
  end

  def handle_info({:notification, :gossip, %{"metrics" => _} = payload}, state) do
    %{"metrics" => metrics, "node" => node, "time" => time} = payload

    for %{"series" => series, "value" => value} = metric <- metrics do
      labels =
        metric
        |> Map.drop(~w(series value))
        |> Map.put("node", node)

      inner_store(state.table, series, from_map(value), labels, time)
    end

    {:noreply, state}
  end

  def handle_info({:notification, _channel, _payload}, state) do
    {:noreply, state}
  end

  def handle_info(:compact, %State{compact_periods: periods, table: table} = state) do
    inner_compact(table, periods)

    {:noreply, schedule_compact(state)}
  end

  defp from_map(%{"size" => _} = value), do: Sketch.from_map(value)
  defp from_map(value), do: Gauge.from_map(value)

  # Table

  defp table(name) do
    [{_pid, table}] = Registry.lookup(Oban.Registry, name)

    table
  end

  defp inner_compact(table, periods) do
    delete_outdated(table, periods)

    Enum.reduce(periods, System.system_time(:second), fn {step, duration}, ts ->
      since = ts - duration
      match = {{:_, :_, :"$1"}, :"$2", :_}
      guard = [{:andalso, {:>=, :"$2", since}, {:"=<", :"$1", ts}}]

      objects = :ets.select(table, [{match, guard, [:"$_"]}])
      _delete = :ets.select_delete(table, [{match, guard, [true]}])

      objects
      |> Enum.chunk_by(fn {{ser, lab, max}, _, _} ->
        {ser, lab, div(ts - max - 1, step)}
      end)
      |> Enum.map(&compact_object/1)
      |> then(&:ets.insert(table, &1))

      since
    end)
  end

  defp compact_object([{{series, labels, _}, _, _} | _] = metrics) do
    {min_ts, max_ts} =
      metrics
      |> Enum.flat_map(fn {{_, _, max_ts}, min_ts, _} -> [max_ts, min_ts] end)
      |> Enum.min_max()

    value =
      metrics
      |> Enum.map(&elem(&1, 2))
      |> Enum.reduce(&Value.merge/2)

    {{series, labels, max_ts}, min_ts, value}
  end

  defp delete_outdated(table, periods) do
    systime = System.system_time(:second)
    maximum = Enum.reduce(periods, 0, fn {_, duration}, acc -> duration + acc end)

    since = systime - maximum
    match = {{:_, :_, :"$1"}, :_, :_}
    guard = [{:<, :"$1", since}]

    :ets.select_delete(table, [{match, guard, [true]}])
  end

  defp inner_store(table, series, value, labels, time) do
    key = {to_string(series), labels, time}
    match = {key, time, :"$1"}

    value =
      case :ets.select_reverse(table, [{match, [], [:"$1"]}], 1) do
        {[old_value], _cont} -> Value.merge(old_value, value)
        _ -> value
      end

    :ets.insert(table, {key, time, value})
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

  defp select(table, series, since, filters) do
    stime = System.system_time(:second)
    match = {{to_string(series), :"$1", :"$2"}, :_, :_}
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
