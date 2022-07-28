defmodule Oban.Met do
  @moduledoc """
  Documentation for `Oban.Met`.
  """

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

  @doc """
  Get a summary of the current counts for a particular field, optionally subdivided by another
  field.

  Unlike queues and workers, states are static and constant, so they'll always show up in the
  counts or subdivision maps.

  ## Examples

  Retrieve counts using the default `by: :state`:

      Met.counts()
      # => %{"available" => 10, "cancelled" => 0, "completed" => 15, ...

  By state, without any subdivision, explicitly:

      Met.counts(by: :state, sub: false)
      # => %{"available" => 10, "cancelled" => 0, "completed" => 15, ...

  By state, subdivided by queue:

      Met.counts(by: :state, sub: :queue)
      # => %{"available" => %{"alpha" => 9, "gamma" => 1}, "cancelled" => %{}, ...

  By queue, subdivided by state:

      Met.counts(by: :queue, sub: :state)
      # => %{"alpha" => %{"available" => 10, "cancelled" => 0, "completed" => 15, ...

  By queue, subdivided by worker:

      Met.counts(by: :state, sub: :worker)
      # => %{"alpha" => %{"WorkerA" => 5, "WorkerB" => 5}, "gamma" => %{}, ...
  """
  @spec counts(oban_name(), count_opts() | filter_opts()) :: counts() | sub_counts()
  def counts(oban \\ Oban, opts \\ []) do
    %{}
  end

  @doc """
  Summarize a series of data with an aggregate over a configurable window of time.

  Generate series data using the defaults of `series: :state, agg: :max, res: :seconds`:

      Met.summary()
      # => [%{at: %DateTime{}, label: "available", value: 9}, %{at: %DateTime{}, label: "completed", value: 3}]

  Summarize by state, with a minimum aggregate and by minute:

      Met.summary(series: :state, agg: :min, res: :minutes)
      # => [%{at: %DateTime{}, label: "available", value: 9}, %{at: %DateTime{}, label: "cancelled", value: 7}]

  Summarize by queue, using the median and an hourly resolution:

      Met.summary(series: :queue, agg: :p50, res: :hours)
      # => [%{at: %DateTime{}, label: "alpha", value: 4}, %{at: %DateTime{}, label: "gamma", value: 7}}]

  Summarize by execution time, using the 95th percentile and only for a couple of workers:

      Met.summary(series: :ellapsed, agg: :p95, workers: ["WorkerA", "WorkerB"])
      # => [%{at: %DateTime{}, label: "", value: 100}, %{at: %DateTime{}, label: "", value: 100}]
  """
  @spec summary(oban_name, summary_opts() | filter_opts()) :: [
          %{at: DateTime.t(), data: counts()}
        ]
  def summary(oban \\ Oban, opts \\ []) do
    []
  end
end
