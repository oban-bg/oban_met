defmodule Oban.Met.ReporterTest do
  use Oban.Met.Case

  alias Oban.Met.Reporter
  alias Oban.{Job, Notifier}

  @name Oban.Reporter

  setup :start_supervised_oban

  describe "reporting" do
    test "reporting queried counts", %{conf: conf} do
      pid = start_supervised!({Reporter, conf: conf, name: @name})

      changesets =
        for queue <- ~w(alpha gamma), worker <- ~w(Worker.A Worker.B) do
          Job.new(%{}, queue: queue, worker: worker)
        end

      Oban.insert_all(conf.name, changesets)

      :ok = Notifier.listen(conf.name, [:gossip])
      :ok = Reporter.checkpoint(pid)

      assert_receive {:notification, :gossip, payload}

      assert %{"name" => _, "node" => "worker.1"} = payload
      assert %{"metrics" => metrics, "time" => _} = payload

      assert ~w(available) = utake(metrics, "series")
      assert ~w(alpha gamma) = utake(metrics, "queue")
      assert ~w(Worker.A Worker.B) = utake(metrics, "worker")
    end
  end

  defp utake(metrics, key) do
    metrics
    |> Enum.map(& &1[key])
    |> :lists.usort()
  end
end
