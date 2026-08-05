--!strict

-- The package root is the Conal-style Push-Pull FRP API. The previous
-- Atom/Computed runtime remains available as an explicitly named compatibility
-- extension while projects migrate; it is not the FRP denotation.

-- A static string require gives the standalone analyzer access to the canonical
-- type witnesses. The function is intentionally never called at runtime, so
-- Studio continues to use Instance-based requires exclusively.
local function staticTypes()
	return require("./src/Types")
end

type FRPModule = typeof(staticTypes().frp())
type DynamicCompatibility = any
type DynamicModule = DynamicCompatibility

export type Capture<T> = typeof(staticTypes().capture(nil :: T?))
export type Emit<T> = typeof(staticTypes().emit(nil :: T?))
export type CloneCodec<T> = typeof(staticTypes().cloneCodec(nil :: T?))
export type ImmutableNamespace = typeof(staticTypes().immutable())
export type LabelOptions = typeof(staticTypes().labelOptions())
export type SourceOptions<T> = typeof(staticTypes().sourceOptions(nil :: T?))
export type ScanOptions<T> = typeof(staticTypes().scanOptions(nil :: T?))
export type SubscribeOptions = typeof(staticTypes().subscribeOptions())
export type HostOptions = typeof(staticTypes().hostOptions())
export type Occurrence<T> = typeof(staticTypes().occurrence(nil :: T?))
export type OccurrenceInput<T> = typeof(staticTypes().occurrenceInput(nil :: T?))
export type Snapshot<T, B> = typeof(staticTypes().snapshot(nil :: T?, nil :: B?))
export type EventDebugInfo = typeof(staticTypes().eventDebugInfo())
export type ReactiveDebugInfo = typeof(staticTypes().reactiveDebugInfo())
export type FrameContext = typeof(staticTypes().frameContext())
export type FrameResult = typeof(staticTypes().frameResult())
export type HostError = typeof(staticTypes().hostError())
export type BehaviorSinkMetadata<T> = typeof(staticTypes().behaviorSinkMetadata(nil :: T?))

export type Host = typeof(staticTypes().host())
export type Event<T> = typeof(staticTypes().event(nil :: T?))
export type Reactive<T> = typeof(staticTypes().reactive(nil :: T?))
export type Behavior<T> = typeof(staticTypes().behavior(nil :: T?))
export type Future<T> = typeof(staticTypes().future(nil :: T?))
export type TimeFunction<T> = typeof(staticTypes().timeFunction(nil :: T?))
export type Runtime = typeof(staticTypes().runtime())

local FRP: FRPModule
local Runtime: DynamicModule
local Clock: DynamicModule
local Codec: DynamicModule
local Hash: DynamicModule
local Immutable: DynamicModule
local dynamicRequire: DynamicModule = require

if script ~= nil then
	FRP = dynamicRequire(script.Core.FRP)
	Runtime = dynamicRequire(script.Core.Runtime)
	Clock = dynamicRequire(script.Core.Clock)
	Codec = dynamicRequire(script.Core.Codec)
	Hash = dynamicRequire(script.Core.Hash)
	Immutable = dynamicRequire(script.Core.Immutable)
else
	-- Standalone Luau hosts resolve a directory init module relative to either
	-- this file or the entry script. Try only local package layouts; Studio uses
	-- the ModuleScript branch above.
	local function requireCore(name: string): DynamicModule
		local attempts = {
			"./Core/" .. name,
			"../src/Core/" .. name,
			"./src/Core/" .. name,
		}
		local messages: { string } = {}
		for _, path in ipairs(attempts) do
			local ok, module = pcall(dynamicRequire, path)
			if ok then
				return module
			end
			messages[#messages + 1] = tostring(module)
		end
		error("ReactiveState could not load Core/" .. name .. ": " .. table.concat(messages, " | "), 0)
	end
	FRP = requireCore("FRP")
	Runtime = requireCore("Runtime")
	Clock = requireCore("Clock")
	Codec = requireCore("Codec")
	Hash = requireCore("Hash")
	Immutable = requireCore("Immutable")
end

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
	set: (self: Atom<T>, value: T) -> (),
	update: (self: Atom<T>, updater: (T) -> T) -> (),
	mutate: (self: Atom<T>, mutator: (T) -> ()) -> (),
	touch: (self: Atom<T>) -> (),
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

FRP.VERSION = "0.2.0-dev.2"
FRP.API_VERSION = 2
FRP.SEMANTICS_VERSION = 1
FRP.clock = Clock
FRP.codec = Codec
FRP.hash = Hash
FRP.Immutable = Immutable
FRP.StateRuntime = Runtime

-- Deprecated compatibility alias for the pre-FRP State runtime. New FRP code
-- starts with newHost(); existing 0.1 projects can migrate incrementally.
function FRP.create(options)
	return Runtime.new(options)
end

function FRP.createStateRuntime(options)
	return Runtime.new(options)
end

function FRP.isRuntime(value): boolean
	return type(value) == "table" and Runtime.isRuntime(value)
end

return FRP
