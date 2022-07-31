defmodule Oban.Met.SketchTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Oban.Met.Sketch

  doctest Oban.Met.Sketch

  property "all values are stored for quantile estimation" do
    check all values <- list_of(positive_integer(), min_length: 1) do
      sketch = Enum.reduce(values, Sketch.new(), &Sketch.insert(&2, &1))

      assert length(values) == Sketch.size(sketch)
      assert Sketch.quantile(sketch, 0.5) > 0
    end
  end
end
