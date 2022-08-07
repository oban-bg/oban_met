defmodule Oban.Met.Reporter do
  @moduledoc """
  Track local telemetry events and periodically relay them to external recorders.
  """

  use GenServer

  alias __MODULE__, as: State
  alias Oban.Met.Sketch
  alias Oban.Notifier

  defstruct [:conf, :name, :table, :timer, interval: :timer.seconds(1)]

  @trans_state %{
    cancelled: :cancelled,
    discard: :discarded,
    failure: :retryable,
    success: :completed,
    snoozed: :scheduled
  }

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

  @doc false
  @spec all_metrics(GenSever.name()) :: [tuple()]
  def all_metrics(name) do
    GenServer.call(name, :all_metrics)
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
  def terminate(_reason, %State{timer: timer} = state) do
    if is_reference(timer), do: Process.cancel_timer(timer)

    :telemetry.detach(handler_id(state))

    :ok
  end

  @impl GenServer
  def handle_info(:report, %State{conf: conf, table: table} = state) do
    metrics =
      table
      |> :ets.tab2list()
      |> Enum.map(fn {labels, value} -> Map.put(labels, :value, value) end)

    :ets.delete_all_objects(table)

    payload = %{name: inspect(conf.name), node: conf.node, metrics: metrics}

    Notifier.notify(conf, :gossip, payload)

    {:noreply, schedule_report(state)}
  end

  @impl GenServer
  def handle_call(:all_metrics, _from, %State{table: table} = state) do
    {:reply, :ets.tab2list(table), state}
  end

  # Telemetry Events

  defp attach_events(%State{conf: conf, table: table} = state) do
    :telemetry.attach_many(
      handler_id(state),
      [[:oban, :job, :start], [:oban, :job, :stop], [:oban, :job, :exception]],
      &__MODULE__.handle_event/4,
      {conf, table}
    )

    state
  end

  defp handler_id(state) do
    "oban-met-recorder-#{inspect(state.name)}"
  end

  @doc false
  def handle_event([:oban, :job, :start], _measure, %{conf: conf} = meta, {conf, tab}) do
    insert_or_update(tab, [
      {%{name: :available, queue: meta.job.queue, type: :count}, -1},
      {%{name: :executing, queue: meta.job.queue, type: :count}, 1}
    ])
  end

  def handle_event([:oban, :job, _], measure, %{conf: conf} = meta, {conf, tab}) do
    %{job: %{queue: queue, worker: worker}} = meta

    insert_or_update(tab, [
      {%{name: :executing, queue: queue, type: :count}, -1},
      {%{name: @trans_state[meta.state], queue: queue, type: :count}, 1},
      {%{name: :exec_time, queue: queue, type: :sketch, worker: worker}, measure.duration},
      {%{name: :wait_time, queue: queue, type: :sketch, worker: worker}, measure.queue_time}
    ])
  end

  def handle_event(_event, _measure, _meta, _conf), do: :ok

  defp insert_or_update(table, objects) when is_list(objects) do
    for object <- objects, do: insert_or_update(table, object)
  end

  defp insert_or_update(table, {key, val}) do
    case :ets.lookup(table, key) do
      [{%{type: :count}, old}] ->
        :ets.insert(table, {key, old + val})

      [{%{type: :sketch}, old}] ->
        :ets.insert(table, {key, Sketch.insert(old, val)})

      [] ->
        case key do
          %{type: :count} ->
            :ets.insert(table, {key, val})

          %{type: :sketch} ->
            :ets.insert(table, {key, Sketch.insert(Sketch.new(), val)})
        end
    end
  end

  # Scheduling

  defp schedule_report(state) do
    timer = Process.send_after(self(), :report, state.interval)

    %{state | timer: timer}
  end
end
