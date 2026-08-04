# OVERDARE Studio 설치

이 문서는 빌드된 `ReactiveState` source package를 World의 `ReplicatedStorage/ReactiveState`에 설치하는 절차다. 현재 배포물은 `0.2.0-dev.1` preview이며 Asset Store 공개 배포용 최종본이 아니다.

## 1. 패키지 생성·검증

저장소 루트에서 실행한다.

```sh
node tools/build-studio-package.mjs
node tools/build-studio-package.mjs --verify
luau tools/studio-package-smoke.luau
```

생성물은 다음과 같다.

- `dist/ReactiveState/`: Runtime에 포함할 Luau source tree
- `dist/StudioInstaller.luau`: edit-time 자동 설치기
- `dist/ReactiveState.manifest.json`: 파일 해시와 Studio object mapping
- `dist/ReactiveState.project.json`: source-tree sync 도구용 최소 project mapping

## 2. Studio에 설치

먼저 대상 World의 복사본이나 source-control checkpoint를 만든다. Studio의 신뢰할 수 있는 edit-time 명령 실행 환경에서 `dist/StudioInstaller.luau` 전체를 실행한다. 설치기는 다음 동작만 한다.

1. `ReplicatedStorage`에 기존 `ReactiveState`가 있는지 확인한다.
2. 메모리에서 ModuleScript/Folder tree와 source를 구성한다.
3. 모든 구성이 성공한 뒤 root를 `ReplicatedStorage`에 연결한다.
4. 버전·protocol·package SHA-256을 root attributes에 기록한다.

기존 `ReactiveState`가 있거나 source 쓰기 권한이 없으면 아무것도 덮어쓰지 않고 실패한다. 자동 설치를 지원하지 않는 Studio 빌드에서는 `dist/ReactiveState.manifest.json`의 `studioObjects` 배열대로 object를 만든 뒤 각 `sourcePath`의 내용을 대응하는 ModuleScript Source에 복사한다.

정상 object tree는 다음과 같다.

```text
ReplicatedStorage
└── ReactiveState (ModuleScript; init.luau)
    ├── AttributePreset (ModuleScript; AttributePreset/init.luau)
    ├── BehaviorTree (ModuleScript; BehaviorTree/init.luau)
    ├── Bridge (ModuleScript; Bridge/init.luau)
    ├── Core (Folder)
    │   ├── Clock (ModuleScript)
    │   ├── Codec (ModuleScript)
    │   ├── FRP (ModuleScript)
    │   ├── Hash (ModuleScript)
    │   └── Runtime (ModuleScript)
    ├── Debug (ModuleScript; Debug/init.luau)
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

assert(FRP.VERSION == "0.2.0-dev.1")
assert(FRP.API_VERSION == 2)
assert(FRP.SEMANTICS_VERSION == 1)

local host = FRP.newHost()
local changes, emit = host:source()
local value = FRP.stepper(1, changes)

host:frame(1, function()
    emit(5)
end)
assert(value:at(1) == 1)
assert(value:current() == 5)
host:dispose()

print("Push-Pull FRP Studio require PASS")
```

설치기 root attribute에는 legacy `ReactiveStateNetworkProtocolVersion`과 FRP RemoteEvent용 `ReactiveStateEventProtocolVersion`이 각각 기록된다.

Client에서도 root와 실제 사용할 optional module을 한 번씩 require한다. 그다음 `docs/overdare-checklist.md` 순서로 engine event, RemoteEvent, multi-client, cleanup, Studio benchmark gate를 검증한다.

## 업데이트와 되돌리기

기존 tree 위에 일부 source만 덮어쓰지 않는다. 새 package의 manifest SHA-256을 확인한 뒤 기존 `ReactiveState`를 명시적으로 이름 변경해 보관하고, 새 tree 전체를 설치한다. 검증 실패 시 새 tree를 제거하고 보관한 tree 이름을 되돌린다. state/API/canonical/network protocol version 변경은 애플리케이션 migration과 함께 검토한다.
