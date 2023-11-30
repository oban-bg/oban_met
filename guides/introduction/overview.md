# Overview

🏤 Oban.Met supervises a collection of autonomous modules for in-memory, distributed time-series
data with zero-configuration. `Oban.Web` relies on `Met` for queue gossip, detailed job counts,
and historic metrics.

Metrics are gathered and managed automatically for applications using Oban Web. See
[installation](installation.md) for use in a worker-only node.

## Features

### 📇 Metric Aggregation

Telemetry powered metric tracking and aggregation with compaction.

### 📰 Queue Reporting

Periodic queue checking and reporting (replaces the deprecated `Gossip` plugin).

### 👷‍♀️ Job Reporting

Periodic counting and reporting with backoff (replaces `Stats` plugin)

### 🎩 Distributed Leadership

Leader backed distributed metric sharing with handoff between nodes.
