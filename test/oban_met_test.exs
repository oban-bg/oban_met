defmodule Oban.MetTest do
  use ExUnit.Case, async: true

  @event [:oban, :supervisor, :init]

  describe "initializing storage" do
    test "starting storage servers for oban instances on :init" do
      for name <- [Oban.A, Oban.B, Oban.C, Oban.A] do
        :telemetry.execute(@event, %{}, %{conf: %{name: name}})
      end

      assert %{active: 3} = Supervisor.count_children(Oban.Met.Supervisor)
    end
  end
end
