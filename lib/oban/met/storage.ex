defmodule Oban.Met.Storage do
  use GenServer

  @doc false
  def child_spec(opts) do
    opts
    |> super()
    |> Supervisor.child_spec(id: Keyword.get(opts, :name, __MODULE__))
  end

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl GenServer
  def init(_opts) do
    {:ok, []}
  end
end
