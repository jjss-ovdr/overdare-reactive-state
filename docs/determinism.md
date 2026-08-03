# 결정성·Rollback 경계

Rollback을 켠 Runtime 안에서는 다음 데이터가 Runtime 계약 안에 있어야 한다.

- 권위 있는 Atom/Store 원본 상태
- tick별 입력과 stable sequence
- seed와 상태를 보존할 수 있는 PRNG
- snapshot 또는 양방향 journal로 복원할 수 있는 table/value
- Runtime 밖으로 나갈 effect를 나타내는 command

Computed cache, dependency edge, watcher queue는 snapshot 대상이 아니다. 원본 상태를 복원한 뒤 dirty 처리하고 다시 계산한다.

현재 preview 구현은 `history.strategy = "snapshot"`으로 매 tick의 원본 Atom을 bounded full snapshot ring에 저장한다. tick lookup과 capacity 초과 교체는 O(1)이지만, snapshot 생성 자체는 모든 history Atom을 codec으로 encode/hash하므로 상태 크기에 비례한다. 이는 rollback 의미론과 오류 원자성을 먼저 검증하기 위한 선택이다. Journal 또는 reversible patch를 지원한다고 가정하지 않는다.

## 금지되는 입력

- wall clock을 상태 전이에 직접 사용
- 결과에 영향을 주는 `pairs()` 순서
- Computed 안에서 `Instance.Position`, 외부 mutable singleton, engine query를 직접 읽기
- snapshot Atom에 Instance, function, thread, connection, metatable table을 기본 codec으로 저장
- rollback 가능한 command와 영구 보상·저장을 같은 effect로 취급

Engine 값은 정해진 RunService phase에서 Atom 또는 tick input으로 sampling한다. Canonical 상태에는 Instance 대신 stable entity/resource ID를 저장한다.

## Table 계약

기본 equality는 reference/SameValue이며 table 내부 mutation은 자동 감지하지 않는다.

```lua
-- 권장
player:update(function(old)
    return {
        health = old.health - 10,
        armor = old.armor,
    }
end)

-- 자동 감지되지 않음
player:get().health = 10
```

`mutate()`는 history codec으로 이전 값을 clone할 수 있을 때만 사용한다. 기본 Codec은 nil/boolean/number/string과 이 값만 포함한 plain table을 지원하며 executable/engine 객체와 cycle을 거부한다.

## Effect 정책

- `speculative`: 즉시 표현할 수 있지만 cancellation key로 취소·보상 가능해야 한다.
- `confirmed`: rollback window를 벗어난 뒤 idempotency key와 함께 한 번만 실행한다.
- `local`: canonical 게임 상태에 영향을 주지 않는 post-commit 표현이다.

상태 변경은 action/reducer/step 안에서 끝내고, `StepContext:emit()`은 Runtime 밖에서 수행할 의도만 기록한다.

## Native physics

Runtime은 엔진 solver 내부 상태까지 복원한다고 약속하지 않는다.

1. Observe: phase polling 결과만 Atom에 저장한다.
2. Restore fields: 검증된 property와 codec만 복원한다.
3. External authority: native physics 결과를 권위 입력으로 취급하고 논리 상태만 예측한다.

완전한 경쟁형 rollback은 library-owned deterministic simulation 또는 플랫폼이 공식 지원하는 snapshot 경로가 필요하다.
