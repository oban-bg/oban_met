# Changelog for Oban Met v1.0

## v1.0.3 — 2025-05-06

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
