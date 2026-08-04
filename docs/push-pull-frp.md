# 논문 의미론과 strict Luau 이식

기준 문헌은 Conal Elliott, *Push-pull functional reactive programming* (Haskell Symposium 2009)이다.

- [저자 공식 페이지](http://conal.net/papers/push-pull-frp/)
- [논문 PDF](http://conal.net/papers/push-pull-frp/push-pull-frp.pdf)

이 문서는 “비슷한 signal API”가 아니라 어떤 부분을 같은 denotation으로 구현했으며, Haskell 실행 장치를 Luau에서 무엇으로 대체했는지 기록한다.

## 1. 시간과 Future

Behavior의 `Time`은 유한한 전순서다. occurrence에만 `-∞`와 `+∞`를 추가한 `BoundTime`을 사용한다.

```text
-∞ < finite Time < +∞
```

```text
Future<A> ≅ (BoundTime, A)
```

의존성 결합과 earliest 대안은 서로 반대다.

```text
map(f, a@ta)         = f(a)@ta
pure(a)              = a@-∞
ap(f@tf, a@ta)       = f(a)@max(tf, ta)
bind(a@ta, k)        = b@max(ta, tb), where k(a)=b@tb

never                = +∞
earlier(a@ta, b@tb)  = min by time, left on tie
```

Luau API의 `Future.at`은 finite time만 받는다. `pure`와 `never`가 두 bound를 명시적으로 만든다. `NaN`과 무한 Host time은 거부한다.

## 2. Event

```text
Event<A> denotation = time-nondecreasing [(BoundTime, A)]
```

같은 time의 occurrence는 payload가 같아도 모두 남는다. merge는 chronological stable-left merge다.

```text
A = [(1,A1),(2,A2a),(2,A2b),(4,A4)]
B = [(2,B2a),(2,B2b),(3,B3)]

A ⊕ B =
[(1,A1),(2,A2a),(2,A2b),(2,B2a),(2,B2b),(3,B3),(4,A4)]
```

Event Monad는 inner prefix를 버리지 않는다.

```text
delayOccs(to, inner) = [(max(to, ti), a) | (ti,a) in inner]
bind(outer, k)       = stable merge of every delayOccs(to, k(a))
```

여기서 `k`의 타입은 정확히 `A -> Event<B>`다. occurrence time을 숨은 callback 인자로 넘기면 `(m >>= k) >>= h`와 `m >>= (\x -> k(x) >>= h)`에서 `h`가 서로 다른, 이미 clamp된 time을 볼 수 있어 결합법칙이 깨진다. 따라서 public `map/bind`는 payload만 받고, time 관찰은 law 바깥의 명시적 `mapWithTime`/`snapshot` 경계로 분리한다.

따라서 outer가 5에 inner를 만들고 inner에 3의 occurrence가 있으면 결과는 5다. 새로 subscribe한 sink에 과거 finite occurrence를 재생한다는 뜻은 아니다. `bind` denotation을 계산할 때 동적으로 선택한 stream의 과거 prefix가 필요하다는 뜻이다.

mapper가 현재 frame 안에서 새 Event를 만들어도 같은 규칙을 지킨다. 예를 들어 outer `@5`가 `[(3,past),(5,same),(7,future)]`를 만들면 결과는 `[(5,past),(5,same),(7,future)]`다. immutable `fromOccurrences` Event는 과거 prefix를 pull하고, 동시간 root는 active frame에 합치며, 미래 root는 frame commit 성공 뒤 예약한다.

## 3. Reactive와 strict boundary

```text
Reactive<A> = Stepper(initial A, changes Event<A>)

rat(r, t) = last(initial :: [a | (te,a) in changes, te < t])
```

비교가 `te <= t`가 아니라 `te < t`다.

```text
r = stepper(0, [(1,10),(1,11),(3,30)])

rat(r,1) = 0
rat(r,2) = 11
rat(r,3) = 11
rat(r,4) = 30
```

실행 Host에는 두 관찰이 있다.

- `reactive:at(t)`: 논문의 strict denotation.
- `reactive:current()`: frame commit 뒤 effect adapter가 사용할 운영상 최신값.

Applicative의 동시간 변화는 함수 쪽을 먼저 처리한다.

```text
rf: initial id, @2 (*10)
rx: initial 1,  @2 2
rf <*> rx changes @2 = [10, 20]
```

Reactive `join`에서는 기존 inner의 동시간 변화가 먼저, outer switch가 나중이다. switch 뒤의 기존 inner 미래 occurrence는 폐기한다.

## 4. TimeFunction과 Behavior

```text
TimeFunction<A> = Constant(A) | Dynamic(Time -> A)
Behavior<A>     = Reactive<TimeFunction<A>>
```

```text
apply(Constant(a), t) = a
apply(Dynamic(f), t)  = f(t)
```

상수끼리의 map/ap는 Constant로 남는다. 하나라도 dynamic이면 양쪽을 같은 정확한 time에 sample하는 Dynamic이 된다.

```text
at(Behavior(phases), t) = apply(rat(phases,t), t)
time                     = Behavior(pure(Dynamic(identity)))
```

Behavior는 Functor와 Applicative를 제공한다. 논문의 reactive normal form에는 Behavior Monad 구현이 없으므로 이 라이브러리도 `Behavior.bind/join`을 제공하지 않는다.

## 5. push와 pull의 실제 경계

논문에서 Event/Reactive의 이산 phase 변경은 data-driven이고, 현재 time function의 렌더링은 demand-driven이다. Luau Core도 같은 경계를 둔다.

- source frame이 Event dependency에 dirty를 push한다.
- Reactive와 sink가 dirty Event node만 pull한다.
- Constant phase는 한 번만 renderer에 전달한다.
- Dynamic phase만 Host advance마다 time으로 pull한다.
- graph가 dormant이면 mapper/predicate를 source 발생 때 실행하지 않는다.

소비형 Host는 시간 증가 순서만 허용해 지나간 prefix 검색과 active phase를 캐시한다. 테스트·진단용 `Event:occurrences()`는 닫힌 prefix를 read-only로 pull해 denotation과 비교할 수 있다. 과거 cutoff를 조회해도 live `scan/bind` state는 되감기지 않는다.

## 6. Haskell 실행 장치와의 차이

논문 구현의 future time은 `AddBounds`, `Max`, `Improving`을 조합하고 `unamb`로 두 호환 계산을 동시에 시도한다. 이것은 Haskell의 다음 특성에 기대어 있다.

- lazy value와 bottom
- block 가능한 partial comparison
- `unsafePerformIO`
- thread race와 loser kill

strict Luau에서는 함수 인자가 먼저 평가되고 coroutine이 CPU 계산을 선점하지 못한다. 이 구조를 이름만 같은 `unamb`로 옮기면 deadlock 또는 task 도착 속도에 따른 비결정적 tie가 된다.

이 구현의 대체 장치는 다음과 같다.

| 논문 구현 장치 | strict Luau 대응 |
|---|---|
| lazy Event tail | source prefix + demand-driven 조합자 reconstruction |
| improving lower bound | Host의 명시적 monotonic frontier |
| future exact time | timestamped source 또는 scheduled Future |
| `unamb` earliest race | 알려진 time 비교; tie는 graph structural left |
| real-time sink thread | explicit subscribe/dispose와 Host advance |
| 여러 root의 동시간 폐쇄 | `Host:frame(time)` barrier |

한 번 닫힌 numeric time은 다시 열지 않는다. 재개방을 허용하면 먼저 전달된 `right@t` 뒤에 나중의 `left@t`를 삽입할 수 없어 live sink 결과와 Event denotation이 달라진다. 예약 root와 callback root는 frame을 닫기 전에 함께 수집하고, sink의 재진입 occurrence는 미래 time만 허용한다.

generic unresolved Future race는 현재 공개하지 않는다. 외부 비동기 시스템이 lower-bound/watermark protocol을 제공한다면 별도 adapter에서 exact time이 알려진 뒤 Host에 넣는다.

## 7. OVERDARE와 logical frame

여러 Signal callback이 같은 engine frame에 속한다면 각각 즉시 Host commit을 만들면 안 된다. 나중에 도착한 left source를 이미 전달한 right source보다 앞에 삽입할 수 없기 때문이다.

`Overdare.attachFRP`는 다음 순서로 동작한다.

```text
Signal callbacks -> pending queue
RunService phase -> one Host:frame(time)
                 -> all pending source emissions
                 -> frame occurrence
```

이 barrier 덕분에 callback 도착이 `right, left`여도 `left:merge(right)`의 결과는 `left, right`다.

## 8. 자동 semantic gate

현재 테스트에는 다음 항목이 포함된다.

- Future `max`/`min` truth table과 left tie
- Event duplicate 보존, stable chronological merge, bind prefix clamp, Cartesian ap
- Event Functor/Monad callback value-only 계약과 associativity
- frame 안에서 동적으로 만든 inner Event의 past/same/future occurrence
- `stepper/switcher` exact-time strict boundary
- Reactive simultaneous applicative와 dynamic join/switch
- stateful scan의 nil state, 동일 inner 재선택, read-only 과거 pull
- Constant/Dynamic TimeFunction 조합
- Behavior 같은-time pointwise sample, 다중/중복 phase delivery와 global time switch
- Event-at-Behavior strict snapshot
- dormant graph quiescence
- frame prepare rollback과 sink error isolation
- 100개 randomized stable-merge trace와 배열 reference 비교
- OVERDARE multi-Signal single-frame batching 및 disposer
- discarded graph GC와 Host dispose ownership 해제

전용 benchmark는 `future/max_sync`, `event/stable_merge_ties`, `event/push_pull_pipeline`, `reactive/applicative_simultaneous`, `behavior/continuous_pull`, `behavior/switcher_churn`, `event/dormant_quiescence`를 O1/O2/codegen에서 실행한다.

## 9. 아직 의도적으로 없는 기능

- generic public `unamb`와 unresolved improving Future
- Behavior Monad
- continuous numerical integration helper
- Zeno stream 또는 한 finite time 이전의 무한 occurrence 지원
- Event/Reactive graph 자체의 자동 복제와 built-in AOI projection (명시적 FRP protocol/authority adapter는 `docs/networking.md`에 제공)
- Studio target-device 절대 성능 합격선

## 10. 수명과 무한 prefix

정통 Event Monad에서 미래의 mapper가 임의의 과거 inner occurrence를 선택할 수 있으므로 Host가 살아 있는 동안 source prefix와 Reactive history는 의미론적 데이터다. 일반적인 bounded retention을 기본값으로 두면 `bind` 법칙이 깨진다.

- parent의 downstream dependency는 weak-key라 사용자가 버린 graph는 Host 수명 중에도 GC 대상이다.
- `host:dispose()`는 남은 graph edge, callback, scheduler, prefix/history를 모두 해제한다.
- 장시간 multiplayer 서버는 match/session/replication epoch 단위 Host를 사용하고 종료 시 dispose한다.
- bounded-history mode가 필요하다면 과거 선택 범위를 제한하는 별도 타입/계약으로 추가해야 하며 이 Core Event와 같은 denotation이라고 부르지 않는다.

이 항목은 Core 의미를 바꾸지 않고 별도 연구·adapter로 추가해야 한다.
