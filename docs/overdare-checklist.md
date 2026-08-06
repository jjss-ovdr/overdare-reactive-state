# OVERDARE Studio 검증 체크리스트

이 저장소의 CLI test는 engine API를 fake로 검증한다. 다음 항목을 실제 Studio build에서 통과하기 전에는 production/1.0으로 표시하지 않는다.

독립 QA에서는 원본 World를 복사하거나 checkpoint를 만든 뒤 disposable test World에 생성 package와 harness Script를 임시 설치해도 된다. 이는 저장소 코드 수정과 구분한다. 테스트 뒤 World를 저장·게시하지 않거나 설치 객체를 제거한다. Studio가 열려 있지만 blank World에 harness가 없는 경우 상태는 `BLOCKED: test harness not installed / temporary World mutation not authorized`이며, `Studio environment unavailable`로 기록하지 않는다.

## 설치와 require

- `src` tree를 ReactiveState ModuleScript package로 import한다.
- Server Script와 LocalScript에서 root Core를 각각 require한다.
- Server와 client Host/Event graph가 서로 다른 메모리인지 확인한다.
- Core만 require했을 때 RunService connection과 RemoteEvent listener가 0개인지 확인한다.
- Asset Drawer로 복사한 clean World에서도 child ModuleScript 경로가 같은지 확인한다.
- Studio VM에서 `table.freeze`/`table.isfrozen`이 동작하고 반환된 occurrence의 `time`, `value`, `order` 수정이 오류인지 확인한다.
- `FRP.Immutable.serializable()` source에 plain table을 emit한 뒤 원본을 바꿔도 captured payload가 분리·재귀 freeze돼 있는지 확인한다.
- `--!strict` 소비자 ModuleScript에서 root의 `script.Types` witness가 해석되고 `Event<number>`를 `Event<string>`에 대입하거나 occurrence metadata를 쓰면 Studio 진단이 뜨는지 확인한다.

## RunService

- `Overdare.attachFRP`가 여러 Signal 입력을 한 phase의 `Host:frame` 하나로 묶는지 확인한다.
- Signal callback 도착이 right→left여도 `left:merge(right)`가 left→right인지 확인한다.
- 같은 Signal의 동일 payload occurrence가 모두 보존되는지 확인한다.
- frame time `t` 직후 `Reactive:at(t)`는 이전 값이고 `current()`는 새 값인지 확인한다.
- Constant Behavior는 phase 진입 시 한 번, Dynamic Behavior는 advance마다 render되는지 확인한다.
- 한 Host의 두 번째 active FRP driver가 거부되고 driver dispose 뒤 Host는 계속 동작하는지 확인한다.
- `phaseSignal`과 `eventFromSignal`에 `callback -> disposer` 함수형 Signal을
  주입했을 때 정상 구독되고 각 binding/driver dispose 시 disposer가 한 번씩 실행되는지 확인한다.

- `Stepped`, `Heartbeat`, `RenderStepped`에서 platform이 전달하는 argument와 `deltaIndex`를 확인한다.
- `Overdare.attach`의 priority/creation 순서가 매 실행 동일한지 확인한다.
- 1/60 fixed step에서 긴 frame을 만들어 `drop`, `clamp`, `error`와 `maxSubsteps`를 각각 확인한다.
- Callback 오류 후 accumulator/tick이 반쯤 진행되지 않는지 확인한다.
- Dispose 뒤 signal callback이 다시 실행되지 않는지 확인한다.

## Instance 경계

- `Overdare.bind`가 commit 뒤 Source → property 한 방향으로만 쓰는지 확인한다.
- `Overdare.sample`이 선택한 phase에서 physics/transform property를 읽고 transaction으로 publish하는지 확인한다.
- Instance destroy와 Scope dispose에서 connection이 한 번만 끊기는지 확인한다.
- Snapshot/network canonical state에는 Instance 대신 stable entity/resource ID만 넣는다.

## RemoteEvent와 multi-client

- manifest의 `validationHarness.objects`와 동일한 class/path/source hash로
  `examples/StudioMultiplayer`의 server Script와 client LocalScript를 설치하고,
  두 객체 모두 `Enabled == true`인지 확인한 뒤 Number of Players를 2 이상으로 실행한다.
- Play 직후 server 1개와 client별 1개의 `[RSMP][v1]|BOOT|...|stage=entry`를 확인한다.
  BOOT가 하나도 없으면 RemoteEvent 실패가 아니라 `HARNESS_NOT_STARTED`로 분류한다.
- Server Output의 `[RSMP][v1]|FINAL|...|status=PASS|...|clients=2` 한 줄을 필수 positive evidence로 보존한다.
- RemoteEvent server/client callback signature를 adapter injection과 맞춘다.
- 2명 이상의 client에 서로 다른 visibility projection snapshot을 보낸다.
- duplicate, out-of-order, gap, stale tick, 잘못된 schemaVersion과 변조된 hash를 주입한다.
- Oversized/deep table과 알 수 없는 field가 server action에 도달하지 않는지 확인한다.
- Client intent가 validator/authorize를 우회해 server Atom을 직접 설정하지 못하는지 확인한다.
- Correction 뒤 ack된 input이 제거되고 미확정 input만 stable sequence로 replay되는지 확인한다.
- FRP intent의 exact packet 재전송은 한 번만 적용되고 `duplicate_intent`가 되는지 확인한다.
- FRP authority sequence gap이 replay buffer로 복구되고 buffer miss가 새 snapshot epoch로 전환되는지 확인한다.
- 마지막 client intent 유실은 ack timeout 재전송, 마지막 server event 유실은 heartbeat로 드러나는지 확인한다.
- `PlayerRemoving` 뒤 Player reference, replay buffer, server tick 상태가 제거되고 재접속 session key가 새로 생기는지 확인한다.
- Studio Network StressTest의 lag/loss/jitter/variance에서 retry/resync가 수렴하는지 확인한다.

## Timeline과 성능

- `future/event/reactive/behavior`와 immutable capture 전용 8개 FRP workload를 Studio VM에서 실행한다.

- 같은 seed/input으로 두 번 실행한 매 tick `getStateHash()`를 비교한다.
- Rollback window 끝과 confirmed tick 경계를 확인한다.
- 180 tick full snapshot의 실제 memory/GC 비용을 대상 기기에서 측정한다.
- Linear, fan-out, diamond, dynamic dependency, sparse/dense workload를 profile한다.
- 긴 session에서 Scope, connection, Runtime과 history가 해제되는지 확인한다.

## Release gate

- Git tag, `VERSION`, `API_VERSION`, `SEMANTICS_VERSION`, network protocol/schema version과 Asset Store artifact source commit을 기록한다.
- Source package와 배포 package에서 같은 test fixture 결과를 확인한다.
- `docs/asset-store-release.md` 순서대로 RC를 비공개 업로드하고 Owned 탭에서 clean World로 다시 내려받아 manifest SHA, function Signal, server + 2-client `90/90`을 재검증한다.
- 지원하지 않는 native physics 완전 rollback과 journal history를 문서에서 약속하지 않는다.
