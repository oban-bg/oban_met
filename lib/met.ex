defmodule Oban.Met do
  @moduledoc """
  Metric introspection for Oban.
  """

  alias Oban.Met.{Examiner, Recorder, Value}
  alias Oban.Registry

  @type oban_name :: term()

  @type counts :: %{optional(String.t()) => non_neg_integer()}
  @type sub_counts :: %{optional(String.t()) => non_neg_integer() | counts()}

  @type name_or_table :: GenServer.name() | :ets.table()
  @type series :: atom() | String.t()
  @type value :: Value.t()
  @type label :: String.t()
  @type ts :: integer()

  @type filter_value :: String.t() | [String.t()]

  @type filter_opts ::
          {:node, filter_value()}
          | {:queue, filter_value()}
          | {:state, filter_value()}

  @type latest_opts :: [
    filters: [filter_opts()],
    group: String.t(),
    lookback: pos_integer(),
    ntile: float()
  ]

  @type timeslice_opts :: [
    by: pos_integer(),
    filters: [filter_opts()],
    label: :any | String.t(),
    lookback: pos_integer(),
    ntile: float()
  ]

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
  @spec latest(oban_name(), series()) :: counts() | sub_counts()
  def latest(oban \\ Oban, series, opts \\ []) do
    oban
    |> Registry.via(Recorder)
    |> Recorder.latest(series, opts)
  end

  @doc """
  Summarize a series of data with an aggregate over a configurable window of time.
  """
  @spec timeslice(oban_name(), series(), timeslice_opts()) :: [{ts(), value(), label()}]
  def timeslice(oban \\ Oban, series, opts \\ []) do
    oban
    |> Registry.via(Recorder)
    |> Recorder.timeslice(series, opts)
  end
end
