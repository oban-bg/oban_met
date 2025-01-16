# Oban Met

<p align="center">
  <a href="https://hex.pm/packages/oban_met">
    <img alt="Hex Version" src="https://img.shields.io/hexpm/v/oban_met.svg" />
  </a>

  <a href="https://hexdocs.pm/oban_met">
    <img alt="Hex Docs" src="http://img.shields.io/badge/hex.pm-docs-green.svg?style=flat" />
  </a>

  <a href="https://github.com/oban-bg/oban_met/actions">
    <img alt="CI Status" src="https://github.com/oban-bg/oban_met/actions/workflows/ci.yml/badge.svg" />
  </a>

  <a href="https://opensource.org/licenses/Apache-2.0">
    <img alt="Apache 2 License" src="https://img.shields.io/hexpm/l/oban_met" />
  </a>
</p>

<!-- MDOC -->

Met is a distributed, compacting, multidimensional, telemetry-powered time series datastore for
Oban that requires no configuration. It gathers data for queues, job counts, execution metrics,
active crontabs, historic metrics, and more.

Met powers the charts and runtime details shown in the [Oban Web][web] dashboard.

[web]: https://github.com/oban-bg/oban_web

## Features

- **🤖 Autonomous** - Supervises a collection of autonomous modules that dynamically start and stop alongside
  Oban instances without any code changes.

- **🎩 Distributed** - Metrics are shared between all connected nodes via pubsub. Leadership is used
  to restrict expensive operations, such as performing counts, to a single node.

- **📼 Recorded** - Telemetry events and scraped data are stored in-memory as time series data.
  Values are stored as either gauges or space efficient "sketches".

- **🪐 Multidimensional** - Metrics are stored with labels such as `node`, `queue`, `worker`, etc.
  that can be filtered and grouped dynamically at runtime.

- **🗜️ Compacting** - Time series values are periodically compacted into larger windows of time to
  save space and optimize querying historic data. Compaction periods use safe defaults, but are
  configurable.

- **✏️ Estimating** - In supporting systems (Postgres), count queries use optimized estimates
  automatically for tables with a large number of jobs.

- **🔎 Queryable** - Historic metrics may be filtered and grouped by any label, sliced by
  arbitrary time intervals, and numeric values aggregated at dynamic percentiles (e.g. P50, P99)
  without pre-computed histogram buckets.

- **🤝 Handoff** - Ephemeral data storage via data replication with handoff between nodes. All nodes have a
  shared view of the cluster's data and new nodes are caught up when they come online.

## Installation

Oban Met is included with Oban Web and manual installation is only necessary in hybrid
environments (separate Web and Worker nodes).

To receive metrics from non-web nodes in a system with separate "web" and "worker" applications
you must explicitly include `oban_met` as a dependency for "workers".

```elixir
{:oban_met, "~> 1.0"}
```

## Usage

No configuration is necessary and Oban Met will start automatically in a typical application. A
variety of options are provided for more complex or nuanced usage.

### Auto Start

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

### Customizing Estimates

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

### Explicit Migrations

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

<!-- MDOC -->

## Contributing

To run the test suite you must have PostgreSQL 12+. Once dependencies are installed, setup the
databases and run necessary migrations:

```bash
mix test.setup
```

## Community

There are a few places to connect and communicate with other Oban users:

- Ask questions and discuss *#oban* on the [Elixir Forum][forum]
- [Request an invitation][invite] and join the *#oban* channel on Slack
- Learn about bug reports and upcoming features in the [issue tracker][issues]

[invite]: https://elixir-slack.community/
[forum]: https://elixirforum.com/
[issues]: https://github.com/sorentwo/oban/issues
