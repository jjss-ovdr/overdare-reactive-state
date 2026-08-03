--!strict

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
