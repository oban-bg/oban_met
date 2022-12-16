defmodule Oban.Met.Values.Gauge do
  @moduledoc """
  One or more non-negative integers captured over time.
  """

  alias __MODULE__, as: Gauge

  @derive Jason.Encoder
  defstruct data: []

  @type t :: %__MODULE__{data: [non_neg_integer()]}

  @doc """
  Initialize a new gauge with a latest value.

  ## Examples

      iex> Gauge.new(0)
      ...> |> Gauge.size()
      1

      iex> Gauge.new([0, 1, 2])
      ...> |> Gauge.size()
      3

      iex> Gauge.new([-1])
      ...> |> Gauge.first()
      0
  """
  @spec new(non_neg_integer() | [non_neg_integer()]) :: t()
  def new(data) when is_integer(data) or is_list(data) do
    data =
      data
      |> List.wrap()
      |> Enum.map(&max(0, &1))

    %Gauge{data: List.wrap(data)}
  end

  @doc """
  Add to the latest value for a gauge.

  ## Examples

      iex> 1
      ...> |> Gauge.new()
      ...> |> Gauge.add(1)
      ...> |> Gauge.add(1)
      ...> |> Gauge.first()
      3

  Our gauge is specially tailored for tracking database counts, which may never be negative.

      iex> Gauge.new([1])
      ...> |> Gauge.add(-1)
      ...> |> Gauge.add(-1)
      ...> |> Gauge.first()
      0
  """
  @spec add(t(), integer()) :: t()
  def add(%Gauge{data: [head | tail]} = gauge, value) do
    updated = max(0, head + value)

    %Gauge{gauge | data: [updated | tail]}
  end

  @doc """
  Gets the latest value for a gauge.

  ## Examples

      iex> 1 |> Gauge.new() |> Gauge.first()
      1

      iex> 1
      ...> |> Gauge.new()
      ...> |> Gauge.add(1)
      ...> |> Gauge.add(1)
      ...> |> Gauge.first()
      3
  """
  @spec first(t()) :: non_neg_integer()
  def first(%Gauge{data: [latest | _]}), do: latest

  @doc """
  Merges two gauges into a one.

  ## Examples

  Merging two gauges retains all values:

      iex> gauge_1 = Gauge.new(1)
      ...> gauge_2 = Gauge.new(2)
      ...> gauge_1
      ...> |> Gauge.merge(gauge_2)
      ...> |> Gauge.size()
      2

  Merging two gauges retains the latest value from the first gauge:

      iex> gauge_1 = Gauge.new(1)
      ...> gauge_2 = Gauge.new(2)
      ...> gauge_1
      ...> |> Gauge.merge(gauge_2)
      ...> |> Gauge.first()
      1
  """
  @spec merge(t(), t()) :: t()
  def merge(%Gauge{data: data_1}, %Gauge{data: data_2}) do
    %Gauge{data: data_1 ++ data_2}
  end

  @doc """
  Compute the quantile value for a gauge.

  ## Examples

  With single values:

      iex> Gauge.quantile(Gauge.new(0), 1.0)
      0

      iex> Gauge.quantile(Gauge.new(1), 1.0)
      1

  With multiple values:

      iex> gauge = Gauge.new(Enum.to_list(1..100))
      ...>
      ...> assert Gauge.quantile(gauge, 0.0) == 1
      ...> assert Gauge.quantile(gauge, 0.5) == 50
      ...> assert Gauge.quantile(gauge, 1.0) == 100
  """
  @spec quantile(t(), float()) :: integer()
  def quantile(%Gauge{data: [value]}, _), do: value

  def quantile(%Gauge{data: data}, quantile) when quantile >= 0 and quantile <= 1 do
    index = max(0, floor(length(data) * quantile) - 1)

    data
    |> Enum.sort()
    |> Enum.at(index)
  end

  @doc false
  @spec size(t()) :: non_neg_integer()
  def size(%Gauge{data: data}), do: length(data)

  @doc """
  Initialize a gauge struct from a stringified map, e.g. encoded JSON.

  ## Examples

      iex> Gauge.new([1, 2])
      ...> |> Jason.encode!()
      ...> |> Jason.decode!()
      ...> |> Gauge.from_map()
      ...> |> Gauge.size()
      2
  """
  @spec from_map(%{optional(String.t()) => term()}) :: t()
  def from_map(%{"data" => data}), do: %Gauge{data: data}
end
