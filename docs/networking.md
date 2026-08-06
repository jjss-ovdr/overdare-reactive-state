# FRP 멀티플레이와 서버 권위

멀티플레이는 부가적인 값 복제가 아니라 기본 보안 경계다. 클라이언트는 authoritative state를 보내지 않고 intent만 보낸다. 서버는 schema·순서·빈도·권한을 검증한 뒤 `Event`로 공개하고, 클라이언트에는 서버가 만든 event 또는 snapshot만 전달한다.

`Network`는 engine-neutral protocol이고 연결을 만들지 않는다. 실제 OVERDARE `RemoteEvent`와 `Heartbeat` 연결은 `Overdare.attachFRPServerRemote` / `attachFRPClientRemote`를 호출할 때만 생긴다. 패킷의 로컬 도착 시각이 FRP occurrence time이며, `clientTick`과 `serverTick`은 wire metadata로 남는다.

## FRP protocol 선언

서버와 클라이언트가 같은 선언을 공유한다.

```lua
local Network = require(ReplicatedStorage.ReactiveState.Network)

local protocol = Network.defineFRPProtocol({
    move = {
        direction = Network.CLIENT_INTENT,
        validate = function(value)
            return type(value) == "table"
                and type(value.x) == "number"
                and type(value.z) == "number"
        end,
    },
    world = {
        direction = Network.SERVER_TO_CLIENT,
        validate = function(value)
            return type(value) == "table" and type(value.revision) == "number"
        end,
    },
}, {
    id = "gameplay-v1",       -- 다른 RemoteEvent protocol과 섞이지 않는 stable ID
    schemaVersion = 1,
    replayCapacity = 128,
    pendingCapacity = 128,
    rateLimit = { capacity = 60, refillPerSecond = 30 },
    maxDepth = 8,
    maxElements = 1024,
    maxStringLength = 4096,
    maxBytes = 16384,
})
```

Codec 기본값은 plain Luau value만 허용한다. finite number, boolean, string, nil, metatable·cycle이 없는 table 외의 값은 거부한다. canonical payload에는 `Player`나 `Instance` 대신 stable entity/resource ID를 넣는다.

`defineEventProtocol`, `createEventServer`, `createEventClient`는 같은 API의 설명형 alias다.

## 서버

```lua
local FRP = require(ReplicatedStorage.ReactiveState)
local Overdare = require(ReplicatedStorage.ReactiveState.Overdare)

local host = FRP.newHost()
local driver = Overdare.attachFRP(host, { phase = "Heartbeat" })

local channel = Overdare.attachFRPServerRemote(driver, remoteEvent, {
    protocol = protocol,
    -- 생략하면 game:GetService("Players").PlayerRemoving을 자동 연결한다.
    playerRemovingSignal = Players.PlayerRemoving,

    authorize = function(clientId, messageType, payload)
        return messageType == "move" and canMove(clientId, payload)
    end,

    buildSnapshot = function(clientId, request)
        return {
            messageType = "world",
            payload = projectWorldFor(clientId),
            serverTick = simulationTick,
        }
    end,
})

local stop = channel:intents():subscribe(function(intent)
    -- intent = { clientId, messageType, payload, sequence, clientTick, receivedAt }
    applyValidatedIntent(intent.clientId, intent.payload)
end)

channel:send(player, "world", delta, simulationTick)
channel:broadcast(players, "world", delta, simulationTick)
```

주요 API:

- `intents()`: schema와 authority를 통과한 intent만 나오는 `Event`.
- `violations()`: malformed, duplicate/stale/gap, unauthorized, rate-limit 결과 `Event`.
- `arrivals()`: `{ clientId, stateKey, packet, receivedAt }` 형태의 진단용 raw arrival `Event`.
- `send(playerOrClientId, messageType, payload, serverTick, kind?)`.
- `sendSnapshot(...)`, `sendHeartbeat(...)`.
- `broadcast(players, ...)`: client별 sequence/ack가 다르므로 내부적으로 `FireClient`로 확장한다. sequenced packet에 `FireAllClients`를 쓰지 않는다.
- `bindOutbound(event)`: `{ peer, messageType, payload, serverTick, kind? }` Event를 transport effect에 연결한다.
- `getPeerStatus(clientId)`, `getPlayer(clientId)`, `removePeer(...)`, `dispose()`.

`OnServerEvent`의 첫 번째 `Player`만 transport identity로 신뢰한다. payload 속의 user ID를 발신자로 쓰지 않는다. 기본 stable ID는 `Player.UserId`이며, 다른 테스트 transport는 `getClientId`를 명시한다.

## 클라이언트

```lua
local host = FRP.newHost()
local driver = Overdare.attachFRP(host, { phase = "Heartbeat" })
local channel = Overdare.attachFRPClientRemote(driver, remoteEvent, {
    protocol = protocol,
    initialResync = true, -- 기본값
})

channel:authority():subscribe(function(message)
    -- message = { kind, messageType, payload, epoch, sequence, serverTick, ... }
    applyServerMessage(message)
end)

local status = channel:send("move", { x = 1, z = 0 }, clientTick)
assert(status.ok)
```

주요 API:

- `authority()`: sequence 검증을 통과한 server event/snapshot `Event`.
- `snapshots()`, `violations()`, 진단용 `arrivals()`.
- `send(messageType, payload, clientTick?)`.
- `bindOutbound(event)`: `{ messageType, payload, clientTick? }` Event를 intent 송신에 연결한다.
- `status()`, `pending()`, `requestResync()`, `dispose()`.

클라이언트가 보낸 exact intent packet은 ack 전까지 bounded pending deque에 보존된다. timeout이 지나면 새 prediction이나 새 sequence를 만들지 않고 같은 wire/sequence를 재전송한다.
`eventFromSignal`에서 만든 outbound Event는 입력 Signal callback 안에서 즉시 전송하지 않고 다음 driver phase에서 함께 commit된다. 같은 phase의 `ScriptSignal:Wait()` 재개 순서는 driver의 `Connect` callback 완료 장벽이 아니므로, 동기 확인이 필요한 테스트는 sequence와 payload가 일치하는 새 packet을 제한 시간 동안 기다려야 한다.

## Sequence와 복구

양방향 stream은 client별로 독립적이다.

- `sequence < expected`: duplicate/stale. gameplay Event에 다시 내보내지 않는다.
- `sequence > expected`: gap. state를 진행하지 않고 예상 sequence를 요청한다.
- `sequence == expected`: 정확히 한 번 처리한다.
- Exact sequence의 unknown message, invalid payload, unauthorized intent는 reject하지만 처리된 sequence로 소비하고 ack한다. 그래야 잘못된 한 intent가 이후 입력을 영구히 막지 않는다.
- Envelope 자체가 malformed이거나 protocol/schema가 다르면 sequence를 소비하지 않는다.

Client intent gap은 pending deque에서 `expectedSequence`부터 exact packet을 재전송한다. Server event gap은 client별 replay buffer를 먼저 사용한다. buffer가 구간을 덮지 못하면 `buildSnapshot`으로 새 epoch의 snapshot sequence 1을 보낸다.

마지막 패킷 하나만 사라지면 뒤 sequence가 없어 gap이 드러나지 않는다. 이를 위해:

- client는 `ackTimeout` 후 intent를 재전송한다.
- server adapter는 기본 1초 `heartbeatInterval`로 authoritative sequence를 진행한다.

재시도는 `retryBackoff`, `maxRetryDelay`, `maxRetries`로 제한한다. max retry 알림 뒤에도 capped retry를 계속하며 `onRetryExhausted`를 호출하고 authoritative resync를 요청한다. 초기/gap resync 요청 자체가 유실되는 경우도 `resyncRetryInterval`(기본 1초)마다 같은 epoch/expected sequence로 재전송한다.

Heartbeat는 authoritative packet sequence만 진행하고 마지막 application `serverTick`을 그대로 사용한다. 따라서 paused simulation이나 낮은 빈도의 application tick을 heartbeat가 앞질러 이후 정상 event를 stale로 만들지 않는다.

## 원자성과 자원 제한

Remote callback은 protocol reducer를 즉시 실행하지 않는다. 각 signal은 bounded queue에 들어가고 `Heartbeat`의 Host frame 하나에서 처리된다. `Event.scan` reducer state는 copy-on-write라 frame prepare가 실패하면 client별 sequence/rate state도 commit되지 않는다. Transport 송신은 Host commit 뒤 effect다.

기본 제한:

- Remote binding당 frame queue 128 (`maxPendingPerFrame`).
- Client별 30 packet/s, burst 60 token bucket.
- Packet 16 KiB 추정 budget, depth 8, element 1024, string 4096.
- Replay/pending 각각 128 packet.

Validator, codec, authorize, snapshot callback은 yield할 수 없다. 오류나 yield는 fail-closed status가 되며 gameplay Event에 들어가지 않는다.

정통 Event denotation을 위해 살아 있는 FRP Host는 source prefix를 보존한다. 따라서 production server는 match/session/replication epoch가 Host와 channel을 소유하고 종료 시 `channel:dispose()`, `driver:dispose()`, `host:dispose()`를 호출해야 한다. 영구 world 하나에 같은 Host를 무기한 유지하는 bounded `LiveEvent` 계약은 현재 제공하지 않는다.

## 기존 StateRuntime snapshot/patch

`Network.defineSchema`, `createServer`, `createClient`는 0.1 StateRuntime 호환 API다. client별 visibility/AOI projection, canonical state hash, snapshot/patch, prediction/reconciliation이 필요할 때 계속 사용할 수 있다.

```lua
local schema = Network.defineSchema({
    health = {
        direction = Network.SERVER_TO_CLIENT,
        source = serverHealth,
        target = clientHealth,
    },
    damage = {
        direction = Network.CLIENT_INTENT,
        validate = function(value)
            return type(value) == "number" and value >= 0 and value <= 20
        end,
    },
}, { schemaVersion = 1 })

local server = Network.createServer({ schema = schema, runtime = serverRuntime })
local client = Network.createClient({ schema = schema, runtime = clientRuntime })
```

Transport adapter는 `Overdare.createServerReplication` / `createClientPrediction`이다. 이 호환 경로도 duplicate/stale뿐 아니라 forward intent gap을 거부한다. 새 FRP gameplay Event에는 위의 `defineFRPProtocol` 경로를 사용한다.

실제 process 격리와 engine signature 검증은 [Studio multi-client harness](../examples/StudioMultiplayer/README.md)를 따른다.
