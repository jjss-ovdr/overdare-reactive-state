# Independent Luau baseline — 2026-08-03

ReactiveState `0.1.0-dev.1`, standard profile, warm-up 1회, 표본 5회. 시간 단위는 ms이며 모든 행의 workload correctness assertion이 통과했다.

환경: Apple M5 Pro 18-core, 24 GB, arm64, macOS 26.3.2. Luau source commit `decb2d0526797a175d7c5ba8d4d78858ced98553`.

| Workload | O1 p50 | O2 min | O2 p50 | O2 p95 | O2 max | O2 units/s | codegen p50 |
|---|---:|---:|---:|---:|---:|---:|---:|
| linear_chain/d1 | 0.626 | 0.607 | 0.611 | 0.707 | 0.707 | 163.59k | 0.496 |
| linear_chain/d10 | 2.653 | 2.499 | 2.558 | 2.821 | 2.821 | 39.09k | 2.966 |
| linear_chain/d100 | 27.310 | 22.791 | 23.178 | 23.353 | 23.353 | 4.31k | 21.355 |
| fan_out/w10 | 1.113 | 1.047 | 1.073 | 1.225 | 1.225 | 279.49k | 0.879 |
| fan_out/w100 | 11.067 | 10.144 | 10.269 | 10.441 | 10.441 | 292.14k | 8.832 |
| fan_out/w1000 | 133.006 | 117.974 | 119.445 | 122.701 | 122.701 | 251.16k | 119.825 |
| diamond/w100 | 36.451 | 33.710 | 33.859 | 33.910 | 33.910 | 118.14k | 30.139 |
| dynamic_dependency/b128 | 2.648 | 2.405 | 2.517 | 2.605 | 2.605 | 158.91k | 2.228 |
| sparse_ai/d10 | 2.491 | 1.960 | 2.185 | 2.282 | 2.282 | 183.06k | 2.080 |
| sparse_ai/d100 | 21.418 | 20.374 | 20.442 | 20.666 | 20.666 | 195.68k | 19.052 |
| dense_ai/all | 44.889 | 40.972 | 41.395 | 42.024 | 42.024 | 193.26k | 38.739 |
| transaction_burst/w100 | 1.880 | 1.790 | 1.803 | 1.948 | 1.948 | 1.33M | 1.489 |
| transaction_burst/w1000 | 19.619 | 17.778 | 17.974 | 18.103 | 18.103 | 1.34M | 15.651 |
| history/off | 0.580 | 0.548 | 0.552 | 0.563 | 0.563 | 326.11k | 0.473 |
| history/manual_interval_1 | 31.928 | 30.702 | 30.961 | 31.548 | 31.548 | 5.81k | 24.985 |
| history/manual_interval_6 | 5.850 | 5.506 | 5.681 | 5.779 | 5.779 | 31.68k | 4.592 |
| history/manual_interval_30 | 1.632 | 1.539 | 1.550 | 1.638 | 1.638 | 116.14k | 1.309 |
| history/snapshot_c30_scalar | 32.226 | 31.188 | 31.213 | 31.600 | 31.600 | 5.77k | 24.785 |
| history/snapshot_c180_scalar | 32.534 | 31.261 | 31.476 | 31.607 | 31.607 | 5.72k | 25.628 |
| history/eviction_steady_c30 | 33.203 | 31.024 | 31.269 | 31.398 | 31.398 | 5.76k | 25.443 |
| history/snapshot_c180_table32 | 399.873 | 365.658 | 367.281 | 369.850 | 369.850 | 490.09 | 275.653 |
| rollback_replay/d1 | 0.330 | 0.322 | 0.343 | 0.372 | 0.372 | 2.92k | 0.258 |
| rollback_replay/d15 | 2.048 | 1.907 | 1.922 | 1.939 | 1.939 | 7.80k | 1.606 |
| rollback_replay/d60 | 7.265 | 6.726 | 6.871 | 6.957 | 6.957 | 8.73k | 5.898 |
| rollback_replay/d120 | 14.199 | 13.461 | 13.542 | 13.760 | 13.760 | 8.86k | 11.003 |
| rollback_replay/d179 | 21.377 | 20.146 | 20.459 | 20.520 | 20.520 | 8.75k | 16.436 |
| network_patch/build_c1 | 5.150 | 4.657 | 4.745 | 4.926 | 4.926 | 2.53k | 3.907 |
| network_patch/build_c8 | 32.948 | 31.677 | 31.887 | 32.013 | 32.013 | 3.01k | 24.626 |
| network_patch/build_c32 | 128.079 | 123.962 | 124.558 | 124.979 | 124.979 | 3.08k | 95.466 |
| network_patch/apply_only | 7.745 | 7.395 | 7.495 | 7.580 | 7.580 | 2.67k | 5.953 |
| network_patch/end_to_end | 15.641 | 14.895 | 15.295 | 15.493 | 15.493 | 1.31k | 11.694 |

O2 retained-memory highlights after forced GC:

- history manual interval 1: run `+613 KB`; interval 6: `+102 KB`; interval 30: `+20 KB`.
- snapshot capacity 30 scalar: `+103 KB`; capacity 180 scalar: `+617 KB`; capacity 180 `table[32]`: `+2,192 KB`.
- prefilled capacity-30 eviction steady-state: run `+0 KB`, cleanup `+0 KB` median.
- network build 1/8/32 clients: `+7/+53/+212 KB` while last payload baselines are retained.
- O2 cleanup residual은 대부분 `0 KB`, 최대 median `1 KB`였다.

Codegen cleanup residual은 native-code cache를 포함하므로 Runtime object leak 지표로 직접 비교하지 않는다.

재현 명령:

```sh
luau benchmarks/run.luau -a standard O1
luau -O2 benchmarks/run.luau -a standard O2
luau --codegen benchmarks/run.luau -a standard codegen
```

미지원 또는 외부 gate: 180-tick journal, built-in snapshot interval, 실제 OVERDARE Studio/RemoteEvent multi-client/target-device timing, native physics rollback.
