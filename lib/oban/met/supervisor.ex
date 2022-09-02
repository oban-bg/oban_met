defmodule Oban.Met.Supervisor do
  @moduledoc false

  use Supervisor

  alias Oban.Registry
  alias Oban.Met.{Examiner, Recorder, Reporter}

  @spec child_spec(Keyword.t()) :: Supervisor.child_spec()
  def child_spec(opts) do
    conf = Keyword.fetch!(opts, :conf)
    name = Registry.via(conf.name, __MODULE__)

    opts
    |> super()
    |> Map.put(:id, name)
  end

  @spec start_link(Keyword.t()) :: Supervisor.on_start()
  def start_link(opts) when is_list(opts) do
    Supervisor.start_link(__MODULE__, opts, name: opts[:name])
  end

  # Callbacks

  @impl Supervisor
  def init(opts) do
    conf = Keyword.fetch!(opts, :conf)

    children = [
      {Examiner, conf: conf, name: Registry.via(conf.name, Examiner)},
      {Recorder, conf: conf, name: Registry.via(conf.name, Recorder)},
      {Reporter, conf: conf, name: Registry.via(conf.name, Reporter)}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
