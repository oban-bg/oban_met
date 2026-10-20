defmodule Oban.Met do
  @external_resource readme = Path.join([__DIR__, "../README.md"])

  @moduledoc readme
             |> File.read!()
             |> String.split("<!-- MDOC -->")
             |> Enum.fetch!(1)

  use Supervisor

  alias Oban.Met.{Cronitor, Examiner, Listener, Recorder, Reporter, Value}
  alias Oban.Registry

  @type counts :: %{optional(String.t()) => number()}
  @type sub_counts :: %{optional(String.t()) => non_neg_integer() | counts()}

  @type series :: atom() | String.t()
  @type value :: Value.t()
  @type label :: String.t()
  @type ts :: integer()

  @type filter_value :: label() | atom() | [label() | atom()]

  @type series_detail :: %{series: String.t(), labels: [label()], type: module()}

  @type operation :: :max | :sum | {:pct, float()}

  @type labels_opts :: [lookback: pos_integer(), since: pos_integer()]

  @type latest_opts :: [
          filters: keyword(filter_value()),
          group: nil | label() | atom(),
          lookback: pos_integer()
        ]

  @type timeslice_opts :: [
          by: pos_integer(),
          filters: keyword(filter_value()),
          group: nil | label() | atom(),
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

  The supervisor is registered under the Oban instance's name, so only one may run per instance.

  ## Options

  * `:conf` - configuration for a running Oban instance, required

  ## Example

  Start a supervisor for the default Oban instance:

      Oban.Met.start_link(conf: Oban.config())
  """
  @spec start_link(Keyword.t()) :: Supervisor.on_start()
  def start_link(opts) when is_list(opts) do
    conf = Keyword.fetch!(opts, :conf)
    name = Registry.via(conf.name, __MODULE__)

    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Retrieve stored producer checks.

  Checks are gathered from every local queue producer about once a second and broadcast to all
  connected nodes, so each node holds a replica of checks from the entire cluster. Checks that
  haven't been refreshed in 30 seconds are purged.

  ## Output

  Checks are the result of `Oban.check_queue/1` after a round trip through JSON, so keys and
  timestamps are strings. The `limit` key is renamed to `local_limit`, and the exact contents
  depend on which `Oban.Engine` is in use. A `Basic` engine check looks similar to this:

      %{
        "local_limit" => 10,
        "name" => "Oban",
        "node" => "worker.1",
        "paused" => false,
        "queue" => "default",
        "refresh_interval" => 60000,
        "running" => [100, 102],
        "shutdown_started_at" => nil,
        "started_at" => "2026-10-20T10:32:12.035202Z",
        "updated_at" => "2026-10-20T10:32:12.035204Z",
        "uuid" => "4e776a25-042e-432b-96fa-3a08f245e749"
      }

  ## Examples

  Get all current checks:

      Oban.Met.checks()

  Get current checks for a non-standard Oban instance:

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

  Each entry is a tuple of the cron expression, the worker name, and a map of the entry's
  options. Crontabs are shared between nodes as JSON, so option keys are strings. Duplicate
  entries across nodes are removed, and crontabs from nodes that haven't reported in 60 seconds
  are dropped.

  ## Examples

  Get a merged crontab:

      Oban.Met.crontab()
      [
        {"* * * * *", "MyApp.WorkerA", %{}},
        {"0 * * * *", "MyApp.WorkerB", %{"args" => %{"mode" => "foo"}}}
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

  @doc false
  def labels(label, opts) when is_list(opts), do: labels(Oban, label, opts)

  @doc """
  Get the unique values recently recorded for a label across all series.

  ## Options

  * `:lookback` - how many seconds before `:since` to include, defaults to `120`

  * `:since` - the unix time, in seconds, that the lookback is measured from, defaults to now

  ## Examples

  Get all known queues:

      Oban.Met.labels("queue")
      ["alpha", "delta", "gamma"]

  Get workers recorded within the last minute:

      Oban.Met.labels("worker", lookback: 60)
      ["MyApp.OtherWorker", "MyApp.Worker"]

  Get queues for a non-standard Oban instance:

      Oban.Met.labels(MyOban, "queue")
  """
  @spec labels(Oban.name(), label(), labels_opts()) :: [label()]
  def labels(oban \\ Oban, label, opts \\ [])

  def labels(oban, label, opts) do
    oban
    |> Registry.via(Recorder)
    |> Recorder.labels(to_string(label), opts)
  end

  @doc """
  Get all stored rows for a series without any filtering or aggregation.

  Rows are returned newest first in their internal storage format, which is primarily useful for
  debugging.
  """
  @spec lookup(Oban.name(), series()) :: [term()]
  def lookup(oban \\ Oban, series) do
    oban
    |> Registry.via(Recorder)
    |> Recorder.lookup(to_string(series))
  end

  @doc false
  def latest(series, opts) when is_list(opts), do: latest(Oban, series, opts)

  @doc """
  Get the latest values for a series, summed and optionally grouped by a label.

  Each distinct combination of labels contributes its most recent value from within the
  lookback. Without a `:group`, all values are summed under the `"all"` key. Values that lack the
  group label are also summed under `"all"`. Groups without any recent values are omitted.

  ## Series

  Latest values are intended for gauge series (as reported by `series/1`):

  * `:full_count` - jobs in the database, with `node`, `queue`, and `state` labels.

  * `:exec_count` - jobs that finished executing, with `node`, `queue`, `state`, and `worker`
    labels. The `state` is the job's state after execution, e.g. `completed` or `retryable`.

  Sketch series such as `:exec_time` return approximate sums, which are rarely useful. Use
  `timeslice/3` with a percentile for those instead.

  ## Options

  * `:filters` - a keyword list of labels and values that recorded labels must match. A value
    may be a string, an atom, or a list of either to match any of them. Separate labels must
    all match. Defaults to `[]`.

  * `:group` - a label to group values by, defaults to `nil`

  * `:lookback` - how many seconds back to include values, defaults to `2`

  ## Examples

  Get the `:full_count` value without any grouping:

      Oban.Met.latest(:full_count)
      %{"all" => 99}

  Group the `:full_count` value by state:

      Oban.Met.latest(:full_count, group: "state")
      %{"available" => 9, "completed" => 80, "executing" => 5, ...}

  Group recent executions by queue:

      Oban.Met.latest(:exec_count, group: "queue")
      %{"alpha" => 9, "gamma" => 3}

  Filter values by node:

      Oban.Met.latest(:exec_count, filters: [node: "worker.1"])
      %{"all" => 6}

  Filter values by queue and any of several states:

      Oban.Met.latest(:full_count, filters: [queue: "alpha", state: ["available", "scheduled"]])
      %{"all" => 12}

  Get values for a non-standard Oban instance:

      Oban.Met.latest(MyOban, :full_count, group: "queue")
  """
  @spec latest(Oban.name(), series(), latest_opts()) :: counts()
  def latest(oban \\ Oban, series, opts \\ [])

  def latest(oban, series, opts) do
    oban
    |> Registry.via(Recorder)
    |> Recorder.latest(to_string(series), opts)
  end

  @doc """
  List all recorded series along with their labels and value type.

  ## Examples

      Oban.Met.series()
      [
        %{series: "exec_count", labels: ["node", "queue", "state", "worker"], type: Gauge},
        %{series: "exec_time", labels: ["node", "queue", "state", "worker"], type: Sketch},
        %{series: "full_count", labels: ["node", "queue", "state"], type: Gauge},
        %{series: "wait_time", labels: ["node", "queue", "state", "worker"], type: Sketch}
      ]
  """
  @spec series(Oban.name()) :: [series_detail()]
  def series(oban \\ Oban) do
    oban
    |> Registry.via(Recorder)
    |> Recorder.series()
  end

  @doc false
  def timeslice(series, opts) when is_list(opts), do: timeslice(Oban, series, opts)

  @doc """
  Summarize a series into buckets of time, with values aggregated within each bucket.

  Returns a list of `{bucket, value, label}` tuples, sorted by label and then from the oldest
  bucket to the newest. Buckets without any values are omitted.

  ## Buckets

  The bucket is an index counting backward from `:since`, not a timestamp. Bucket `0` holds the
  `:by` seconds immediately before `:since`, bucket `1` the `:by` seconds before that, and so on
  through the lookback. Bucket `n` covers from `since - (n + 1) * by` up to, but not including,
  `since - n * by`. Values recorded at or after `:since` fall into negative buckets.

  ## Aggregation

  Values in each bucket are combined by label, according to `:group`, and then reduced with the
  `:operation`:

  * `:sum` - the total of all values. Exact for gauges and approximate for sketches.

  * `:max` - the largest value. For gauges, that's the peak per-second total for the group.

  * `{:pct, ntile}` - the percentile, with `ntile` between `0.0` and `1.0`. Empty sketches
    return `nil`.

  Sketches, such as `:exec_time` and `:wait_time`, estimate values with a 2% relative error and
  store times in `:native` units unless the `:sketch_time_unit` is configured. The
  `:exec_count` gauge counts executions per second, so `:sum` gives the executions within each
  bucket. The `:full_count` gauge is a reading that repeats with each report, so use `:max` or a
  percentile rather than summing it.

  ## Compaction

  Older values are compacted into wider intervals to save space. By default, values keep
  one-second resolution for 2 minutes, then compact into 5 second intervals for 15 minutes, 30
  second intervals for the next 33 minutes, and 60 second intervals for about 2.5 more hours,
  after which they're deleted. Compacted values land in a single bucket, so buckets narrower than
  the compaction interval are sparse for older data.

  ## Options

  * `:by` - the width of each bucket in seconds, defaults to `1`

  * `:filters` - a keyword list of labels and values that recorded labels must match, as in
    `latest/3`. Defaults to `[]`.

  * `:group` - a label to group values by. Values without the label, or all values when `nil`,
    are combined under a `nil` label. Defaults to `nil`.

  * `:lookback` - how many seconds before `:since` to include, defaults to `60`

  * `:operation` - how to reduce values within each bucket, one of `:sum`, `:max`, or
    `{:pct, ntile}`. Defaults to `:sum`.

  * `:since` - the unix time, in seconds, that buckets count back from, defaults to now

  ## Examples

  Retrieve the 95th percentile `exec_time` for each of the last three seconds:

      Oban.Met.timeslice(:exec_time, lookback: 3, operation: {:pct, 0.95})
      [
        {2, 16771374649.128689, nil},
        {1, 24040058779.3428, nil},
        {0, 22191534459.516357, nil}
      ]

  Count executions in 5 second buckets over the last minute, grouped by queue:

      Oban.Met.timeslice(:exec_count, by: 5, group: "queue")
      [
        {11, 4, "analysis"},
        {10, 7, "analysis"},
        ...
        {1, 12, "events"},
        {0, 9, "events"}
      ]

  Find the longest `wait_time` in a single queue:

      Oban.Met.timeslice(:wait_time, filters: [queue: "default"], operation: :max)

  Slice from a fixed point in time for a non-standard Oban instance:

      Oban.Met.timeslice(MyOban, :exec_count, by: 10, lookback: 300, since: since)
  """
  @spec timeslice(Oban.name(), series(), timeslice_opts()) ::
          [{ts(), nil | number(), nil | label()}]
  def timeslice(oban \\ Oban, series, opts \\ [])

  def timeslice(oban, series, opts) do
    oban
    |> Registry.via(Recorder)
    |> Recorder.timeslice(to_string(series), opts)
  end

  # Callbacks

  @impl Supervisor
  def init(opts) do
    conf = Keyword.fetch!(opts, :conf)

    children = [
      {Cronitor, with_opts(:cronitor, conf, opts)},
      {Examiner, with_opts(:examiner, conf, opts)},
      {Recorder, with_opts(:recorder, conf, opts)},
      {Listener, with_opts(:listener, conf, opts)},
      {Reporter, with_opts(:reporter, conf, opts)},
      {Task, fn -> :telemetry.execute([:oban, :met, :init], %{}, %{pid: self(), conf: conf}) end}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp with_opts(name, conf, opts) do
    real_name =
      name
      |> to_string()
      |> String.capitalize()
      |> then(&Module.safe_concat([Oban, Met, &1]))

    init_opts = Keyword.get(opts, name, [])

    :oban_met
    |> Application.get_env(name, [])
    |> Keyword.merge(init_opts)
    |> Keyword.put(:conf, conf)
    |> Keyword.put(:name, Registry.via(conf.name, real_name))
  end
end
