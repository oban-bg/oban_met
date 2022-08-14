defmodule Oban.Met.Checkpoint do
  @moduledoc """
  Checkpoint modules periodically recalculate and store absolute values for a gauge.
  """

  @doc """
  Calculate guage checkpoint metrics for storage.
  """
  @callback call(opts :: Keyword.t()) :: {[{atom(), integer(), map()}], Keyword.t()}

  @doc """
  Determine the interval until the next checkpoint application.
  """
  @callback interval(opts :: Keyword.t()) :: {timeout(), Keyword.t()}
end
