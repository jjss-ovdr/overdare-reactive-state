# 성능 전략과 결과

성능 suite는 전략 문서 13.3의 10개 workload를 독립 Luau와 OVERDARE Studio에서 같은 코드로 실행한다. 절대 시간 합격선은 대상 기기에서 Studio baseline을 얻은 뒤 정한다. 현재 gate는 정확성 invariant와 크기 증가에 따른 추세다.

## 측정 범위

| 전략 workload | Suite case |
|---|---|
| Linear chain | depth 1/10/100, watched pull |
| Fan-out | 10/100/1,000 Computed와 Watch |
| Diamond | 100개 diamond, transaction당 staged write 2회 |
| Dynamic dependency | 128개 branch 반복 교체와 inactive edge 검증 |
| Sparse AI | 1,000 agent 중 tick당 10/100개 dirty |
| Dense AI | 1,000 agent 전부 dirty |
| Transaction burst | 100/1,000 Atom, Atom당 staged write 2회 |
| History | off, 명시적 interval 1/6/30, capacity 30/180, eviction steady-state, table payload |
| Rollback replay | 180 tick 중 거리 1/15/60/120/179 |
| Network patch | 64 fields, 1/8/32 client visibility build, apply-only, end-to-end |

각 표본은 setup/graph prime, steady-state 실행, correctness 검증, cleanup을 분리한다. assertion, `getStateHash()`, 출력은 steady-state 시간 밖에 있다. `collectgarbage("collect")`와 `gcinfo()`를 제공하는 독립 CLI에서는 setup 직전, run 직후, cleanup 직후 retained heap도 기록한다.

## 실행

```sh
luau benchmarks/run.luau -a standard O1
luau -O2 benchmarks/run.luau -a standard O2
luau --codegen benchmarks/run.luau -a standard codegen
```

Studio에서는 [`benchmarks/StudioRunner.server.luau`](../benchmarks/StudioRunner.server.luau)를 사용한다. 자세한 설치와 profile은 [`benchmarks/README.md`](../benchmarks/README.md)에 있다.

## 2026-08-03 독립 Luau baseline

- 31개 benchmark case: O1/O2/codegen 모두 correctness PASS
- 52개 자동 test: 기본/O2/codegen 모두 52 passed, 0 failed
- 환경: Apple M5 Pro 18-core, 24 GB, arm64, macOS 26.3.2
- Luau source commit: `decb2d0526797a175d7c5ba8d4d78858ced98553`
- profile: standard, warm-up 1회, 측정 5회

전체 수치는 [독립 Luau baseline 결과](../benchmarks/results/2026-08-03-independent-luau.md)에 보존했다.

관찰된 핵심은 다음과 같다.

- O2에서 sparse 1%는 400 agent update에 p50 2.185 ms, dense 100%는 8,000 update에 41.395 ms였다. 두 경우 모두 dirty agent만 한 번 평가·통지했다.
- history-off 180 tick은 O2 p50 0.552 ms지만 16개 scalar full snapshot 180개는 31.476 ms였다. `table[32]` payload는 367.281 ms와 약 2,192 KB retained history를 사용했다. Journal/patch 최적화 필요성이 수치로 드러난다.
- capacity 30의 eviction steady-state는 O2 p50 31.269 ms이고 run retained heap 증가는 0 KB였다. O(1) ring 교체로 보유량은 안정됐지만 매 tick 전체 encode/hash 비용은 그대로다.
- 64-field visibility patch build는 8 client p50 31.887 ms, 32 client 124.558 ms로 client 수에 거의 선형 증가했다. 현재 schema projection/hash가 client마다 전체 field를 순회하기 때문이다.
- 이 CLI build에서 명시적으로 한계를 높인 linear depth probe는 199를 통과하고 200에서 host C stack 한계가 발생했다. Runtime 기본 `maxEvaluationDepth=128`은 그 전에 설명 가능한 오류를 낸다. 이 숫자를 Studio VM 한계로 간주하면 안 된다.
- codegen run 뒤 cleanup residual은 동적으로 만들어진 benchmark closure의 native-code cache도 포함한다. O1/O2 cleanup residual과 Runtime의 구조 검증을 누수 gate로 사용하고, codegen residual만으로 Runtime 누수라고 판정하지 않는다.

## 아직 통과하지 않은 gate

- `history.strategy="journal"`과 built-in snapshot interval은 아직 구현되지 않았다.
- 실제 OVERDARE Studio server/client VM 수치는 아직 없다.
- RemoteEvent transport를 거치는 실제 multi-client, native physics sampling, target-device, Asset Drawer 설치 검증은 별도다.

따라서 독립 Luau 결과는 구현 baseline이지 1.0 release 승인이 아니다.
