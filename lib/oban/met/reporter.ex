defmodule Oban.Met.Reporter do
  @moduledoc false

  # Periodically count and report jobs by state and queue.
  #
  # Because exact counts are expensive, counts are throttled based on the size of a particular
  # state. States with fewer than 2,000 jobs are counted every second, but beyond that states are
  # counted after an exponentially calculated backoff period. This is a tradeoff that aims to
  # preserve system resources at the expense of accuracy.

  use GenServer

  import Ecto.Query, only: [group_by: 3, select: 3, where: 3]

  alias __MODULE__, as: State
  alias Oban.{Backoff, Job, Notifier, Peer, Repo}
  alias Oban.Met.Values.Gauge

  @empty {[], nil}

  @empty_states %{
    "available" => @empty,
    "cancelled" => @empty,
    "completed" => @empty,
    "discarded" => @empty,
    "executing" => @empty,
    "retryable" => @empty,
    "scheduled" => @empty
  }

  defstruct [:conf, :name, :timer, checks: @empty_states, interval: :timer.seconds(1)]

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
  def check_backoff(value, opts \\ []) do
    base = Keyword.get(opts, :factor, 3)
    clamp = Keyword.get(opts, :clamp, 2_000)
    limit = Keyword.get(opts, :limit, 900)

    exponent =
      (value - clamp)
      |> max(1)
      |> :math.log10()
      |> trunc()

    if exponent > 0 do
      (base ** exponent)
      |> trunc()
      |> min(limit)
    else
      0
    end
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
      checks = checks(state)

      metrics =
        for {_key, {counts, _last}} <- checks,
            count <- counts,
            do: Map.update!(count, :value, &Gauge.new/1)

      payload = %{
        metrics: metrics,
        name: inspect(conf.name),
        node: conf.node,
        time: System.system_time(:second)
      }

      Notifier.notify(conf, :metrics, payload)

      {:noreply, schedule_checkpoint(%{state | checks: checks})}
    else
      {:noreply, schedule_checkpoint(state)}
    end
  end

  defp schedule_checkpoint(state) do
    %State{state | timer: Process.send_after(self(), :checkpoint, state.interval)}
  end

  defp checks(state) do
    sysnow = System.system_time(:second)

    {checks, states} =
      for {state, {counts, last_at}} <- state.checks, reduce: {%{}, []} do
        {check_acc, state_acc} ->
          if checkable?(counts, last_at, sysnow) do
            {Map.put(check_acc, state, @empty), [state | state_acc]}
          else
            {Map.put(check_acc, state, {counts, last_at}), state_acc}
          end
      end

    query =
      Job
      |> select([j], %{series: :full_count, state: j.state, queue: j.queue, value: count(j.id)})
      |> where([j], j.state in ^states)
      |> group_by([j], [j.state, j.queue])

    Backoff.with_retry(fn ->
      state.conf
      |> Repo.all(query)
      |> Enum.group_by(& &1.state)
      |> Enum.reduce(checks, fn {state, counts}, acc ->
        Map.put(acc, state, {counts, sysnow})
      end)
    end)
  end

  defp checkable?(_counts, nil, _sysnow), do: true

  defp checkable?(counts, last_at, sysnow) do
    backoff =
      counts
      |> Enum.reduce(0, &(&2 + &1.value))
      |> max(1)
      |> check_backoff()

    sysnow - backoff >= last_at
  end
end
