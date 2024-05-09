defmodule Oban.Met.Cronitor do
  @moduledoc false

  use GenServer

  alias __MODULE__, as: State
  alias Oban.Notifier

  defstruct [
    :conf,
    :name,
    :timer,
    crontabs: %{},
    interval: :timer.seconds(15),
    ttl: :timer.seconds(60)
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

  def merged_crontab(name) do
    GenServer.call(name, :merged_crontab)
  end

  # Callbacks

  @impl GenServer
  def init(opts) do
    Process.flag(:trap_exit, true)

    state = struct!(State, opts)

    Notifier.listen(state.conf.name, [:cronitor])

    {:ok, state, {:continue, :start}}
  end

  @impl GenServer
  def handle_continue(:start, %State{} = state) do
    handle_info(:share, state)
  end

  @impl GenServer
  def terminate(_reason, state) do
    if is_reference(state.timer), do: Process.cancel_timer(state.timer)

    :ok
  end

  @impl GenServer
  def handle_call(:share, _from, %State{} = state) do
    {:noreply, state} = handle_info(:share, state)

    {:reply, :ok, state}
  end

  def handle_call(:merged_crontab, _from, %State{} = state) do
    merged_crontab =
      for {_key, {_ts, crontab}} <- state.crontabs, entry <- crontab, uniq: true, do: entry

    {:reply, merged_crontab, state}
  end

  @impl GenServer
  def handle_info(:share, %State{} = state) do
    %{name: name, node: node, plugins: plugins} = state.conf

    crontab =
      plugins
      |> Keyword.get(Oban.Plugins.Cron, [])
      |> Keyword.get(:crontab, [])
      |> Enum.map(fn
        {expr, work} -> {expr, inspect(work), []}
        {expr, work, opts} -> {expr, inspect(work), opts}
      end)

    payload = %{crontab: crontab, name: inspect(name), node: node}

    Notifier.notify(state.conf, :cronitor, payload)

    state =
      state
      |> purge_stale()
      |> schedule_share()

    {:noreply, state}
  end

  def handle_info({:notification, :cronitor, payload}, %State{} = state) do
    %{"crontab" => crontab, "name" => name, "node" => node} = payload

    ts = System.system_time(:millisecond)

    crontab =
      Enum.map(crontab, fn [expr, work, opts] ->
        {expr, work, Map.new(opts, &List.to_tuple/1)}
      end)

    crontabs = Map.put(state.crontabs, {node, name}, {ts, crontab})

    {:noreply, %State{state | crontabs: crontabs}}
  end

  # Helpers

  defp purge_stale(state) do
    expires = System.system_time(:millisecond) - state.ttl
    crontabs = Map.reject(state.crontabs, fn {_key, {ts, _tab}} -> ts < expires end)

    %State{state | crontabs: crontabs}
  end

  defp schedule_share(state) do
    %State{state | timer: Process.send_after(self(), :share, state.interval)}
  end
end
