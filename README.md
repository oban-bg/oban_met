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
  shared view of the cluster's data and, with the `Oban.Notifiers.PG` notifier, new nodes are
  caught up when they come online.

## Installation

Oban Met is included with Oban Web and manual installation is only necessary in hybrid
environments (separate Web and Worker nodes).

To receive metrics from non-web nodes in a system with separate "web" and "worker" applications
you must explicitly include `oban_met` as a dependency for "workers".

```elixir
{:oban_met, "~> 1.3"}
```

Met requires Oban v2.23 or later.

## Usage

No configuration is necessary and Oban Met will start automatically in a typical application. A
variety of options are provided for more complex or nuanced usage.

### Querying Metrics

Met records four series, each labeled by `node`, `queue`, and `state`, and the job series also by
`worker`:

* `exec_count` - a gauge of jobs that finished executing each second, labeled by their state after
  execution, e.g. `completed` or `retryable`
* `exec_time` - a sketch of job execution times
* `wait_time` - a sketch of how long jobs waited in the queue before executing
* `full_count` - a gauge of jobs in the database, counted periodically by the leader node

Use `Oban.Met.latest/3` for current values and `Oban.Met.timeslice/3` for history, filtered and
grouped by any label:

```elixir
Oban.Met.latest(:full_count, group: "state")
%{"available" => 9, "completed" => 80, "executing" => 5}

Oban.Met.timeslice(:exec_time, by: 5, group: "queue", operation: {:pct, 0.95})
[{11, 9970235387.03, "analysis"}, ..., {0, 1520977874.33, "events"}]
```

Producer checks from every node are available through `Oban.Met.checks/1`, and the merged crontab
from every node through `Oban.Met.crontab/1`.

### Configuration

Met starts without configuration, but every supervised component accepts options that may be
provided two ways:

* Through the **application environment**, where they apply to all Oban instances:

  ```elixir
  config :oban_met, reporter: [estimate_limit: 200_000]
  ```

* Through the **plugin specification**, where they apply to a single instance and take precedence
  over the application environment:

  ```elixir
  {Oban.Met, reporter: [estimate_limit: 200_000]}
  ```

Options are namespaced by component: `:cronitor`, `:examiner`, `:listener`, `:recorder`, and
`:reporter`. Most are internal and best left alone, but the sections below cover the options worth
tuning.

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

By default Met only starts when Oban's `:testing` mode is `:disabled`. To run Met under a specific
testing mode, for example to inspect metrics during `:manual` tests, add the mode to
`:auto_testing_modes`:

```elixir
config :oban_met, auto_testing_modes: [:disabled, :manual]
```

### Customizing Estimates

The `estimate_limit` determines when counts switch from an accurate `count(*)` query to a much more
efficient, but less accurate, estimate function. The limit applies to each state's total across all
queues: once a state reaches the limit, its count for every queue is estimated on the following
checks. Estimates are only available on Postgres, and other databases always use exact counts.

The default limit is a conservative 50k, which may be too low for systems with insert spikes. This
declares an override to set the limit to 200k:

```elixir
{Oban.Met, reporter: [estimate_limit: 200_000]}
```

### Customizing Check Interval

The reporter periodically counts jobs in each state/queue combination to provide the counts
displayed in Oban Web. By default, counts are checked every 1 second. For systems where real-time
counts aren't critical, or to reduce database load, you can increase the interval:

```elixir
{Oban.Met, reporter: [check_interval: :timer.seconds(5)]}
```

The list of queues used for estimates is refreshed every 60 checks, so newly added queues may take
longer to appear in estimated counts with a longer interval.

### Explicit Migrations

Met will create the necessary estimate function automatically when possible. The migration isn't
necessary under normal circumstances, but is provided to avoid permission issues or allow full
control over database changes. If the database role Met connects with can't create or replace the
function, counts fail on every check and the error is logged until the migration is used instead.

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

Pass a `:prefix` to both functions, e.g. `Oban.Met.Migration.up(prefix: "private")`, when Oban
runs in an alternate prefix.

Then configure the reporter not to auto-migrate:

```elixir
config :oban_met, reporter: [auto_migrate: false]
```

### Customizing the Estimate Function

By default the reporter installs and calls the built-in PostgreSQL `oban_count_estimate` function.
On other Postgres-compatible engines that can't run that definition (e.g. CockroachDB) you can
supply your own `(prefix -> ddl)` builder and keep `auto_migrate` enabled. The returned DDL must
create a `<prefix>.oban_count_estimate(state text, queue text)` function returning an integer estimate:

```elixir
{Oban.Met, reporter: [estimate_function: &MyApp.ObanEstimate.build/1]}
```

### Compaction Periods

Recorded metrics are periodically compacted into coarser windows to bound memory use. Each period
is a `{step, duration}` tuple in seconds, where `step` is the resolution and `duration` is how long
values are retained at that resolution, after the periods before it. The defaults keep about three
and a half hours of history:

```elixir
{Oban.Met, recorder: [compact_periods: [{1, 120}, {5, 900}, {30, 2_000}, {60, 9_300}]]}
```

> #### Web Charts {: .neutral}
>
> Oban Web's charts are rendered from these recorded metrics. Drastically shortening the periods
> reduces the history available to plot and may impact chart rendering.

### Sketch Time Unit

Timing metrics (execution time, queue time) are stored in space-efficient quantile sketches. By
default, values are recorded in `:native` time units (nanoseconds on most systems), which provides
maximum precision but uses more space.

For reduced storage size (~20% smaller) and better bin consolidation, you can configure sketches to
store timing in milliseconds:

```elixir
config :oban_met, sketch_time_unit: :millisecond
```

This is a compile-time option that affects how timing values are binned in sketches, so changing it
requires recompiling Met, e.g. `mix deps.compile oban_met --force`.

> #### Cluster Consistency {: .warning}
>
> All nodes in a cluster **must** use the same `sketch_time_unit` setting. Mixing units between
> nodes will produce incorrect aggregated metrics.
>
> After changing this setting, existing metrics will be invalid until compaction ages them out
> (about three and a half hours with default compaction periods).

<!-- MDOC -->

## Contributing

To run the test suite you must have PostgreSQL 12+. Once dependencies are installed, setup the
databases and run necessary migrations:

```bash
mix test.setup
```

Use `mix test.reset` to drop, recreate, and migrate the test databases.

## Community

There are a few places to connect and communicate with other Oban users:

- Ask questions and discuss *#oban* on the [Elixir Forum][forum]
- [Request an invitation][invite] and join the *#oban* channel on Slack
- Learn about bug reports and upcoming features in the [issue tracker][issues]

[invite]: https://elixir-slack.community/
[forum]: https://elixirforum.com/
[issues]: https://github.com/oban-bg/oban/issues
