# Changelog

## 0.2.0-dev.1 - Unreleased

- Replaced the root contract with Conal Elliott's Push-Pull FRP normal form:
  `Future`, `Event`, `Reactive`, `TimeFunction`, and `Behavior`.
- Added strict-before sampling, duplicate-preserving stable-left Event merge,
  Future max/min algebras, Event/Reactive monads, and Behavior applicative.
- Added a monotonic Host with atomic same-time frames, pushed source dirtiness,
  demand-driven Event evaluation, scheduled Future occurrences, and explicit
  renderer lifecycle.
- Added past-prefix reconstruction so dynamically selected Event streams retain
  the paper's `max(outerTime, innerTime)` semantics.
- Added an OVERDARE FRP driver that batches multiple Signals into one phase
  frame; renamed the optional AI facade to `BehaviorTree`.
- Added paper truth-table, randomized denotational, late-composition, atomicity,
  and OVERDARE batching tests plus seven dedicated O1/O2/codegen benchmarks.
- Made closed logical times single-commit, coalesced scheduled and callback roots,
  and supported dynamically constructed Event past/same/future occurrences.
- Made diagnostic prefix pulls read-only, preserved every Behavior phase
  occurrence, fixed nil scan state and prepare-time Reactive construction, and
  added weak downstream edges plus full Host disposal cleanup.
- Kept lawful Event/Reactive map and bind callbacks value-only; occurrence-time
  observation is an explicit `mapWithTime`/`snapshot` extension.
- Kept the 0.1 Atom/Computed engine as the explicit `createStateRuntime()`
  compatibility extension; it is no longer described as the FRP Core.
- Added a multiplayer-first FRP protocol and OVERDARE RemoteEvent adapter with
  server authority, per-client sequence/ack, rate and wire budgets, bounded
  queues, exact intent retries, heartbeats, replay, snapshot epochs, and
  PlayerRemoving cleanup.
- Added lost-initial-resync retry, non-advancing heartbeat ticks, automatic
  Players lifecycle hookup, session-generation cleanup, and atomic snapshot
  failure handling.
- Added fake two-client loss/reorder/replay/snapshot/lifecycle tests and an
  actual OVERDARE Studio two-client release-gate harness.
- Added 2/8/32-peer protocol benchmarks for validated intent ingress and
  authoritative streams, plus replay recovery and untrusted-packet rejection.

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
