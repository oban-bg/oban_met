defmodule Oban.Met.Values.Sketch do
  @moduledoc """
  A fast and fully mergeable quantile sketch with relative error guarantees.

  Derived from [DogSketch](https://github.com/moosecodebv/dog_sketch), based on DDSketch. This
  variant has a hard-coded error rate of 0.02 for the sake of simplicity.
  """

  alias __MODULE__, as: Sketch

  @type t :: %__MODULE__{
          data: %{optional(pos_integer()) => pos_integer()},
          size: non_neg_integer()
        }

  @derive Jason.Encoder
  defstruct data: %{}, size: 0

  @error 0.02
  @gamma (1 + @error) / (1 - @error)
  @inv_log_gamma 1.0 / :math.log(@gamma)

  @doc """
  Create a new sketch instance with an optional error rate.

  ## Examples

      iex> sketch = Sketch.new()
      ...> Sketch.size(sketch)
      0

      iex> sketch = Sketch.new(1)
      ...> Sketch.size(sketch)
      1

      iex> sketch = Sketch.new([1, 2, 3])
      ...> Sketch.size(sketch)
      3
  """
  @spec new(pos_integer() | [pos_integer()]) :: t()
  def new(values \\ []) do
    values
    |> List.wrap()
    |> Enum.reduce(%Sketch{}, &add(&2, &1))
  end

  @doc """
  Insert sample values into a sketch.

  ## Examples

      iex> Sketch.new()
      ...> |> Sketch.add(1)
      ...> |> Sketch.add(2)
      ...> |> Sketch.add(3)
      ...> |> Sketch.size()
      3
  """
  @spec add(t(), pos_integer()) :: t()
  def add(%Sketch{} = sketch, value) when is_integer(value) and value > 0 do
    bin = ceil(:math.log(value) * @inv_log_gamma)
    data = Map.update(sketch.data, bin, 1, &(&1 + 1))

    %Sketch{sketch | data: data, size: sketch.size + 1}
  end

  @doc """
  Merge two sketch instances.

  ## Examples

      iex> sketch_1 = Sketch.new([1])
      ...>
      ...> Sketch.new([2])
      ...> |> Sketch.merge(sketch_1)
      ...> |> Sketch.size()
      2
  """
  @spec merge(t(), t()) :: t()
  def merge(%Sketch{} = sketch_1, %Sketch{} = sketch_2) do
    data = Map.merge(sketch_1.data, sketch_2.data, fn _, val_1, val_2 -> val_1 + val_2 end)

    %Sketch{sketch_1 | data: data, size: sketch_1.size + sketch_2.size}
  end

  @doc """
  Compute the quantile value for a sketch.

  ## Examples

  Without any values:

      iex> Sketch.quantile(Sketch.new(), 0.5)
      nil

  With recorded values:

      iex> Sketch.new()
      ...> |> Sketch.add(1)
      ...> |> Sketch.add(2)
      ...> |> Sketch.add(3)
      ...> |> Sketch.quantile(0.5)
      ...> |> trunc()
      2
  """
  @spec quantile(t(), float()) :: nil | float()
  def quantile(%Sketch{size: 0}, _ntile), do: nil

  def quantile(sketch, quantile) when quantile >= 0 and quantile <= 1 do
    size_ntile = sketch.size * quantile

    index =
      sketch.data
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.reduce_while(0, fn {key, val}, size ->
        if size + val >= size_ntile do
          {:halt, key}
        else
          {:cont, size + val}
        end
      end)

    2 * :math.pow(@gamma, index) / (@gamma + 1)
  end

  @doc """
  Compute the sum for a sketch. Hardcoded to 0.

  ## Examples

      iex> Sketch.sum(Sketch.new([1, 2, 3, 3]))
      0.0
  """
  @spec sum(t()) :: float()
  def sum(%Sketch{data: _data}), do: 0.0

  @doc """
  Union two sketches into a single value. This is an alias for `merge/2`.
  """
  @spec union(t(), t()) :: t()
  def union(sketch_1, sketch_2), do: merge(sketch_1, sketch_2)

  @doc """
  Convert a sketch into a list of bins and values.

  ## Examples

      iex> Sketch.new()
      ...> |> Sketch.add(1)
      ...> |> Sketch.add(2)
      ...> |> Sketch.add(3)
      ...> |> Sketch.to_list()
      ...> |> length()
      3
  """
  @spec to_list(t()) :: [float()]
  def to_list(%Sketch{data: data}) do
    for {key, val} <- data, do: {2 * :math.pow(@gamma, key) / (@gamma + 1), val}
  end

  @doc false
  @spec size(t()) :: non_neg_integer()
  def size(%Sketch{size: size}), do: size

  @doc """
  Initialize a sketch struct from a stringified map, e.g. encoded JSON.

  ## Examples

      iex> Sketch.new([1, 2])
      ...> |> Jason.encode!()
      ...> |> Jason.decode!()
      ...> |> Sketch.from_map()
      ...> |> Sketch.quantile(1.0)
      ...> |> floor()
      2
  """
  @spec from_map(%{optional(String.t()) => term()}) :: t()
  def from_map(%{"data" => data, "size" => size}) do
    data = Map.new(data, fn {key, val} -> {String.to_integer(key), val} end)

    %Sketch{data: data, size: size}
  end
end
