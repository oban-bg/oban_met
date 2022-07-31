defmodule Oban.Met.Reporter do
  @moduledoc """
  Track local telemetry events and periodically relay them to external recorders.

  {{:count, :available}, 1, %{queue: "default"}}
  {{:count, :scheduled}, 1, %{queue: "default"}}
  """

  use GenServer

  alias __MODULE__, as: State
  alias Oban.Notifier

  defstruct [:conf, :name, :table, :timer, interval: :timer.seconds(1)]

  @trans_state %{
    cancelled: :cancelled,
    discard: :discarded,
    failure: :retryable,
    success: :completed,
    snoozed: :scheduled
  }

  @spec start_link(Keyword.t()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: opts[:name])
  end

  @spec all_metrics(GenSever.name()) :: [tuple()]
  def all_metrics(name) do
    GenServer.call(name, :all_metrics)
  end

  def handle_event([:oban, :job, :start], _measure, %{conf: conf} = meta, {conf, tab}) do
    labels = %{queue: meta.job.queue}

    for object <- [{{:count, :available}, -1, labels}, {{:count, :executing}, 1, labels}] do
      insert_or_update(tab, object)
    end
  end

  def handle_event([:oban, :job, _], _measure, %{conf: conf} = meta, {conf, tab}) do
    labels = %{queue: meta.job.queue}

    insert_or_update(tab, {{:count, :executing}, -1, labels})
    insert_or_update(tab, {{:count, @trans_state[meta.state]}, 1, labels})
  end

  def handle_event(_event, _measure, _meta, _conf), do: :ok

  defp insert_or_update(table, {key, value, _} = object) do
    case :ets.lookup(table, key) do
      [{^key, original, labels}] ->
        :ets.insert(table, {key, original + value, labels})

      [] ->
        :ets.insert(table, object)
    end
  end

  # Callbacks

  @impl GenServer
  def init(opts) do
    Process.flag(:trap_exit, true)

    table = :ets.new(:reporter, [:set, :public, write_concurrency: true])

    state =
      State
      |> struct!(Keyword.put(opts, :table, table))
      |> attach_events()
      |> schedule_report()

    {:ok, state}
  end

  @impl GenServer
  def terminate(_reason, %State{timer: timer}) do
    if is_reference(timer), do: Process.cancel_timer(timer)

    :ok
  end

  @impl GenServer
  def handle_info(:report, %State{conf: conf, table: table} = state) do
    metrics =
      table
      |> :ets.tab2list()
      |> Enum.map(fn {key, value, labels} -> [Tuple.to_list(key), value, labels] end)

    :ets.delete_all_objects(table)

    payload = %{name: inspect(conf.name), node: conf.node, metrics: metrics}

    Notifier.notify(conf, :gossip, payload)

    {:noreply, schedule_report(state)}
  end

  @impl GenServer
  def handle_call(:all_metrics, _from, %State{table: table} = state) do
    {:reply, :ets.tab2list(table), state}
  end

  defp attach_events(%State{conf: conf, table: table} = state) do
    :telemetry.attach_many(
      handler_id(state),
      [[:oban, :job, :start], [:oban, :job, :stop], [:oban, :job, :exception]],
      &__MODULE__.handle_event/4,
      {conf, table}
    )

    state
  end

  defp schedule_report(state) do
    timer = Process.send_after(self(), :report, state.interval)

    %{state | timer: timer}
  end

  defp handler_id(state) do
    "oban-met-recorder-#{inspect(state.name)}"
  end
end
