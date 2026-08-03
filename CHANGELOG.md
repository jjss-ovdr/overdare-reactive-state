# Changelog

## 0.1.0-dev.1 - Unreleased

- Initial Luau-first push-pull reactive runtime.
- Staged atomic transactions with nested rollback-only propagation and
  transaction-local Computed evaluation.
- Lazy push-pull Computed graph with dynamic dependency replacement,
  pending verification, cycle/cross-Runtime diagnostics, and stable watches.
- Bounded O(1)-eviction full-snapshot ring, rollback/replay, coalesced replay watches,
  canonical drift hash, and confirmed command outbox.
- Store, one-way Bridge, schema-based Network protocol, OVERDARE phase/
  RemoteEvent adapters, Behavior, AttributePreset, and Debug modules.
- Core, property, malformed-network, fake-adapter, and real-Runtime integration
  tests for the preview release.
- Engine-neutral performance suite covering the ten strategy workloads with
  CLI O1/O2/codegen and OVERDARE Studio runners, correctness gates, p50/p95,
  setup/cleanup timing, and retained-heap sampling.
- Trace-disabled hot paths avoid detailed event-table allocation; Runtime
  disposal releases graph/history/outbox ownership; nested pull depth now has
  an explicit diagnostic limit before host stack overflow.
