defmodule Oban.Met do
  @moduledoc """
  Metric introspection for Oban.
  """

  alias Oban.Met.{Examiner, Recorder}
  alias Oban.Registry

  @type oban_name :: term()

  @type count_field :: :queue | :state | :worker | :node
  @type count_opts :: {:by, count_field()} | {:sub, count_field()}

  @type counts :: %{optional(String.t()) => non_neg_integer()}
  @type sub_counts :: %{optional(String.t()) => non_neg_integer() | counts()}

  @type filter_value :: :all | [atom() | String.t()]

  @type filter_opts ::
          {:nodes, filter_value()}
          | {:queues, filter_value()}
          | {:states, filter_value()}
          | {:workers, filter_value()}

  @type summary_opts ::
          {:series, :state | :queue | :waiting | :ellapsed}
          | {:agg, :min | :max | :p50 | :p95 | :p99}
          | {:res, :seconds | :minutes | :hours | :days}

  @type name_or_table :: GenServer.name() | :ets.t()
  @type series :: atom() | String.t()
  @type value :: Value.t()
  @type label :: String.t()
  @type ts :: integer()

  @doc """
  Retrieve all stored producer checks.

  This mimics the output of the legacy `Oban.Web.Plugins.Stats.all_gossip/1` function.
  """
  def all_checks(oban \\ Oban) do
    oban
    |> Registry.via(Examiner)
    |> Examiner.all_checks()
  end

  @states ~w(available cancelled completed discarded executing retryable scheduled)

  @doc """
  Retrieve gauges for all job states (which is typically all gauges).

  This mimics the output of the legacy `Oban.Web.Plugins.Stats.all_counts/1` function.
  """
  def all_gauges(oban \\ Oban) do
    name = Registry.via(oban, Recorder)
    base = Map.new(@states, &{&1, 0})

    @states
    |> Enum.map(&{&1, Recorder.latest(name, &1, group: "queue", lookback: 60)})
    |> Enum.reduce(%{}, fn {state, queues}, acc ->
      Enum.reduce(queues, acc, fn {queue, value}, sub_acc ->
        Map.update(sub_acc, queue, %{base | state => value}, &Map.put(&1, state, value))
      end)
    end)
    |> Enum.map(fn {queue, counts} -> Map.put(counts, "name", queue) end)
  end

  @doc """
  Get the latest values for a series, optionally subdivided by a label.

  Unlike queues and workers, states are static and constant, so they'll always show up in the
  counts or subdivision maps.
  """
  @spec latest(oban_name(), count_opts() | filter_opts()) :: counts() | sub_counts()
  def latest(oban \\ Oban, series, opts \\ []) do
    oban
    |> Registry.via(Recorder)
    |> Recorder.latest(series, opts)
  end

  @doc """
  Summarize a series of data with an aggregate over a configurable window of time.
  """
  @spec timeslice(oban_name, summary_opts() | filter_opts()) :: [{ts(), value(), label()}]
  def timeslice(oban \\ Oban, series, opts \\ []) do
    oban
    |> Registry.via(Recorder)
    |> Recorder.timeslice(series, opts)
  end
end
