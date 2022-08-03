defmodule Oban.Met.Recorder do
  @moduledoc """
  {series, min_ts, max_ts, value, labels}

  {:available, 1659097422, 1659097422, 1, %{type: "count", queue: "default"}}
  """

  use GenServer

  alias __MODULE__, as: State
  alias Oban.Notifier

  defstruct [:conf, :name, :table, :timer]

  @spec start_link(Keyword.t()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: opts[:name])
  end

  @spec fetch(GenServer.name(), atom() | binary(), Keyword.t()) :: [term()]
  def fetch(name, series, _opts \\ []) do
    {:ok, table} = Registry.meta(Oban.Registry, name)

    :ets.lookup(table, to_string(series))
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

    ts = System.system_time(:second)

    for %{"name" => name, "value" => value} = labels <- metrics do
      labels =
        labels
        |> Map.drop(["name", "value"])
        |> Map.put("node", node)
        |> Map.update!("type", &(if &1 == "count", do: "delta", else: &1))

      :ets.insert(state.table, {name, ts, ts, value, labels})
    end

    {:noreply, state}
  end

  @impl GenServer
  def handle_info(:compact, %State{} = state) do
    # TODO: Kick off a task for this

    {:noreply, schedule_compact(state)}
  end

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
end
