defmodule Oban.Met.ReporterTest do
  use Oban.Met.Case

  use ExUnitProperties

  alias Oban.Met.Reporter
  alias Oban.{Job, Notifier}

  @name Oban.Reporter

  setup :start_supervised_oban

  describe "check_backoff/1" do
    test "increasing the backoff period for higher counts" do
      assert 1 = Reporter.check_backoff(0)
      assert 1 = Reporter.check_backoff(10)
      assert 1 = Reporter.check_backoff(100)
      assert 1 = Reporter.check_backoff(1000)

      assert 27 = Reporter.check_backoff(10_000)
      assert 81 = Reporter.check_backoff(100_000)
      assert 243 = Reporter.check_backoff(1_000_000)
      assert 729 = Reporter.check_backoff(10_000_000)
      assert 900 = Reporter.check_backoff(100_000_000)

      check all count <- positive_integer() do
        value = Reporter.check_backoff(count)

        assert value > 0
        assert value < 1800
      end
    end
  end

  describe "checkups" do
    @tag oban_opts: [peer: Oban.Peers.Isolated, testing: :disabled]
    test "reporting queried counts", %{conf: conf} do
      pid = start_supervised!({Reporter, conf: conf, name: @name})

      changesets =
        for queue <- ~w(alpha gamma), worker <- ~w(Worker.A Worker.B) do
          Job.new(%{}, queue: queue, worker: worker)
        end

      Oban.insert_all(conf.name, changesets)

      Notifier.listen(conf.name, [:gossip])
      send(pid, :checkpoint)

      assert_receive {:notification, :gossip, payload}

      assert %{"name" => _, "node" => "worker.1"} = payload
      assert %{"metrics" => metrics, "time" => _} = payload

      assert ~w(full_count) = utake(metrics, "series")
      assert ~w(available) = utake(metrics, "state")
      assert ~w(alpha gamma) = utake(metrics, "queue")
    end

    @tag oban_opts: [peer: Oban.Peers.Disabled]
    test "skipping checks when the instance is a follower", %{conf: conf} do
      pid = start_supervised!({Reporter, conf: conf, name: @name})

      Notifier.listen(conf.name, [:gossip])
      send(pid, :checkpoint)

      refute_receive {:notification, :gossip, _}
    end
  end

  defp utake(metrics, key) do
    metrics
    |> Enum.map(& &1[key])
    |> :lists.usort()
  end
end
