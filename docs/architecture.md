# ReactiveState 아키텍처

ReactiveState는 일반 Luau 제어 흐름을 유지하면서, 선택한 상태 경계에만 반응형 그래프와 원자적 transaction을 적용한다. UI 프레임워크나 게임 루프를 소유하지 않으며 Runtime 인스턴스 사이의 상태도 암묵적으로 공유하지 않는다.

## Commit 파이프라인

```text
transaction callback
  -> Atom write를 transaction-local overlay에 stage
  -> 최종값 검증 및 net-change 계산
  -> Atom 값을 한 번에 publish
  -> downstream을 dirty / pending으로 push
  -> watched Source를 pull하여 안정화
  -> (priority, stable id) 순서로 post-commit watch 실행
```

일반 signal 라이브러리의 `batch`는 대개 알림만 미룬다. ReactiveState의 `transaction`은 callback이 실패하면 staged write와 command를 폐기한다. Nested transaction은 가장 바깥 transaction에 합류하며 독립 savepoint가 아니다.

Root transaction은 `mutate → prepare → publish → notify`로 나뉜다. validator, equality, watched Computed, codec처럼 실패할 수 있는 사용자 코드는 prepare가 끝나기 전에 실행한다. Publish는 미리 계산된 값을 교체하는 구간이고, watch 오류는 이미 확정된 상태를 되돌리지 않으며 다음 watch를 계속 실행한다. Watch 중 write는 현재 notification stack에 재진입하지 않고 별도의 queued transaction으로 처리한다.

## 반응형 그래프

- Atom은 원본 값과 단조 증가 revision을 소유한다.
- Computed는 실제로 읽힐 때 계산하고 결과와 dependency revision을 캐시한다.
- 원본 변경은 getter를 즉시 호출하지 않고 영향을 받은 downstream만 표시한다.
- `pending` Computed는 upstream revision을 먼저 확인한다. Upstream Computed 결과가 같으면 자기 getter를 실행하지 않는다.
- 조건부 read가 바뀌면 이전 dependency edge를 제거하고 이번 평가에서 읽은 edge만 남긴다.
- Computed 평가 중 write와 다른 Runtime Source read는 오류다.
- 중첩 pull 깊이는 기본 128에서 진단해 host VM의 stack overflow를 피한다. 더 큰 한계는 대상 VM에서 depth probe 후 명시적으로 설정한다.
- Watch는 계산 노드가 아니라 외부 effect 경계이며 commit이 끝난 뒤에만 실행된다.

이 조합은 diamond graph의 중간 상태 노출과 불필요한 downstream 재계산을 피한다.

## 참고 구현에서 채택한 부분

- [Alien Signals](https://github.com/stackblitz/alien-signals)와 [Charm](https://github.com/littensy/charm): `pending/dirty` push-pull 및 양방향 dependency link.
- [Roblox Signals](https://github.com/Roblox/signals): lazy Computed, 명시적인 scope, 같은 computed 결과의 downstream 억제.
- [Angular Signals](https://github.com/angular/angular/tree/main/packages/core/primitives/signals)와 [Preact Signals](https://github.com/preactjs/signals): producer revision과 link가 마지막으로 본 revision을 분리하는 value versioning.
- [Fusion](https://github.com/dphfox/Fusion): 재평가 결과와 새 dependency를 후보 상태로 만든 뒤 성공할 때 교체하는 오류 안전성.
- [Vide](https://github.com/centau/vide): dependency graph와 ownership tree의 분리.
- [MobX](https://github.com/mobxjs/mobx): deduplicated reaction queue, 동적 dependency diff, idempotent disposal.
- [Reflex](https://github.com/reflex-frp/reflex)와 [Sodium](https://github.com/SodiumFRP/sodium): frame 안정화와 rank 아이디어. 현재 Atom/Computed Core에는 과도한 rank scheduler를 넣지 않았고, 향후 Event/merge/switch 계층의 참고 기준으로 남긴다.

특히 일반 batch 구현과 달리 callback 오류를 실제로 되돌리기 위해 Atom 값은 transaction-local overlay에 먼저 쓴다. Transaction 안의 Computed도 별도 speculative cache와 candidate dependency를 사용하며, 성공한 commit에서 watch가 관찰한 candidate만 graph에 설치한다.

## 의도적으로 가져오지 않은 부분

- ModuleScript 전역 active subscriber, scheduler, node ID
- `os.clock()`을 graph revision으로 사용
- callback 오류가 나도 이미 쓴 값을 유지하는 notification-only batch
- Core를 자동으로 Heartbeat/RenderStepped에 연결하는 숨은 game loop
- deep table proxy와 임의 Atom 자동 replication
- weak table 또는 GC finalizer에 정확한 disposal을 맡기는 방식
- Computed 오류를 숨기고 마지막 값을 정상값처럼 반환하는 정책

## 모듈 경계

```text
src/init.luau                 Core 진입점
src/Core/Runtime.luau         Atom/Computed/transaction/watch/Store/Timeline
src/Core/Clock.luau           수동·고정 clock (수동 advance)
src/Core/Codec.luau           snapshot 가능한 기본 값 계약
src/Core/Hash.luau            canonical drift hash

src/Bridge/init.luau          Runtime 간 one-way bridge
src/Network/init.luau         schema/sequence/revision 기반 payload
src/Overdare/init.luau        RunService/Instance/RemoteEvent 경계
src/Behavior/init.luau        사용자가 tick하는 선택 facade
src/AttributePreset/init.luau schema 기반 Attribute 입력
src/Debug/init.luau           opt-in trace/inspection
```

Root ModuleScript는 optional module을 eager `require()`하지 않는다. 따라서 Core만 사용하는 Runtime은 engine connection, network listener, bridge registry, behavior scheduler를 만들지 않는다.

## 0.1 상태

현재 버전은 설계와 독립 Luau 검증을 위한 preview다. 공식 Luau CLI의 회귀/property test와 fake/real Runtime adapter 통합 test, 전략의 10개 성능 workload는 제공하지만, OVERDARE Studio server/client, multi-client, Asset Store 삽입 검증을 통과하기 전에는 1.0이나 production-ready로 표시하지 않는다. Timeline은 현재 bounded full snapshot ring 구현이며 journal/patch history는 아직 제공하지 않는다.
