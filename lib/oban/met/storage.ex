defmodule Oban.Met.Storage do
  @moduledoc """
  ETS based storage and automatic management of Oban's timeseries data.

  Storage doesn't perform any calculations on metrics, only storing and fetching with automated
  compaction, pruning, and persistence.

  ## Tuple Format

  {{type, series}, min_ts, max_ts, value, labels}

  {{:delta, :available}, 1659097422, 1659097422,  1, %{queue: "default"}}
  {{:delta, :scheduled}, 1659097422, 1659097422, -1, %{queue: "default"}}
  {{:count, :available}, 1659097421, 1659097421,  5, %{queue: "default"}}
  """

  use GenServer

  alias __MODULE__, as: State

  defstruct [:conf, :name, :table]

  @spec child_spec(Keyword.t()) :: Supervisor.child_spec()
  def child_spec(opts) do
    opts
    |> super()
    |> Supervisor.child_spec(id: Keyword.get(opts, :name, __MODULE__))
  end

  @spec start_link(Keyword.t()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: opts[:name])
  end

  @doc """
  Store a new count delta for timeseries data.

  * Data is stored with min and max timestamps rounded to the current second.

  ## Examples

      Storage.store_count(server, 9, old: :scheduled, new: :available, queue: "default")
      :ok
  """
  @spec store_count(GenServer.name(), integer(), Keyword.t()) :: :ok | {:error, term()}
  def store_count(name, delta, opts) do
    {:ok, table} = Registry.meta(Oban.Registry, name)

    old = Keyword.fetch!(opts, :old)
    new = Keyword.fetch!(opts, :new)
    queue = Keyword.fetch!(opts, :queue)
    timestamp = Keyword.get(:timestamp, seconds_ago(0))

    :ets.insert(table, {{:delta, timestamp, timestamp}, delta, old, new, queue})

    :ok
  end

  @doc """
  Fetch something from the store.
  """
  @spec fetch_count(GenServer.name(), Keyword.t()) :: [term()]
  def fetch_count(name, opts \\ []) do
    {:ok, table} = Registry.meta(Oban.Registry, name)

    now = DateTime.utc_now()
    every = Keyword.get(opts, :every, :second)
    since = Keyword.get(opts, :since, seconds_ago(120))

    # NOTE: What if there aren't any counts in the time requested? We need to keep going until we
    # get at least one count.
    counts = :ets.select(table, [{{{:count, :"$1", :_}, :_, :_, :_}, [{:>, :"$1", since}], [:"$$"]}])
    deltas = :ets.select(table, [{{{:delta, :"$1", :_}, :_, :_, :_, :_}, [{:>, :"$1", since}], [:"$$"]}])

    # - store counts and deltas with the same number of fields
    # - normalize the counts and deltas
    # - unify them in a single sorted list
    # - transform each into rolling values (apply each delta over the last value)

    since
    |> Stream.iterate(&DateTime.add(&1, 1, every))
    |> Stream.take_while(fn ts -> DateTime.compare(ts, now) != :gt end)

    # What's the shape of the data I'm returning here?
    #   - per window of time, each state/queue combination
    #   - {timestamp, count, state, queue}
    #
  end

  defp seconds_ago(seconds) do
    DateTime.utc_now()
    |> DateTime.add(-seconds, :second)
    |> DateTime.truncate(:second)
    |> DateTime.to_unix()
  end

  # Callbacks

  @impl GenServer
  def init(opts) do
    table = :ets.new(:metrics, [:bag, :public, write_concurrency: true])
    state = %State{conf: opts[:conf], name: opts[:name], table: table}

    Registry.put_meta(Oban.Registry, state.name, table)

    # TODO: Listen to telemetry
    # TODO: Listen to pubsub in collector mode
    # TODO: Start tracking keyframes
    # TODO: Start a compaction schedule

    {:ok, state}
  end
end
