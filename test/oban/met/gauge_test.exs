defmodule Oban.Met.GaugeTest do
  use ExUnit.Case, async: true

  use ExUnitProperties

  alias Oban.Met.Gauge

  doctest Gauge

  property "all values are stored for quantile estimation" do
    check all values <- list_of(integer(1..100), min_length: 1) do
      gauge = Gauge.new(values)

      assert Gauge.quantile(gauge, 0.0) >= 1
      assert Gauge.quantile(gauge, 1.0) <= 100
    end
  end
end
