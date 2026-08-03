# Changelog for Oban Met v1.3

## Unreleased

### Bug fixes

- [Reporter] Make the estimate query portable across Postgres-compatible engines

  The estimate path referenced a set-returning function's `value` column through a bare table
  alias, which resolves on PostgreSQL but fails on CockroachDB (the alias renames the column).
  Wrapping each function in a derived table with a column-list alias (`AS t(value)`) is standard
  SQL and behaves identically on both engines.

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
