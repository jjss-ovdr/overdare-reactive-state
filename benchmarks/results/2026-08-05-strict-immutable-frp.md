# Strict/immutable Push-Pull FRP baseline — 2026-08-05

`0.2.0-dev.2`, standard profile, warm-up 1회, 표본 5회의 median이다. strict public type surface, frozen occurrence envelope, opt-in serializable capture를 적용한 뒤 세 실행 모드에서 8개 workload의 correctness assertion이 모두 통과했다.

환경: Apple M5 Pro 18-core, 24 GB, arm64, macOS 26.3.2, Luau source `decb2d0526797a175d7c5ba8d4d78858ced98553`. 독립 Luau CLI 결과이며 실제 OVERDARE Studio/대상 기기 수치가 아니다.

| Workload | Operations | O1 median ms | O2 median ms | O2 codegen median ms |
|---|---:|---:|---:|---:|
| `future/max_sync` | 20,000 | 14.799 | 12.844 | 10.195 |
| `event/stable_merge_ties` | 2,000 | 1.149 | 1.229 | 0.914 |
| `event/push_pull_pipeline` | 24,000 | 139.434 | 139.732 | 79.114 |
| `reactive/applicative_simultaneous` | 2,000 | 5.578 | 5.747 | 4.104 |
| `behavior/continuous_pull` | 1,000 | 2.830 | 2.506 | 2.051 |
| `behavior/switcher_churn` | 1,000 | 12.283 | 11.983 | 8.476 |
| `event/dormant_quiescence` | 1,000 | 120.778 | 121.316 | 62.129 |
| `event/immutable_capture` | 1,000 | 4.225 | 4.134 | 3.304 |

기존 2026-08-04 O2-codegen과 비교하면 main push-pull pipeline은 77.719 ms에서 79.114 ms로 1.8% 증가했다. reactive/behavior/switcher/dormant 경로는 같거나 더 빨랐고, 가장 짧은 stable-merge 표본은 0.791 ms에서 0.914 ms로 0.123 ms 증가했다. 전체적으로 occurrence freeze 이후 명확한 구조적 회귀는 보이지 않는다.

새 `event/immutable_capture`는 frame마다 shared child가 있는 작은 plain table을 clone/freeze하고 sink까지 전달한다. O2-codegen은 1,000회에 3.304 ms, 약 3.30 µs/frame이다. 이 값에는 Host frame commit과 sink 호출도 포함되므로 codec clone만의 순수 비용으로 해석하지 않는다.

재현 명령:

```sh
luau -O1 benchmarks/frp-run.luau -a standard O1
luau -O2 benchmarks/frp-run.luau -a standard O2
luau -O2 --codegen benchmarks/frp-run.luau -a standard O2-codegen
```
