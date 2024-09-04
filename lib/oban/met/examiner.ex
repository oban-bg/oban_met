defmodule Oban.Met.Examiner do
  @moduledoc false

  # Examiner uses notifications to periodically exchange queue state information between all
  # interested nodes.

  # This module is more of a "producer queue checker", but that name stinks.

  use GenServer

  alias __MODULE__, as: State
  alias Oban.Notifier

  require Logger

  @type name_or_table :: :ets.tab() | GenServer.name()

  defstruct [
    :conf,
    :name,
    :table,
    :timer,
    interval: 750,
    ttl: :timer.seconds(30)
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

  @spec all_checks(name_or_table()) :: [map()]
  def all_checks(name_or_table) do
    name_or_table
    |> table()
    |> :ets.select([{{:_, :_, :"$1"}, [], [:"$1"]}])
  end

  @spec store(name_or_table(), map(), timestamp: integer()) :: :ok
  def store(name_or_table, check, opts \\ []) when is_map(check) do
    %{"node" => node, "name" => name, "queue" => queue} = check

    timestamp = Keyword.get(opts, :timestamp, System.system_time(:millisecond))

    name_or_table
    |> table()
    |> :ets.insert({{node, name, queue}, timestamp, check})

    :ok
  end

  @spec purge(name_or_table(), pos_integer()) :: {:ok, non_neg_integer()}
  def purge(name_or_table, ttl) when is_integer(ttl) and ttl > 0 do
    expires = System.system_time(:millisecond) - ttl
    pattern = [{{:_, :"$1", :_}, [{:<, :"$1", expires}], [true]}]

    deleted =
      name_or_table
      |> table()
      |> :ets.select_delete(pattern)

    {:ok, deleted}
  end

  # Callbacks

  @impl GenServer
  def init(opts) do
    Process.flag(:trap_exit, true)

    table = :ets.new(:checks, [:public, read_concurrency: true])
    state = struct!(State, Keyword.put(opts, :table, table))

    Notifier.listen(state.conf.name, [:gossip])

    Registry.register(Oban.Registry, state.name, table)

    {:ok, state, {:continue, :start}}
  end

  @impl GenServer
  def handle_continue(:start, %State{} = state) do
    handle_info(:check, state)
  end

  @impl GenServer
  def terminate(_reason, state) do
    if is_reference(state.timer), do: Process.cancel_timer(state.timer)

    :ok
  end

  @impl GenServer
  def handle_info(:check, %State{} = state) do
    match = [{{{state.conf.name, {:producer, :_}}, :"$1", :_}, [], [:"$1"]}]

    checks =
      Oban.Registry
      |> Registry.select(match)
      |> Enum.map(&safe_check(&1, state))
      |> Enum.filter(&is_map/1)
      |> Enum.map(&sanitize_name/1)

    if Enum.any?(checks), do: Notifier.notify(state.conf, :gossip, %{checks: checks})

    purge(state.table, state.ttl)

    {:noreply, schedule_check(state)}
  end

  def handle_info({:notification, :gossip, %{"checks" => checks}}, %State{} = state) do
    Enum.each(checks, &store(state.table, &1))

    {:noreply, state}
  end

  def handle_info({:notification, :gossip, _payload}, state) do
    {:noreply, state}
  end

  def handle_info(message, state) do
    Logger.warning(
      message: "Received unexpected message: #{inspect(message)}",
      source: :oban_met,
      module: __MODULE__
    )

    {:noreply, state}
  end

  # Table

  defp table(tab) when is_reference(tab), do: tab

  defp table(name) do
    [{_pid, table}] = Registry.lookup(Oban.Registry, name)

    table
  end

  # Scheduling

  defp schedule_check(state) do
    %State{state | timer: Process.send_after(self(), :check, state.interval)}
  end

  # Checking

  defp safe_check(pid, state) do
    if Process.alive?(pid), do: GenServer.call(pid, :check, state.interval)
  catch
    :exit, _ -> :error
  end

  defp sanitize_name(%{name: name} = check) when is_binary(name), do: check
  defp sanitize_name(%{name: name} = check), do: %{check | name: inspect(name)}
end
