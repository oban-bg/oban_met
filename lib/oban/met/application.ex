defmodule Oban.Met.Application do
  @moduledoc false

  use Application

  require Logger

  @main_sup Oban.Met.Supervisor
  @task_sup Oban.Met.TaskSupervisor
  @handler_id :oban_met_handler

  @impl Application
  def start(_type, _args) do
    :telemetry.attach(@handler_id, [:oban, :supervisor, :init], &__MODULE__.init_metrics/4, [])

    children = [
      {Task.Supervisor, name: @task_sup},
      {Task, &boot_metrics/0}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: @main_sup)
  end

  @impl Application
  def prep_stop(state) do
    :telemetry.detach(@handler_id)

    state
  end

  @doc false
  def init_metrics(_event, _measure, %{conf: conf}, _conf) do
    start_metrics(conf)
  end

  @doc false
  def boot_metrics do
    Oban.Registry
    |> Registry.select([{{Oban, :_, :"$1"}, [], [:"$1"]}])
    |> Enum.each(&start_metrics/1)
  end

  defp start_metrics(conf) do
    opts = Application.get_all_env(:oban_met)

    if opts[:auto_start] and conf.testing in opts[:auto_testing_modes] do
      spec = Oban.Met.child_spec(conf: conf)

      case Supervisor.start_child(@main_sup, spec) do
        {:ok, _pid} ->
          Task.Supervisor.start_child(@task_sup, fn -> watch_oban(spec, conf) end)

          :ok

        {:error, {:already_started, _pid}} ->
          :ok

        {:error, {error, _stack}} ->
          Logger.error("Unable to start Oban.Met supervisor: #{inspect(error)}")
      end
    end
  end

  defp watch_oban(%{id: child_id}, conf) do
    ref =
      conf.name
      |> Oban.whereis()
      |> Process.monitor()

    receive do
      {:DOWN, ^ref, :process, _pid, _reason} ->
        Process.demonitor(ref, [:flush])

        with :ok <- Supervisor.terminate_child(@main_sup, child_id) do
          Supervisor.delete_child(@main_sup, child_id)
        end
    end
  end
end
