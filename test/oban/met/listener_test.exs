defmodule Oban.Met.ListenerTest do
  use Oban.Met.Case, async: true

  alias Oban.Met.Listener
  alias Oban.Notifier

  @name Oban.Listener

  setup :start_supervised_oban

  describe "reporting" do
    test "reporting captured metrics", %{conf: conf} do
      pid = start_supervised!({Listener, conf: conf, name: @name})

      for _ <- 1..3, queue <- ~w(alpha gamma), worker <- ~w(A B C) do
        meta = %{conf: conf, job: %{queue: queue, worker: worker}, state: :success}

        :telemetry.execute([:oban, :job, :stop], %{duration: 100_000, queue_time: 10_000}, meta)
      end

      :ok = Notifier.listen(conf.name, [:gossip])
      :ok = Listener.report(pid)

      assert_receive {:notification, :gossip, %{"metrics" => _} = payload}

      assert %{"name" => _, "node" => "worker.1"} = payload
      assert %{"metrics" => metrics, "time" => _} = payload

      assert 18 == length(metrics)
      assert ~w(exec_count exec_time wait_time) = utake(metrics, "series")
      assert ~w(completed) = utake(metrics, "state")
      assert ~w(alpha gamma) = utake(metrics, "queue")
      assert ~w(A B C) = utake(metrics, "worker")
    end
  end

  defp utake(metrics, key) do
    metrics
    |> Enum.map(& &1[key])
    |> :lists.usort()
  end
end
