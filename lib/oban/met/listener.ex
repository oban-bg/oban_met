defmodule Oban.Met.Listener do
  @moduledoc false

  # Track local telemetry events and periodically relay them to external recorders.

  use GenServer

  alias __MODULE__, as: State
  alias Oban.Met.Values.{Gauge, Sketch}
  alias Oban.Notifier

  defstruct [
    :conf,
    :name,
    :table,
    :timer,
    interval: :timer.seconds(1)
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

  @doc false
  @spec report(GenServer.name()) :: :ok
  def report(name) do
    GenServer.call(name, :report)
  end

  # Callbacks

  @impl GenServer
  def init(opts) do
    Process.flag(:trap_exit, true)

    table = :ets.new(:reporter, [:duplicate_bag, :public, write_concurrency: true])
    state = struct!(State, Keyword.put(opts, :table, table))

    :telemetry.attach_many(
      handler_id(state),
      [[:oban, :job, :stop], [:oban, :job, :exception]],
      &__MODULE__.handle_event/4,
      {state.conf, table}
    )

    {:ok, schedule_report(state)}
  end

  @impl GenServer
  def terminate(_reason, %State{timer: timer} = state) do
    if is_reference(timer), do: Process.cancel_timer(timer)

    :telemetry.detach(handler_id(state))

    :ok
  end

  @impl GenServer
  def handle_info(:report, %State{conf: conf, table: table} = state) do
    since = System.monotonic_time()
    match = {:_, :"$2", :_}
    guard = [{:<, :"$2", since}]

    objects = :ets.select(table, [{match, guard, [:"$_"]}])
    _delete = :ets.select_delete(table, [{match, guard, [true]}])

    payload = %{
      metrics: objects_to_metrics(objects),
      name: inspect(conf.name),
      node: conf.node,
      time: System.system_time(:second)
    }

    Notifier.notify(conf, :metrics, payload)

    {:noreply, schedule_report(state)}
  end

  defp objects_to_metrics(objects) do
    objects
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 2))
    |> Enum.map(fn {{series, state, queue, worker}, values} ->
      value = if series == :exec_count, do: Gauge.new(values), else: Sketch.new(values)

      %{series: series, state: state, queue: queue, worker: worker, value: value}
    end)
  end

  @impl GenServer
  def handle_call(:report, _from, %State{} = state) do
    handle_info(:report, state)

    {:reply, :ok, state}
  end

  # Telemetry Events

  defp handler_id(state) do
    "oban-met-recorder-#{inspect(state.name)}"
  end

  @doc false
  def handle_event([:oban, :job, _], measure, %{conf: conf} = meta, {conf, tab}) do
    %{job: %{queue: queue, worker: worker}, state: state} = meta
    %{duration: exec_time, queue_time: wait_time} = measure

    time = System.monotonic_time()
    trst = trans_state(state)

    # Sketches don't support negative times (caused when the VM wakes from sleep), or zero values
    # (infrequently caused by the same situation).
    exec_time = exec_time |> abs() |> max(1)
    wait_time = wait_time |> abs() |> max(1)

    :ets.insert(tab, [
      {{:exec_time, trst, queue, worker}, time, exec_time},
      {{:wait_time, trst, queue, worker}, time, wait_time},
      {{:exec_count, trst, queue, worker}, time, 1}
    ])
  end

  def handle_event(_event, _measure, _meta, _conf), do: :ok

  # Scheduling

  defp schedule_report(state) do
    timer = Process.send_after(self(), :report, state.interval)

    %{state | timer: timer}
  end

  # For backward compatibility reasons, the telemetry event's state doesn't match the final job
  # state. Here we translate the event state to the `t:Oban.Job.state`.
  defp trans_state(:cancelled), do: :cancelled
  defp trans_state(:discard), do: :discarded
  defp trans_state(:exhausted), do: :discarded
  defp trans_state(:failure), do: :retryable
  defp trans_state(:snoozed), do: :scheduled
  defp trans_state(:success), do: :completed
  defp trans_state(state), do: state
end
