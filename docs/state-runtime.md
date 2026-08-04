# 기존 StateRuntime API

이 문서는 0.1의 `Atom/Computed/transaction` 호환 계층을 설명한다. 정통 FRP API는 [`api.md`](./api.md)를 사용한다. 새 인스턴스는 `FRP.createStateRuntime(options)`로 만든다. `FRP.create(options)`는 마이그레이션 기간의 deprecated alias다.

## Runtime 만들기

```lua
local FRP = require(ReplicatedStorage.ReactiveState)

local runtime = FRP.createStateRuntime({
    label = "match-42",
    deterministic = true,
    history = {
        strategy = "snapshot",
        capacity = 180,
    },
    effects = "confirmed",
    commandNamespace = "match-42",
    onError = function(detail)
        warn(detail.kind, detail.message)
    end,
})
```

주요 option:

- `label`: trace와 오류에 표시할 Runtime 이름.
- `deterministic`: `step()` tick을 연속 증가하도록 검사한다.
- `history`: `true` 또는 `{ strategy = "snapshot", capacity = number }`. Preview에서는 full snapshot만 지원한다.
- `effects`: command 기본 정책인 `"confirmed"`, `"speculative"`, `"local"` 중 하나.
- `commandNamespace`: 결정적인 command ID prefix.
- `trace`/`traceHandler`: 구조화된 trace event callback.
- `onError`: commit 이후 watch/trace/queued transaction 오류 callback.
- `maxReactionChain`: watch가 연속 transaction을 만드는 횟수의 상한. 기본 100.
- `maxEvaluationDepth`: 중첩 pull이 host stack을 넘기 전에 진단하는 상한. 기본 128이며, 더 큰 값은 대상 VM에서 depth probe를 통과한 뒤에만 사용한다.

Runtime은 ModuleScript 전역 singleton이 아니다. 서버 match, 클라이언트 confirmed/predicted world, 테스트마다 별도로 만든다.

## Atom과 Source

```lua
local health = runtime:atom(100, {
    label = "player.health",
    validate = function(value)
        return type(value) == "number" and value >= 0, "health must be non-negative"
    end,
})

health:set(90)
health:update(function(value)
    return value - 10
end)

local publicHealth = health:asReadonly()
```

- `get()`은 현재 transaction의 staged 값까지 읽는다.
- `set(value)`, `update(fn)`, `mutate(fn)`, `touch()`는 transaction 안에서는 write를 stage한다.
- Transaction 밖의 write는 한 번의 implicit transaction을 만든다.
- `mutate()`는 codec으로 값을 먼저 복제한다. 기본 codec이 복제할 수 없는 값에는 custom codec이 필요하다.
- `touch()`는 equality상 같은 값도 revision을 올리지만 watch의 equality는 여전히 callback을 억제할 수 있다.
- `asReadonly()`는 같은 Atom에 대해 안정적인 Source view를 반환한다. 쓰기 ownership 규율이지 보안 경계는 아니다.
- 기본 equality는 identity/SameValue 계열이다. `NaN`끼리는 같고 table 내부 변경은 자동 감지하지 않는다.

Atom option에는 `label`, `equality`, `validate`, `codec`, `history = false`, `transient = true`가 있다. History가 시작된 뒤에는 timeline schema를 바꾸지 못하므로 새 Atom을 만들 수 없다.

## Computed

```lua
local alive = runtime:computed(function()
    return health:get() > 0
end, { label = "player.alive" })
```

- `get()`은 dependency로 추적하면서 필요할 때만 계산한다.
- `peek()`은 호출자의 dependency에는 등록하지 않고 값을 읽는다.
- 조건부로 읽은 Source가 달라지면 성공한 평가 뒤 dependency edge를 교체한다.
- Upstream Computed 결과가 equality상 같으면 pending downstream getter를 다시 실행하지 않는다.
- Getter 오류 시 기존 committed cache와 dependency를 유지한다.
- Getter에서 write, yield, 다른 Runtime Source read, 직접/간접 cycle은 오류다.

## Transaction

```lua
local changeSet = runtime:transaction(function()
    health:set(80)
    stamina:set(50)
end, {
    cause = "damage",
})
```

Transaction은 값과 command를 overlay에 stage한 뒤 prepare가 성공해야 publish한다. Callback, updater, reducer, validator, equality, codec 또는 watched Computed가 실패하면 Atom 값, revision, history, outbox와 watch를 변경하지 않는다.

Nested transaction은 outer transaction에 합류하는 batch이지 savepoint가 아니다. Inner 오류를 `pcall()`로 삼켜도 root는 rollback-only가 되어 실패한다. Root 호출만 `ChangeSet`을 반환하고 nested 호출과 watch 중 queued 호출은 `nil`을 반환한다. `batch`는 같은 구현의 별칭이다.

모든 reactive callback은 동기식이어야 한다. `coroutine.yield()`나 비동기 continuation 전까지 transaction을 유지하는 방식은 지원하지 않는다.

## Watch

```lua
local stop = runtime:watch(alive, function(value, previous, changeSet)
    print(value, previous, changeSet and changeSet.cause)
end, {
    initial = true,
    priority = 0,
    replay = "coalesce",
    label = "alive presentation",
})
```

- Watch는 안정된 commit 뒤 `(priority, creation id)` 순서로 실행한다.
- 같은 transaction에서 최종값만 한 번 관찰한다.
- `initial`은 기본 `true`다.
- `equality`로 callback 억제를 바꿀 수 있다.
- `replay`는 `"coalesce"`, `"all"`, `"suppress"` 중 하나다.
- Watch 중 write/transaction은 현재 callback stack에 재진입하지 않고 다음 transaction queue에 들어간다.
- Post-commit callback 오류는 state를 되돌리지 않는다. `ChangeSet.watchErrors`와 Runtime `onError`로 보고하고 다음 watch를 계속 실행한다.
- 반환된 `stop()`은 idempotent하다.

## Scope

```lua
local scope = runtime:scope()
scope:add(stop)
scope:add(connection)
scope:dispose()
```

Scope는 function 또는 `dispose`, `Destroy`, `Disconnect`, `destroy` method가 있는 객체를 받는다. 역순으로 한 번씩 정리하며 Runtime dispose 시 남은 Scope도 정리한다.

## Store

```lua
local store = runtime:store({
    label = "score",
    initialState = { value = 0 },
    reducer = function(state, action)
        if action.type == "Add" then
            return { value = state.value + action.amount }
        end
        return state
    end,
})

local score = store:select(function(state)
    return state.value
end)

store:dispatch({ type = "Add", amount = 10 })
```

Store는 별도 엔진이 아니라 내부 Atom, Computed와 transaction을 사용하는 facade다. Outer transaction 안의 `dispatch()`는 `nil`, root dispatch는 `ChangeSet`을 반환한다.

## Tick, snapshot과 replay

```lua
runtime:step(1, function(ctx)
    position:update(integrate)
    ctx:emit("PlaySound", { id = "hit" }, { policy = "confirmed" })
end)

local snapshot = runtime:snapshot()
runtime:rollback(0)
runtime:replay(0, 1, function(ctx, tick)
    applyRecordedInput(ctx, tick)
end)
```

- `step(tick, callback)`은 성공할 때만 tick을 진행한다.
- History가 켜져 있고 첫 tick이 1이면 첫 step 직전 상태를 tick 0으로 보존한다.
- `snapshot()`은 history 대상 Atom만 codec으로 encode한다. Computed cache와 graph edge는 포함하지 않는다.
- `restore(snapshot)`은 전체 decode/validation 후 한 transaction으로 적용한다.
- `rollback(tick)`은 retained snapshot으로 복원하며 Atom revision을 되감지 않는다.
- `replay(fromTick, toTick, provider)`은 rollback 뒤 input을 순서대로 적용한다. 실패하면 시작 checkpoint로 복구한다.
- `replay = "coalesce"` watch는 replay 전후 값이 다를 때만 마지막에 한 번 실행한다.
- `getStateHash()`는 drift 탐지용 canonical 비암호학적 hash다.
- `discardAfter(tick)`은 미래 snapshot과 미확정 command를 제거하고 취소 목록을 반환한다.

현재 history는 bounded full snapshot이다. Native physics solver, 외부 mutable table, wall clock, Instance를 자동 복원하지 않는다.

## Command outbox

`StepContext:emit(type, payload, options)`은 외부 작업을 실행하지 않고 data command만 ChangeSet과 outbox에 기록한다.

- `confirmed`: `runtime:confirm(tick)` 이후 반환된 command를 idempotency key와 함께 실행한다.
- `speculative`: 호출자가 ChangeSet에서 즉시 표현할 수 있지만 rollback 시 취소 가능한 작업이어야 한다.
- `local`: canonical 상태에 영향을 주지 않는 로컬 표현용이다.

Default codec payload만 허용한다. Custom codec을 지정하더라도 encode 결과는 plain serializable data여야 한다. `confirm()`은 idle Runtime에서만 가능하며 confirmed tick 아래로 rollback할 수 없다.

## Debug와 종료

- `getDebugSnapshot()`은 node 상태, dependency, revision, history/outbox 수를 반환한다.
- `trace(eventName, fields?)`는 설정된 trace handler로 adapter event를 보낸다.
- `dispose()`는 watch, Scope와 dependency edge를 idempotent하게 정리한다.
- Dispose 뒤 Source read/write는 오류다.
