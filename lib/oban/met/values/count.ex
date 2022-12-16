defmodule Oban.Met.Values.Count do
  @moduledoc """
  One or more non-negative integers captured over time.

  The difference between a `count` and a `gauge` is largely semantic. Counts may only increase,
  while gauges can increase or decrease.
  """

  alias __MODULE__, as: Count

  @derive Jason.Encoder
  defstruct data: 0

  @type t :: %__MODULE__{data: non_neg_integer()}

  @doc """
  Initialize a new count.

  ## Examples

      iex> Count.new(1).data
      1
  """
  @spec new(non_neg_integer()) :: t()
  def new(data) when is_integer(data) and data > 0 do
    %Count{data: data}
  end

  @doc """
  Add to the count.

  ## Examples

      iex> 1
      ...> |> Count.new()
      ...> |> Count.add(1)
      ...> |> Count.add(1)
      ...> |> Map.fetch!(:data)
      3
  """
  @spec add(t(), pos_integer()) :: t()
  def add(%Count{data: old_data}, value) when value > 0 do
    %Count{data: old_data + value}
  end

  @doc """
  Merges two counts into a one.

  ## Examples

  Merging two counts retains all values:

      iex> count_1 = Count.new(1)
      ...> count_2 = Count.new(2)
      ...> Count.merge(count_1, count_2).data
      3
  """
  @spec merge(t(), t()) :: t()
  def merge(%Count{data: data_1}, %Count{data: data_2}) do
    %Count{data: data_1 + data_2}
  end

  @doc """
  Compute the quantile for a count.

  ## Examples

  With single values:

      iex> Count.quantile(Count.new(1), 1.0)
      1

      iex> Count.quantile(Count.new(1), 0.5)
      1
  """
  @spec quantile(t(), float()) :: non_neg_integer()
  def quantile(%Count{data: data}, _), do: data

  @doc false
  @spec size(t()) :: non_neg_integer()
  def size(%Count{}), do: 1

  @doc """
  Initialize a count struct from a stringified map, e.g. encoded JSON.

  ## Examples

      iex> Count.new(2)
      ...> |> Jason.encode!()
      ...> |> Jason.decode!()
      ...> |> Count.from_map()
      ...> |> Map.fetch!(:data)
      2
  """
  @spec from_map(%{optional(String.t()) => term()}) :: t()
  def from_map(%{"data" => data}), do: %Count{data: data}
end
