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
