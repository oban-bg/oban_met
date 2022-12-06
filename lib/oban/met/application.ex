defmodule Oban.Met.Application do
  @moduledoc false

  use Application

  @supervisor Oban.Met.AppSup
  @handler_id :oban_met_handler

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
    opts = Application.get_all_env(:oban_met)

    if opts[:auto_start] and conf.testing in opts[:auto_testing_modes] do
      Supervisor.start_child(@supervisor, {Oban.Met, conf: conf})
    end
  end
end
