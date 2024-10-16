defmodule Oban.Met.Reporter do
  @moduledoc false

  # Periodically count and report jobs by state and queue.
  #
  # Because exact counts are expensive, counts for states with jobs beyond a configurable
  # threshold are estimated. This is a tradeoff that aims to preserve system resources at the
  # expense of accuracy.

  use GenServer

  import Ecto.Query, only: [from: 2, group_by: 3, select: 3, where: 3]

  alias __MODULE__, as: State
  alias Oban.{Job, Notifier, Peer, Repo}
  alias Oban.Met.Values.Gauge
  alias Oban.Pro.Engines.Smart

  @empty_states %{
    "available" => [],
    "cancelled" => [],
    "completed" => [],
    "discarded" => [],
    "executing" => [],
    "retryable" => [],
    "scheduled" => []
  }

  defstruct [
    :conf,
    :name,
    :queue_timer,
    :check_timer,
    checks: @empty_states,
    check_counter: 0,
    check_interval: :timer.seconds(1),
    estimate_limit: 50_000,
    function_created?: false,
    queues: []
  ]

  @spec child_spec(Keyword.t()) :: Supervisor.child_spec()
  def child_spec(opts) do
    name = Keyword.get(opts, :name, __MODULE__)

    %{super(opts) | id: name}
  end

  @spec start_link(Keyword.t()) :: GenServer.on_start()
  def start_link(opts) do
    state = struct!(State, opts)

    GenServer.start_link(__MODULE__, state, name: opts[:name])
  end

  # Callbacks

  @impl GenServer
  def init(state) do
    Process.flag(:trap_exit, true)

    # Used to ensure testing helpers to auto-allow this module for sandbox access.
    :telemetry.execute([:oban, :plugin, :init], %{}, %{conf: state.conf, plugin: __MODULE__})

    {:ok, schedule_checks(state)}
  end

  @impl GenServer
  def terminate(_reason, %State{} = state) do
    if is_reference(state.check_timer), do: Process.cancel_timer(state.check_timer)

    :ok
  end

  @impl GenServer
  def handle_info(:checkpoint, %State{conf: conf} = state) do
    if Peer.leader?(conf.name) do
      state =
        state
        |> create_estimate_function()
        |> cache_queues()

      {:ok, checks} = checks(state)

      metrics =
        for {_key, counts} <- checks,
            count <- counts,
            do: Map.update!(count, :value, &Gauge.new/1)

      payload = %{
        metrics: metrics,
        name: inspect(conf.name),
        node: conf.node,
        time: System.system_time(:second)
      }

      Notifier.notify(conf, :metrics, payload)

      {:noreply,
       schedule_checks(%{state | check_counter: state.check_counter + 1, checks: checks})}
    else
      {:noreply, schedule_checks(state)}
    end
  end

  # Scheduling

  defp schedule_checks(state) do
    timer = Process.send_after(self(), :checkpoint, state.check_interval)

    %State{state | check_timer: timer}
  end

  # Checking

  # An `EXPLAIN` can only be executed as the top level of a query, or through an SQL function's
  # EXECUTE as we're doing here. A named function helps the performance because it is prepared,
  # and we have to support distributed databases that don't allow DO/END functions.
  defp create_estimate_function(%{conf: conf, function_created?: false} = state) do
    query = """
    CREATE OR REPLACE FUNCTION #{conf.prefix}.oban_count_estimate(state text, queue text)
    RETURNS integer AS $func$
    DECLARE
      plan jsonb;
    BEGIN
      EXECUTE 'EXPLAIN (FORMAT JSON)
               SELECT id
               FROM #{conf.prefix}.oban_jobs
               WHERE state = $1::#{conf.prefix}.oban_job_state
               AND queue = $2'
        INTO plan
        USING state, queue;
      RETURN plan->0->'Plan'->'Plan Rows';
    END;
    $func$
    LANGUAGE plpgsql 
    """

    Repo.query!(conf, query, [])

    %{state | function_created?: true}
  end

  defp create_estimate_function(state), do: state

  defp cache_queues(state) do
    if Integer.mod(state.check_counter, 60) == 0 do
      source = if state.conf.engine == Smart, do: "oban_producers", else: "oban_jobs"
      query = from(p in source, select: p.queue, distinct: true)

      %{state | queues: Repo.all(state.conf, query)}
    else
      state
    end
  end

  defp checks(%{estimate_limit: limit} = state) do
    {count_states, guess_states} =
      for {state, counts} <- state.checks, reduce: {[], []} do
        {count_acc, guess_acc} ->
          total = Enum.reduce(counts, 0, &(&2 + &1.value))

          if total < limit do
            {[state | count_acc], guess_acc}
          else
            {count_acc, [state | guess_acc]}
          end
      end

    count_query = count_query(count_states)
    guess_query = guess_query(guess_states, state.queues, state.conf)

    Repo.transaction(state.conf, fn ->
      count_counts = Repo.all(state.conf, count_query)
      guess_counts = Repo.all(state.conf, guess_query)

      (count_counts ++ guess_counts)
      |> Enum.group_by(& &1.state)
      |> Enum.reduce(@empty_states, fn {state, counts}, acc ->
        Map.put(acc, state, counts)
      end)
    end)
  end

  defp count_query(states) do
    Job
    |> select([j], %{series: :full_count, state: j.state, queue: j.queue, value: count(j.id)})
    |> where([j], j.state in ^states)
    |> group_by([j], [j.state, j.queue])
  end

  defp guess_query(states, queues, conf) do
    from(p in fragment("json_array_elements_text(?)", ^queues),
      cross_join: x in fragment("json_array_elements_text(?)", ^states),
      select: %{
        series: :full_count,
        state: x.value,
        queue: p.value,
        value: fragment("?.oban_count_estimate(?, ?)", literal(^conf.prefix), x.value, p.value)
      }
    )
  end
end
