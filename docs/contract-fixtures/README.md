# Contract Fixtures

Canonical wire examples shared by the orchestrator and iOS client tests.

`orchestrator-sse/*.sse` contains OpenAI-compatible SSE frames as emitted by the
orchestrator. Client tests should parse these files without special cases; server
tests can compare route output against the same shapes when route fixtures are
needed.
