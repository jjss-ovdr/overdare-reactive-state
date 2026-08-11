# ReactiveState agent quickstart

이 문서는 빈 OVERDARE World에서 게임을 만드는 사용자와 에이전트가 구현 소스를
역으로 읽지 않고 권장 공개 API를 선택하도록 돕는다. 빌드하면
`dist/AGENT_QUICKSTART.md`에도 같은 내용이 들어간다.

설치된 Studio package만 있다면 먼저 root의 내장 가이드를 읽는다.

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local packageRoot = ReplicatedStorage:WaitForChild("ReactiveState")
local ReactiveState = require(packageRoot)

print(ReactiveState.START_HERE)
local guide = ReactiveState.Guides.serverAuthoritativeMultiplayer
print(guide.protocol, guide.serverTransport, guide.clientTransport)
```

`ReactiveState.Guides`는 설명 데이터만 반환한다. require만으로 Instance, signal
connection, RemoteEvent channel을 만들지 않는다.

## 요청에서 API 고르기

| 사용자 요청 | 상태 API | 경계 API |
|---|---|---|
| 로컬 HUD, 설정, 단일 프로세스 점수·라운드 | `createCapital()` 또는 `createStateRuntime()` | 없음 |
| 시간과 occurrence 순서가 핵심인 입력·시뮬레이션 | `newHost()` + `Event`/`Reactive` | 필요할 때 `Overdare.attachFRP()` |
| 서버 권위형 멀티플레이 점수·인벤토리·전투 | 도메인에 맞춰 위 둘 중 하나 | `Network.defineFRPProtocol()` + `Overdare.attachFRP*Remote()` |

`Capital.Bus()`는 한 프로세스 안의 로컬 신호다. RemoteEvent 대신 사용할 수 없다.
반대로 `Network`는 상태 저장소가 아니라 client intent와 server authority 사이의
프로토콜 경계다. 서버 권위형 게임은 상태 API와 경계 API를 함께 사용한다.

## 서버 권위형 게임의 기본 형태

### 1. 양쪽에서 같은 protocol을 선언한다

```lua
local Network = require(ReplicatedStorage.ReactiveState.Network)

local protocol = Network.defineFRPProtocol({
    collectCoin = {
        direction = Network.CLIENT_INTENT,
        validate = function(payload)
            return type(payload) == "table" and type(payload.coinId) == "string"
        end,
    },
    race = {
        direction = Network.SERVER_TO_CLIENT,
        validate = function(snapshot)
            return type(snapshot) == "table"
                and type(snapshot.round) == "number"
                and type(snapshot.coinsLeft) == "number"
        end,
    },
}, {
    id = "coin-race-v1",
    schemaVersion = 1,
    rateLimit = { capacity = 20, refillPerSecond = 10 },
    replayCapacity = 64,
    pendingCapacity = 32,
    maxDepth = 8,
    maxElements = 256,
    maxStringLength = 256,
    maxBytes = 8192,
})
```

클라이언트 intent에는 점수나 전체 상태를 넣지 않는다. `coinId`, 버튼 동작처럼
서버가 다시 검증할 수 있는 최소 요청만 넣는다.

### 2. 서버에서 검증하고 authoritative state를 보낸다

```lua
local ReactiveState = require(ReplicatedStorage.ReactiveState)
local Overdare = require(ReplicatedStorage.ReactiveState.Overdare)

local host = ReactiveState.newHost()
local driver = Overdare.attachFRP(host, { phase = "Heartbeat" })
local channel = Overdare.attachFRPServerRemote(driver, raceRemote, {
    protocol = protocol,
    authorize = function(clientId, messageType, payload)
        return messageType == "collectCoin" and canCollect(clientId, payload.coinId)
    end,
    buildSnapshot = function(clientId, request)
        return {
            messageType = "race",
            payload = projectRaceFor(clientId),
            serverTick = simulationTick,
        }
    end,
})

local stopIntents = channel:intents():subscribe(function(intent)
    -- sender identity is intent.clientId; never trust a user id inside payload.
    applyValidatedCoinIntent(intent.clientId, intent.payload)
    channel:broadcast(activePlayers, "race", makeRaceSnapshot(), simulationTick)
end)
```

`authorize`를 통과한 intent만 gameplay Event에 들어온다. 점수 계산, 참가자 roster,
남은 코인 수와 승자 판정은 서버가 소유한다.

### 3. 클라이언트는 authority만 화면에 반영한다

```lua
local host = ReactiveState.newHost()
local driver = Overdare.attachFRP(host, { phase = "Heartbeat" })
local channel = Overdare.attachFRPClientRemote(driver, raceRemote, {
    protocol = protocol,
    initialResync = true,
})

local stopAuthority = channel:authority():subscribe(function(message)
    if message.messageType == "race" then
        renderRace(message.payload)
    end
end)

local status = channel:send("collectCoin", { coinId = selectedCoinId })
assert(status.ok)
```

세션이 끝나면 subscription, channel, driver, Host 순서로 정리한다. Capital 또는
StateRuntime을 별도로 만들었다면 그것도 같은 match/session owner가 dispose한다.

## 구현 전에 지킬 불변 조건

- 한 라운드의 참가자 ID를 고정하고 join/leave 시 계속할지 취소할지 명시한다.
- collection 개수는 상수가 아니라 authoritative collection에서 계산한다.
- reactive transaction이 성공한 뒤 Instance 변경과 네트워크 송신을 실행한다.
- client payload의 score, userId, snapshot을 권위 있는 값으로 사용하지 않는다.
- sequence, rate limit, retry, replay, resync를 raw RemoteEvent callback으로 다시 만들지 않는다.
- 프로젝트 전용 `ReactiveState` shim을 만들지 않는다.

## 완료 증거

문법 검사만으로 멀티플레이 완료를 선언하지 않는다.

1. 1 client: 최초 snapshot, 재접속, UI 반영
2. 2 clients: 권한 분리, 동시 intent, 중복 packet, 라운드 종료와 재시작
3. 3rd client / disconnect: spectator 또는 roster 교체 정책
4. malformed·과대·고빈도 payload 거부와 rate-limit 결과
5. channel/driver/Host dispose 후 callback과 pending queue가 남지 않음
6. 테스트 직후 생성된 fresh log와 package version/SHA 기록

전체 protocol 옵션과 status 계약은 [`networking.md`](./networking.md)를 본다.
