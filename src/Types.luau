--!strict

-- Public Push-Pull FRP types. Values stored by the runtime are exposed through
-- read-only records; the payload T itself follows the configured capture
-- policy (identity by default).

export type Disposable = () -> ()
export type Capture<T> = (value: T) -> T
export type Emit<T> = (value: T, time: number?) -> ()

export type CloneCodec<T> = {
	read clone: (value: T) -> T,
}

export type ImmutableNamespace = {
	serializable: <T>(codec: CloneCodec<T>?) -> Capture<T>,
}

export type LabelOptions = {
	read label: string?,
}

export type SourceOptions<T> = {
	read label: string?,
	read capture: Capture<T>?,
}

export type ScanOptions<S> = {
	read label: string?,
	read capture: Capture<S>?,
}

export type SubscribeOptions = {
	read initial: boolean?,
	read priority: number?,
}

export type HostOptions = {
	read startTime: number?,
	read onError: ((kind: string, message: unknown, details: unknown) -> ())?,
}

export type Occurrence<T> = {
	read time: number,
	read value: T,
	read order: number,
}

export type NamedOccurrenceInput<T> = {
	read time: number,
	read value: T,
}

export type TupleOccurrenceInput<T> = {
	read [number]: number | T,
}

export type OccurrenceInput<T> = NamedOccurrenceInput<T> | TupleOccurrenceInput<T>

export type EventDebugInfo = {
	read id: number,
	read label: string,
	read kind: string,
	read rank: number,
	read dependents: number,
}

export type ReactiveDebugInfo = {
	read id: number,
	read label: string,
	read rank: number,
	read historyCount: number,
	read changeEvent: number,
}

export type FrameContext = {
	read id: number,
	read time: number,
}

export type FrameResult = {
	read id: number,
	read time: number,
	read occurrenceCount: number,
}

export type HostError = {
	read kind: string,
	read message: string,
	read details: unknown,
}

export type Snapshot<T, B> = {
	read event: T,
	read behavior: B,
}

export type BehaviorSinkMetadata<T> = {
	read time: number,
	read frameId: number,
	read phaseOccurrence: Occurrence<TimeFunction<T>>?,
}

-- Luau 0.723 rejects recursive generic aliases when a combinator changes T.
-- Each method therefore spells out Handle<T> & Methods instead of recursively
-- referring to the public alias. The required function brand makes T
-- invariant and is compile-time-only.
export type HostHandle = {
	frame: (self: HostHandle, time: number, callback: ((frame: FrameContext) -> ())?) -> FrameResult,
	advanceTo: (self: HostHandle, time: number) -> number,
	now: (self: HostHandle) -> number,
	getErrors: (self: HostHandle) -> { HostError },
	dispose: (self: HostHandle) -> (),
	Destroy: (self: HostHandle) -> (),
}

type BehaviorHandle<T> = {
	read _behaviorType: (T) -> T,
}

type FutureHandle<T> = {
	read _futureType: (T) -> T,
}

type FutureMethods = {
	isNever: <T>(self: Future<T>) -> boolean,
	force: <T>(self: Future<T>) -> (number, T?),
	map: <T, U>(self: Future<T>, mapper: (T) -> U) -> Future<U>,
	ap: <A, U>(self: Future<(A) -> U>, argument: Future<A>) -> Future<U>,
	bind: <T, U>(self: Future<T>, mapper: (T) -> Future<U>) -> Future<U>,
	join: <U>(self: Future<Future<U>>) -> Future<U>,
	earlier: <T>(self: Future<T>, other: Future<T>) -> Future<T>,
	getTime: <T>(self: Future<T>) -> number,
	getValue: <T>(self: Future<T>) -> T?,
}

export type Future<T> = FutureMethods & FutureHandle<T>

type EventHandle<T> = {
	read _eventType: (T) -> T,
}

type EventMethods = {
	getHost: <T>(self: EventHandle<T> & EventMethods) -> (HostHandle & HostMethods),
	getDebugInfo: <T>(self: EventHandle<T> & EventMethods) -> EventDebugInfo,
	occurrences: <T>(self: EventHandle<T> & EventMethods, untilTime: number?) -> { Occurrence<T> },
	map: <T, U>(self: EventHandle<T> & EventMethods, mapper: (T) -> U, options: LabelOptions?) -> (EventHandle<U> & EventMethods),
	mapWithTime: <T, U>(self: EventHandle<T> & EventMethods, mapper: (T, number) -> U, options: LabelOptions?) -> (EventHandle<U> & EventMethods),
	filter: <T>(self: EventHandle<T> & EventMethods, predicate: (T) -> boolean, options: LabelOptions?) -> (EventHandle<T> & EventMethods),
	merge: <T>(self: EventHandle<T> & EventMethods, other: EventHandle<T> & EventMethods, options: LabelOptions?) -> (EventHandle<T> & EventMethods),
	scan: <T, S>(self: EventHandle<T> & EventMethods, initialValue: S, reducer: (S, T) -> S, options: ScanOptions<S>?) -> (EventHandle<S> & EventMethods),
	bind: <T, U>(self: EventHandle<T> & EventMethods, mapper: (T) -> (EventHandle<U> & EventMethods), options: LabelOptions?) -> (EventHandle<U> & EventMethods),
	join: <U>(self: Event<Event<U>>, options: LabelOptions?) -> Event<U>,
	ap: <A, U>(self: EventHandle<(A) -> U> & EventMethods, argument: EventHandle<A> & EventMethods, options: LabelOptions?) -> (EventHandle<U> & EventMethods),
	snapshot: (<T, B>(
		self: EventHandle<T> & EventMethods,
		behavior: BehaviorHandle<B>,
		combine: nil?,
		options: LabelOptions?
	) -> (EventHandle<Snapshot<T, B>> & EventMethods))
		& (<T, B, U>(
			self: EventHandle<T> & EventMethods,
			behavior: BehaviorHandle<B>,
			combine: (T, B, number) -> U,
			options: LabelOptions?
		) -> (EventHandle<U> & EventMethods)),
	subscribe: <T>(
		self: EventHandle<T> & EventMethods,
		callback: (value: T, time: number, occurrence: Occurrence<T>) -> (),
		options: SubscribeOptions?
	) -> Disposable,
}

export type Event<T> = EventMethods & EventHandle<T>

type ReactiveHandle<T> = {
	read _reactiveType: (T) -> T,
}

type ReactiveMethods = {
	getHost: <T>(self: ReactiveHandle<T> & ReactiveMethods) -> (HostHandle & HostMethods),
	changes: <T>(self: ReactiveHandle<T> & ReactiveMethods) -> (EventHandle<T> & EventMethods),
	initial: <T>(self: ReactiveHandle<T> & ReactiveMethods) -> T,
	current: <T>(self: ReactiveHandle<T> & ReactiveMethods) -> T,
	at: <T>(self: ReactiveHandle<T> & ReactiveMethods, time: number) -> T,
	getDebugInfo: <T>(self: ReactiveHandle<T> & ReactiveMethods) -> ReactiveDebugInfo,
	map: <T, U>(
		self: ReactiveHandle<T> & ReactiveMethods,
		mapper: (T) -> U,
		options: LabelOptions?
	) -> (ReactiveHandle<U> & ReactiveMethods),
	ap: <A, U>(
		self: ReactiveHandle<(A) -> U> & ReactiveMethods,
		argument: ReactiveHandle<A> & ReactiveMethods,
		options: LabelOptions?
	) -> (ReactiveHandle<U> & ReactiveMethods),
	bind: <T, U>(
		self: ReactiveHandle<T> & ReactiveMethods,
		mapper: (T) -> (ReactiveHandle<U> & ReactiveMethods),
		options: LabelOptions?
	) -> (ReactiveHandle<U> & ReactiveMethods),
	join: <U>(self: Reactive<Reactive<U>>, options: LabelOptions?) -> Reactive<U>,
	switcher: <T>(
		self: ReactiveHandle<T> & ReactiveMethods,
		event: EventHandle<ReactiveHandle<T> & ReactiveMethods> & EventMethods,
		options: LabelOptions?
	) -> (ReactiveHandle<T> & ReactiveMethods),
	subscribe: <T>(
		self: ReactiveHandle<T> & ReactiveMethods,
		callback: (value: T, time: number, occurrence: Occurrence<T>?) -> (),
		options: SubscribeOptions?
	) -> Disposable,
}

export type Reactive<T> = ReactiveMethods & ReactiveHandle<T>

type TimeFunctionMethods = {
	isConstant: <T>(self: TimeFunction<T>) -> boolean,
	apply: <T>(self: TimeFunction<T>, time: number) -> T,
	map: <T, U>(self: TimeFunction<T>, mapper: (T) -> U) -> TimeFunction<U>,
	ap: <A, U>(self: TimeFunction<(A) -> U>, argument: TimeFunction<A>) -> TimeFunction<U>,
	bind: <T, U>(self: TimeFunction<T>, mapper: (T) -> TimeFunction<U>) -> TimeFunction<U>,
	join: <U>(self: TimeFunction<TimeFunction<U>>) -> TimeFunction<U>,
}

type TimeFunctionHandle<T> = {
	read _timeFunctionType: (T) -> T,
}

export type TimeFunction<T> = TimeFunctionMethods & TimeFunctionHandle<T>

type BehaviorMethods = {
	getHost: <T>(self: BehaviorHandle<T> & BehaviorMethods) -> (HostHandle & HostMethods),
	phases: <T>(
		self: BehaviorHandle<T> & BehaviorMethods
	) -> (ReactiveHandle<TimeFunction<T>> & ReactiveMethods),
	at: <T>(self: BehaviorHandle<T> & BehaviorMethods, time: number) -> T,
	current: <T>(self: BehaviorHandle<T> & BehaviorMethods) -> T,
	map: <T, U>(
		self: BehaviorHandle<T> & BehaviorMethods,
		mapper: (T) -> U,
		options: LabelOptions?
	) -> (BehaviorHandle<U> & BehaviorMethods),
	ap: <A, U>(
		self: BehaviorHandle<(A) -> U> & BehaviorMethods,
		argument: BehaviorHandle<A> & BehaviorMethods,
		options: LabelOptions?
	) -> (BehaviorHandle<U> & BehaviorMethods),
	switcher: <T>(
		self: BehaviorHandle<T> & BehaviorMethods,
		event: EventHandle<BehaviorHandle<T> & BehaviorMethods> & EventMethods,
		options: LabelOptions?
	) -> (BehaviorHandle<T> & BehaviorMethods),
	subscribe: <T>(
		self: BehaviorHandle<T> & BehaviorMethods,
		callback: (value: T, time: number, metadata: BehaviorSinkMetadata<T>?) -> (),
		options: SubscribeOptions?
	) -> Disposable,
}

export type Behavior<T> = BehaviorMethods & BehaviorHandle<T>

type HostMethods = {
	source: <T>(
		self: HostHandle & HostMethods,
		options: SourceOptions<T>?
	) -> (EventHandle<T> & EventMethods, Emit<T>),
	sample: <T>(
		self: HostHandle & HostMethods,
		behavior: BehaviorHandle<T> & BehaviorMethods,
		time: number?
	) -> T,
	eventFromFuture: <T>(
		self: HostHandle & HostMethods,
		future: Future<T>,
		options: SourceOptions<T>?
	) -> (EventHandle<T> & EventMethods),
	eventFromOccurrences: <T>(
		self: HostHandle & HostMethods,
		entries: { OccurrenceInput<T> },
		options: SourceOptions<T>?
	) -> (EventHandle<T> & EventMethods),
}

export type Host = HostHandle & HostMethods

export type FutureNamespace = {
	at: <T>(time: number, value: T) -> Future<T>,
	never: <T>() -> Future<T>,
	pure: <T>(value: T) -> Future<T>,
	isNever: <T>(self: Future<T>) -> boolean,
	force: <T>(self: Future<T>) -> (number, T?),
	map: <T, U>(self: Future<T>, mapper: (T) -> U) -> Future<U>,
	ap: <A, U>(self: Future<(A) -> U>, argument: Future<A>) -> Future<U>,
	bind: <T, U>(self: Future<T>, mapper: (T) -> Future<U>) -> Future<U>,
	join: <T>(self: Future<Future<T>>) -> Future<T>,
	earlier: <T>(self: Future<T>, other: Future<T>) -> Future<T>,
	alt: <T>(self: Future<T>, other: Future<T>) -> Future<T>,
	getTime: <T>(self: Future<T>) -> number,
	getValue: <T>(self: Future<T>) -> T?,
}

export type EventNamespace = {
	never: <T>(host: Host, options: LabelOptions?) -> Event<T>,
	pure: <T>(host: Host, value: T, options: SourceOptions<T>?) -> Event<T>,
	once: <T>(host: Host, time: number, value: T, options: SourceOptions<T>?) -> Event<T>,
	fromOccurrences: <T>(host: Host, entries: { OccurrenceInput<T> }, options: SourceOptions<T>?) -> Event<T>,
	source: <T>(host: Host, options: SourceOptions<T>?) -> (Event<T>, Emit<T>),
	fromFuture: <T>(host: Host, future: Future<T>, options: SourceOptions<T>?) -> Event<T>,
	getHost: <T>(self: Event<T>) -> Host,
	getDebugInfo: <T>(self: Event<T>) -> EventDebugInfo,
	occurrences: <T>(self: Event<T>, untilTime: number?) -> { Occurrence<T> },
	map: <T, U>(self: Event<T>, mapper: (T) -> U, options: LabelOptions?) -> Event<U>,
	mapWithTime: <T, U>(self: Event<T>, mapper: (T, number) -> U, options: LabelOptions?) -> Event<U>,
	filter: <T>(self: Event<T>, predicate: (T) -> boolean, options: LabelOptions?) -> Event<T>,
	merge: <T>(self: Event<T>, other: Event<T>, options: LabelOptions?) -> Event<T>,
	scan: <T, S>(self: Event<T>, initialValue: S, reducer: (S, T) -> S, options: ScanOptions<S>?) -> Event<S>,
	bind: <T, U>(self: Event<T>, mapper: (T) -> Event<U>, options: LabelOptions?) -> Event<U>,
	join: <T>(self: Event<Event<T>>, options: LabelOptions?) -> Event<T>,
	ap: <A, U>(self: Event<(A) -> U>, argument: Event<A>, options: LabelOptions?) -> Event<U>,
	snapshot: (<T, B>(
		self: Event<T>,
		behavior: Behavior<B>,
		combine: nil?,
		options: LabelOptions?
	) -> Event<Snapshot<T, B>>)
		& (<T, B, U>(
			self: Event<T>,
			behavior: Behavior<B>,
			combine: (T, B, number) -> U,
			options: LabelOptions?
		) -> Event<U>),
	subscribe: <T>(
		self: Event<T>,
		callback: (value: T, time: number, occurrence: Occurrence<T>) -> (),
		options: SubscribeOptions?
	) -> Disposable,
}

export type ReactiveNamespace = {
	pure: <T>(host: Host, value: T, options: LabelOptions?) -> Reactive<T>,
	stepper: <T>(initialValue: T, event: Event<T>, options: LabelOptions?) -> Reactive<T>,
	switch: <T>(initialReactive: Reactive<T>, event: Event<Reactive<T>>, options: LabelOptions?) -> Reactive<T>,
	accum: <T>(initialValue: T, eventOfFunctions: Event<(T) -> T>, options: ScanOptions<T>?) -> Reactive<T>,
	getHost: <T>(self: Reactive<T>) -> Host,
	changes: <T>(self: Reactive<T>) -> Event<T>,
	initial: <T>(self: Reactive<T>) -> T,
	current: <T>(self: Reactive<T>) -> T,
	at: <T>(self: Reactive<T>, time: number) -> T,
	getDebugInfo: <T>(self: Reactive<T>) -> ReactiveDebugInfo,
	map: <T, U>(self: Reactive<T>, mapper: (T) -> U, options: LabelOptions?) -> Reactive<U>,
	ap: <A, U>(self: Reactive<(A) -> U>, argument: Reactive<A>, options: LabelOptions?) -> Reactive<U>,
	bind: <T, U>(self: Reactive<T>, mapper: (T) -> Reactive<U>, options: LabelOptions?) -> Reactive<U>,
	join: <T>(self: Reactive<Reactive<T>>, options: LabelOptions?) -> Reactive<T>,
	switcher: <T>(self: Reactive<T>, event: Event<Reactive<T>>, options: LabelOptions?) -> Reactive<T>,
	subscribe: <T>(
		self: Reactive<T>,
		callback: (value: T, time: number, occurrence: Occurrence<T>?) -> (),
		options: SubscribeOptions?
	) -> Disposable,
}

export type TimeFunctionNamespace = {
	constant: <T>(value: T) -> TimeFunction<T>,
	pure: <T>(value: T) -> TimeFunction<T>,
	dynamic: <T>(callback: (time: number) -> T) -> TimeFunction<T>,
	fromFunction: <T>(callback: (time: number) -> T) -> TimeFunction<T>,
	isConstant: <T>(self: TimeFunction<T>) -> boolean,
	apply: <T>(self: TimeFunction<T>, time: number) -> T,
	map: <T, U>(self: TimeFunction<T>, mapper: (T) -> U) -> TimeFunction<U>,
	ap: <A, U>(self: TimeFunction<(A) -> U>, argument: TimeFunction<A>) -> TimeFunction<U>,
	bind: <T, U>(self: TimeFunction<T>, mapper: (T) -> TimeFunction<U>) -> TimeFunction<U>,
	join: <T>(self: TimeFunction<TimeFunction<T>>) -> TimeFunction<T>,
}

export type BehaviorNamespace = {
	pure: <T>(host: Host, value: T, options: LabelOptions?) -> Behavior<T>,
	constant: <T>(host: Host, value: T, options: LabelOptions?) -> Behavior<T>,
	fromFunction: <T>(host: Host, callback: (time: number) -> T, options: LabelOptions?) -> Behavior<T>,
	time: (host: Host, options: LabelOptions?) -> Behavior<number>,
	stepper: <T>(initialValue: T, event: Event<T>, options: LabelOptions?) -> Behavior<T>,
	switch: <T>(initialBehavior: Behavior<T>, event: Event<Behavior<T>>, options: LabelOptions?) -> Behavior<T>,
	accum: <T>(initialValue: T, eventOfFunctions: Event<(T) -> T>, options: ScanOptions<T>?) -> Behavior<T>,
	lift2: <A, B, U>(
		callback: (A, B) -> U,
		left: Behavior<A>,
		right: Behavior<B>,
		options: LabelOptions?
	) -> Behavior<U>,
	lift3: <A, B, C, U>(
		callback: (A, B, C) -> U,
		first: Behavior<A>,
		second: Behavior<B>,
		third: Behavior<C>,
		options: LabelOptions?
	) -> Behavior<U>,
	getHost: <T>(self: Behavior<T>) -> Host,
	phases: <T>(self: Behavior<T>) -> Reactive<TimeFunction<T>>,
	at: <T>(self: Behavior<T>, time: number) -> T,
	current: <T>(self: Behavior<T>) -> T,
	map: <T, U>(self: Behavior<T>, mapper: (T) -> U, options: LabelOptions?) -> Behavior<U>,
	ap: <A, U>(self: Behavior<(A) -> U>, argument: Behavior<A>, options: LabelOptions?) -> Behavior<U>,
	switcher: <T>(self: Behavior<T>, event: Event<Behavior<T>>, options: LabelOptions?) -> Behavior<T>,
	subscribe: <T>(
		self: Behavior<T>,
		callback: (value: T, time: number, metadata: BehaviorSinkMetadata<T>?) -> (),
		options: SubscribeOptions?
	) -> Disposable,
}

-- The pre-FRP StateRuntime is a migration surface. DynamicCompatibility is
-- intentionally confined to this legacy boundary and engine utility modules.
export type DynamicCompatibility = any

export type ChangeSet = {
	transactionId: number,
	tick: number?,
	cause: string,
	changedNodes: { DynamicCompatibility },
	changes: { DynamicCompatibility },
	actions: { DynamicCompatibility },
	commands: { DynamicCompatibility },
	replay: boolean,
	watchErrors: { DynamicCompatibility },
}

export type Source<T> = {
	get: (self: Source<T>) -> T,
	getRevision: (self: Source<T>) -> number,
	getRuntime: (self: Source<T>) -> DynamicCompatibility,
	getDebugInfo: (self: Source<T>) -> DynamicCompatibility,
}

export type Atom<T> = Source<T> & {
	set: (self: Atom<T>, value: T) -> ChangeSet?,
	update: (self: Atom<T>, updater: (T) -> T) -> ChangeSet?,
	mutate: (self: Atom<T>, mutator: (T) -> ()) -> ChangeSet?,
	touch: (self: Atom<T>) -> ChangeSet?,
	asReadonly: (self: Atom<T>) -> Source<T>,
}

export type Computed<T> = Source<T> & {
	peek: (self: Computed<T>) -> T,
}

export type Scope = {
	add: (self: Scope, disposable: DynamicCompatibility) -> DynamicCompatibility,
	dispose: (self: Scope) -> (),
	Destroy: (self: Scope) -> (),
	isDisposed: (self: Scope) -> boolean,
}

export type Store<S, A> = {
	getState: (self: Store<S, A>) -> S,
	dispatch: (self: Store<S, A>, action: A) -> ChangeSet?,
	select: <T>(self: Store<S, A>, selector: (S) -> T, options: DynamicCompatibility?) -> Computed<T>,
}

export type Runtime = {
	atom: <T>(self: Runtime, initialValue: T, options: DynamicCompatibility?) -> Atom<T>,
	computed: <T>(self: Runtime, getter: () -> T, options: DynamicCompatibility?) -> Computed<T>,
	watch: <T>(
		self: Runtime,
		source: Source<T>,
		callback: (T, T?, ChangeSet?) -> (),
		options: DynamicCompatibility?
	) -> Disposable,
	scope: (self: Runtime, callback: ((Scope) -> ())?) -> Scope,
	transaction: (self: Runtime, callback: () -> (), metadata: DynamicCompatibility?) -> ChangeSet?,
	batch: (self: Runtime, callback: () -> (), metadata: DynamicCompatibility?) -> ChangeSet?,
	store: <S, A>(self: Runtime, options: DynamicCompatibility) -> Store<S, A>,
	step: (
		self: Runtime,
		tick: number,
		callback: (DynamicCompatibility) -> (),
		metadata: DynamicCompatibility?
	) -> ChangeSet,
	snapshot: (self: Runtime, tick: number?) -> DynamicCompatibility,
	restore: (self: Runtime, snapshot: DynamicCompatibility) -> ChangeSet?,
	rollback: (self: Runtime, tick: number) -> ChangeSet?,
	replay: (
		self: Runtime,
		fromTick: number,
		toTick: number,
		inputProvider: (DynamicCompatibility, number) -> ()
	) -> (),
	confirm: (self: Runtime, tick: number) -> { DynamicCompatibility },
	discardAfter: (self: Runtime, tick: number) -> { DynamicCompatibility },
	getTick: (self: Runtime) -> number?,
	getConfirmedTick: (self: Runtime) -> number?,
	getStateHash: (self: Runtime) -> string,
	getPendingCommands: (self: Runtime) -> { DynamicCompatibility },
	getDebugSnapshot: (self: Runtime) -> DynamicCompatibility,
	trace: (self: Runtime, eventName: string, fields: DynamicCompatibility?) -> (),
	dispose: (self: Runtime) -> (),
}

export type FRP = {
	VERSION: string,
	API_VERSION: number,
	SEMANTICS_VERSION: number,
	NEG_INFINITY: number,
	POS_INFINITY: number,
	Host: Host,
	Event: EventNamespace,
	Reactive: ReactiveNamespace,
	Behavior: BehaviorNamespace,
	Future: FutureNamespace,
	TimeFunction: TimeFunctionNamespace,
	Immutable: ImmutableNamespace,
	clock: DynamicCompatibility,
	codec: DynamicCompatibility,
	hash: DynamicCompatibility,
	StateRuntime: DynamicCompatibility,
	newHost: (options: HostOptions?) -> Host,
	never: <T>(host: Host, options: LabelOptions?) -> Event<T>,
	eventPure: <T>(host: Host, value: T, options: SourceOptions<T>?) -> Event<T>,
	reactivePure: <T>(host: Host, value: T, options: LabelOptions?) -> Reactive<T>,
	stepper: <T>(initialValue: T, event: Event<T>, options: LabelOptions?) -> Reactive<T>,
	switcher: <T>(initialReactive: Reactive<T>, event: Event<Reactive<T>>, options: LabelOptions?) -> Reactive<T>,
	accumReactive: <T>(initialValue: T, eventOfFunctions: Event<(T) -> T>, options: ScanOptions<T>?) -> Reactive<T>,
	accumEvent: <T>(initialValue: T, eventOfFunctions: Event<(T) -> T>, options: ScanOptions<T>?) -> Event<T>,
	constant: <T>(host: Host, value: T, options: LabelOptions?) -> Behavior<T>,
	fromFunction: <T>(host: Host, callback: (time: number) -> T, options: LabelOptions?) -> Behavior<T>,
	time: (host: Host, options: LabelOptions?) -> Behavior<number>,
	stepperBehavior: <T>(initialValue: T, event: Event<T>, options: LabelOptions?) -> Behavior<T>,
	switcherBehavior: <T>(
		initialBehavior: Behavior<T>,
		event: Event<Behavior<T>>,
		options: LabelOptions?
	) -> Behavior<T>,
	accumBehavior: <T>(initialValue: T, eventOfFunctions: Event<(T) -> T>, options: ScanOptions<T>?) -> Behavior<T>,
	lift2: <A, B, U>(
		callback: (A, B) -> U,
		left: Behavior<A>,
		right: Behavior<B>,
		options: LabelOptions?
	) -> Behavior<U>,
	lift3: <A, B, C, U>(
		callback: (A, B, C) -> U,
		first: Behavior<A>,
		second: Behavior<B>,
		third: Behavior<C>,
		options: LabelOptions?
	) -> Behavior<U>,
	once: <T>(host: Host, time: number, value: T, options: SourceOptions<T>?) -> Event<T>,
	fromOccurrences: <T>(host: Host, entries: { OccurrenceInput<T> }, options: SourceOptions<T>?) -> Event<T>,
	isHost: (value: unknown) -> boolean,
	isEvent: (value: unknown) -> boolean,
	isReactive: (value: unknown) -> boolean,
	isBehavior: (value: unknown) -> boolean,
	isFuture: (value: unknown) -> boolean,
	create: (options: DynamicCompatibility?) -> Runtime,
	createStateRuntime: (options: DynamicCompatibility?) -> Runtime,
	createCapital: (options: DynamicCompatibility?) -> DynamicCompatibility,
	Compat: DynamicCompatibility,
	isRuntime: (value: unknown) -> boolean,
}

-- These functions are compile-time witnesses used by src/init.luau to
-- re-export the canonical aliases without executing a string require in
-- Studio. Calling one directly is unsupported.
local TypeWitness = {}

function TypeWitness.frp(): FRP
	error("type witness", 0)
end

function TypeWitness.host(): Host
	error("type witness", 0)
end

function TypeWitness.event<T>(_value: T?): Event<T>
	error("type witness", 0)
end

function TypeWitness.reactive<T>(_value: T?): Reactive<T>
	error("type witness", 0)
end

function TypeWitness.behavior<T>(_value: T?): Behavior<T>
	error("type witness", 0)
end

function TypeWitness.future<T>(_value: T?): Future<T>
	error("type witness", 0)
end

function TypeWitness.timeFunction<T>(_value: T?): TimeFunction<T>
	error("type witness", 0)
end

function TypeWitness.occurrence<T>(_value: T?): Occurrence<T>
	error("type witness", 0)
end

function TypeWitness.occurrenceInput<T>(_value: T?): OccurrenceInput<T>
	error("type witness", 0)
end

function TypeWitness.snapshot<T, B>(_eventValue: T?, _behaviorValue: B?): Snapshot<T, B>
	error("type witness", 0)
end

function TypeWitness.capture<T>(_value: T?): Capture<T>
	error("type witness", 0)
end

function TypeWitness.emit<T>(_value: T?): Emit<T>
	error("type witness", 0)
end

function TypeWitness.cloneCodec<T>(_value: T?): CloneCodec<T>
	error("type witness", 0)
end

function TypeWitness.immutable(): ImmutableNamespace
	error("type witness", 0)
end

function TypeWitness.behaviorSinkMetadata<T>(_value: T?): BehaviorSinkMetadata<T>
	error("type witness", 0)
end

function TypeWitness.sourceOptions<T>(_value: T?): SourceOptions<T>
	error("type witness", 0)
end

function TypeWitness.scanOptions<T>(_value: T?): ScanOptions<T>
	error("type witness", 0)
end

function TypeWitness.labelOptions(): LabelOptions
	error("type witness", 0)
end

function TypeWitness.subscribeOptions(): SubscribeOptions
	error("type witness", 0)
end

function TypeWitness.hostOptions(): HostOptions
	error("type witness", 0)
end

function TypeWitness.eventDebugInfo(): EventDebugInfo
	error("type witness", 0)
end

function TypeWitness.reactiveDebugInfo(): ReactiveDebugInfo
	error("type witness", 0)
end

function TypeWitness.frameContext(): FrameContext
	error("type witness", 0)
end

function TypeWitness.frameResult(): FrameResult
	error("type witness", 0)
end

function TypeWitness.hostError(): HostError
	error("type witness", 0)
end

function TypeWitness.runtime(): Runtime
	error("type witness", 0)
end

return TypeWitness
