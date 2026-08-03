# ReactiveState

OVERDARE Studio용 Luau-first push-pull 반응형 상태 Runtime이다. 일반 Luau 함수와 제어 흐름은 그대로 두고, 상태·파생값·원자적 변경이 필요한 경계에서만 사용한다.

> 현재 상태: `0.1.0-dev.1` preview. 독립 Luau Runtime에서 검증 중이며 OVERDARE Studio multi-client/Asset Store gate를 통과하기 전에는 1.0으로 배포하지 않는다.

## 특징

- Runtime별로 완전히 격리된 Atom, lazy Computed, post-commit Watch
- 오류 시 write를 폐기하는 nested atomic transaction
- dynamic dependency, cycle/cross-Runtime/write-in-Computed 진단
- 안정적인 watch priority/creation 순서와 Scope disposal
- 같은 commit 계약을 사용하는 Store와 fixed tick
- opt-in bounded snapshot history/rollback/replay와 command outbox
- schema 기반 Network, one-way Bridge, OVERDARE adapter
- optional Behavior와 AttributePreset facade
- `io`, `package`, C module, 숨은 Heartbeat/game loop 의존 없음

## 가장 작은 사용법

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local State = require(ReplicatedStorage:WaitForChild("ReactiveState"))

local runtime = State.create()
local price = runtime:atom(100, { label = "price" })
local quantity = runtime:atom(2, { label = "quantity" })

local total = runtime:computed(function()
    return price:get() * quantity:get()
end, { label = "total" })

local stop = runtime:watch(total, function(value)
    print("total", value)
end)

runtime:transaction(function()
    price:set(120)
    quantity:set(3)
end)

-- 화면/round/match 수명이 끝날 때
stop()
runtime:dispose()
```

Watch는 transaction의 중간값을 보지 않고 최종값 `360`을 한 번만 본다. 아무도 `total`을 읽거나 watch하지 않으면 Atom write 시 getter를 실행하지 않는다.

## 쓰기 ownership

Writable Atom은 애플리케이션의 Domain State Module 안에 숨기고, 외부에는 read-only Source와 action을 공개하는 패턴을 권장한다.

```lua
local runtime = State.create()
local healthAtom = runtime:atom(100, { label = "player.health" })

local function damage(amount)
    runtime:transaction(function()
        healthAtom:update(function(health)
            return math.max(0, health - amount)
        end)
    end)
end

return {
    runtime = runtime,
    health = healthAtom:asReadonly(),
    damage = damage,
}
```

`asReadonly()`는 같은 실행 환경의 ownership 규율이지 보안 경계가 아니다. Client intent는 서버에서 별도로 검증해야 한다.

## Optional module

Root ModuleScript는 Core만 load한다. 필요한 module만 명시적으로 가져온다.

```lua
local Bridge = require(ReplicatedStorage.ReactiveState.Bridge)
local Network = require(ReplicatedStorage.ReactiveState.Network)
local Overdare = require(ReplicatedStorage.ReactiveState.Overdare)
local Behavior = require(ReplicatedStorage.ReactiveState.Behavior)
local AttributePreset = require(ReplicatedStorage.ReactiveState.AttributePreset)
local Debug = require(ReplicatedStorage.ReactiveState.Debug)
```

Bridge는 서로 다른 Runtime 사이의 one-way 전달, Network는 server/client schema payload, Overdare는 RunService/Instance/RemoteEvent 경계만 담당한다. 어느 것도 Core에 자동 연결되지 않는다.

## 설치

`src`를 하나의 `ReactiveState` ModuleScript tree로 배치한다. 포함된 [`default.project.json`](./default.project.json)은 `src/init.luau`를 root ModuleScript로, 하위 디렉터리를 optional child로 매핑한다.

Studio에 넣을 검증 가능한 package와 edit-time 설치기를 만들려면 다음을 실행한다.

```sh
node tools/build-studio-package.mjs
node tools/build-studio-package.mjs --verify
luau tools/studio-package-smoke.luau
```

결과는 `dist/ReactiveState`, `dist/StudioInstaller.luau`, `dist/ReactiveState.manifest.json`에 생성된다. 실제 배치·require 확인·업데이트 절차는 [OVERDARE Studio 설치](./docs/studio-install.md)에 있다.

공용 package는 `ReplicatedStorage`에 둘 수 있지만 서버 전용 validator, secret, visibility 정책은 `ServerScriptService` 또는 `ServerStorage`의 애플리케이션 코드에 둔다.

현재 preview의 Timeline은 안전성을 우선해 tick별 full snapshot을 bounded ring에 보존한다. `history.strategy = "snapshot"`만 지원하며, 전략 문서의 journal/patch 최적화는 메모리·성능 gate를 통과한 뒤 추가할 항목이다.

## 테스트

공식 Luau CLI가 PATH에 있을 때:

```sh
luau tests/run.luau
luau-analyze src tests examples benchmarks
```

독립 CLI 테스트는 최종 Studio gate를 대체하지 않는다. 배포 전에는 OVERDARE Studio에서 server/client require, Stepped/Heartbeat/RenderStepped, physics sampling, RemoteEvent, multi-client, Scope cleanup을 별도로 검증해야 한다.

현재 자동 검증은 Core 회귀·property·Network·adapter 통합을 포함한 52개 case다.

전략 문서의 10개 성능 workload는 같은 suite를 독립 Luau와 Studio에서 실행하도록 구성했다.

```sh
luau benchmarks/run.luau -a standard O1
luau -O2 benchmarks/run.luau -a standard O2
luau --codegen benchmarks/run.luau -a standard codegen
```

독립 Luau baseline은 구현 회귀 비교용이며 Studio/대상 기기의 절대 성능을 대신하지 않는다. 실행법과 현재 측정 결과는 [성능 전략과 결과](./docs/performance.md)에 있다.

## 문서

- [설계와 참고 구현](./docs/architecture.md)
- [Core API](./docs/api.md)
- [Network와 prediction](./docs/networking.md)
- [결정성·rollback 경계](./docs/determinism.md)
- [성능 전략과 결과](./docs/performance.md)
- [OVERDARE Studio 설치](./docs/studio-install.md)
- [OVERDARE Studio 검증 체크리스트](./docs/overdare-checklist.md)
- [예제](./examples)

## 라이선스

MIT. 이 구현은 독립 작성했으며 참고한 프로젝트와 라이선스는 [NOTICE.md](./NOTICE.md)에 정리했다.
