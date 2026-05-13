# Changelog for Oban Met v1.0

## v1.2.0 — 2026-05-13

This release is entirely dedicated to performance optimizations for the `Recorder` process, which
is heavily utilized by the Web dashboard. A summary of overall performance improvements in this
release:

|      Operation      |  Before everything   |     After all changes     |   Speedup    |
|---------------------|----------------------|---------------------------|--------------|
| latest:exec_count   | 15.6 ms (compressed) | 0.013 ms                  | ~1200×       |
| latest:full_count   | 14.0 ms (compressed) | 0.014 ms                  | ~1000×       |
| labels:worker       | 99.5 ms (compressed) | 0.134 ms                  | ~740×        |
| series              | 308 ms (compressed)  | 0.157 ms                  | ~1960×       |
| timeslice:exec_time | 23.9 ms (compressed) | 0.63 ms                   | ~38×         |
| compact             | 1.45 s (blocking)    | ~0.82 s (off-process)     | non-blocking |

### Enhancements

- [Recorder] Reorder series-table key to bound timeslice scans

  Move max_ts to position 2 of the key. Within a series rows now sort by time, so chunked
  `select_reverse/3` walks newest-first and stops as soon as a chunk's oldest row falls below the
  lookback cutoff. ETS work becomes proportional to rows-in-lookback rather than rows-in-series,
  which is most of the win for short-lookback charts.

  Measured end-to-end on `Recorder.timeslice/3` against a realistic 300k-row / 400-combo shape,
  grouped by queue with p95 quantile:

  ```text
  lookback 60s    4.05 ms → 0.63 ms   ~6.4x
  lookback 600s   9.75 ms → 5.58 ms   ~1.7x
  ```

  The select-level scan is 30x faster at lookback 60. Elixir reductions are now the limit for that
  path. Against the original compressed-table baseline a 60s-lookback timeslice is ~38x faster.

- [Recorder] Add latest-snapshot table to accelerate `latest/3`

  `Recorder.latest/3` previously scanned the series table's full prefix range for one series.
  Using a benchmark of 300k rows, with ~1k-combo cardinality, that's ~25k rows walked through to
  filter out everything past the 2s lookback.

  A second table (`:metrics_latest`) now holds one row per key with the most recent value and
  time, which is bounded by cardinality rather than history.

  Measured at 300k rows / 400 combos / 750 timestamps per combo:

  ```text
  latest:exec_count   8.75 ms → 0.013 ms  (657× faster)
  latest:full_count   8.85 ms → 0.014 ms  (664× faster)
  per-call memory     10.6 KB → 1.4 KB    (7.6× less)
  ```

  The snapshot is swept of stale entries during compaction (anything older than the retention
  horizon) and rebuilt from the series table on handoff to keep peak memory bounded during
  reconstruction.

- [Recorder] Serve `labels/3` and `series/1` from latest snapshot

  The latest snapshot already contains one row per unique (series, labels)
  combo, which is exactly the diversity these two functions need.
  Switching `labels` and `series` yeilded massive speed and memory
  improvements:

  ```text
  labels:worker  32.26 ms → 0.134 ms (240× faster)
                   935 KB → 29 KB    (31× less memory)
  series/1         214 ms → 0.157 ms (1597× faster)
                   209 MB → 59 KB    (3550× less memory)
  ```

  That includes the effect of an improved post select pipeline also uses
  fewer operations with a single reduce piped into a map.

- [Recorder] Trim compact periods for fidelity with less data

  The previous periods retained roughly 780 buckets per (series, labels) combination across a 3.4
  hour horizon, sized well beyond what any oban_web chart actually reads. The new windows are
  dimensioned so each chart period (1s through 2m) still sees source granularity at or below its
  `by` step throughout its lookback range.

  Measured against a realistic shape (400 active label combos × ~750 timestamps over the full
  horizon):

  ```text
  before: 119k rows / 81 MB / 267 ms compact
  after:  103k rows / 70 MB / 225 ms compact
  ```

  A modest ~13% drop in steady-state memory and compaction work without changing any public
  behavior. Customers running with a per-process `compact_periods` override are unaffected.

- [Recorder] Move compaction off-process and drop compression

  Drop `:compressed` from the metrics ETS table. The flag decompressed every row on every
  match-spec evaluation, which is the recorder's entire hot path. Removing it speeds up compaction
  1.8x, `latest` 3x, and `timeslice` 4x at 300k rows, at the cost of 2x ETS memory.

- [Recorder] Run compaction out of the recorder process

  Run compaction in a `Task` against a `:public` table. The recorder process is no longer blocked
  for ~800ms/minute on compaction work, and the 290 MB transient allocation lives on the Task's
  heap rather than forcing a `:hibernate` on the recorder. Concurrent `:metrics` writes complete
  during compaction (measured ~14× faster worst-case store latency) instead of queueing in the
  recorder's mailbox.

- [Recorder] Target handoff acks to the requesting recorder

  A leader's ack was broadcast to every listener, so every recorder on every node decoded the
  payload only to find it wasn't theirs. Now messages are routed via the notifier's ident
  mechanism. Also skip syns whose name/node match the leader's own conf so the leader no longer
  responds to its own startup announcement.

- [Recorder] Accept handoff off the recorder process

  The follower now decodes the handoff payload and rebuilds in a separate process to avoid
  blocking or bloating the recorder. Rebuilding the latest table no longer deletes all objects in
  order to preserves concurrent writes, those keys are cleaned up later during compaction.

- [Recorder] Spawn handoff serialization in a linked task

  The leader's handoff dumped the entire series table, serialized, compressed, and base64-encoded
  inline in the Recorder process. For large tables, that's hundreds of milliseconds blocking and
  significant memory usage for the process. That work moved into a task so the Recorder returns
  immediately.

- [Recorder] Compress encoded recorder handoff output

  The handoff payload was serialized uncompressed before notification. The trailing gzip can't
  recover much from a base64 string, so the binary went out essentially uncompressed. Now it's
  compresssed at the step where the input is still raw terms with highly repetitive label maps.


## v1.1.0 — 2026-03-25

### Enhancements

- [Met] Require a minimum of Oban v2.21

  Oban v2.21 introduces the `suspended` state, which is now counted by the reporter along with the
  other states.

## v1.0.6 — 2026-02-19

### Enhancements

- [Met] Add configurable time unit for timing metrics

  Metrics stored in sketches now support configurable time units via the `:sketch_time_unit`
  compile-time option. By default, timing values remain in `:native` units for backward
  compatibility.

  Setting `config :oban_met, sketch_time_unit: :millisecond` reduces sketch storage size by ~20%
  and consolidates timing values into fewer bins by eliminating nanosecond-level measurement
  noise.

- [Cronitor] Share crontab options as a map rather than nested lists

  For compatibility with entries shared by python, we convert options to a
  map structure rather than a list of lists.

## v1.0.5 — 2025-12-10

### Bug Fixes

- [Examiner] Normalize `limit` to `local_limit` for web consistency

  Oban checks return `limit`, while Pro stores them as `local_limit`. That causes inconsistent
  data when displaying OSS queue details in `oban_web`. This stores `limit` as `local_limit`
  consistently, rather than checking for both keys.

## v1.0.4 — 2025-11-26

### Bug Fixes

- [Met] Match on config to auto-start named instances

  The registry pattern only matched `Oban` instances, not modules created with `use Oban`. This
  modifies the pattern to extract `Oban.Config` structs directly.

- [Met] Remove use of struct update syntax deprecated in Elixir v1.19


## v1.0.3 — 2025-05-06

### Enhancements

- [Examiner] Use parallel execution for health checks.

  Minimize total time taken to scrape checks from producers by parallelizing calls. The worst case
  time is now O(1) rather than O(n) when producers are busy.

## v1.0.2 — 2025-03-14

This release requires Oban v2.19 because of a dependency on the new JSON module.

### Bug Fixes

- [Met] Log unexpected messages from trapping servers

  The `reporter` and `cronitor` have a small set of messages they expect. Rather than crashing on
  unexpected messages, the processes now log a warning instead.

- [Meta] Override application options with passed options

  Passed options weren't relayed to the underlying module and only application level options had
  any effect. This ensures options from both locations are merged.

- [Met] Use conditional JSON derive and Oban.JSON wrapper

## v1.0.1 — 2025-01-16

### Bug Fixes

- [Value] Implement `JSON.Encoder` for value types

  The encoder is necessary to work with official JSON encoded values as well as legacy Jason.

## v1.0.0 — 2025-01-16

This is the official v1.0 release _and_ the package is now open source!

### Enhancements

- [Reporter] Count queries work with all official Oban engines and databases (Postgres, SQLite,
  and MySQL).

- [Migration] Add ability to explicitly create estimate function through a dedicated migration.

  For databases that don't allow the application connect to create new functions, this adds an
  `Oban.Met.Migration` module and an option to disable auto-migrating in the reporter.

### Bug Fixes

- [Reporter] Skip queries with empty states or queues to prevent query errors.

  Querying with an empty list may cause the following error:

  ```
  (Postgrex.Error) ERROR 42809 (wrong_object_type) op ANY/ALL (array)
  ```

  This fixes the error by skipping queries for empty lists. This could happen if all of the states
  were above the estimate threshold, or no active queues were found.
