defmodule Oban.Met do
  @moduledoc """
  Metric introspection for Oban.
  """

  use Supervisor

  alias Oban.Met.{Examiner, Listener, Recorder, Reporter, Value}
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
          group: String.t(),
          lookback: pos_integer(),
          operation: operation()
        ]

  @type timeslice_opts :: [
          by: pos_integer(),
          filters: keyword(filter_value()),
          group: nil | label(),
          label: :any | String.t(),
          lookback: pos_integer(),
          operation: operation()
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

  @doc false
  @spec start_link(Keyword.t()) :: Supervisor.on_start()
  def start_link(opts) when is_list(opts) do
    conf = Keyword.fetch!(opts, :conf)
    name = Registry.via(conf.name, __MODULE__)

    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Retrieve stored producer checks.

  This mimics the output of the legacy `Oban.Web.Plugins.Stats.all_gossip/1` function.
  """
  @spec checks(Oban.name()) :: [map()]
  def checks(oban \\ Oban) do
    oban
    |> Registry.via(Examiner)
    |> Examiner.all_checks()
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
  Get the latest values for a series, optionally subdivided by a label.

  Unlike queues and workers, states are static and constant, so they'll always show up in the
  counts or subdivision maps.
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

      Oban.Met.timeslice(Oban, "exec_time", lookback: 3)
      [
        {2, 16771374649.128689, nil},
        {1, 24040058779.3428, nil},
        {0, 22191534459.516357, nil},
      ]

  Group `exec_time` slices by the `queue` label:

      Oban.Met.timeslice(Oban, "exec_time", group: "queue")
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

    children =
      [
        {Examiner, conf: conf, name: Registry.via(conf.name, Examiner)},
        {Recorder, conf: conf, name: Registry.via(conf.name, Recorder)},
        {Listener, conf: conf, name: Registry.via(conf.name, Listener)},
        {Reporter, conf: conf, name: Registry.via(conf.name, Reporter)}
      ] ++ event_child(conf)

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp event_child(conf) do
    meta = %{pid: self(), conf: conf}

    [Task.child_spec(fn -> :telemetry.execute([:oban, :met, :init], %{}, meta) end)]
  end
end
