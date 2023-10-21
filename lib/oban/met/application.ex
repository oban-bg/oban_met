defmodule Oban.Met.Application do
  @moduledoc false

  use Application

  require Logger

  @supervisor Oban.Met.AppSup
  @handler_id :oban_met_handler

  @impl Application
  def start(_type, _args) do
    :telemetry.attach(@handler_id, [:oban, :supervisor, :init], &__MODULE__.init_metrics/4, [])

    Supervisor.start_link([{Task, &boot_metrics/0}], strategy: :one_for_one, name: @supervisor)
  end

  @impl Application
  def prep_stop(state) do
    :telemetry.detach(@handler_id)

    state
  end

  @doc false
  def boot_metrics do
    Oban.Registry
    |> Registry.select([{{Oban, :_, :"$1"}, [], [:"$1"]}])
    |> Enum.each(&start_metrics/1)
  end

  @doc false
  def init_metrics(_event, _measure, %{conf: conf}, _conf) do
    start_metrics(conf)
  end

  defp start_metrics(conf) do
    opts = Application.get_all_env(:oban_met)

    if opts[:auto_start] and conf.testing in opts[:auto_testing_modes] do
      case Supervisor.start_child(@supervisor, {Oban.Met, conf: conf}) do
        {:ok, _pid} ->
          :ok

        {:error, {:already_started, _pid}} ->
          :ok

        {:error, {error, _stack}} ->
          Logger.error("Unable to start Oban.Met supervisor: #{inspect(error)}")
      end
    end
  end
end
