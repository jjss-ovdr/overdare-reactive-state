# OVERDARE Studio 검증 체크리스트

이 저장소의 CLI test는 engine API를 fake로 검증한다. 다음 항목을 실제 Studio build에서 통과하기 전에는 production/1.0으로 표시하지 않는다.

## 설치와 require

- `src` tree를 ReactiveState ModuleScript package로 import한다.
- Server Script와 LocalScript에서 root Core를 각각 require한다.
- Server와 client Runtime/Atom 값이 서로 다른 메모리인지 확인한다.
- Core만 require했을 때 RunService connection과 RemoteEvent listener가 0개인지 확인한다.
- Asset Drawer로 복사한 clean World에서도 child ModuleScript 경로가 같은지 확인한다.

## RunService

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

- RemoteEvent server/client callback signature를 adapter injection과 맞춘다.
- 2명 이상의 client에 서로 다른 visibility projection snapshot을 보낸다.
- duplicate, out-of-order, gap, stale tick, 잘못된 schemaVersion과 변조된 hash를 주입한다.
- Oversized/deep table과 알 수 없는 field가 server action에 도달하지 않는지 확인한다.
- Client intent가 validator/authorize를 우회해 server Atom을 직접 설정하지 못하는지 확인한다.
- Correction 뒤 ack된 input이 제거되고 미확정 input만 stable sequence로 replay되는지 확인한다.

## Timeline과 성능

- 같은 seed/input으로 두 번 실행한 매 tick `getStateHash()`를 비교한다.
- Rollback window 끝과 confirmed tick 경계를 확인한다.
- 180 tick full snapshot의 실제 memory/GC 비용을 대상 기기에서 측정한다.
- Linear, fan-out, diamond, dynamic dependency, sparse/dense workload를 profile한다.
- 긴 session에서 Scope, connection, Runtime과 history가 해제되는지 확인한다.

## Release gate

- Git tag, `State.VERSION`, network protocol/schema version과 Asset Store artifact source commit을 기록한다.
- Source package와 배포 package에서 같은 test fixture 결과를 확인한다.
- 지원하지 않는 native physics 완전 rollback과 journal history를 문서에서 약속하지 않는다.
