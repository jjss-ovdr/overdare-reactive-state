# Multiplayer-first FRP protocol baseline — 2026-08-04

`0.2.0-dev.1`, standard profile, warm-up 1회, 표본 5회의 p50/p95다. payload padding은 96 bytes이며 모든 표본에서 sequence, ack, checksum, replay continuity, reject-without-advance correctness assertion이 통과했다.

환경: Apple M5 Pro 18-core, 24 GB, arm64, macOS 26.3.2. Luau source commit은 `decb2d0526797a175d7c5ba8d4d78858ced98553`이다. 독립 Luau CLI protocol 수치이며 실제 OVERDARE RemoteEvent 왕복이나 target-device 수치가 아니다.

| Workload | Ops | O1 p50 / p95 ms | O2 p50 / p95 ms | O2 codegen p50 / p95 ms |
|---|---:|---:|---:|---:|
| `intent/validated_ingress_02p` | 12,000 | 248.454 / 256.977 | 209.602 / 214.115 | 137.562 / 139.808 |
| `intent/validated_ingress_08p` | 12,000 | 222.636 / 256.383 | 204.927 / 214.952 | 136.014 / 139.770 |
| `intent/validated_ingress_32p` | 12,000 | 269.046 / 312.901 | 215.335 / 221.822 | 139.531 / 141.066 |
| `authority/per_peer_stream_02p` | 12,000 | 285.642 / 309.078 | 282.327 / 339.561 | 181.362 / 183.453 |
| `authority/per_peer_stream_08p` | 12,000 | 294.740 / 305.829 | 279.114 / 286.565 | 181.899 / 183.013 |
| `authority/per_peer_stream_32p` | 12,000 | 300.026 / 301.970 | 283.151 / 297.094 | 186.682 / 193.095 |
| `recovery/replay_064` | 12,800 | 184.118 / 189.917 | 170.130 / 171.228 | 112.493 / 116.013 |
| `security/reject_untrusted` | 12,000 | 19.089 / 20.831 | 16.967 / 17.377 | 9.225 / 9.281 |

O2 codegen p50 기준 validated intent는 2/8/32 peer에서 각각 약 87.2k/88.2k/86.0k packets/s, authoritative encode+client reduce는 약 66.2k/66.0k/64.3k packets/s였다. peer 수별 총 operation을 12,000으로 동일하게 고정했을 때 32-peer p50이 2-peer 대비 intent 약 1.4%, authority 약 2.9% 높아, 이 범위에서는 client별 state 분리가 급격한 비선형 저하를 만들지 않았다.

`recovery/replay_064`의 operation은 source encode 6,400회와 client replay apply 6,400회의 합이다. `recover()`의 64-packet clone 작업도 측정 구간에 들어가지만 operation 수에는 별도로 더하지 않았다. `security/reject_untrusted`는 실행 가능한 값을 넣은 packet을 wire boundary에서 거부하며 intent sequence가 0인지 매 표본 확인한다.

재현 명령:

```sh
luau -O1 benchmarks/multiplayer-run.luau -a standard O1
luau -O2 benchmarks/multiplayer-run.luau -a standard O2
luau -O2 --codegen benchmarks/multiplayer-run.luau -a standard O2-codegen
```

이 결과의 release 해석은 “엔진 독립 protocol 회귀 baseline 통과”까지다. 실제 2-client process, RemoteEvent scheduling, network stress, target device는 `examples/StudioMultiplayer` harness로 별도 통과해야 한다.
