# 성능 벤치마크

## Push-Pull FRP Core

```sh
luau -O1 benchmarks/frp-run.luau -a standard O1
luau -O2 benchmarks/frp-run.luau -a standard O2
luau -O2 --codegen benchmarks/frp-run.luau -a standard O2-codegen
```

`FRPSuite.luau`는 Future/Event/Reactive/Behavior에 전용인 7개 workload와 각 correctness assertion을 실행한다. `smoke`, `standard` profile을 지원한다. 현재 결과는 [`results/2026-08-04-push-pull-frp.md`](./results/2026-08-04-push-pull-frp.md)에 있다.

## Multiplayer-first FRP protocol

```sh
luau -O1 benchmarks/multiplayer-run.luau -a standard O1
luau -O2 benchmarks/multiplayer-run.luau -a standard O2
luau -O2 --codegen benchmarks/multiplayer-run.luau -a standard O2-codegen
```

`MultiplayerSuite.luau`는 2/8/32 peer에서 validated client intent와 per-client authoritative stream을 각각 측정한다. 여기에 64-packet replay 복구와 비신뢰 wire packet 거부를 더한 8개 workload가 있으며 모든 표본은 sequence/checksum/replay/security invariant를 검증한다. 현재 결과는 [`results/2026-08-04-multiplayer-frp.md`](./results/2026-08-04-multiplayer-frp.md)에 있다. 이 수치는 엔진 독립 프로토콜 baseline이다. 실제 RemoteEvent transport와 기기 성능은 아래 Studio gate에서 별도로 측정한다.

## 기존 StateRuntime 호환 baseline

이전 전략 문서 13.3의 10개 workload를 동일한 engine-neutral suite로 측정한다. 이 결과는 `Atom/Computed` 호환 계층의 baseline이지 FRP Core의 성능이라고 부르지 않는다.

## 독립 Luau

```sh
luau benchmarks/run.luau -a standard O1
luau -O2 benchmarks/run.luau -a standard O2
luau --codegen benchmarks/run.luau -a standard codegen
```

프로필은 `smoke`, `standard`, `stress` 중 하나다. 결과는 warm-up/샘플 수, p50/p95/min/max, units/s, setup p50, 강제 GC 후 run heap 변화와 cleanup 잔존량을 함께 출력한다. CLI 수치는 Studio/대상 기기 수치로 간주하지 않고 구현 간 회귀 baseline으로만 사용한다.

## OVERDARE Studio

1. `ReactiveState` package를 `ReplicatedStorage`에 둔다.
2. 이 `benchmarks` 폴더를 test place에 동기화하거나 복사한다.
3. `StudioRunner.server.luau`를 server Script로 실행한다.
4. Output의 Markdown 표와 Studio build, OS/CPU, server/client, 대상 기기를 함께 보존한다.

Studio runner도 독립 CLI와 같은 `Suite.luau`를 실행한다. 실제 RemoteEvent transport, 물리 sampling, multi-client process와 target-device 결과는 [`../docs/overdare-checklist.md`](../docs/overdare-checklist.md)의 별도 play test가 필요하다.

## 현재 명시적 제한

- preview history는 full snapshot만 지원한다. `180 tick journal`은 `UNSUPPORTED`다.
- built-in snapshot interval 설정은 아직 없다. suite는 history-off Runtime에서 명시적 `snapshot()` 간격 1/6/30을 별도로 비교한다.
- 절대 시간 합격선은 OVERDARE 대상 기기 baseline을 얻은 뒤 정한다. 지금의 필수 합격 조건은 workload별 correctness invariant다.
