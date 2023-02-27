defmodule Oban.Met.Values.Gauge do
  @moduledoc """
  One or more non-negative integers captured over time.
  """

  alias __MODULE__, as: Gauge

  @derive Jason.Encoder
  defstruct data: 0

  @type t :: %__MODULE__{data: non_neg_integer()}

  @doc """
  Initialize a new gauge.

  ## Examples

      iex> Gauge.new(1).data
      1
  """
  @spec new(non_neg_integer()) :: t()
  def new(data) when is_integer(data) and data > 0 do
    %Gauge{data: data}
  end

  @doc """
  Add to the gauge.

  ## Examples

      iex> 1
      ...> |> Gauge.new()
      ...> |> Gauge.add(1)
      ...> |> Gauge.add(1)
      ...> |> Map.fetch!(:data)
      3
  """
  @spec add(t(), pos_integer()) :: t()
  def add(%Gauge{data: old_data}, value) when value > 0 do
    %Gauge{data: old_data + value}
  end

  @doc """
  Merges two gauge into a one.

  ## Examples

  Merging two gauge retains all values:

      iex> gauge_1 = Gauge.new(1)
      ...> gauge_2 = Gauge.new(2)
      ...> Gauge.merge(gauge_1, gauge_2).data
      3
  """
  @spec merge(t(), t()) :: t()
  def merge(%Gauge{data: data_1}, %Gauge{data: data_2}) do
    %Gauge{data: data_1 + data_2}
  end

  @doc """
  Compute the quantile for a gauge.

  ## Examples

  With single values:

      iex> Gauge.quantile(Gauge.new(1), 1.0)
      1

      iex> Gauge.quantile(Gauge.new(1), 0.5)
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
      ...> |> Map.fetch!(:data)
      2
  """
  @spec from_map(%{optional(String.t()) => term()}) :: t()
  def from_map(%{"data" => data}), do: %Gauge{data: data}
end
