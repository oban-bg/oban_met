defmodule Oban.Met.Examiner do
  @moduledoc false

  # Examiner uses notifications to periodically exchange queue state information between all
  # interested nodes.

  # This module is more of a "producer queue checker", but that name stinks.

  use GenServer

  alias __MODULE__, as: State
  alias Oban.Notifier

  @type name_or_table :: :ets.tab() | GenServer.name()

  defstruct [:conf, :name, :table, :timer, interval: :timer.seconds(1), ttl: :timer.seconds(30)]

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
    case fetch_table(name_or_table) do
      {:ok, table} -> :ets.select(table, [{{:_, :_, :"$1"}, [], [:"$1"]}])
      {:error, _} -> []
    end
  end

  @spec store(name_or_table(), map(), timestamp: integer()) :: :ok | {:error, term()}
  def store(name_or_table, check, opts \\ []) when is_map(check) do
    with {:ok, table} <- fetch_table(name_or_table) do
      %{"node" => node, "name" => name, "queue" => queue} = check

      timestamp = Keyword.get(opts, :timestamp, System.system_time(:millisecond))

      :ets.insert(table, {{node, name, queue}, timestamp, check})

      :ok
    end
  end

  @spec purge(name_or_table(), pos_integer()) ::
          {:ok, non_neg_integer()} | {:error, :bad_table_reference}
  def purge(name_or_table, ttl) when is_integer(ttl) and ttl > 0 do
    with {:ok, table} <- fetch_table(name_or_table) do
      expires = System.system_time(:millisecond) - ttl
      pattern = [{{:_, :"$1", :_}, [{:<, :"$1", expires}], [true]}]

      {:ok, :ets.select_delete(table, pattern)}
    end
  end

  @spec fetch_table(name_or_table()) :: {:ok, :ets.table()} | {:error, term()}
  def fetch_table(table) when is_reference(table), do: {:ok, table}

  def fetch_table(name) do
    case Registry.meta(Oban.Registry, name) do
      {:ok, table} when is_atom(table) or is_reference(table) ->
        if :ets.info(table) != :undefined do
          {:ok, table}
        else
          {:error, :bad_table_reference}
        end

      result ->
        {:error, result}
    end
  rescue
    ArgumentError -> {:error, :bad_table_reference}
  end

  # Callbacks

  @impl GenServer
  def init(opts) do
    Process.flag(:trap_exit, true)

    table = :ets.new(:checks, [:public, read_concurrency: true])

    state =
      State
      |> struct!(Keyword.put(opts, :table, table))
      |> schedule_check()

    :ok = Notifier.listen(state.conf.name, [:gossip])
    :ok = Registry.put_meta(Oban.Registry, state.name, table)

    {:ok, state}
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
