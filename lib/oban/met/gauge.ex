defmodule Oban.Met.Gauge do
  @moduledoc """
  One or more non-negative integer values captured over time.
  """

  alias __MODULE__, as: Gauge

  @derive Jason.Encoder
  defstruct data: []

  @type t :: %__MODULE__{data: [non_neg_integer()]}

  @doc """
  Initialize a new gauge with a latest value.

  ## Examples

      iex> Oban.Met.Gauge.new(0)
      ...> |> Oban.Met.Gauge.size()
      1

      iex> Oban.Met.Gauge.new([0, 1, 2])
      ...> |> Oban.Met.Gauge.size()
      3
  """
  @spec new(non_neg_integer() | [non_neg_integer()]) :: t()
  def new(data) when is_integer(data) and data >= 0, do: new([data])
  def new(data) when is_list(data), do: %Gauge{data: data}

  @doc """
  Add to the latest value for a gauge.

  ## Examples

      iex> 1
      ...> |> Oban.Met.Gauge.new()
      ...> |> Oban.Met.Gauge.add(1)
      ...> |> Oban.Met.Gauge.add(1)
      ...> |> Oban.Met.Gauge.first()
      3
  """
  @spec add(t(), non_neg_integer()) :: t()
  def add(%Gauge{data: [latest | rest]} = gauge, value) do
    %Gauge{gauge | data: [latest + value | rest]}
  end

  @doc """
  Gets the latest value for a gauge.

  ## Examples

      iex> 1 |> Oban.Met.Gauge.new() |> Oban.Met.Gauge.first()
      1

      iex> 1
      ...> |> Oban.Met.Gauge.new()
      ...> |> Oban.Met.Gauge.add(1)
      ...> |> Oban.Met.Gauge.add(1)
      ...> |> Oban.Met.Gauge.first()
      3
  """
  @spec first(t()) :: non_neg_integer()
  def first(%Gauge{data: [latest | _]}), do: latest

  @doc """
  Merges two gauges into a one.

  ## Examples

  Merging two gauges retains all values:

      iex> gauge_1 = Oban.Met.Gauge.new(1)
      ...> gauge_2 = Oban.Met.Gauge.new(2)
      ...> gauge_1
      ...> |> Oban.Met.Gauge.merge(gauge_2)
      ...> |> Oban.Met.Gauge.size()
      2

  Merging two gauges retains the latest value from the first gauge:

      iex> gauge_1 = Oban.Met.Gauge.new(1)
      ...> gauge_2 = Oban.Met.Gauge.new(2)
      ...> gauge_1
      ...> |> Oban.Met.Gauge.merge(gauge_2)
      ...> |> Oban.Met.Gauge.first()
      1
  """
  @spec merge(t(), t()) :: t()
  def merge(%Gauge{data: [latest | rest]}, %Gauge{data: data}) do
    %Gauge{data: [latest | rest ++ data]}
  end

  @doc """
  Compute the quantile value for a gauge.

  ## Examples

  With single values:

      iex> Oban.Met.Gauge.quantile(Oban.Met.Gauge.new(0), 1.0)
      0

      iex> Oban.Met.Gauge.quantile(Oban.Met.Gauge.new(1), 1.0)
      1

  With multiple values

      iex> gauge = Oban.Met.Gauge.new(Enum.to_list(1..100))
      ...>
      ...> assert Oban.Met.Gauge.quantile(gauge, 0.0) == 1
      ...> assert Oban.Met.Gauge.quantile(gauge, 0.5) == 50
      ...> assert Oban.Met.Gauge.quantile(gauge, 1.0) == 100
  """
  @spec quantile(t(), float()) :: integer()
  def quantile(%Gauge{data: [value]}, _), do: value

  def quantile(%Gauge{data: data}, quantile) when quantile >= 0 and quantile <= 1 do
    index = max(0, floor(length(data) * quantile) - 1)

    data
    |> Enum.sort()
    |> Enum.at(index)
  end

  @spec size(t()) :: non_neg_integer()
  def size(%Gauge{data: data}), do: length(data)
end
