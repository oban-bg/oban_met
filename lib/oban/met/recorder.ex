defmodule Oban.Met.Recorder do
  @moduledoc """
  {series, min_ts, max_ts, value, labels}

  {:available, 1659097422, 1659097422, 1, %{type: "count", queue: "default"}}
  """

  use GenServer

  alias __MODULE__, as: State
  alias Oban.Notifier
  alias Oban.Met.Sketch

  @type name_or_table :: GenServer.name() | :ets.t()
  @type series :: atom() | String.t()
  @type value :: integer() | Sketch.t()
  @type labels :: %{optional(String.t()) => term()}

  defstruct [:conf, :name, :table, :timer]

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

    :ets.lookup(table, to_string(series))
  end

  @spec latest(name_or_table(), series(), Keyword.t()) :: %{optional(String.t()) => value()}
  def latest(name, series, opts \\ []) do
    {:ok, table} = Registry.meta(Oban.Registry, name)

    table
    |> select(series, opts)
    |> group_metrics(opts[:group])
    |> Map.new(fn {group, metrics} ->
      value =
        metrics
        |> filter_metrics(opts[:filters])
        |> sort_metrics()
        |> reduce_metrics()

      {group, value}
    end)
  end

  # -> timeslice/3
  #
  # 2. Values over time
  #   a. with an optional quantile for sketch data types
  #   b. grouped by a label
  #   c. filtered by a label
  #   d. over configured periods (1s, 5s, 1m, etc)
  #   e. using a configured lookback (30m, 1h, 5h)

  @spec store(name_or_table(), series(), value(), labels(), Keyword.t()) :: :ok | :error
  def store(name_or_table, series, value, labels, opts \\ [])

  def store(table, series, value, labels, opts) when is_reference(table) do
    ts = Keyword.get(opts, :timestamp, System.system_time(:second))

    :ets.insert(table, {to_string(series), ts, ts, value, labels})

    :ok
  end

  def store(name, series, value, labels, opts) do
    with {:ok, table} <- Registry.meta(Oban.Registry, name) do
      store(table, series, value, labels, opts)
    end
  end

  # Callbacks

  @impl GenServer
  def init(opts) do
    table = :ets.new(:metrics, [:bag, :public, :compressed, write_concurrency: true])

    state =
      State
      |> struct!(Keyword.put(opts, :table, table))
      |> subscribe_gossip()
      |> schedule_compact()

    Registry.put_meta(Oban.Registry, state.name, table)

    # TODO: Start tracking keyframes eventually. This requires a database, or mocking.

    {:ok, state}
  end

  @impl GenServer
  def handle_info({:notification, :gossip, %{"metrics" => _} = payload}, %State{} = state) do
    %{"node" => node, "metrics" => metrics} = payload

    for %{"name" => name, "type" => type, "value" => value} = labels <- metrics do
      labels =
        labels
        |> Map.delete("value")
        |> Map.put("node", node)
        |> Map.update!("type", &if(&1 == "count", do: "delta", else: &1))

      store(state.table, name, cast_value(value, type), labels)
    end

    {:noreply, state}
  end

  def handle_info({:notification, :gossip, _payload}, state) do
    {:noreply, state}
  end

  @impl GenServer
  def handle_info(:compact, %State{} = state) do
    # TODO: Kick off a task for this

    {:noreply, schedule_compact(state)}
  end

  defp cast_value(%{"data" => _} = value, "sketch"), do: Sketch.from_map(value)
  defp cast_value(value, _type), do: value

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
      |> :timer.seconds()

    timer = Process.send_after(self(), :compact, interval)

    %State{state | timer: timer}
  end

  # Fetching & Filtering

  defp select(table, series, opts) do
    series = to_string(series)
    since = System.system_time(:second) - Keyword.get(opts, :lookback, 60)

    match = {series, :_, :"$1", :"$2", :"$3"}
    guard = [{:>=, :"$1", since}]

    :ets.select(table, [{match, guard, [{{:"$1", :"$2", :"$3"}}]}])
  end

  defp group_metrics(metrics, nil), do: %{"all" => metrics}

  defp group_metrics(metrics, group) do
    Enum.group_by(metrics, &get_in(&1, [Access.elem(2), to_string(group)]))
  end

  defp sort_metrics(metrics) do
    Enum.sort_by(metrics, fn {max_ts, _value, _labels} -> -max_ts end)
  end

  defp filter_metrics(metrics, nil), do: metrics

  defp filter_metrics(metrics, filters) do
    filters = Map.new(filters, fn {key, val} -> {to_string(key), List.wrap(val)} end)

    Enum.filter(metrics, fn {_max_ts, _value, labels} ->
      Enum.all?(filters, fn {name, list} -> labels[name] in list end)
    end)
  end

  defp reduce_metrics([]), do: nil

  defp reduce_metrics([{_max_ts, value, _labels} | tail]) do
    Enum.reduce_while(tail, value, fn {_max, value, labels}, acc ->
      case labels["type"] do
        "count" -> {:halt, acc + value}
        "delta" -> {:cont, acc + value}
        "sketch" -> {:cont, Sketch.merge(value, acc)}
      end
    end)
  end
end
