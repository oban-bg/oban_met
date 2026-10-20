# Changelog for Oban Met v1.3

## v1.3.3 — 2026-10-20

### Bug Fixes

- [Listener] Fix exec_count max and pct within single interval

  Execution counts were reported with one entry per execution rather than a single total, so
  `timeslice/3` with `:max` or `{:pct, ntile}` reported 1 for any busy second.

- [Met] Fix default instance dispatch met functions

  Calling `labels/2`, `latest/2`, or `timeslice/2` with opts, but no instance name, used the series
  as the instance name and crashed. Two-argument calls with a keyword list now use the default
  `Oban` instance, matching the documented examples.

- [Recorder] Fix crashing and unmatched filters

  Filtering with an empty list of values, such as `filters: [queue: []]`, raised an
  `Enum.EmptyError`. Empty value lists now match nothing.

  Filter values given as atoms, such as `filters: [queue: :default]`, never matched because labels
  are stored as strings. Values are now converted to strings before comparison.

- [Recorder] Accept atoms for latest and timeslice groups

  Grouping by an atom label, such as `group: :queue`, silently combined all values under a single
  group. Atom groups are now treated like their string equivalents.

- [Recorder] Fix timeslice at the edges of the lookback window

  The lookback window was measured from the current time rather than `since`, so a past `since`
  dropped data from the oldest bucket and a future `since` returned an extra bucket beyond the
  window. The window now covers the `lookback` seconds before `since`.

- [Reporter] Prevent database errors from crashing the reporter

  A database error while counting jobs crashed the reporter on every check, which brought down the
  Met supervisor after a few seconds of database unavailability.

  Counting now retries through `Oban.Repo.transaction/3` and skips the check once retries are
  exhausted. Requires Oban v2.23+.

- [Value] Approximate sums for sketch values

  Summing a sketch always returned `0.0`, so `timeslice/3` with the default `:sum` operation and
  `latest/3` reported zero for `exec_time` and `wait_time`. Sketch sums are now estimated from their
  bins, with the same 2% error as quantiles.

- [Value] Fix inflated max and pct for compacted gauges

  Grouping compacted gauges collapsed each interval into a single total, so `timeslice/3` with
  `:max` or `{:pct, ntile}` reported the interval's total rather than its peak once data was older
  than the first compaction period. Gauges are now combined position by position, preserving both
  the per-second peak and the total.

- [Value] Correct gauge and sketch edge cases and specs

  Gauges now accept zero in `Gauge.new/1` and support `Gauge.add/2` on an empty gauge, matching
  their documented types. The default gauge struct holds an empty list rather than an integer.

  Specs for `Gauge.quantile/2`, `Sketch.to_list/1`, and sketch bins also reflect the values they
  actually return.

## v1.3.2 — 2026-10-06

### Bug Fixes

- [Reporter] Recognize `Oban.Pro.Engine` for queue discovery

  Pro v1.8 renamed the `Smart` engine to `Oban.Pro.Engine`. The reporter only checked for the
  legacy `Oban.Pro.Engines.Smart` name, so with the new name it fell back to running a `SELECT
  DISTINCT queue` over `oban_jobs` instead of reading `oban_producers`. Both names are now
  recognized.

- [Recorder] Prevent recorder tasks from shutdown crashing

  Compaction and handoff tasks run detached from the Recorder that owns their ETS tables. When the
  Recorder terminated during an orderly shutdown the tables were destroyed while a task was still
  scanning, and the next ETS call raised with "invalid continuation" or a missing table
  identifier.

  Tasks now treat a deleted source table as a normal end to the pass, while real errors still
  crash the task as before. Handoff payload inserts are also detached so a malformed payload from
  a peer can't terminate the Recorder and destroy its metrics history.

## v1.3.1 — 2026-08-26

### Enhancements

- [Recorder] Make the job-count estimator pluggable

  Wrap set-returning estimate functions in derived tables with explicit column-list aliases for
  CockroachDB compatibility. This avoids alias resolution that causes undefined-column errors once
  a state reaches `estimate_limit`, which could cause a crash-loop.

  Add an `:estimate_function` option for supplying an estimate function DDL. The option accepts a
  `(prefix -> ddl)` builder and defaults to the existing `oban_count_estimate` implementation.
  That preserves current behavior and allows engines that don't support dynamic explains to use
  compatible implementations and retain `auto_migrate`.

### Bug Fixes

- [Cronitor] Handle new Oban.Cron name from Oban v2.24

  Oban v2.24 elevated `Oban.Cron` from a plugin to a standard service, and renamed it accordingly.
  Now both the new and old name formats are supported by the `Cronitor` module.

## v1.3.0 — 2026-08-01

### Enhancements

- [Recorder] Restore :compressed option to series table

  The larger `metrics_series` table is now compressed, while the smaller `metrics_latest` remains
  uncompressed because it stays small.

- [Recorder] Bound compaction with chunking

  Prevent overlapping compactions and use a dedicated ETS table for chunked compaction. The
  resulting peak memory usage is ~61x lower with a relevant sample of ~260k rows.

  | Compaction | Time     | Peak memory | Table before | Table after |
  | ---------- | -------- | ----------- | ------------ | ----------- |
  | Unbounded  | 849.7 ms | 258.5 MiB   | 147.1 MiB    | 143.6 MiB   |
  | Bounded    | 806.2 ms | 4.2 MiB     | 147.1 MiB    | 143.5 MiB   |

- [Recorder] Restrict metric handoff to the PG notifier

  Handoff passes entire recorded tables between nodes over pubsub. The handoff size can easily be
  larger than what Postgres can deliver, which the notifier blocks. Rather than silently failing,
  handoff is restricted to the `PG` notifier.

- [Recorder] Chunk recorded table handoffs with acking

  Recorder handoff copied the entire table in a single payload using `tab2list` and
  `term_to_binary`. That spiked memory on both the sender and receiver, using hundreds of MB of
  memory with larger tables.

  The sender now streams the table through ETS continuation, sending 5k rows per message awaiting
  an ack before the next batch. Only one chunk is in flight at a time.

  The result is a ~5x smaller overall peak process heap:

  |                   | elapsed | peak process |   wire   |
  |-------------------|---------|--------------|----------|
  | legacy full table | 645 ms  | 202.0 MiB    | 3.53 MiB |
  | chunked 5,000     | 965 ms  | 39.4 MiB     | 3.62 MiB |
  | round trip 5,000  | 1817 ms | 34.8 MiB     | 3.62 MiB |
