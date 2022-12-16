defmodule Oban.Met.Values.SketchTest do
  use ExUnit.Case, async: true

  use ExUnitProperties

  alias Oban.Met.Values.Sketch

  doctest Sketch

  property "all values are stored for quantile estimation" do
    check all values <- list_of(positive_integer(), min_length: 1) do
      sketch = Sketch.new(values)

      assert length(values) == Sketch.size(sketch)
      assert Sketch.quantile(sketch, 0.5) > 0
    end
  end

  property "encoded and decoded sketches retain the same values" do
    check all values <- list_of(positive_integer(), min_length: 1) do
      sketch = Sketch.new(values)

      size = Sketch.size(sketch)
      min = Sketch.quantile(sketch, 0.0)
      med = Sketch.quantile(sketch, 0.5)
      max = Sketch.quantile(sketch, 1.0)

      sketch =
        sketch
        |> Jason.encode!()
        |> Jason.decode!()
        |> Sketch.from_map()

      assert size == Sketch.size(sketch)
      assert min == Sketch.quantile(sketch, 0.0)
      assert med == Sketch.quantile(sketch, 0.5)
      assert max == Sketch.quantile(sketch, 1.0)
    end
  end
end
