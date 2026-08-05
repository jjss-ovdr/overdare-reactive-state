# Strict/immutable multiplayer FRP protocol baseline — 2026-08-05

`0.2.0-dev.2`, standard profile, warm-up 1회, 표본 5회의 p50/p95다. payload padding은 96 bytes이며 세 실행 모드에서 sequence, ack, checksum, replay continuity, reject-without-advance assertion을 포함한 8개 workload가 모두 통과했다.

환경: Apple M5 Pro 18-core, 24 GB, arm64, macOS 26.3.2, Luau source `decb2d0526797a175d7c5ba8d4d78858ced98553`. 독립 Luau CLI protocol 수치이며 실제 OVERDARE RemoteEvent 왕복이나 target-device 수치가 아니다.

| Workload | Ops | O1 p50 / p95 ms | O2 p50 / p95 ms | O2 codegen p50 / p95 ms |
|---|---:|---:|---:|---:|
| `intent/validated_ingress_02p` | 12,000 | 216.224 / 222.646 | 210.616 / 219.986 | 141.094 / 145.567 |
| `intent/validated_ingress_08p` | 12,000 | 216.749 / 220.556 | 212.891 / 215.297 | 138.211 / 146.402 |
| `intent/validated_ingress_32p` | 12,000 | 237.806 / 242.079 | 228.826 / 236.451 | 141.512 / 146.981 |
| `authority/per_peer_stream_02p` | 12,000 | 303.311 / 360.231 | 294.491 / 368.576 | 183.370 / 189.708 |
| `authority/per_peer_stream_08p` | 12,000 | 304.298 / 312.662 | 294.513 / 306.340 | 187.123 / 239.522 |
| `authority/per_peer_stream_32p` | 12,000 | 288.666 / 306.650 | 283.245 / 299.962 | 186.442 / 190.506 |
| `recovery/replay_064` | 12,800 | 188.329 / 206.344 | 181.907 / 193.171 | 112.448 / 112.750 |
| `security/reject_untrusted` | 12,000 | 18.628 / 18.674 | 17.033 / 17.294 | 9.039 / 9.095 |

O2-codegen은 변동이 큰 첫 실행을 한 번 더 반복해 위 표에 재측정값을 기록했다. 2026-08-04 baseline 대비 p50 변화는 대부분 약 ±3% 안이고 replay는 사실상 동일하다. strict type 선언은 런타임에서 제거되고 immutable capture는 opt-in이므로, protocol 기본 경로에서 구조적 회귀는 관찰되지 않았다. 8-peer authority p95는 여전히 표본 편차가 커 p50을 회귀 기준으로 사용한다.

재현 명령:

```sh
luau -O1 benchmarks/multiplayer-run.luau -a standard O1
luau -O2 benchmarks/multiplayer-run.luau -a standard O2
luau -O2 --codegen benchmarks/multiplayer-run.luau -a standard O2-codegen
```

이 결과는 engine-neutral protocol gate다. 실제 server + 2 clients, RemoteEvent scheduling, lag/loss/jitter와 target-device 검증은 `examples/StudioMultiplayer` harness에서 별도로 수행한다.
