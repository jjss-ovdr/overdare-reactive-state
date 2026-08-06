# OVERDARE Push-Pull FRP

Conal Elliott의 2009년 논문 [Push-pull functional reactive programming](http://conal.net/papers/push-pull-frp/)을 기준으로 만든 Luau FRP 라이브러리다. `Atom/Computed`를 FRP라고 다시 부르는 구현이 아니라, 논문의 재귀적 정규형을 공개 타입과 실행 의미로 사용한다.

```text
Future<A>   ≅ (futureTime, A)
Reactive<A> = Stepper(initial A, changes Event<A>)
Event<A>    ≅ Future<Reactive<A>>
Fun<T, A>   = Constant(A) | Function(T -> A)
Behavior<A> = Reactive<Fun<Time, A>>
```

현재 버전은 `0.2.0-dev.4`, API version 2, FRP semantics version 1이다. 독립 Luau CLI에서 의미 테스트와 전용 벤치를 통과했지만 실제 OVERDARE Studio server/client 및 target-device gate 전에는 production-ready로 표시하지 않는다.

## 가장 작은 예제

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local FRP = require(ReplicatedStorage:WaitForChild("ReactiveState"))

local host = FRP.newHost()
local damage, emitDamage = host:source()
local health = FRP.accumReactive(100, damage:map(function(amount)
    return function(previous)
        return math.max(0, previous - amount)
    end
end))

health:subscribe(function(value)
    print("health", value)
end)

host:frame(1, function()
    emitDamage(10)
    emitDamage(5) -- 같은 시각의 occurrence도 제거하지 않는다.
end)

assert(health:at(1) == 100)  -- occurrenceTime < sampleTime
assert(health:current() == 85) -- frame commit 뒤 운영상 최신값

host:advanceTo(2)
assert(health:at(2) == 85)
host:dispose()
```

`at(t)`가 정확한 발생 시각에는 이전 값을 반환하는 것은 의도된 의미론이다. `<=`로 바꾸지 않는다.

## Push와 pull

- `Future`, `Event`, `Reactive`의 이산 occurrence가 변경을 push한다.
- 활성 `Behavior` phase가 동적 시간 함수일 때만 정확한 sample time으로 pull한다.
- `Constant` phase는 시간 advance마다 사용자 함수를 다시 실행하지 않는다.
- 아무 sink나 `Reactive`가 요구하지 않는 Event 파이프라인은 source push 때 mapper를 실행하지 않는다.
- 한 logical time의 외부 입력은 `host:frame(t, callback)` 하나에 모아야 한다. 닫힌 time은 재개방할 수 없고, 동시간 merge는 callback 도착 순서가 아니라 그래프의 왼쪽 Event가 먼저다.

논문의 Haskell 구현이 사용하는 laziness, bottom, `unsafePerformIO`, `unamb` thread race를 Luau에서 흉내 내지는 않는다. strict single-threaded Luau에서는 timestamped source, 단조 Host frontier, 닫힌 frame barrier로 같은 denotation을 구현한다. 자세한 대응은 [논문 의미론과 Luau 이식](./docs/push-pull-frp.md)에 있다.

## 타입과 불변성

공개 FRP 타입은 `--!strict`에서 payload `T`를 `source → map/bind/ap/join/snapshot → sink`까지 보존한다. occurrence record의 `time`, `value`, `order`는 읽기 전용으로 선언되고 실제 table도 freeze된다.

generic payload는 함수, Instance, 다른 FRP 값도 허용하므로 기본 deep-copy는 하지 않는다. mutable plain table을 장기간 보존하거나 네트워크 경계에서 받는다면 opt-in capture를 사용한다.

```lua
local capture = FRP.Immutable.serializable()
local packets, emitPacket = host:source({ capture = capture })
local history = FRP.fromOccurrences(host, entries, { capture = capture })
local totals = packets:scan({ total = 0 }, reducer, { capture = capture })
```

기본 serializable capture는 codec clone 뒤 table graph를 재귀적으로 freeze하며 shared alias를 보존한다. capture와 reducer가 오류를 내거나 yield하면 frame은 commit되지 않는다. 자세한 계약은 [Core API](./docs/api.md#타입과-불변-payload)에 있다.

## OVERDARE 연결

엔진 Signal을 각각 즉시 commit하면 같은 엔진 프레임의 동시성이 깨진다. `Overdare.attachFRP`는 입력을 모았다가 RunService phase마다 Host frame 하나로 닫는다.

```lua
local Overdare = require(ReplicatedStorage.ReactiveState.Overdare)
local driver = Overdare.attachFRP(host, {
    phase = "Heartbeat",
})

local activated, binding = driver:eventFromSignal(button.Activated)
local frames = driver:frames()

activated:subscribe(function()
    print("activated")
end)

binding:dispose()
driver:dispose() -- Host는 소유하지 않으므로 살아 있다.
```

한 Host에는 활성 OVERDARE clock driver를 하나만 둘 수 있다. 멀티플레이에서는 패킷 도착 시각을 Event time으로 쓰고 server tick은 payload 데이터로 보존한다.

멀티플레이용 `Network.defineFRPProtocol`과 `Overdare.attachFRPServerRemote` / `attachFRPClientRemote`는 intent-only client, server authority, client별 sequence/ack, rate·payload 제한, exact intent retry, replay buffer와 snapshot epoch를 제공한다. 자세한 전체 예제는 [멀티플레이 Network 경계](./docs/networking.md)에 있다.

## 공개 코어

- `Future`: `pure`, `at`, `never`, `map`, `ap`, `bind`, `join`, `earlier`
- `Event`: `pure`, `never`, `once`, `fromOccurrences`, `map`, `filter`, `merge`, `scan`, `bind`, `join`, `ap`, `snapshot`, `subscribe`; occurrence-aware 확장은 `mapWithTime`
- `Reactive`: `pure`, `stepper`, `map`, `ap`, `bind`, `join`, `switcher`, `at`, `current`, `subscribe`
- `Behavior`: `constant`, `fromFunction`, `time`, `map`, `ap`, `lift2`, `lift3`, `stepper`, `switcher`, `at`, `subscribe`
- `Host`: `source`, `frame`, `advanceTo`, `sample`, `dispose`
- `Immutable`: serializable plain-data clone/freeze capture

논문 정규형의 `Behavior`에는 `bind`/`join`을 제공하지 않는다. 선택적 AI behavior tree는 이름 충돌을 피하려고 `ReactiveState.BehaviorTree`에 있다.

정통 Functor/Monad 법칙을 지키기 위해 `Event.map/bind`와 `Reactive.map/bind` mapper에는 값만 전달한다. occurrence time이 도메인 로직에 필요하면 payload에 넣고, effect/sampling 경계에서는 `mapWithTime` 또는 `snapshot`을 사용한다.

이전 `Atom/Computed/transaction` 구현은 마이그레이션용 `FRP.createStateRuntime()`에 남아 있으며 정통 FRP Core로 취급하지 않는다. 임시 호환 alias `FRP.create()`도 같은 State runtime을 만든다.

## 설치와 검증

### 고정 Luau 도구체인

strict public type gate는 [`tools/luau-toolchain.json`](./tools/luau-toolchain.json)의 공식 Luau source commit `decb2d0526797a175d7c5ba8d4d78858ced98553`을 기준으로 한다. `luau-lsp analyze`는 편집기용 frontend이며 이 gate의 `luau-analyze` 대체물이 아니다. 오래된 analyzer가 `read` property 또는 recursive generic을 지원하지 않으면 `tools/check-frp-types.mjs`가 capability probe에서 즉시 중단한다.

공식 Luau를 같은 commit으로 빌드할 때는 다음 target을 사용한다.

```sh
git clone https://github.com/luau-lang/luau.git .tooling/luau
git -C .tooling/luau checkout decb2d0526797a175d7c5ba8d4d78858ced98553
cmake -S .tooling/luau -B .tooling/luau/cmake -DCMAKE_BUILD_TYPE=RelWithDebInfo
cmake --build .tooling/luau/cmake --target Luau.Repl.CLI --config RelWithDebInfo
cmake --build .tooling/luau/cmake --target Luau.Analyze.CLI --config RelWithDebInfo
```

생성된 `luau`와 `luau-analyze`를 PATH에 두거나 `LUAU_ANALYZE=/absolute/path/to/luau-analyze`를 지정한다. `.tooling/`은 git에서 제외되며 임시 검증용으로만 사용한다.

```sh
node tools/build-studio-package.mjs
node tools/build-studio-package.mjs --verify
node tools/build-studio-package.mjs --check-normalization
luau tools/studio-package-smoke.luau

luau tests/run.luau
luau -O2 tests/run.luau
luau -O2 --codegen tests/run.luau
luau-analyze src tests examples benchmarks
node tools/check-frp-types.mjs
```

전용 FRP 벤치:

```sh
luau -O1 benchmarks/frp-run.luau -a standard O1
luau -O2 benchmarks/frp-run.luau -a standard O2
luau -O2 --codegen benchmarks/frp-run.luau -a standard O2-codegen
```

멀티플레이 protocol 벤치:

```sh
luau -O1 benchmarks/multiplayer-run.luau -a standard O1
luau -O2 benchmarks/multiplayer-run.luau -a standard O2
luau -O2 --codegen benchmarks/multiplayer-run.luau -a standard O2-codegen
```

현재 자동 검증은 140개 test, 8개 Push-Pull FRP workload, 8개 multiplayer protocol workload를 포함한다. 그중 fake RemoteEvent 기반 2-client test는 격리, 권한, phase-buffered outbound binding, opaque engine callable, duplicate/stale/gap, 양방향 유실·재전송, replay miss→snapshot, queue/packet limit과 disposal을 포함한다. CLI 수치는 회귀 baseline이며 실제 Studio/기기 성능을 대신하지 않는다.

## 문서

- [논문 의미론과 Luau 이식](./docs/push-pull-frp.md)
- [Core API](./docs/api.md)
- [아키텍처](./docs/architecture.md)
- [OVERDARE Studio 설치](./docs/studio-install.md)
- [성능 전략과 결과](./docs/performance.md)
- [멀티플레이 Network 경계](./docs/networking.md)
- [기존 StateRuntime API](./docs/state-runtime.md)

## 라이선스

MIT. 논문과 참고 프로젝트의 코드를 복사하지 않은 독립 구현이며 출처와 라이선스는 [NOTICE.md](./NOTICE.md)에 정리했다.
