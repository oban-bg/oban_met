defmodule Oban.Met.ExaminerTest do
  use Oban.Met.Case, async: false

  alias Oban.Met.Examiner
  alias Oban.{Notifier, Registry}

  @name Oban.Examiner

  defmodule FakeProducer do
    use GenServer

    def child_spec(opts) do
      opts
      |> super()
      |> Map.put(:id, opts[:name])
    end

    def start_link(opts) do
      GenServer.start_link(__MODULE__, opts, name: opts[:name])
    end

    @impl GenServer
    def init(opts), do: {:ok, Map.new(opts)}

    @impl GenServer
    def handle_call(:check, _, state) do
      case state do
        %{kill: true} -> Process.exit(self(), :kill)
        %{slow: true} -> Process.sleep(20)
        _ -> :ok
      end

      {:reply, state, state}
    end
  end

  describe "fetching checks" do
    setup [:start_supervised_oban, :start_supervised_gossiper]

    test "fetching all stored checks" do
      store(name: Oban, node: "web.1", queue: "alpha", limit: 4)
      store(name: Oban, node: "web.2", queue: "alpha", limit: 4)
      store(name: Oban, node: "web.1", queue: "gamma", limit: 5)

      checks = Examiner.all_checks(@name)

      assert_in(checks, %{"node" => "web.1", "limit" => 4, "queue" => "alpha"})
      assert_in(checks, %{"node" => "web.2", "limit" => 4, "queue" => "alpha"})
    end
  end

  describe "expiring checks" do
    setup [:start_supervised_oban, :start_supervised_gossiper]

    test "older checks are automatically purged" do
      ts = System.system_time(:millisecond)

      store(%{name: Oban, node: "web.1", queue: "alpha", limit: 5}, timestamp: ts - 1900)
      store(%{name: Oban, node: "web.1", queue: "delta", limit: 5}, timestamp: ts - 2100)

      Examiner.purge(@name, :timer.seconds(2))

      assert [check] = Examiner.all_checks(@name)

      assert %{"node" => "web.1", "limit" => 5, "queue" => "alpha"} = check
    end
  end

  describe "broadcasting checks" do
    setup [:start_supervised_oban, :start_supervised_gossiper]

    test "queue producers periodically emit check meta as gossip", %{conf: conf} do
      :ok = Notifier.listen(conf.name, [:gossip])

      alpha_name = Registry.via(conf.name, {:producer, :alpha})
      omega_name = Registry.via(conf.name, {:producer, :omega})

      start_supervised!({FakeProducer, queue: "alpha", name: alpha_name, node: Oban})
      start_supervised!({FakeProducer, queue: "omega", name: omega_name, node: Oban})

      Process.sleep(10)

      assert_receive {:notification, :gossip, %{"checks" => checks}}

      assert [%{"queue" => _}, %{"queue" => _}] = checks
    end

    test "slow producer checks don't crash gossip", %{conf: conf} do
      :ok = Notifier.listen(conf.name, [:gossip])

      fine_name = Registry.via(conf.name, {:producer, :fine})
      slow_name = Registry.via(conf.name, {:producer, :slow})
      kill_name = Registry.via(conf.name, {:producer, :kill})

      start_supervised!({FakeProducer, name: fine_name, node: Oban, queue: "fine"})
      start_supervised!({FakeProducer, name: slow_name, node: Oban, queue: "slow", slow: true})
      start_supervised!({FakeProducer, name: kill_name, node: Oban, queue: "kill", kill: true})

      Process.sleep(10)

      assert_receive {:notification, :gossip, %{"checks" => [%{"queue" => "fine"}]}}
    end

    test "broadcast checks are stored", %{pid: pid} do
      checks = [
        %{name: Oban, node: "web.1", queue: "alpha", limit: 5},
        %{name: Oban, node: "web.1", queue: "gamma", limit: 5},
        %{name: Oban, node: "web.1", queue: "delta", limit: 5}
      ]

      payload =
        %{checks: checks}
        |> Jason.encode!()
        |> Jason.decode!()

      send(pid, {:notification, :gossip, payload})

      Process.sleep(10)

      checks = Examiner.all_checks(@name)

      assert length(checks) == 3
    end
  end

  defp start_supervised_gossiper(%{conf: conf}) do
    pid = start_supervised!({Examiner, conf: conf, name: @name, interval: 10, ttl: 1_000})

    {:ok, pid: pid}
  end

  defp store(check, opts \\ []) do
    payload =
      check
      |> Map.new()
      |> Jason.encode!()
      |> Jason.decode!()

    Examiner.store(@name, payload, opts)
  end

  defp assert_in(list, payload) do
    keys = Map.keys(payload)
    vals = Enum.map(list, &Map.take(&1, keys))

    assert payload in vals
  end
end
