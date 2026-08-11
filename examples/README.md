# Examples

- `DomainState.luau`: writable Atom을 숨기고 Source와 action만 공개하는 ModuleScript 패턴 (`createStateRuntime`).
- Capital/`Get`/`Set` 스타일은 README와 `docs/state-runtime.md`의 `FRP.createCapital()` 예제를 본다.
- `FixedStep.luau`: 외부 RunService phase가 Runtime tick을 구동하는 방법.
- `NetworkSchema.luau`: server-to-client state와 client intent를 분리한 schema factory.
- `StudioMultiplayer/`: 실제 OVERDARE server + 2 clients에서 FRP RemoteEvent와 기존 snapshot/prediction 경계를 함께 검증하는 release-gate harness.
- 설치된 package만 있는 blank World에서는 `ReactiveState.START_HERE`와 `ReactiveState.Guides.serverAuthoritativeMultiplayer`를 먼저 본다.

예제는 자동 실행되지 않는다. OVERDARE project의 역할에 맞는 Script/LocalScript/ModuleScript로 복사하고 package 위치를 조정한다.
