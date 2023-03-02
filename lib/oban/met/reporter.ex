defmodule Oban.Met.Reporter do
  @moduledoc false

  # Periodically count and report jobs by state, queue, and worker

  use GenServer

  import Ecto.Query, only: [group_by: 3, select: 3]

  alias __MODULE__, as: State
  alias Oban.{Backoff, Job, Notifier, Peer, Repo}
  alias Oban.Met.Values.Gauge

  @empty %{
    available: 0,
    cancelled: 0,
    completed: 0,
    discarded: 0,
    executing: 0,
    retryable: 0,
    scheduled: 0
  }

  defstruct [:conf, :name, :timer, checks: @empty, interval: :timer.seconds(1)]

  @spec child_spec(Keyword.t()) :: Supervisor.child_spec()
  def child_spec(opts) do
    name = Keyword.get(opts, :name, __MODULE__)

    %{super(opts) | id: name}
  end

  @spec start_link(Keyword.t()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: opts[:name])
  end

  # Callbacks

  @impl GenServer
  def init(opts) do
    Process.flag(:trap_exit, true)

    state = struct!(State, opts)

    # Used to ensure testing helpers to auto-allow this module for sandbox access.
    :telemetry.execute([:oban, :plugin, :init], %{}, %{conf: state.conf, plugin: __MODULE__})

    {:ok, schedule_checkpoint(state)}
  end

  @impl GenServer
  def terminate(_reason, %State{timer: timer}) do
    if is_reference(timer), do: Process.cancel_timer(timer)

    :ok
  end

  @impl GenServer
  def handle_info(:checkpoint, %State{conf: conf} = state) do
    if Peer.leader?(conf.name) do
      metrics =
        conf
        |> counts()
        |> Enum.map(fn map -> Map.update!(map, :value, &Gauge.new/1) end)

      payload = %{
        metrics: metrics,
        name: inspect(conf.name),
        node: conf.node,
        time: System.system_time(:second)
      }

      Notifier.notify(conf, :gossip, payload)
    end

    {:noreply, schedule_checkpoint(state)}
  end

  defp schedule_checkpoint(state) do
    %State{state | timer: Process.send_after(self(), :checkpoint, state.interval)}
  end

  defp counts(conf) do
    query =
      Job
      |> group_by([j], [j.state, j.queue, j.worker])
      |> select([j], %{series: j.state, queue: j.queue, worker: j.worker, value: count(j.id)})

    Backoff.with_retry(fn -> Repo.all(conf, query) end)
  end
end
