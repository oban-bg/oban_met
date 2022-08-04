defmodule Oban.Met.Sketch do
  @moduledoc """
  Derived from [DogSketch](https://github.com/moosecodebv/dog_sketch), based on DDSketch.
  """

  @type t :: %__MODULE__{
          data: %{optional(pos_integer()) => pos_integer()},
          size: non_neg_integer(),
          gamma: non_neg_integer(),
          inv_log_gamma: non_neg_integer()
        }

  alias __MODULE__, as: Sketch

  @derive Jason.Encoder
  defstruct data: %{}, gamma: 0, inv_log_gamma: 0, size: 0

  @doc """
  Create a new sketch instance with an optional error rate.

  ## Examples

      iex> sketch = Oban.Met.Sketch.new()
      ...> Oban.Met.Sketch.size(sketch)
      0
  """
  @spec new(error: float()) :: t()
  def new(opts \\ [error: 0.02]) do
    error = Keyword.fetch!(opts, :error)
    gamma = (1 + error) / (1 - error)
    inv_log_gamma = 1.0 / :math.log(gamma)

    %Sketch{gamma: gamma, inv_log_gamma: inv_log_gamma}
  end

  @doc """
  Merge two sketch instances with a common error rate.

  ## Examples

      iex> sketch_1 = Oban.Met.Sketch.new()
      ...> sketch_1 = Oban.Met.Sketch.insert(sketch_1, 1)
      ...>
      ...> Oban.Met.Sketch.new()
      ...> |> Oban.Met.Sketch.insert(2)
      ...> |> Oban.Met.Sketch.merge(sketch_1)
      ...> |> Oban.Met.Sketch.size()
      2
  """
  @spec merge(t(), t()) :: t()
  def merge(%Sketch{} = sketch_1, %Sketch{} = sketch_2) do
    data = Map.merge(sketch_1.data, sketch_2.data, fn _, val_1, val_2 -> val_1 + val_2 end)

    %Sketch{sketch_1 | data: data, size: sketch_1.size + sketch_2.size}
  end

  @doc """
  Insert sample values into a sketch.

  ## Examples

      iex> Oban.Met.Sketch.new()
      ...> |> Oban.Met.Sketch.insert(1)
      ...> |> Oban.Met.Sketch.insert(2)
      ...> |> Oban.Met.Sketch.insert(3)
      ...> |> Oban.Met.Sketch.size()
      3
  """
  @spec insert(t(), pos_integer()) :: t()
  def insert(%Sketch{} = sketch, value) when is_integer(value) and value > 0 do
    bin = ceil(:math.log(value) * sketch.inv_log_gamma)
    data = Map.update(sketch.data, bin, 1, &(&1 + 1))

    %Sketch{sketch | data: data, size: sketch.size + 1}
  end

  @doc """
  Compute the quantile value for a sketch.

  ## Examples

  Without any values:

      iex> Oban.Met.Sketch.quantile(Oban.Met.Sketch.new(), 0.5)
      nil

  With recorded values:

      iex> Oban.Met.Sketch.new()
      ...> |> Oban.Met.Sketch.insert(1)
      ...> |> Oban.Met.Sketch.insert(2)
      ...> |> Oban.Met.Sketch.insert(3)
      ...> |> Oban.Met.Sketch.quantile(0.5)
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

    2 * :math.pow(sketch.gamma, index) / (sketch.gamma + 1)
  end

  @doc """
  Convert a sketch into a list of bins and values.

  ## Examples

      iex> Oban.Met.Sketch.new()
      ...> |> Oban.Met.Sketch.insert(1)
      ...> |> Oban.Met.Sketch.insert(2)
      ...> |> Oban.Met.Sketch.insert(3)
      ...> |> Oban.Met.Sketch.to_list()
      ...> |> length()
      3
  """
  @spec to_list(t()) :: [float()]
  def to_list(%Sketch{data: data, gamma: gamma}) do
    for {key, val} <- data, do: {2 * :math.pow(gamma, key) / (gamma + 1), val}
  end

  @doc false
  @spec size(t()) :: non_neg_integer()
  def size(%Sketch{size: size}), do: size

  @doc """
  Initialize a sketch struct from a stringified map, e.g. encoded JSON.

  ## Examples

      iex> Oban.Met.Sketch.new()
      ...> |> Oban.Met.Sketch.insert(1)
      ...> |> Oban.Met.Sketch.insert(2)
      ...> |> Jason.encode!()
      ...> |> Jason.decode!()
      ...> |> Oban.Met.Sketch.from_map()
      ...> |> Oban.Met.Sketch.size()
      2
  """
  @spec from_map(%{optional(String.t()) => term()}) :: t()
  def from_map(%{"data" => data, "gamma" => gamma, "inv_log_gamma" => inv, "size" => size}) do
    %Sketch{data: data, gamma: gamma, inv_log_gamma: inv, size: size}
  end
end
