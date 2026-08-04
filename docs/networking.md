# Network와 prediction

> 현재 `Network` 모듈은 0.1 `StateRuntime` 호환 확장이다. 정통 FRP Core의 `Event/Reactive/Behavior`를 자동 복제하지 않는다. FRP-native 입력에서는 로컬 packet 도착 시각을 occurrence time으로 쓰고 server tick/sequence는 payload로 유지한다.

Network 모듈은 transport를 열지 않는 순수 protocol 계층이다. RemoteEvent 연결은 `Overdare` adapter가 담당한다. Client가 보내는 값은 authoritative state가 아니라 항상 intent로 처리한다.

## Schema

```lua
local Network = require(ReplicatedStorage.ReactiveState.Network)

local schema = Network.defineSchema({
    {
        key = "health",
        direction = Network.SERVER_TO_CLIENT,
        source = serverHealth, -- server 환경
        target = clientHealth, -- client 환경
        validate = function(value)
            return type(value) == "number" and value >= 0
        end,
    },
    {
        key = "damage",
        direction = Network.CLIENT_INTENT,
        validate = function(value)
            return type(value) == "number" and value >= 0 and value <= 20
        end,
    },
}, {
    schemaVersion = 1,
    limits = {
        maxFields = 64,
        maxDepth = 8,
        maxElements = 1024,
        maxStringLength = 4096,
    },
})
```

방향은 `SERVER_TO_CLIENT`와 `CLIENT_INTENT`만 있다. 한 key를 묵시적 양방향 상태로 만들지 않는다. Field binding은 schema를 구성하는 실행 환경에 맞춰 넣을 수 있으며, intent만 받는 server schema처럼 필요하지 않은 `source`/`target`은 생략할 수 있다.

Field option:

- `codec`, `validate`: wire encode/decode와 도메인 검증.
- `visibility(clientId, value, context)`: client별 포함 여부.
- `project(value, clientId, context)`: server projection/AOI.
- `predict`: `true`, function, 또는 `{ apply = function }`인 client prediction reducer.

## Server

```lua
local server = Network.createServer({
    schema = schema,
    runtime = serverRuntime,
    authorize = function(clientId, action)
        return canUseAction(clientId, action)
    end,
    onIntent = function(clientId, actions)
        applyActions(clientId, actions)
    end,
})

local snapshotStatus = server:createSnapshot(clientId, serverTick)
local patchStatus = server:createPatch(clientId, serverTick)
local intentStatus = server:acceptIntent(clientId, payload)
```

각 status는 `{ ok, code, message? }` 형태다. Server는 client별 baseline, outgoing sequence, revision, 마지막 intent sequence와 tick을 보존한다. `acceptIntent`는 protocol/schema, field 방향, 순서, 크기, codec, validator와 `authorize`를 통과한 actions만 하나의 Runtime transaction으로 `onIntent`에 전달한다.

Rate limit, 플레이어 권한, 거리/cooldown과 transport authentication은 애플리케이션 server 코드의 책임이다.

## Client

```lua
local client = Network.createClient({
    schema = schema,
    runtime = clientRuntime,
    onResyncNeeded = function(status)
        requestFullSnapshot(status.code)
    end,
})

local intent = client:createIntent({ damage = 7 }, clientTick)
remote:FireServer(intent.payload)

local applied = client:receive(serverPayload)
```

Client는 snapshot을 먼저 요구하고 patch sequence/baseRevision의 gap, stale/duplicate payload, protocol/schema mismatch와 canonical state hash mismatch를 거부한다. Server state 적용과 미확정 prediction replay는 하나의 Runtime transaction이다. `ackSequence`까지의 pending input은 제거된다.

`status.requestResync == true`면 새 full snapshot을 요청해야 한다. Hash는 drift 탐지용이며 인증이나 서명 용도가 아니다.

## OVERDARE transport 연결

```lua
local adapter = Overdare.createServerReplication({
    replicator = server,
    remoteEvent = remoteEvent,
})

local clientAdapter = Overdare.createClientPrediction({
    replicator = client,
    remoteEvent = remoteEvent,
})
```

Adapter는 이미 만든 replicator와 RemoteEvent-like transport를 연결하고 connection 수명만 소유한다. Module load 시 RemoteEvent나 listener를 자동 생성하지 않는다. 실제 OVERDARE signature와 multi-client 동작은 [Studio 체크리스트](./overdare-checklist.md)로 검증한다.
