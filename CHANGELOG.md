# Changelog for Oban Met v0.1.0

Initial release!

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

- Telemetry powered metric tracking and aggregation with compaction
- Periodic queue checking and reporting, replaces the `Gossip` plugin
- Periodic counting and reporting with backoff, replaces `Web.Stats` plugin
- Leader backed distributed metric sharing with handoff
- Automatic instrumentation attached after instance startup
