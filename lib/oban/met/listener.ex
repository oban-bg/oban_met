defmodule Oban.Met.Listener do
  @moduledoc false

  # Track local telemetry events and periodically relay them to external recorders.

  use GenServer

  alias __MODULE__, as: State
  alias Oban.Met.Values.Sketch
  alias Oban.Notifier

  defstruct [
    :conf,
    :name,
    :report_timer,
    :table,
    report_interval: :timer.seconds(1)
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
  @spec report(GenServer.name()) :: [tuple()]
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
  def terminate(_reason, %State{report_timer: rt} = state) do
    if is_reference(rt), do: Process.cancel_timer(rt)

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

    Notifier.notify(conf, :gossip, payload)

    {:noreply, schedule_report(state)}
  end

  defp objects_to_metrics(objects) do
    objects
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 2))
    |> Enum.map(fn {{series, queue, worker}, values} ->
      %{series: series, queue: queue, worker: worker, value: Sketch.new(values)}
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
    %{job: %{queue: queue, worker: worker}} = meta
    %{duration: exec_time, queue_time: wait_time} = measure

    time = System.monotonic_time()

    :ets.insert(tab, [
      {{:exec_time, queue, worker}, time, exec_time},
      {{:wait_time, queue, worker}, time, wait_time}
    ])
  end

  def handle_event(_event, _measure, _meta, _conf), do: :ok

  # Scheduling

  defp schedule_report(state) do
    timer = Process.send_after(self(), :report, state.report_interval)

    %{state | report_timer: timer}
  end
end
