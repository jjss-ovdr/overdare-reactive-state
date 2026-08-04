--!strict

export type Occurrence<T> = {
	time: number,
	value: T,
	order: number,
}

export type Disposable = () -> ()

export type Future<T> = {
	isNever: (self: Future<T>) -> boolean,
	force: (self: Future<T>) -> (number, T?),
	map: <U>(self: Future<T>, mapper: (T) -> U) -> Future<U>,
	ap: <U>(self: Future<any>, argument: Future<any>) -> Future<U>,
	bind: <U>(self: Future<T>, mapper: (T) -> Future<U>) -> Future<U>,
	earlier: (self: Future<T>, other: Future<T>) -> Future<T>,
	getTime: (self: Future<T>) -> number,
	getValue: (self: Future<T>) -> T?,
}

export type Event<T> = {
	getHost: (self: Event<T>) -> any,
	occurrences: (self: Event<T>, untilTime: number?) -> { Occurrence<T> },
	map: <U>(self: Event<T>, mapper: (T) -> U, options: any?) -> Event<U>,
	mapWithTime: <U>(self: Event<T>, mapper: (T, number) -> U, options: any?) -> Event<U>,
	filter: (self: Event<T>, predicate: (T) -> boolean, options: any?) -> Event<T>,
	merge: (self: Event<T>, other: Event<T>, options: any?) -> Event<T>,
	scan: <S>(self: Event<T>, initialValue: S, reducer: (S, T) -> S, options: any?) -> Event<S>,
	bind: <U>(self: Event<T>, mapper: (T) -> Event<U>, options: any?) -> Event<U>,
	join: (self: Event<T>, options: any?) -> any,
	ap: (self: Event<T>, argument: any, options: any?) -> any,
	snapshot: (self: Event<T>, behavior: any, combine: ((T, any, number) -> any)?, options: any?) -> any,
	subscribe: (self: Event<T>, callback: (T, number, Occurrence<T>) -> (), options: any?) -> Disposable,
}

export type Reactive<T> = {
	getHost: (self: Reactive<T>) -> any,
	initial: (self: Reactive<T>) -> T,
	changes: (self: Reactive<T>) -> Event<T>,
	current: (self: Reactive<T>) -> T,
	at: (self: Reactive<T>, time: number) -> T,
	map: (self: Reactive<T>, mapper: (T) -> any, options: any?) -> any,
	ap: (self: Reactive<T>, argument: any, options: any?) -> any,
	bind: (self: Reactive<T>, mapper: (T) -> any, options: any?) -> any,
	join: (self: Reactive<T>, options: any?) -> any,
	switcher: (self: Reactive<T>, event: any, options: any?) -> Reactive<T>,
	subscribe: (self: Reactive<T>, callback: (T, number, Occurrence<T>?) -> (), options: any?) -> Disposable,
}

export type Behavior<T> = {
	getHost: (self: Behavior<T>) -> any,
	at: (self: Behavior<T>, time: number) -> T,
	current: (self: Behavior<T>) -> T,
	map: (self: Behavior<T>, mapper: (T) -> any, options: any?) -> any,
	ap: (self: Behavior<T>, argument: any, options: any?) -> any,
	switcher: (self: Behavior<T>, event: any, options: any?) -> Behavior<T>,
	subscribe: (self: Behavior<T>, callback: (T, number, any?) -> (), options: any?) -> Disposable,
}

export type Host = {
	source: (self: Host, options: any?) -> (any, (any, number?) -> ()),
	frame: (self: Host, time: number, callback: ((any) -> ())?) -> any,
	advanceTo: (self: Host, time: number) -> number,
	sample: (self: Host, behavior: any, time: number?) -> any,
	eventFromFuture: (self: Host, future: any, options: any?) -> any,
	eventFromOccurrences: (self: Host, entries: { any }, options: any?) -> any,
	now: (self: Host) -> number,
	getErrors: (self: Host) -> { any },
	dispose: (self: Host) -> (),
}

export type ChangeSet = {
	transactionId: number,
	tick: number?,
	cause: string,
	changedNodes: { any },
	changes: { any },
	actions: { any },
	commands: { any },
	replay: boolean,
	watchErrors: { any },
}

export type Source<T> = {
	get: (self: Source<T>) -> T,
	getRevision: (self: Source<T>) -> number,
	getRuntime: (self: Source<T>) -> any,
	getDebugInfo: (self: Source<T>) -> any,
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
	add: (self: Scope, disposable: any) -> any,
	dispose: (self: Scope) -> (),
	Destroy: (self: Scope) -> (),
	isDisposed: (self: Scope) -> boolean,
}

export type Store<S, A> = {
	getState: (self: Store<S, A>) -> S,
	dispatch: (self: Store<S, A>, action: A) -> ChangeSet?,
	select: <T>(self: Store<S, A>, selector: (S) -> T, options: any?) -> Computed<T>,
}

export type Runtime = {
	atom: <T>(self: Runtime, initialValue: T, options: any?) -> Atom<T>,
	computed: <T>(self: Runtime, getter: () -> T, options: any?) -> Computed<T>,
	watch: <T>(self: Runtime, source: Source<T>, callback: (T, T?, ChangeSet?) -> (), options: any?) -> (() -> ()),
	scope: (self: Runtime, callback: ((Scope) -> ())?) -> Scope,
	transaction: (self: Runtime, callback: () -> (), metadata: any?) -> ChangeSet?,
	batch: (self: Runtime, callback: () -> (), metadata: any?) -> ChangeSet?,
	store: <S, A>(self: Runtime, options: any) -> Store<S, A>,
	step: (self: Runtime, tick: number, callback: (any) -> (), metadata: any?) -> ChangeSet,
	snapshot: (self: Runtime, tick: number?) -> any,
	restore: (self: Runtime, snapshot: any) -> ChangeSet?,
	rollback: (self: Runtime, tick: number) -> ChangeSet?,
	replay: (self: Runtime, fromTick: number, toTick: number, inputProvider: (any, number) -> ()) -> (),
	confirm: (self: Runtime, tick: number) -> { any },
	discardAfter: (self: Runtime, tick: number) -> { any },
	getTick: (self: Runtime) -> number?,
	getConfirmedTick: (self: Runtime) -> number?,
	getStateHash: (self: Runtime) -> string,
	getPendingCommands: (self: Runtime) -> { any },
	getDebugSnapshot: (self: Runtime) -> any,
	trace: (self: Runtime, eventName: string, fields: any?) -> (),
	dispose: (self: Runtime) -> (),
}

return {}
