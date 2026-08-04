--!nonstrict

-- The package root is the Conal-style Push-Pull FRP API. The previous
-- Atom/Computed runtime remains available as an explicitly named compatibility
-- extension while projects migrate; it is not the FRP denotation.

local FRP: any
local Runtime
local Clock
local Codec
local Hash

if script ~= nil then
	FRP = require(script.Core.FRP)
	Runtime = require(script.Core.Runtime)
	Clock = require(script.Core.Clock)
	Codec = require(script.Core.Codec)
	Hash = require(script.Core.Hash)
else
	-- Standalone Luau hosts resolve a directory init module relative to either
	-- this file or the entry script. Try only local package layouts; Studio uses
	-- the ModuleScript branch above.
	local function requireCore(name)
		local attempts = {
			"./Core/" .. name,
			"../src/Core/" .. name,
			"./src/Core/" .. name,
		}
		local messages = {}
		for _, path in ipairs(attempts) do
			local ok, module = pcall(require, path)
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
end

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
	add: (self: Scope, disposable: any) -> any,
	dispose: (self: Scope) -> (),
	Destroy: (self: Scope) -> (),
	isDisposed: (self: Scope) -> boolean,
}

export type Runtime = any

export type Host = any
export type Event<T> = any
export type Reactive<T> = any
export type Behavior<T> = any
export type Future<T> = any
export type TimeFunction<T> = any

FRP.VERSION = "0.2.0-dev.1"
FRP.API_VERSION = 2
FRP.SEMANTICS_VERSION = 1
FRP.clock = Clock
FRP.codec = Codec
FRP.hash = Hash
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
