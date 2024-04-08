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
