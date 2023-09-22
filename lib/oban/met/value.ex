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
  def merge(struct_1, struct_2)

  @doc """
  Compute the quantile for a value.
  """
  def quantile(struct, quantile)

  @doc """
  Sum all data points for a value.
  """
  def sum(struct)

  @doc """
  Union two values by reducing them into one.
  """
  def union(struct_1, struct_2)
end

for module <- [Oban.Met.Values.Gauge, Oban.Met.Values.Sketch] do
  defimpl Oban.Met.Value, for: module do
    defdelegate add(struct, value), to: @for

    defdelegate merge(struct_1, struct_2), to: @for

    defdelegate quantile(struct, quantile), to: @for

    defdelegate sum(struct), to: @for

    defdelegate union(struct_1, struct_2), to: @for
  end
end
