defmodule Oban.Met.Reporter do
  @moduledoc """
  Track local telemetry events and periodically relay them to external recorders.
  """

  use GenServer

  import Ecto.Query, only: [group_by: 3, select: 3]

  alias __MODULE__, as: State
  alias Oban.Met.{Gauge, Sketch}
  alias Oban.{Job, Notifier, Repo}

  defstruct [
    :checkpoint_timer,
    :conf,
    :name,
    :report_timer,
    :table,
    checkpoint_interval: :timer.minutes(1),
    report_interval: :timer.seconds(1)
  ]

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

    {:ok, state, {:continue, :checkpoint}}
  end

  @impl GenServer
  def handle_continue(:checkpoint, %State{} = state) do
    {:noreply, state} = handle_info(:checkpoint, state)

    {:noreply, schedule_report(state)}
  end

  @impl GenServer
  def terminate(_reason, %State{checkpoint_timer: ct, report_timer: rt} = state) do
    if is_reference(rt), do: Process.cancel_timer(rt)
    if is_reference(ct), do: Process.cancel_timer(ct)

    :telemetry.detach(handler_id(state))

    :ok
  end

  @impl GenServer
  def handle_info(:checkpoint, %State{conf: conf, table: table} = state) do
    # TODO: Guard against connection errors, this needs a backoff
    query =
      Job
      |> group_by([j], [j.queue, j.state])
      |> select([j], {j.queue, j.state, count(j.id)})

    for {queue, state, count} <- Repo.all(conf, query, timeout: :infinity) do
      :ets.insert(table, {%{series: state, type: :gauge, queue: queue}, Gauge.new(count)})
    end

    {:noreply, schedule_checkpoint(state)}
  end

  @impl GenServer
  def handle_info(:report, %State{conf: conf, table: table} = state) do
    sorting = fn
      {%{type: :gauge}, _} -> 0
      {_, _} -> 1
    end

    metrics =
      table
      |> :ets.tab2list()
      |> Enum.sort_by(sorting)
      |> Enum.map(fn {labels, value} ->
        labels
        |> Map.put(:node, conf.node)
        |> Map.put(:value, value)
      end)

    :ets.delete_all_objects(table)

    Notifier.notify(conf, :gossip, %{name: inspect(conf.name), metrics: metrics})

    {:noreply, schedule_report(state)}
  end

  @impl GenServer
  def handle_call(:all_metrics, _from, %State{table: table} = state) do
    {:reply, :ets.tab2list(table), state}
  end

  # Telemetry Events

  @events [
    [:oban, :job, :start],
    [:oban, :job, :stop],
    [:oban, :job, :exception],
    [:oban, :engine, :insert_job, :stop],
    [:oban, :engine, :insert_all_jobs, :stop],
  ]

  defp attach_events(%State{conf: conf, table: table} = state) do
    :telemetry.attach_many(
      handler_id(state),
      @events,
      &__MODULE__.handle_event/4,
      {conf, table}
    )

    state
  end

  defp handler_id(state) do
    "oban-met-recorder-#{inspect(state.name)}"
  end

  @doc false
  def handle_event([:oban | event], measure, %{conf: conf} = meta, {conf, tab}) do
    track_event(event, measure, meta, tab)
  end

  def handle_event(_event, _measure, _meta, _conf), do: :ok

  @doc false
  def track_event([:job, :start], _measure, meta, tab) do
    insert_or_update(tab, [
      {%{series: :available, queue: meta.job.queue, type: :delta}, -1},
      {%{series: :executing, queue: meta.job.queue, type: :delta}, 1}
    ])
  end

  def track_event([:job, _], measure, meta, tab) do
    %{job: %{queue: queue, worker: worker}} = meta
    %{duration: exec_time, queue_time: wait_time} = measure

    insert_or_update(tab, [
      {%{series: :executing, queue: queue, type: :delta}, -1},
      {%{series: @trans_state[meta.state], queue: queue, type: :delta}, 1},
      {%{series: :exec_time, queue: queue, type: :sketch, worker: worker}, exec_time},
      {%{series: :wait_time, queue: queue, type: :sketch, worker: worker}, wait_time}
    ])
  end

  def track_event([:engine, :insert_job, _], _, %{job: job}, tab) do
    series = if job.state == "scheduled", do: :scheduled, else: :available

    insert_or_update(tab, [
      {%{series: series, queue: job.queue, type: :delta}, 1}
    ])
  end

  def track_event([:engine, :insert_all_jobs, _], _, %{changesets: changesets}, tab) do
    IO.inspect(changesets, label: "CHANGESETS")

    :ok
  end

  def track_event(_event, _measure, _meta, _tab), do: :ok

  defp insert_or_update(table, objects) when is_list(objects) do
    for object <- objects, do: insert_or_update(table, object)
  end

  defp insert_or_update(table, {key, val}) do
    case :ets.lookup(table, key) do
      [{%{type: :delta}, old}] ->
        :ets.insert(table, {key, old + val})

      [{%{type: :sketch}, old}] ->
        :ets.insert(table, {key, Sketch.add(old, val)})

      [] ->
        case key do
          %{type: :delta} ->
            :ets.insert(table, {key, val})

          %{type: :sketch} ->
            :ets.insert(table, {key, Sketch.new([val])})
        end
    end
  end

  # Scheduling

  defp schedule_checkpoint(state) do
    timer = Process.send_after(self(), :report, state.checkpoint_interval)

    %{state | checkpoint_timer: timer}
  end

  defp schedule_report(state) do
    timer = Process.send_after(self(), :report, state.report_interval)

    %{state | report_timer: timer}
  end
end
