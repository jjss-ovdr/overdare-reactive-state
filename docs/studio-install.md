# OVERDARE Studio 설치

이 문서는 빌드된 `ReactiveState` source package를 World의 `ReplicatedStorage/ReactiveState`에 설치하는 절차다. 현재 배포물은 `0.2.0-rc.1` 비공개 배포 후보이며 Asset Store 공개 최종본이 아니다.

**blank World / 에이전트 주의:** `ReplicatedStorage`에 동명 ModuleScript를 새로 만들어 Atom shim을 넣지 않는다. 이 파일이 소스 오브 트루스이고, 패키지 빌드 후 같은 내용이 `dist/INSTALL.md`로 복사된다. 공식 tree는 단일 파일이 아니라 아래 18-object package다.

## 어떤 API를 쓸지

| 목적 | 진입점 | 문서 |
|---|---|---|
| Push-Pull FRP (`Host`, `Event`, `Reactive`) | `FRP.newHost()` | [`api.md`](./api.md) |
| Atom/Computed 게임 상태 (`:get`/`:set`) | `FRP.createStateRuntime()` | [`state-runtime.md`](./state-runtime.md) |
| shim 호환 Capital (`:Get`/`:Set`, `Transaction`) | `FRP.createCapital()` | [`state-runtime.md`](./state-runtime.md#capital-facade-getset-스타일) |
| 서버 권위형 멀티플레이 | `Network.defineFRPProtocol()` + `Overdare.attachFRP*Remote()` | [`agent-quickstart.md`](./agent-quickstart.md) |

`Capital.Bus`는 로컬 Connect/Fire 버스일 뿐이며 `FRP.Event`가 아니다. `Capital.Event`는 deprecated shim alias다.

## 1. 패키지 생성·검증

저장소 루트에서 실행한다.

```sh
node tools/build-studio-package.mjs
node tools/build-studio-package.mjs --verify
node tools/build-studio-package.mjs --check-normalization
luau tools/studio-package-smoke.luau
```

빌더는 checkout의 CRLF/LF와 무관하게 모든 package source와 text artifact를 LF로 정규화한다. `--check-normalization`은 두 입력 형식이 동일한 package SHA-256을 만드는지 17개 source 전체로 검증한다.

생성물은 다음과 같다.

- `dist/ReactiveState/`: Runtime에 포함할 Luau source tree
- `dist/AGENT_QUICKSTART.md`: 서버 권위형 게임을 위한 task-oriented API 선택 가이드
- `dist/StudioInstaller.luau`: edit-time 자동 설치기
- `dist/ReactiveState.manifest.json`: 파일 해시, Studio package object mapping,
  root attribute와 installed guide 위치, 임시 RSMP 검증 하네스의 class/path/Enabled/source-hash 계약
- `dist/ReactiveState.project.json`: source-tree sync 도구용 최소 project mapping

빌더는 standalone CLI 분석용 root type witness 경로 `./src/Types`를 Studio package에서 `script.Types`로 정확히 한 번 바꾼다. 런타임 로직은 바꾸지 않으며, manifest hash와 installer에는 변환된 Studio source가 들어간다. `--verify`는 이 target-specific 변환까지 대조한다.

## 2. Studio에 설치

먼저 대상 World의 복사본이나 source-control checkpoint를 만든다. Studio의 신뢰할 수 있는 edit-time 명령 실행 환경에서 `dist/StudioInstaller.luau` 전체를 실행한다. 설치기는 다음 동작만 한다.

1. `ReplicatedStorage`에 기존 `ReactiveState`가 있는지 확인한다.
2. 메모리에서 ModuleScript/Folder tree와 source를 구성한다.
3. 모든 구성이 성공한 뒤 root를 `ReplicatedStorage`에 연결한다.
4. 버전·protocol·package SHA-256과 installed guide 위치를 root attributes에 기록한다.

기존 `ReactiveState`가 있거나 source 쓰기 권한이 없으면 아무것도 덮어쓰지 않고 실패한다. 자동 설치를 지원하지 않는 Studio 빌드에서는 `dist/ReactiveState.manifest.json`의 `studioObjects` 배열대로 object를 만들고 각 `sourcePath`의 내용을 대응하는 ModuleScript Source에 복사한 뒤, `install.rootAttributes`를 root에 적용한다.

동일 manifest의 `validationHarness`는 런타임 package 설치 대상이 아니다. disposable
World에서 멀티클라이언트 검증을 할 때만 두 BaseScript를 정확한 class/path로 만들고,
`properties.Enabled == true`와 정규화된 source SHA-256을 확인하는 QA 계약이다.

정상 object tree는 다음과 같다.

```text
ReplicatedStorage
└── ReactiveState (ModuleScript; init.luau)
    ├── AttributePreset (ModuleScript; AttributePreset/init.luau)
    ├── BehaviorTree (ModuleScript; BehaviorTree/init.luau)
    ├── Bridge (ModuleScript; Bridge/init.luau)
    ├── Compat (ModuleScript; Compat/init.luau)
    ├── Core (Folder)
    │   ├── Clock (ModuleScript)
    │   ├── Codec (ModuleScript)
    │   ├── FRP (ModuleScript)
    │   ├── Hash (ModuleScript)
    │   ├── Immutable (ModuleScript)
    │   └── Runtime (ModuleScript)
    ├── Debug (ModuleScript; Debug/init.luau)
    ├── Guides (ModuleScript; Guides.luau)
    ├── Network (ModuleScript; Network/init.luau)
    │   └── EventProtocol (ModuleScript)
    ├── Overdare (ModuleScript; Overdare/init.luau)
    └── Types (ModuleScript; Types.luau)
```

## 3. Studio require 확인

임시 ServerScript에서 실행한다.

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local FRP = require(ReplicatedStorage:WaitForChild("ReactiveState"))

assert(FRP.VERSION == "0.2.0-rc.1")
assert(FRP.API_VERSION == 2)
assert(FRP.SEMANTICS_VERSION == 1)
assert(FRP.Guides.GUIDE_VERSION == 1)
assert(FRP.START_HERE == FRP.Guides.START_HERE)

local host = FRP.newHost()
local changes, emit = host:source({ capture = FRP.Immutable.serializable() })
local value = FRP.stepper(1, changes)

local input = { score = 5 }

host:frame(1, function()
    emit(input)
end)
input.score = 99
local occurrence = changes:occurrences()[1]
assert(table.isfrozen(occurrence))
assert(table.isfrozen(occurrence.value))
assert(occurrence.value.score == 5)
host:dispose()

host = FRP.newHost()
changes, emit = host:source()
value = FRP.stepper(1, changes)
host:frame(1, function()
    emit(5)
end)
assert(value:at(1) == 1)
assert(value:current() == 5)
host:dispose()

local capital = FRP.createCapital({ label = "studio-install.capital" })
local score = capital.Atom(0)
capital.Transaction(function()
    score:Set(1)
end)
assert(score:Get() == 1)
capital:dispose()

print("Push-Pull FRP Studio require PASS")
```

설치기 root attribute에는 legacy `ReactiveStateNetworkProtocolVersion`과 FRP RemoteEvent용 `ReactiveStateEventProtocolVersion`, 그리고 `ReactiveStateGuideVersion` / `ReactiveStateStartHere`가 각각 기록된다. manifest fallback 설치도 `install.rootAttributes`를 그대로 적용한다.

Client에서도 root와 실제 사용할 optional module을 한 번씩 require한다. 그다음 `docs/overdare-checklist.md` 순서로 engine event, RemoteEvent, multi-client, cleanup, Studio benchmark gate를 검증한다.

## 업데이트와 되돌리기

기존 tree 위에 일부 source만 덮어쓰지 않는다. 새 package의 manifest SHA-256을 확인한 뒤 기존 `ReactiveState`를 명시적으로 이름 변경해 보관하고, 새 tree 전체를 설치한다. 검증 실패 시 새 tree를 제거하고 보관한 tree 이름을 되돌린다. state/API/canonical/network protocol version 변경은 애플리케이션 migration과 함께 검토한다.
