# Docs

This folder is for durable project documentation:

- [`SPEC.md`](SPEC.md) is the app/orchestrator contract and requirements.
- [`multi-upstream.md`](multi-upstream.md) explains model routing across multiple upstream hosts.
- [`REAL_UPSTREAM_TESTS.md`](REAL_UPSTREAM_TESTS.md) documents ignored smoke tests that require real model servers.
- [`resilient-turns.md`](resilient-turns.md) records the resumable streaming-turn design referenced by code and the spec.
- [`contract-fixtures/`](contract-fixtures/) contains wire-format fixtures used by tests.

Implementation handoffs, redesign sketches, and old plans should stay out of the
repo once their decisions have landed in code or `SPEC.md`.
