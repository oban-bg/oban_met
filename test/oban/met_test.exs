defmodule Oban.MetTest do
  use Oban.Met.Case

  alias Oban.Met.Recorder
  alias Oban.Met.Values.Gauge
  alias Oban.Registry

  setup do
    start_supervised!({Oban, notifier: Oban.Notifiers.Isolated, repo: Oban.Met.Repo})

    name = Registry.via(Oban, Recorder)

    start_supervised!({Recorder, conf: Oban.config(), name: name})

    Recorder.store(name, :exec_count, Gauge.new(2), %{"queue" => "alpha"})
    Recorder.store(name, :exec_count, Gauge.new(3), %{"queue" => "gamma"})

    :ok
  end

  describe "default instance dispatch" do
    test "passing options without an instance name to labels/2" do
      assert ~w(alpha gamma) == Oban.Met.labels("queue", lookback: 60)
      assert Oban.Met.labels("queue", lookback: 60) == Oban.Met.labels(Oban, "queue")
    end

    test "passing options without an instance name to latest/2" do
      assert %{"alpha" => 2, "gamma" => 3} == Oban.Met.latest(:exec_count, group: "queue")
      assert %{"all" => 5} == Oban.Met.latest(Oban, :exec_count)
    end

    test "passing options without an instance name to timeslice/2" do
      assert [{_, 2, "alpha"} | _] = Oban.Met.timeslice(:exec_count, group: "queue")
      assert [{_, 5, nil}] = Oban.Met.timeslice(Oban, :exec_count)
    end
  end
end
