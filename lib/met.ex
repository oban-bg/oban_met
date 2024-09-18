defmodule Oban.Met do
  @moduledoc """
  Metric introspection for Oban.

  `Oban.Met` supervises a collection of autonomous modules for in-memory, distributed time-series
  data with zero-configuration. `Oban.Web` relies on `Met` for queue gossip, detailed job counts,
  and historic metrics.

  ## Highlights

  * Telemetry powered execution tracking for time-series data that is replicated between nodes,
    filterable by label, arbitrarily mergeable over windows of time, and compacted for longer
    playback.

  * Centralized counting across queues and states with exponential backoff to minimize load and
    data replication between nodes.

  * Ephemeral data storage via data replication with handoff between nodes. All nodes have a
    shared view of the cluster's data and new nodes are caught up when they come online.
  """

  use Supervisor

  alias Oban.Met.{Cronitor, Examiner, Listener, Recorder, Reporter, Value}
  alias Oban.Registry

  @type counts :: %{optional(String.t()) => non_neg_integer()}
  @type sub_counts :: %{optional(String.t()) => non_neg_integer() | counts()}

  @type series :: atom() | String.t()
  @type value :: Value.t()
  @type label :: String.t()
  @type ts :: integer()

  @type filter_value :: label() | [label()]

  @type series_detail :: %{series: series(), labels: [label()], value: module()}

  @type operation :: :max | :sum | {:pct, float()}

  @type latest_opts :: [
          filters: keyword(filter_value()),
          group: nil | label(),
          lookback: pos_integer()
        ]

  @type timeslice_opts :: [
          by: pos_integer(),
          filters: keyword(filter_value()),
          group: nil | label(),
          label: nil | label(),
          lookback: pos_integer(),
          operation: operation(),
          since: pos_integer()
        ]

  @doc false
  @spec child_spec(Keyword.t()) :: Supervisor.child_spec()
  def child_spec(opts) do
    conf = Keyword.fetch!(opts, :conf)
    name = Registry.via(conf.name, __MODULE__)

    opts
    |> super()
    |> Map.put(:id, name)
  end

  @doc """
  Start a Met supervisor for an Oban instance.

  `Oban.Met` typically starts supervisors automatically when Oban instances initialize. However,
  starting a supervisor manually can be used if `auto_start` is disabled.

  ## Options

  These options are required; without them the supervisor won't start:

  * `:conf` — configuration for a running Oban instance, required

  * `:name` — an optional name for the supervisor, defaults to `Oban.Met`

  ## Example

  Start a supervisor for the default Oban instance:

      Oban.Met.start_link(conf: Oban.config())

  Start a supervisor with a custom name:

      Oban.Met.start_link(conf: Oban.config(), name: MyApp.MetSup)
  """
  @spec start_link(Keyword.t()) :: Supervisor.on_start()
  def start_link(opts) when is_list(opts) do
    conf = Keyword.fetch!(opts, :conf)
    name = Registry.via(conf.name, __MODULE__)

    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Retrieve stored producer checks.

  This mimics the output of the legacy `Oban.Web.Plugins.Stats.all_gossip/1` function.

  Checks are queried approximately every second and broadcast to all connected nodes, so each node
  is a replica of checks from the entire cluster. Checks are stored for 30 seconds before being
  purged.

  ## Output

  Checks are the result of `Oban.check_queue/1`, and the exact contents depends on which
  `Oban.Engine` is in use. A `Basic` engine check will look similar to this:

      %{
        uuid: "2dde4c0f-53b8-4f59-9a16-a9487454292d",
        limit: 10,
        node: "me@local",
        paused: false,
        queue: "default",
        running: [100, 102],
        started_at: ~D[2020-10-07 15:31:00],
        updated_at: ~D[2020-10-07 15:31:00]
      }

  ## Examples

  Get all current checks:

      Oban.Met.checks()

  Get current checks for a non-standard Oban isntance:

      Oban.Met.checks(MyOban)
  """
  @spec checks(Oban.name()) :: [map()]
  def checks(oban \\ Oban) do
    oban
    |> Registry.via(Examiner)
    |> Examiner.all_checks()
  end

  @doc """
  Get a normalized, unified crontab from all connected nodes.

  ## Examples

  Get a merged crontab:

      Oban.Met.crontab()
      [
        {"* * * * *", "Worker.A", []},
        {"* * * * *", "Worker.B", [["args", %{"mode" => "foo"}]]}
      ]

  Get the crontab for a non-standard Oban instance:

      Oban.Met.crontab(MyOban)
  """
  @spec crontab(Oban.name()) :: [{binary(), binary(), map()}]
  def crontab(oban \\ Oban) do
    oban
    |> Registry.via(Cronitor)
    |> Cronitor.merged_crontab()
  end

  @doc """
  Get all stored, unique values for a particular label.

  ## Examples

  Get all known queues:

      Oban.Met.labels("queue")
      ~w(alpha gamma delta)

  Get all known workers:

      Oban.Met.labels("worker")
      ~w(MyApp.Worker MyApp.OtherWorker)
  """
  @spec labels(Oban.name(), label(), keyword()) :: [label()]
  def labels(oban \\ Oban, label, opts \\ []) do
    oban
    |> Registry.via(Recorder)
    |> Recorder.labels(to_string(label), opts)
  end

  @doc """
  Get all stored values for a series without any filtering.
  """
  @spec lookup(Oban.name(), series()) :: [term()]
  def lookup(oban \\ Oban, series) do
    oban
    |> Registry.via(Recorder)
    |> Recorder.lookup(to_string(series))
  end

  @doc """
  Get the latest values for a gauge series, optionally subdivided by a label.

  Unlike queues and workers, states are static and constant, so they'll always show up in the
  counts or subdivision maps.

  ## Gauge Series

  Latest counts only apply to `Gauge` series. There are two gauges available (as reported by
  `series/1`:

  * `:exec_count` — jobs executing at that moment, including `node`, `queue`, `state`, and
    `worker` labels.

  * `:full_count` — jobs in the database, including `queue`, and `state` labels.

  ## Examples

  Get the `:full_count` value without any grouping:

      Oban.Met.latest(:full_count)
      %{"all" => 99}

  Group the `:full_count` value by state:

      Oban.Met.latest(:full_count, group: "state")
      %{"available" => 9, "completed" => 80, "executing" => 5, ...

  Group results by queue:

      Oban.Met.latest(:exec_count, group: "queue")
      %{"alpha" => 9, "gamma" => 3}

  Group results by node:

      Oban.Met.latest(:exec_count, group: "node")
      %{"worker.1" => 6, "worker.2" => 5}

  Filter values by node:

      Oban.Met.latest(:exec_count, filters: [node: "worker.1"])
      %{"all" => 6}

  Filter values by queue and state:

      Oban.Met.latest(:exec_count, filters: [node: "worker.1", "worker.2"])
  """
  @spec latest(Oban.name(), series()) :: counts() | sub_counts()
  def latest(oban \\ Oban, series, opts \\ []) do
    oban
    |> Registry.via(Recorder)
    |> Recorder.latest(to_string(series), opts)
  end

  @doc """
  List all recorded series along with their labels and value type.

  ## Examples

      Oban.Met.series()
      [
        %{series: "exec_time", labels: ["state", "queue", "worker"], value: Sketch},
        %{series: "wait_time", labels: ["state", "queue", "worker"], value: Sketch},
        %{series: "exec_count", labels: ["state", "queue", "worker"], value: Gauge},
        %{series: "full_count", labels: ["state", "queue"], value: Gauge}
      ]
  """
  @spec series(Oban.name()) :: [series_detail()]
  def series(oban \\ Oban) do
    oban
    |> Registry.via(Recorder)
    |> Recorder.series()
  end

  @doc """
  Summarize a series of data with an aggregate over a configurable window of time.

  ## Examples

  Retreive a 3 second timeslice of the `exec_time` sketch:

      Oban.Met.timeslice(Oban, :exec_time, lookback: 3)
      [
        {2, 16771374649.128689, nil},
        {1, 24040058779.3428, nil},
        {0, 22191534459.516357, nil},
      ]

  Group `exec_time` slices by the `queue` label:

      Oban.Met.timeslice(Oban, :exec_time, group: "queue")
      [
        {1, 9970235387.031698, "analysis"},
        {0, 11700429279.446463, "analysis"},
        {1, 23097311376.231316, "default"},
        {0, 23097311376.231316, "default"},
        {1, 1520977874.3348415, "events"},
        {0, 2558504265.2738624, "events"},
        ...
  """
  @spec timeslice(Oban.name(), series(), timeslice_opts()) :: [{ts(), value(), label()}]
  def timeslice(oban \\ Oban, series, opts \\ []) do
    oban
    |> Registry.via(Recorder)
    |> Recorder.timeslice(to_string(series), opts)
  end

  # Callbacks

  @impl Supervisor
  def init(opts) do
    conf = Keyword.fetch!(opts, :conf)

    children = [
      {Cronitor, with_opts(:cronitor, conf: conf, name: Registry.via(conf.name, Cronitor))},
      {Examiner, with_opts(:examiner, conf: conf, name: Registry.via(conf.name, Examiner))},
      {Recorder, with_opts(:recorder, conf: conf, name: Registry.via(conf.name, Recorder))},
      {Listener, with_opts(:listener, conf: conf, name: Registry.via(conf.name, Listener))},
      {Reporter, with_opts(:reporter, conf: conf, name: Registry.via(conf.name, Reporter))},
      {Task, fn -> :telemetry.execute([:oban, :met, :init], %{}, %{pid: self(), conf: conf}) end}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp with_opts(name, opts) do
    :oban_met
    |> Application.get_env(name, [])
    |> Keyword.merge(opts)
  end
end
