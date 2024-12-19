# Installation

## Usage in Worker Only Nodes

To receive metrics from non-web nodes in a system with separate "web" and "worker" applications you must explicitly include oban_met as a dependency for "workers".

```elixir
# mix.exs
defp deps do
  [
    {:oban_met, "~> 0.1", repo: :oban},
    ...
```

## Auto Start

Supervised Met instances start automatically along with Oban instances unless Oban is in testing
mode. You can disable auto-starting globally with application configuration:

```elixir
config :oban_met, auto_start: false
```

Then, start instances as a child directly within your Oban app's plugins:

```elixir
plugins: [
  Oban.Met,
  ...
]
```

## Customizing Estimates

Options for internal `Oban.Met` processes can be overridden from the plugin specification. Most
options are internal and not meant to be overridden, but one particularly useful option to tune is
the `estimate_limit`. The `estimate_limit` determines at which point state/queue counts switch
from using an accurate `count(*)` call to a much more efficient, but less accurate, estiamte
function.

The default limit is a conservative 50k, which may be too low for systems with insert spikes. This
declares an override to set the limit to 200k:

```elixir
{Oban.Met, reporter: [estimate_limit: 200_000]}
```

## Explicit Migrations

Met will create the necessary estimate function automatically when possible. The migration isn't
necessary under normal circumstances, but is provided to avoid permission issues or allow full
control over database changes.

```bash
mix ecto.gen.migration add_oban_met
```

Open the generated migration and delegate the `up/0` and `down/0` functions to
`Oban.Met.Migration`:

```elixir
defmodule MyApp.Repo.Migrations.AddObanMet do
  use Ecto.Migration

  def up, do: Oban.Met.Migration.up()
  def down, do: Oban.Met.Migration.down()
end
```

Then, after disabling auto-start, configure the reporter not to auto-migrate if you run the
explicit migration:

```elixir
{Oban.Met, reporter: [auto_migrate: false]}
```
