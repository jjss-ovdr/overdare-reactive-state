# OVERDARE Studio multi-client harness

This harness is the platform boundary gate for the real OVERDARE `RemoteEvent`
and `RunService` implementation. It is not part of the runtime package and must
never be enabled in a published World.

For an independent QA run, installing the generated package and these two
harness scripts into a disposable clean test World is required test setup, not
a source-repository modification. A test agent may create these temporary
Studio objects after making a World copy/checkpoint, but must not save over or
publish the original World, edit tracked repository files, commit, or push.
Discard the test World or remove every installed object after collecting the
outputs. An open blank Baseplate without the package/harness is
`BLOCKED: test harness not installed`, not `Studio environment unavailable`.

## Required API contract

The scripts exercise the existing `Network` server/client replicators and these
FRP transport bindings:

```lua
local binding = Overdare.attachFRPServerRemote(driver, remoteEvent, options?)
local intents = binding:intents() -- validated and authorized intent Event
local output = binding:bindOutbound(event)
-- outbound Event<{ peer = Player, messageType, payload, serverTick }>
binding:dispose()

local binding = Overdare.attachFRPClientRemote(driver, remoteEvent, options?)
local authority = binding:authority() -- ordered server event/snapshot Event
local output = binding:bindOutbound(event)
-- outbound Event<{ messageType, payload, clientTick? }>
binding:dispose()
```

`options.protocol` is the shared `Network.defineFRPProtocol` declaration. The
adapter reads the real `(player, payload)` / `(payload)` signal signatures and
does not trust a sender ID inside the payload. Arrival occurrence time is the local
`Heartbeat` time chosen by the driver; a packet's `serverTick` or `clientTick`
stays in the payload. Module load must not create a RemoteEvent or connection.
`bindOutbound` returns an idempotent Disposable. The binding builds and retains
the wire envelope, including per-client sequence and ack. Disposing the parent
binding also owns every outbound binding.

`eventFromSignal` queues input and `bindOutbound` performs its transport effect
when the driver closes the next configured phase. `ScriptSignal:Wait()` only
waits for the signal to fire; it does not guarantee that every `Connect`
callback on that same signal has already completed. The harness therefore waits
for a new matching retained packet across bounded Heartbeat phases instead of
treating one `Heartbeat:Wait()` as a post-flush barrier.

Valid intent and authority envelopes cross the real RemoteEvent. The harness
accepts an intent once, resends its exact wire packet, and verifies
`duplicate_intent` without applying or authorizing it again. It also verifies a
consumed unauthorized intent, targeted authority, and per-client broadcast.

The harness fails immediately with a precise message when this API is missing or
has a different return contract. `eventFromSignal` is used only to create a
deterministic outbound Event; all engine I/O still goes through the public
RemoteEvent binding. A green run therefore proves that binding was exercised in
both directions.

## Install

Build and verify the package from the repository root:

```sh
node tools/build-studio-package.mjs
node tools/build-studio-package.mjs --verify
luau tools/studio-package-smoke.luau
luau -O2 tests/run.luau
```

Install `dist/ReactiveState` at `ReplicatedStorage/ReactiveState` as described in
`docs/studio-install.md`. Then add the two harness scripts:

```text
ReplicatedStorage
└── ReactiveState

ServerScriptService
└── RSMP_Server (Script; Enabled = true)
    └── Source = examples/StudioMultiplayer/Server.server.luau

StarterPlayer
└── StarterPlayerScripts
    └── RSMP_Client (LocalScript; Enabled = true)
        └── Source = examples/StudioMultiplayer/Client.client.luau
```

Do not rely on a newly-created BaseScript's default properties. Before Play,
verify the exact class, parent, `Enabled == true`, and normalized source hash of
both objects. The generated `dist/ReactiveState.manifest.json` contains the
machine-readable `validationHarness.objects` contract with these values and the
source SHA-256 for each script. The harness is temporary QA code: never include
it in a saved or published World.

Stop every existing Play process before installation. Create both scripts with
`Enabled = false`, set their complete Source and parents, then enable both only
after the package and scripts are ready. Start a fresh Play session afterward;
installing into `StarterPlayerScripts` after clients have joined does not satisfy
this gate. Each client must contain the copied
`Players/<LocalPlayer>/PlayerScripts/RSMP_Client` LocalScript.

The server creates `RSMP_State`, `RSMP_FRP`, and `RSMP_Control` RemoteEvents in
`ReplicatedStorage` at runtime. It refuses to reuse objects with those names, so
run this in a clean test World. The client uses bounded `WaitForChild` calls to
cover real replication startup ordering.

## Run

1. In the Play tab test options, set **Number of Players** to at least `2`.
2. Start Play and leave the server and both client windows open.
3. Require one server and two client `BOOT ... stage=entry` lines. Read the
   server Output. Client Output contains diagnostics, but only the
   server emits the release-gate result.
4. Stop the test after one `FINAL` line appears.

Success is exactly one line shaped like:

```text
[RSMP][v1]|FINAL|run=<id>|status=PASS|passed=<n>|failed=0|clients=2
```

Runtime assertions and timeouts print `status=FAIL` and raise an error. A
startup error prints a server `FINAL ... status=FAIL ... stage=startup` or a
client `CLIENT_FAIL ... stage=startup` line. If every `[RSMP]` line is absent,
the scripts did not start: re-check class, parent, `Enabled`, installed source,
and the client-side `Players/<LocalPlayer>/PlayerScripts/RSMP_Client` copy. That
state is `HARNESS_NOT_STARTED`, not a RemoteEvent result. Never accept a run
merely because no FAIL line appeared—the positive final PASS line is mandatory.
Preserve the Studio version, package manifest SHA-256, OS/device, preflight
object properties, server Output, and both client Outputs with the result.

## Automated assertions

The server centrally checks all client reports instead of trusting local print
statements:

- server/client/Studio execution context and real `Stepped`, `Heartbeat`, and
  client-only `RenderStepped` argument shapes;
- two independent client processes and a real `OnServerEvent(player, payload)` /
  `OnClientEvent(payload)` path;
- `FireClient` targeting and per-client sequenced broadcast delivery;
- distinct per-client snapshot projection, visibility, and state hash;
- client prediction, authoritative correction, acknowledgement removal, and
  stable replay of one still-pending input;
- server rejection of deep payloads, wrong schema, wrong direction, unauthorized
  actions, duplicate intent, and stale intent without sequence advancement;
- client rejection and recovery for schema mismatch, sequence gap, stale tick,
  tampered hash, unknown field, duplicate payload, and excessive depth;
- inbound `arrivals()` and outbound `bindOutbound()` over real RemoteEvents,
  including duplicate occurrence preservation, Player identity, targeting, and
  local arrival time rather than packet tick;
- FRP-native wire encoding for accepted intent/authority, exact intent
  duplicate classification, and authority rejection on the same real connection;
- explicit network adapter and FRP binding disposal, including no callback after
  disposal.

The StateRuntime `Network` path remains in this harness because it provides a
second, already-defined oracle for projection, authority, sequence, hash, and
prediction behavior. FRP transport assertions are separate so engine arrival
time is never confused with authoritative simulation tick.

## Manual follow-up gates

These require UI or a real target and cannot be proven by the standalone Luau
runner:

- Test late join in a dedicated application-level run with `3` clients or
  **Add a Client**. This harness intentionally enrolls only its first two clients,
  so late-join snapshot initialization is a separate release gate.
- Test disconnect during a dedicated active run by closing one client window.
  Verify one `PlayerRemoving` `CLEANUP` line appears. The two-client orchestrator
  will then time out or fail by design; this manual evidence does not replace the
  automated `FINAL ... status=PASS` run. A production session owner must call
  `resetClient` and dispose per-peer state before release.
- Repeat with Studio network emulation/poor-network settings used by the project.
  Verify gap/resync policy, timeout behavior, and memory do not grow without
  bound. Do not infer packet loss or reordering guarantees from the fake tests.
- Run on every supported mobile/target device; Studio desktop timing is not a
  target-device performance result.

Official platform references:

- [RemoteEvent API](https://docs.overdare.com/development/api-reference/classes/remoteevent)
- [Server-client communication](https://docs.overdare.com/manual/script-manual/events-and-communication/remoteevent)
- [RunService API](https://docs.overdare.com/development/api-reference/classes/runservice)
- [Studio Play Test](https://docs.overdare.com/manual/studio-manual/get-started/studio-playtest)
- [Players API](https://docs.overdare.com/development/api-reference/classes/players)

## What CLI can and cannot establish

CLI fake transports can completely test validation, authorization, per-peer
sequence state, projection, prediction/reconciliation, timeout state machines,
and idempotent disposal. Package build/verify also proves the installed source
matches its manifest.

CLI cannot establish the real Player injection signature, process isolation,
RemoteEvent serialization/copy semantics, target routing, engine scheduling
relative to Heartbeat, actual disconnection behavior, network conditions, or
device performance. The PASS line from this harness is the minimum evidence for
those Studio-specific boundaries; published-device checks remain separate.
