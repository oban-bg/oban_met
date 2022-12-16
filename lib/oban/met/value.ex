defprotocol Oban.Met.Value do
  @moduledoc """
  Tracked data access functions.
  """

  @doc """
  Add or append a new value to the data type.
  """
  def add(struct, value)

  @doc """
  Merge two values into one.
  """
  def merge(struct_a, struct_b)

  @doc """
  Compute the quantile for a value.
  """
  def quantile(struct, quantile)

  @doc """
  Get the size of the stored data.
  """
  def size(struct)
end

for module <- [Oban.Met.Values.Count, Oban.Met.Values.Gauge, Oban.Met.Values.Sketch] do
  defimpl Oban.Met.Value, for: module do
    defdelegate add(value, integer), to: @for

    defdelegate merge(value_1, value_2), to: @for

    defdelegate quantile(value, quantile), to: @for

    defdelegate size(value), to: @for
  end
end
