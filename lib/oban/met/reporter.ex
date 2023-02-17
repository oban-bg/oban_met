defmodule Oban.Met.Reporter do
  @moduledoc false

  # Track local telemetry events and periodically relay them to external recorders.

  use GenServer

  import Ecto.Query, only: [group_by: 3, select: 3]

  alias __MODULE__, as: State
  alias Oban.Met.Values.{Count, Gauge, Sketch}
  alias Oban.{Job, Notifier, Repo}

  defstruct [
    :checkpoint_timer,
    :conf,
    :name,
    :report_timer,
    :table,
    checkpoint_interval: :timer.minutes(1),
    report_interval: :timer.seconds(1),
    retry_attempts: 5,
    retry_backoff: :timer.seconds(1)
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
  @spec all_metrics(GenServer.name()) :: [tuple()]
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

    # Used to ensure testing helpers to auto-allow this module for sandbox access.
    :telemetry.execute([:oban, :plugin, :init], %{}, %{conf: state.conf, plugin: __MODULE__})

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
    with_retry(state, fn ->
      query =
        Job
        |> group_by([j], [j.queue, j.state])
        |> select([j], {j.queue, j.state, count(j.id)})

      for {queue, state, count} <- Repo.all(conf, query, timeout: :infinity) do
        :ets.insert(table, {%{series: state, queue: queue, type: :gauge}, count})
      end
    end)

    {:noreply, schedule_checkpoint(state)}
  end

  @impl GenServer
  def handle_info(:report, %State{conf: conf, table: table} = state) do
    metrics =
      table
      |> take_safe()
      |> Enum.sort_by(&if &1.type == :gauge, do: 0, else: 1)

    payload = %{
      metrics: metrics,
      name: inspect(conf.name),
      node: conf.node,
      time: System.system_time(:second)
    }

    Notifier.notify(conf, :gossip, payload)

    {:noreply, schedule_report(state)}
  end

  defp take_safe(table) do
    table
    |> tap(&:ets.safe_fixtable(&1, true))
    |> take_safe(:ets.first(table), [])
  after
    :ets.safe_fixtable(table, false)
  end

  defp take_safe(_table, :"$end_of_table", acc), do: acc

  defp take_safe(table, key, acc) do
    [{labels, value}] = :ets.take(table, key)

    value =
      case key do
        %{type: :count} -> Count.new(value)
        %{type: :delta} -> value
        %{type: :gauge} -> Gauge.new(value)
        %{type: :sketch} -> Sketch.new(value)
      end

    take_safe(table, :ets.next(table, key), [Map.put(labels, :value, value) | acc])
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
    [:oban, :plugin, :stop],
    [:oban, :engine, :insert_job, :stop],
    [:oban, :engine, :insert_all_jobs, :stop],
    [:oban, :engine, :cancel_all_jobs, :stop],
    [:oban, :engine, :retry_all_jobs, :stop]
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
    %{job: %{queue: queue, worker: worker}} = meta

    insert_or_update(tab, [
      {%{series: :available, queue: queue, type: :delta, worker: worker}, -1},
      {%{series: :executing, queue: queue, type: :delta, worker: worker}, 1},
      {%{series: :executing, queue: queue, type: :count, worker: worker}, 1}
    ])
  end

  def track_event([:job, _], measure, meta, tab) do
    %{job: %{queue: queue, worker: worker}} = meta
    %{duration: exec_time, queue_time: wait_time} = measure

    state = @trans_state[meta.state]

    insert_or_update(tab, [
      {%{series: :executing, queue: queue, type: :delta, worker: worker}, -1},
      {%{series: state, queue: queue, type: :delta, worker: worker}, 1},
      {%{series: state, queue: queue, type: :count, worker: worker}, 1},
      {%{series: :exec_time, queue: queue, type: :sketch, worker: worker}, exec_time},
      {%{series: :wait_time, queue: queue, type: :sketch, worker: worker}, wait_time}
    ])
  end

  def track_event([:engine, :insert_job, _], _, meta, tab) do
    %{job: %{queue: queue, state: state, worker: worker}} = meta

    series = String.to_existing_atom(state)

    insert_or_update(tab, [
      {%{series: series, queue: queue, type: :delta, worker: worker}, 1},
      {%{series: series, queue: queue, type: :count, worker: worker}, 1}
    ])
  end

  def track_event([:engine, :insert_all_jobs, _], _, %{jobs: jobs}, tab) do
    objects =
      jobs
      |> Enum.group_by(&{&1.state, &1.queue, &1.worker})
      |> Enum.flat_map(fn {{state, queue, worker}, jobs} ->
        series = String.to_existing_atom(state)
        value = length(jobs)

        [
          {%{series: series, queue: queue, type: :delta, worker: worker}, value},
          {%{series: series, queue: queue, type: :count, worker: worker}, value}
        ]
      end)

    insert_or_update(tab, objects)
  end

  def track_event([:engine, :cancel_all_jobs, _], _, %{jobs: jobs}, tab) do
    jobs
    |> jobs_to_objects(:cancelled)
    |> then(&insert_or_update(tab, &1))
  end

  def track_event([:engine, :retry_all_jobs, _], _, %{jobs: jobs}, tab) do
    jobs
    |> jobs_to_objects(:available)
    |> then(&insert_or_update(tab, &1))
  end

  def track_event([:plugin, _], _, %{pruned_jobs: jobs}, tab) do
    objects =
      jobs
      |> Enum.group_by(&{&1.state, &1.queue, &1.worker})
      |> Enum.map(fn {{state, queue, worker}, jobs} ->
        series = String.to_existing_atom(state)

        {%{series: series, queue: queue, type: :delta, worker: worker}, -length(jobs)}
      end)

    insert_or_update(tab, objects)
  end

  def track_event([:plugin, _], _, %{staged_jobs: jobs}, tab) do
    jobs
    |> jobs_to_objects(:available)
    |> then(&insert_or_update(tab, &1))
  end

  def track_event([:plugin, _], _, %{rescued_jobs: _} = meta, tab) do
    %{discarded_jobs: discarded_jobs, rescued_jobs: rescued_jobs} = meta

    discarded_jobs
    |> Enum.map(&%{&1 | state: "executing"})
    |> jobs_to_objects(:discarded)
    |> then(&insert_or_update(tab, &1))

    rescued_jobs
    |> Enum.map(&%{&1 | state: "executing"})
    |> jobs_to_objects(:available)
    |> then(&insert_or_update(tab, &1))
  end

  def track_event(_event, _measure, _meta, _tab), do: :ok

  defp jobs_to_objects(jobs, new_series) do
    jobs
    |> Enum.group_by(&{&1.state, &1.queue, &1.worker})
    |> Enum.flat_map(fn {{state, queue, worker}, jobs} ->
      old_series = String.to_existing_atom(state)
      size = length(jobs)

      [
        {%{series: new_series, queue: queue, type: :delta, worker: worker}, size},
        {%{series: new_series, queue: queue, type: :count, worker: worker}, size},
        {%{series: old_series, queue: queue, type: :delta, worker: worker}, -size}
      ]
    end)
  end

  defp insert_or_update(table, objects) when is_list(objects) do
    for object <- objects, do: insert_or_update(table, object)
  end

  defp insert_or_update(table, {%{type: :sketch} = key, val}) do
    case :ets.lookup(table, key) do
      [{^key, old}] ->
        :ets.insert(table, {key, [val | old]})

      [] ->
        :ets.insert(table, {key, [val]})
    end
  end

  defp insert_or_update(table, {%{type: :gauge} = key, val}) do
    :ets.insert(table, {key, val})
  end

  defp insert_or_update(table, {key, val}) do
    :ets.update_counter(table, key, {2, val}, {key, 0})
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

  # Stability

  defp jittery_sleep(base, jitter \\ 0.5) do
    diff = base * jitter

    trunc(base - diff)..trunc(base + diff)
    |> Enum.random()
    |> Process.sleep()
  end

  defp with_retry(state, fun, attempt \\ 0) do
    fun.()
  rescue
    error in [DBConnection.ConnectionError, Postgrex.Error] ->
      if attempt < state.retry_attempts do
        jittery_sleep(attempt * state.retry_backoff)

        with_retry(state, fun, attempt + 1)
      else
        reraise error, __STACKTRACE__
      end
  end
end
