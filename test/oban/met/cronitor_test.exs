defmodule Oban.Met.CronitorTest do
  use Oban.Met.Case, async: true

  alias Oban.Met.Cronitor
  alias Oban.Notifier

  @name Oban.Cronitor

  describe "sharing crontabs" do
    setup [:start_supervised_oban]

    test "sharing without any cron plugin", %{conf: conf} do
      start_supervised_cronitor(%{conf: conf})

      :ok = Notifier.listen(conf, :cronitor)
      :ok = GenServer.call(@name, :share)

      assert_receive {:notification, :cronitor, %{"crontab" => []}}
    end

    test "sharing crontab configuration with other nodes", %{conf: conf} do
      crontab = [
        {"0 * * * *", MyApp.WorkerA},
        {"1 * * * *", MyApp.WorkerB},
        {"2 * * * *", MyApp.WorkerC, args: %{mode: :foo}},
        {"3 * * * *", MyApp.WorkerC, args: %{mode: :bar}},
        {"4 * * * *", MyApp.WorkerD, priority: 3}
      ]

      start_supervised_cronitor(%{
        conf: %{conf | plugins: [{Oban.Plugins.Cron, crontab: crontab}]}
      })

      :ok = Notifier.listen(conf, :cronitor)
      :ok = GenServer.call(@name, :share)

      assert_receive {:notification, :cronitor, payload}
      assert %{"crontab" => crontab, "name" => _, "node" => "worker.1"} = payload

      assert [
               ["0 * * * *", "MyApp.WorkerA", []],
               ["1 * * * *", "MyApp.WorkerB", []],
               ["2 * * * *", "MyApp.WorkerC", [["args", %{"mode" => "foo"}]]],
               ["3 * * * *", "MyApp.WorkerC", [["args", %{"mode" => "bar"}]]],
               ["4 * * * *", "MyApp.WorkerD", [["priority", 3]]]
             ] == crontab
    end
  end

  describe "fetching merged crontabs" do
    setup [:start_supervised_oban, :start_supervised_cronitor]

    test "fetching all stored crontabs", %{conf: conf} do
      opts = [["args", %{"mode" => "foo"}]]

      share(conf, name: Oban, node: "web.1", crontab: [{"* * * * *", "Worker.A", []}])
      share(conf, name: Oban, node: "web.2", crontab: [{"* * * * *", "Worker.B", []}])
      share(conf, name: Oban, node: "web.3", crontab: [])
      share(conf, name: Oban, node: "web.1", crontab: [{"0 * * * *", "Worker.A", opts}])

      crontab = GenServer.call(@name, :merged_crontab)

      assert {"0 * * * *", "Worker.A", %{"args" => %{"mode" => "foo"}}} in crontab
      assert {"* * * * *", "Worker.B", %{}} in crontab
    end
  end

  defp share(conf, payload) do
    Notifier.notify(conf, :cronitor, Map.new(payload))
  end

  defp start_supervised_cronitor(%{conf: conf}) do
    pid = start_supervised!({Cronitor, conf: conf, name: @name, interval: 10, ttl: 1_000})

    {:ok, pid: pid}
  end
end
