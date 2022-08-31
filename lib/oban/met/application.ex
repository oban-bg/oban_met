defmodule Oban.Met.Application do
  @moduledoc false

  use Application

  @handler_id :oban_met_handler
  @supervisor Oban.Met.AppSup

  @impl Application
  def start(_type, _args) do
    :telemetry.attach(@handler_id, [:oban, :supervisor, :init], &__MODULE__.init_metrics/4, [])

    Supervisor.start_link([], strategy: :one_for_one, name: @supervisor)
  end

  @impl Application
  def prep_stop(state) do
    :telemetry.detach(@handler_id)

    state
  end

  @doc false
  def init_metrics(_event, _measure, %{conf: conf}, _conf) do
    if Application.get_env(:oban_met, :auto_mode) and conf.testing == :disabled do
      Supervisor.start_child(@supervisor, {Oban.Met.Supervisor, conf: conf})
    end
  end
end
