# Changelog for Oban Met v0.1.0

Initial release!

## v0.1.2 — 2023-09-24

## Enhancements

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
