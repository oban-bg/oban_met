defmodule Oban.Met.ReporterTest do
  use Oban.Met.Case

  alias Oban.Notifier
  alias Oban.Met.Reporter

  @name Oban.Reporter

  setup :start_supervised_oban

  describe "reporting" do
    test "reporting captured metrics", %{conf: conf} do
      pid = start_supervised!({Reporter, conf: conf, name: @name})

      for _ <- 1..3, queue <- ~w(alpha gamma), worker <- ~w(A B C) do
        meta = %{conf: conf, job: %{queue: queue, worker: worker}}

        :telemetry.execute([:oban, :job, :stop], %{duration: 100_000, queue_time: 10_000}, meta)
      end

      :ok = Notifier.listen(conf.name, [:gossip])
      :ok = Reporter.report(pid)

      assert_receive {:notification, :gossip, payload}

      assert %{"name" => _, "node" => "worker.1"} = payload
      assert %{"metrics" => metrics, "time" => _} = payload

      assert 12 == length(metrics)
      assert ~w(exec_time wait_time) = utake(metrics, "series")
      assert ~w(alpha gamma) = utake(metrics, "queue")
      assert ~w(A B C) = utake(metrics, "worker")
      assert [%{"value" => %{"size" => 3}} | _] = metrics
    end
  end

  defp utake(metrics, key) do
    metrics
    |> Enum.map(& &1[key])
    |> :lists.usort()
  end
end
