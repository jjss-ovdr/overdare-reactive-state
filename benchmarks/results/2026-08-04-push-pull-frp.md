# Push-Pull FRP Core baseline — 2026-08-04

`0.2.0-dev.1`, standard profile, warm-up 1회, 표본 5회의 median이다. 모든 표본에서 workload correctness assertion이 통과했다.

환경: Apple M5 Pro 18-core, 24 GB, arm64, macOS 26.3.2. 독립 Luau CLI이며 실제 OVERDARE Studio/대상 기기 수치가 아니다.

| Workload | Operations | O1 median ms | O2 median ms | O2 codegen median ms |
|---|---:|---:|---:|---:|
| `future/max_sync` | 20,000 | 14.268 | 12.511 | 9.742 |
| `event/stable_merge_ties` | 2,000 | 1.085 | 1.035 | 0.791 |
| `event/push_pull_pipeline` | 24,000 | 141.063 | 138.267 | 77.719 |
| `reactive/applicative_simultaneous` | 2,000 | 5.534 | 5.593 | 4.471 |
| `behavior/continuous_pull` | 1,000 | 2.685 | 2.527 | 2.117 |
| `behavior/switcher_churn` | 1,000 | 13.021 | 12.505 | 8.937 |
| `event/dormant_quiescence` | 1,000 | 122.344 | 123.445 | 62.551 |

`event/dormant_quiescence`는 128개 dormant mapper의 호출 수가 0인지 함께 검사한다. 표시된 operations는 source frame 수이고, 현재 구현은 미래 occurrence 예약 배열을 매 삽입마다 정렬하므로 1,000개를 미리 예약하는 이 workload가 상대적으로 비싸다. 이 수치는 scheduler queue 자료구조를 heap으로 바꿀 때 비교할 최적화 baseline이다.

재현 명령:

```sh
luau -O1 benchmarks/frp-run.luau -a standard O1
luau -O2 benchmarks/frp-run.luau -a standard O2
luau -O2 --codegen benchmarks/frp-run.luau -a standard O2-codegen
```
