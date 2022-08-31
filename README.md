# ObanMet

### Rationale

* Charts are helpful for monitoring health and troubleshooting from within Oban Web
* Not all apps can, or will, run an extra timeseries or metrics database
* State counts are driven by Postgres, but counting large tables is extremely slow; this requires something novel

#### Setup

* Oban.Met is a new package that's a dependency of ObanWeb and ObanPro, but could stand alone
* Oban.Met listens for [:oban, :supervisor, :start] events and starts a local ets table for each distinct instance

### Recording

* Telemetry events for inserting, fetching, pruning, staging, etc. are recorded as counts
* State data is recorded as counts with labels for queue, worker, node, as well as a the "old" state for tracking
* Telemetry events for job execution are recorded as histograms, with the same labels
* Local collectors broadcast updates periodically, every 1s or so, using pubsub

### Collecting

* Oban.Web nodes collect broadcasted metrics and store them in ETS with a local timestamp
* Collected data is periodically compacted by time, e.g. keep per-second data for 5 minutes, per-minute data for 2 hours, and so on
* Counts (state, queue, etc) have periodic "keyframes" to ensure consistency from the database
* Counts between keyframes apply deltas for each state, e.g. executing +1, +1, -1
* Before shutdown the collector hands off the full database (this could get plopped into a db table instead, not sure)
* (There are some critical details missing here)

### Querying

* Oban.Met provides a few flexible functions to extract counts and summaries from stored data
* Counts include subgrouping (this is a detail of how I'd like to chart, not critical)
* Summaries pull from histograms, they are aggregates (min/max/p50/p95/p99) over a period of time with a particular resultion
* Counts and summaries may be filtered by one or more workers/queues/states/nodes
* There isn't some query language, it's not freeform, just some keyword options for flexibility

### Charting

* Not there yet. Maybe it will be an off-the-shelf package, but it's more likely to be html/svg driven by LV
