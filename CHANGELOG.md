# Changelog for Oban Met v1.0

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
