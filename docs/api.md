# Push-Pull FRP Core API

모든 코어 값은 하나의 `Host`에 속한다. 서로 다른 Host의 Event/Reactive/Behavior를 결합하면 오류다. 조합자 callback은 순수하고 동기식이어야 하며 yield하면 frame이 중단된다.

## Host

```lua
local FRP = require(ReplicatedStorage.ReactiveState)
local host = FRP.newHost({
    startTime = 0,
    onError = function(kind, message, details)
        warn(kind, message)
    end,
})
```

- `host:source(options?) -> Event, emit`: timestamped 외부 입력 경계.
- `host:frame(time, callback?)`: 한 logical time의 root occurrence를 원자적으로 수집·평가·commit한다.
- `host:advanceTo(time)`: 예약된 Future occurrence를 처리하고 continuous Behavior sink를 sample한다.
- `host:sample(behavior, time?)`: 필요하면 먼저 advance한 뒤 `Behavior:at(time)`을 반환한다.
- `host:now()`: 마지막으로 닫힌 frame time.
- `host:getErrors()`: 격리된 sink 오류 복사본.
- `host:dispose()`: sink, 예약 occurrence, graph ownership을 해제한다.

시간은 유한한 non-NaN number이며 Host는 뒤로 갈 수 없다. 닫힌 logical time은 다시 열 수 없다. 같은 time의 여러 source는 반드시 frame 하나에 넣어야 하며, sink 안의 재진입 occurrence는 명시적인 미래 time으로 예약해야 한다. 같은 time의 예약된 Future와 frame root는 Host가 한 barrier로 합친다.

```lua
host:frame(10, function()
    emitLeft("L")
    emitRight("R")
end)
```

## Future

`Future<A>`는 `(-∞ | finite time | +∞, A)`의 정규형이다.

```lua
local ready = FRP.Future.at(3, "ready")
local unit = FRP.Future.pure("available") -- -∞
local never = FRP.Future.never()           -- +∞
```

- `map`: time 유지.
- `ap`, `bind`, `join`: 의존하는 time을 `max`로 결합한다. 항등원은 `-∞`다.
- `earlier`/`alt`: 두 대안 중 `min` time. 동률은 왼쪽을 고른다. 항등원은 `never`다.
- `force() -> time, value`, `isNever()`, `getTime()`, `getValue()`.

`Future.at(math.huge, value)`는 허용하지 않는다. `+∞`는 `never()`만 나타낸다.

## Event

`Event<A>`는 time 비감소 occurrence 목록이다. 같은 time과 같은 payload도 별개로 보존한다.

```lua
local input, emit = host:source({ label = "input" })
local finite = FRP.Event.fromOccurrences(host, {
    { 1, "a" },
    { 1, "b" },
    { 3, "c" },
})
```

생성:

- `FRP.Event.never(host)`
- `FRP.Event.pure(host, value)`: “지금”이 아니라 `-∞` occurrence다.
- `FRP.Event.once(host, time, value)`
- `FRP.Event.fromOccurrences(host, orderedEntries)`
- `host:eventFromFuture(future)`

조합:

- `event:map(fn)`, `filter(predicate)`: lawful callback에는 payload 값만 전달한다.
- `event:mapWithTime(fn)`: occurrence time 관찰이 필요한 명시적 확장. 정통 Functor/Monad 조합에는 사용하지 않는다.
- `left:merge(right)`: 시간순 stable merge. tie에서는 왼쪽의 같은-time occurrence 전체가 먼저다.
- `event:scan(initial, reducer)`
- `event:bind(fn)`, `join()`: inner time을 `max(outerTime, innerTime)`으로 끌어올리고 모든 생성 stream을 stable merge한다.
- `functions:ap(values)`: Event Monad에서 파생된 Cartesian occurrence product.
- `event:snapshot(behavior, combine?)`: occurrence time에서 Behavior를 strict-before sample하는 명시적 확장.
- `event:subscribe(callback, options?) -> disconnect`
- `event:occurrences(untilTime?)`: 테스트·진단용으로 닫힌 prefix를 복사한다.

`fromOccurrences`는 immutable denotation constructor라서 이미 닫힌 frontier보다 이른 finite occurrence도 표현할 수 있다. 이런 과거 occurrence는 `bind`의 `max` 계산과 진단 pull에는 참여하지만 새 live subscriber에게 재생되지 않는다. `occurrences()` 조회는 `scan/bind`의 운영 상태를 변경하거나 과거로 되감지 않는다.

논문의 타입대로 `Event.map`은 `A -> B`, `Event.bind`는 `A -> Event<B>`이며 occurrence time을 숨긴다. time을 bind mapper의 숨은 두 번째 인자로 사용하면 결합법칙이 깨지므로 지원하지 않는다. 시간이 도메인 로직에 필요하면 payload에 넣고, sampling처럼 occurrence 자체를 관찰하는 경계에서는 `mapWithTime` 또는 `snapshot`을 쓴다.

`subscribe`는 기본적으로 `-∞` occurrence를 전달하지만 이미 끝난 finite occurrence는 재생하지 않는다.

## Reactive

`Reactive<A> = Stepper(initial, changes Event<A>)`다.

```lua
local state = FRP.stepper(0, changes)
local doubled = state:map(function(value)
    return value * 2
end)
```

- `initial()`, `changes()`
- `at(time)`: `occurrenceTime < time`인 마지막 값.
- `current()`: 마지막 commit 뒤 운영상 최신값. `at(host:now())`와 다를 수 있다.
- `map`, `ap`, `bind`, `join`
- `reactive:switcher(eventOfReactive)`
- `subscribe(callback, options?)`: change edge를 먼저 설치하고 current를 한 번 전달한 뒤 모든 change occurrence를 전달한다. 따라서 initial callback이 첫 frame을 동기적으로 만들더라도 change를 잃지 않는다.

동시간 Applicative는 함수 Reactive 변화 전체를 먼저, 값 Reactive 변화를 다음에 적용한다. `join`에서는 기존 inner 변화가 outer switch보다 먼저이고 switch 뒤의 기존 inner 미래는 폐기된다.

누적 helper:

```lua
local count = FRP.accumReactive(0, updates) -- Event<(A) -> A>
local totals = FRP.accumEvent(0, updates)
```

## TimeFunction과 Behavior

`TimeFunction<A>`는 `Constant(A)` 또는 `Function(Time -> A)`다. 상수끼리의 map/ap는 `Constant`를 유지한다.

`Behavior<A> = Reactive<TimeFunction<A>>`다.

```lua
local elapsed = FRP.time(host)
local offset = FRP.constant(host, 10)
local position = FRP.lift2(function(time, start)
    return time + start
end, elapsed, offset)

host:advanceTo(2.5)
assert(position:at(2.5) == 12.5)
```

생성·조합:

- `FRP.constant(host, value)` / `Behavior.constant`
- `FRP.fromFunction(host, timeFn)`
- `FRP.time(host)`
- `behavior:map(fn)`, `functionBehavior:ap(argumentBehavior)`
- `FRP.lift2`, `FRP.lift3`
- `FRP.stepperBehavior(initial, event)`
- `behavior:switcher(eventOfBehavior)`
- `behavior:at(time)`, `current()`, `subscribe()`

Behavior 양쪽 Applicative input은 같은 정확한 time으로 sample된다. 논문의 RNF에는 Behavior Monad가 없으므로 `Behavior.bind/join`은 제공하지 않는다.

Behavior sink는 renderer다. Constant phase는 phase 진입 때 한 번, dynamic phase는 Host time이 advance할 때마다 pull·전달한다. 한 frame에 phase occurrence가 여러 개이거나 같은 phase object가 중복되어도 모두 순서대로 전달한다. `initial = false`는 초기 TimeFunction도 pull하지 않는다. phase occurrence의 callback은 commit 뒤 새 renderer phase를 나타내며, 순수 `Behavior:at(exactOccurrenceTime)`은 여전히 이전 phase다.

## 수명과 prefix 보존

임의의 동적 `Event.bind`가 과거 inner occurrence를 선택할 수 있으므로 살아 있는 Host는 source prefix와 Reactive history를 보존한다. 이를 임의로 잘라내면 논문의 denotation이 바뀐다. 버린 downstream graph는 weak dependency edge 덕분에 수거되며 `host:dispose()`는 남은 graph edge, callback, prefix를 모두 끊는다. 장기 서버에서는 match/session/replication epoch마다 Host를 만들고 epoch 종료 시 dispose하는 방식을 권장한다.

## OVERDARE driver

```lua
local Overdare = require(ReplicatedStorage.ReactiveState.Overdare)
local driver = Overdare.attachFRP(host, { phase = "Heartbeat" })
local activated, binding = driver:eventFromSignal(button.Activated, {
    map = function(...) return ... end,
})
local frames = driver:frames()
```

Signal callback은 pending queue에만 넣고 phase callback이 한 번의 Host frame으로 flush한다. 그래서 Signal 도착 순서와 무관하게 Event merge의 구조적 tie 순서가 유지된다. binding/driver disposer는 idempotent하며 driver는 Host를 dispose하지 않는다.
