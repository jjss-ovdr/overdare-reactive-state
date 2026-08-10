# Changelog

## 0.2.0-rc.1 - Unreleased

- Added `FRP.createCapital()` / `FRP.Compat` so Atom/`Get`/`Set`/`Computed`/
  `Transaction` game scripts use the official package instead of inventing a
  project-local ReactiveState shim.
- Documented that `Capital.Event` is a local Connect/Fire bus and is not
  `FRP.Event`, with migration tables for blank-world Studio installs.
- Restored the documented function-subscription Signal boundary by resolving
  plain Luau functions before OVERDARE's opaque canonical `Connect` namecall.
- Added a regression that drives both the FRP clock and an input Event through
  subscription functions and verifies queued occurrence time and disposal.
- Embedded the MIT license in the distributed root ModuleScript and added a
  private-first Asset Store release and clean-download verification runbook.
- Preserved the Conal-style FRP Core and the verified opaque engine callable
  adapter paths unchanged; this release candidate only changes Signal dispatch.

## 0.2.0-dev.4 - Unreleased

- Replaced Lua `function` representation checks at OVERDARE engine boundaries
  with capability-based colon calls for `GetService`, Signal `Connect`,
  RemoteEvent `Fire*`, `GetPlayers`, `Disconnect`, and `Destroy`.
- Kept user-supplied callbacks and replicator protocols strictly function-based
  so opaque engine compatibility does not weaken library configuration errors.
- Extended the same engine-callable compatibility to Runtime scope disposal and
  AttributePreset observation.
- Added opaque-callable regression coverage for the legacy adapters and the
  FRP-native two-client RemoteEvent authority/sequence protocol, including
  Players discovery, broadcast, PlayerRemoving, and cleanup.
- Fixed the Studio multiplayer gate to await a new matching phase-buffered
  outbound packet instead of treating one `Heartbeat:Wait()` as a post-callback
  ordering barrier, with timeout diagnostics for channel status and Host errors.

## 0.2.0-dev.3 - Unreleased

- Fixed `Core.Immutable` to require its sibling `Codec` ModuleScript in
  OVERDARE while retaining the standalone Luau string path outside Studio.
- Added package-build contracts for every Studio module dependency, including
  exact Instance require expressions and ModuleScript target validation.
- Added early server/client RSMP BOOT and startup-failure records so disabled,
  misplaced, or initialization-failed harness scripts cannot look like a silent
  RemoteEvent timeout.
- Added a generated validation-harness contract for Script/LocalScript class,
  path, `Enabled` state, and normalized source hashes.

## 0.2.0-dev.2 - Unreleased

- Added a strict, generic public FRP type surface for Host, Future, Event,
  Reactive, TimeFunction, Behavior, occurrences, emitters, and capture options.
- Made occurrence metadata read-only in the public contract and frozen every
  occurrence envelope at runtime so observers cannot rewrite shared history.
- Added opt-in `capture` policies to source, pure/once/Future conversion,
  `fromOccurrences`, `scan`, and accumulation, with copy-before-reduce staging
  so a mutating reducer failure cannot damage the last committed state.
- Added `FRP.Immutable.serializable()` for codec-backed clone plus recursive
  freeze of plain-data graphs while preserving shared aliases.
- Added positive/negative strict-consumer fixtures, adversarial immutability and
  rollback tests, package smoke coverage, and a dedicated capture benchmark.
- Pinned the official Luau source commit required by the strict type gate and
  added a capability preflight that rejects incompatible analyzer substitutes.
- Made Studio package source and text artifacts LF-normalized so Windows CRLF
  and Unix LF checkouts produce the same package SHA-256.

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
