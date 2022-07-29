defmodule Oban.Met.Application do
  @moduledoc false

  use Application

  alias Oban.Met.Storage

  @handler_id :oban_met_handler
  @supervisor Oban.Met.Supervisor

  @impl Application
  def start(_type, _args) do
    :telemetry.attach(@handler_id, [:oban, :supervisor, :init], &__MODULE__.init_storage/4, [])

    Supervisor.start_link([], strategy: :one_for_one, name: @supervisor)
  end

  @impl Application
  def prep_stop(state) do
    :telemetry.detach(@handler_id)

    state
  end

  @doc false
  def init_storage(_event, _measure, %{conf: conf}, _conf) do
    name = Oban.Registry.via(conf.name, Storage)

    Supervisor.start_child(@supervisor, {Storage, conf: conf, name: name})
  end
end
