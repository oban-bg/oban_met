defmodule Oban.Met.Values.Gauge do
  @moduledoc """
  One or more non-negative integers captured over time.
  """

  alias __MODULE__, as: Gauge

  @derive Jason.Encoder
  defstruct data: 0

  @type t :: %__MODULE__{data: non_neg_integer()}

  @doc """
  Initialize a new gauge with a latest value.

  ## Examples

      iex> Gauge.new(0)
      %Gauge{data: 0}

      iex> Gauge.new(-1)
      %Gauge{data: 0}

      iex> Gauge.new(2)
      %Gauge{data: 2}
  """
  @spec new(non_neg_integer()) :: t()
  def new(data) when is_integer(data) do
    %Gauge{data: max(0, data)}
  end

  @doc """
  Add to the latest value for a gauge.

  ## Examples

      iex> Gauge.new(1)
      ...> |> Gauge.add(-1)
      ...> |> Gauge.add(2)
      %Gauge{data: 2}

  Our gauge is specially tailored for tracking database counts, which may never be negative.

      iex> Gauge.new(1)
      ...> |> Gauge.add(-1)
      ...> |> Gauge.add(-1)
      %Gauge{data: 0}
  """
  @spec add(t(), integer()) :: t()
  def add(%Gauge{data: data}, value) do
    %Gauge{data: max(0, data + value)}
  end

  @doc """
  Compact two gauges into one, retaining only the newest value.

  ## Examples

  Compacting two gauges adds the values:

      iex> gauge_1 = Gauge.new(1)
      ...> gauge_2 = Gauge.new(2)
      ...> Gauge.compact(gauge_2, gauge_1)
      %Gauge{data: 2}
  """
  @spec compact(t(), t()) :: t()
  def compact(%Gauge{} = gauge, _), do: gauge

  @doc """
  Merges two gauges into one.

  ## Examples

  Merging two gauges adds the values:

      iex> gauge_1 = Gauge.new(1)
      ...> gauge_2 = Gauge.new(2)
      ...> Gauge.merge(gauge_1, gauge_2)
      %Gauge{data: 3}
  """
  @spec merge(t(), t()) :: t()
  def merge(%Gauge{data: data_1}, %Gauge{data: data_2}) do
    %Gauge{data: data_1 + data_2}
  end

  @doc """
  Compute the quantile value for a gauge.

  ## Examples

  With single values:

      iex> Gauge.quantile(Gauge.new(1), 1.0)
      1

      iex> Gauge.quantile(Gauge.new(1), 0.0)
      1
  """
  @spec quantile(t(), float()) :: non_neg_integer()
  def quantile(%Gauge{data: data}, _), do: data

  @doc """
  Initialize a gauge struct from a stringified map, e.g. encoded JSON.

  ## Examples

      iex> Gauge.new(2)
      ...> |> Jason.encode!()
      ...> |> Jason.decode!()
      ...> |> Gauge.from_map()
      %Gauge{data: 2}
  """
  @spec from_map(%{optional(String.t()) => term()}) :: t()
  def from_map(%{"data" => data}), do: %Gauge{data: data}
end
