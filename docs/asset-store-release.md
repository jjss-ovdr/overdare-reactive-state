# OVERDARE Asset Store 배포

ReactiveState는 먼저 비공개 World Asset으로 설치·재다운로드 검증한 뒤 공개한다.
현재 배포 후보는 `0.2.0-rc.1`이다. 공개 최종본은 이 문서의 RC gate를 모두 통과한
같은 source에서 버전만 `0.2.0`으로 승격한다.

공식 절차는 OVERDARE의 [에셋 업로드/다운로드](https://docs.overdare.com/korean/manual/studio-manual/asset-and-resource-creation/asset-drawer)와
[에셋 임포트](https://docs.overdare.com/korean/manual/studio-manual/asset-and-resource-creation/asset-import)를 기준으로 한다.

## 1. 릴리스 artifact 고정

clean `main`에서 다음 gate를 실행한다.

```sh
luau-analyze src tests examples benchmarks
node tools/check-frp-types.mjs

luau tests/run.luau
luau -O2 tests/run.luau
luau -O2 --codegen tests/run.luau

node tools/build-studio-package.mjs
node tools/build-studio-package.mjs --verify
node tools/build-studio-package.mjs --check-normalization
luau tools/studio-package-smoke.luau

luau -O1 benchmarks/frp-run.luau -a standard O1
luau -O2 benchmarks/frp-run.luau -a standard O2
luau -O2 --codegen benchmarks/frp-run.luau -a standard O2-codegen
luau -O1 benchmarks/multiplayer-run.luau -a standard O1
luau -O2 benchmarks/multiplayer-run.luau -a standard O2
luau -O2 --codegen benchmarks/multiplayer-run.luau -a standard O2-codegen
```

릴리스 기록에 다음 값을 함께 남긴다.

- Git commit과 tag
- `FRP.VERSION`, `API_VERSION`, `SEMANTICS_VERSION`
- state/FRP network protocol version
- `dist/ReactiveState.manifest.json`의 package SHA-256
- Luau toolchain commit
- CLI test와 benchmark assertion 결과

`dist/`는 생성물이라 Git에는 commit하지 않는다. 업로드 source는 기록한 commit에서
다시 만든 artifact여야 한다.

## 2. 비공개 RC 업로드

1. Play를 중지한 disposable World에서 `docs/studio-install.md`대로 생성 package를 설치한다.
2. Level Browser에서 `ReplicatedStorage/ReactiveState` root ModuleScript 하나만 선택한다.
   검증 harness, benchmark runner, `StudioInstaller.luau`는 포함하지 않는다.
3. 우클릭 **Save to OVERDARE**를 선택하고 **Single Upload**를 사용한다. root의 자손과
   `ReplicatedStorage` 부모 경로가 함께 보존되는지 업로드 미리보기에서 확인한다.
4. Creator Hub 입력 화면에서 **Distribute on Asset Store**를 끈다. 이 상태에서는
   개인 또는 지정 그룹만 사용할 수 있고 Studio의 Asset Drawer **Owned** 탭에 표시된다.
5. 아래 listing 초안을 입력하고 약관에 동의한 뒤 등록한다.

### Listing 초안

- 이름: `ReactiveState Push-Pull FRP 0.2.0-rc.1`
- 한 줄 설명: `OVERDARE용 정통 Push-Pull FRP와 server-authoritative multiplayer adapter`
- 설명:

  ```text
  Conal Elliott의 Push-Pull FRP 의미론을 strict Luau에 이식한 ReactiveState입니다.
  Future, Event, Reactive, Behavior, demand-driven pull, atomic Host frame과
  RemoteEvent authority/sequence/retry/snapshot adapter를 제공합니다.

  설치 경로: ReplicatedStorage/ReactiveState
  버전: 0.2.0-rc.1 | API: 2 | FRP semantics: 1
  라이선스: MIT, Copyright (c) 2026 ReactiveState contributors
  상태: private release candidate — 공개 게임 적용 전 자체 멀티클라이언트 검증 권장
  시작: require(ReplicatedStorage.ReactiveState).START_HERE
  ```

- 태그 제안: `Luau`, `FRP`, `Reactive`, `Multiplayer`, `RemoteEvent`, `Library`

분산되는 root ModuleScript에는 전체 MIT 고지문이 포함돼 있다. 저장소가 private인 동안
listing에서 public source 제공을 약속하지 않는다. 공개 source로 전환할 경우에만 정확한
release tag URL을 추가한다.

## 3. Asset Drawer round-trip gate

업로드에 사용한 World와 설치 tree를 재사용하지 않는다.

1. 새 disposable World의 Asset Drawer **Owned** 탭에서 RC를 내려받는다.
2. `ReplicatedStorage/ReactiveState`에 root와 17개 자손 object가 정확히 복원됐는지 확인하고 `Guides` ModuleScript가 포함됐는지 확인한다.
3. root attribute의 version, protocol version, package SHA-256을 기록한 manifest와 비교한다.
4. Server Script와 LocalScript에서 root 및 optional module을 require하고 `START_HERE` / `Guides.serverAuthoritativeMultiplayer`를 확인한다.
5. `docs/overdare-checklist.md`를 실행한다. 특히 다음을 release evidence로 남긴다.
   - function-subscription phase/input Signal과 dispose
   - opaque `GetService`/`Connect`/`Fire*` engine callable
   - frozen occurrence와 strict-before sampling
   - 실제 server + client 2개의 RemoteEvent harness
   - `[RSMP][v1]|FINAL|...|status=PASS|passed=90|failed=0|clients=2`
6. 원본 업로드 World가 아니라 **다운로드한 artifact**에서 모두 통과했는지 명시한다.

하나라도 실패하면 Asset Store 배포물을 교체하지 않고 RC version을 올려 다시 시작한다.
Play 중 설치, 부분 source 덮어쓰기, 기존 tree 위 재설치는 release evidence로 인정하지 않는다.

## 4. 공개 승격

RC round-trip gate가 통과한 뒤에만 다음을 수행한다.

1. 코드 변경 없이 version과 문서만 `0.2.0`으로 바꾸고 전체 gate를 다시 실행한다.
2. `v0.2.0` annotated Git tag가 package source commit을 가리키게 한다.
3. 최종 package SHA-256과 Studio `90/90` evidence를 release note에 기록한다.
4. Creator Hub의 **Dashboard → My Contents → World Asset**에서 최종 asset을 열고
   **Distribute on Asset Store**를 켠다.
5. Asset Drawer **Store** 탭에서 별도 계정 또는 권한 없는 확인 환경으로 검색·다운로드해
   공개 범위를 확인한다.

기존 소비자가 이미 asset을 복사했다면 자동 dependency update를 가정하지 않는다.
새 버전은 전체 `ReactiveState` tree 교체 방식으로 안내하고, API/protocol 변경 시 별도
migration note를 제공한다.

현재 OVERDARE 정책상 World Asset은 무료 제공 대상이며 별도 수익이 발생하지 않는다.
정책은 바뀔 수 있으므로 공개 직전에 [수익화 가이드라인](https://docs.overdare.com/overdare/policy/overdare-monetization-guidelines)을 다시 확인한다.
