# Changelog for Oban Met v0.1.0

Initial release!

## v0.1.8 — 2024-09-18

### Enhancements

- [Reporter] Use count estimates for larger states.

  Counting is an expensive operation, even when it's optimized to use an index. In systems with
  even 1m jobs counting can take 200-400ms for each query. Previously, the reporter used a backoff
  mechanism to count less frequently when a state like `completed` had more than 10k jobs. The
  backoff increased based on the number of jobs, but it didn't always match the performance impact
  for a database.

  The new mechanism uses an estimate query for any state with more than a configurable number of
  jobs, 50k by default. The estimate is extremely fast at the expense of accuracy. For larger
  values the inaccuracy doesn't matter because we display a rounded value anyhow.

  The threshold can be configured through the application environment. For example, to increase
  the minimum to 100k before it starts estimating:

  ```elixir
  config :oban_met, reporter: [estimate_limit: 100_000]
  ```

### Bug Fixes

- [Examiner] Add catch-all `handle_info` clause to prevent crashing with unexpected notifications.

## v0.1.7 — 2024-06-20

### Bug Fixes

- [Recorder] Explicitly trigger garbage collection after compaction.

  Hibernating doesn't guarantee garbage collection in a highly active system. Now the `Recorder`
  process triggers garbage collection after it compacts stored metrics to ensure retained binaries
  are released.

## v0.1.6 — 2024-05-09

### Enhancements

- [Met] Add `Met.crontab/1` for distributed crontab tracking and aggregation.

  The new `Met.crontab/1` function exposes tracked, merged, and normalized crontabs from all
  connected nodes in a cluster.

- [Examiner] Broadcast queue and cron gossip immediately after init.

  Queue and cron data wasn't broadcast until after the first interval. This was more obvious for
  cron because it only broadcasts every 15s, but it also benefits queue responsiveness.

### Bug Fixes

- [Recorder] Prevent excessive message queue depth in OTP 26.2.5.

  A bug fix in OTP 26.2.5 made the performance of `:ets.select/3` with a map in the key **much
  slower**, effectively linear with the number of objects in the able. That performance degredation
  as enough to bottleneck the `Oban.Met.Recorder` message queue, which bloats the process and may
  cause OOM errors for active systems.

  This restores, and even improves, the performance of `:ets.select/3` for recorder operations by
  moving label maps out of the recorded oject key.

## v0.1.5 — 2024-04-08

### Enhancements

- [Reporter] Increase count frequency by tweaking backoff times.

  The leader node now counts larger queues and states more frequently than before by using a
  smaller expontential backoff.

  - The minimum value for clamping is now 10k, 10x larger than it was before.
  - The exponential factor is now 2 instead of 3, with a maximum of 128s between counts.

- [Met] Add tests and documentation on running `Oban.Met` as an Oban plugin.

  It's possible, even encouraged, to start `Oban.Met` as an Oban plugin in order to avoid
  auto-start race conditions.

## v0.1.4 — 2023-12-15

### Bug Fixes

- [Met] Monitor Oban instances and synchronize shutdown.

  Auto-started Met instances may outlive the Oban instance they're linked to, which causes a
  variety of registry errors when the original process has shutdown. To prevent that, a separate
  process now monitors the linked Oban supervisor process and coordinates shutting down the Met
  supervisor.

## v0.1.3 — 2023-10-29

### Bug Fixes

- [Met] Start `Met` on boot for running oban instances

  It's common for `oban` and `oban_met` to start in separate applications under an umbrella. When
  `oban_met` started _after_ `oban`, then Met missed the telemetry event and can't start a Met
  supervisor.

  This adds a task on boot that starts a Met instance for any running Oban isntances.

- [Recorder] Hibernate recorder process after compact cycle

  The `Recorder` process "touches" large batches of JSON received from `Reporter` processes, but
  it doesn't operate on the data often enough to trigger a full GC. The entire mechanics are
  explained in [this post][post] on the ElixirForum.
  
  Now, the `Recorder` hibernates after compacting to trigger a fullsweep garbage collection.
  
  [post]: https://elixirforum.com/t/extremely-high-memory-usage-in-genservers/4035/23

## v0.1.2 — 2023-09-24

### Enhancements

- [Recorder] Differentiate max/sum/pct operations for timeslice

  Some gauges should be displayed as a sum (exec count) while others should be a maximum (full
  count). Now timeslicing can differentiate between the two, and values types gained `sum/1` and
  `union/2` functions to make it possible.

## v0.1.1 — 2023-08-28

### Bug Fixess

- [Reporter] Reset reported counts whenever they're checkable

  In situations where there wasn't anything new to count, e.g. an empty queue or state, the old
  checks lingered until there was something to count again. Now any checkable counts are reset to
  an empty state before storage to ensure we reset back to 0 without new data.

## v0.1.0 — 2023-08-05

### Enhancements

- Telemetry powered metric tracking and aggregation with compaction
- Periodic queue checking and reporting, replaces the `Gossip` plugin
- Periodic counting and reporting with backoff, replaces `Web.Stats` plugin
- Leader backed distributed metric sharing with handoff
- Automatic instrumentation attached after instance startup
