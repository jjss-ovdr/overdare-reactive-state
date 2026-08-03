--!nonstrict

-- OVERDARE integration is deliberately opt-in. Requiring this module does not
-- read game, connect RunService, inspect an Instance, or create a RemoteEvent.
-- Every engine boundary is resolved only by the function that needs it, and
-- every boundary can be replaced with a small fake in ordinary Luau tests.

local Overdare = {}

export type Phase = "Stepped" | "Heartbeat" | "RenderStepped"
export type OverflowPolicy = "drop" | "clamp" | "error"

export type CallbackEntry = {
	callback: (any?, number, number?) -> (),
	priority: number?,
}

export type OverflowEvent = {
	policy: OverflowPolicy,
	phase: Phase,
	fixedDelta: number,
	frameDelta: number,
	maxSubsteps: number,
	requestedSubsteps: number,
	executedSubsteps: number,
	overflowSubsteps: number,
	droppedDelta: number,
	retainedDelta: number,
	accumulatorBefore: number,
	accumulatorAfterInput: number,
	tick: number,
}

export type Status = {
	ok: boolean,
	code: string?,
	message: string?,
	value: any?,
}

local VALID_PHASES: { [string]: boolean } = {
	Stepped = true,
	Heartbeat = true,
	RenderStepped = true,
}

local DEFAULT_MAX_SUBSTEPS = 8
local DEFAULT_MAX_PAYLOAD_DEPTH = 16
local DEFAULT_MAX_PAYLOAD_ENTRIES = 2048

local function isFinite(value: number): boolean
	return value == value and value ~= math.huge and value ~= -math.huge
end

local function readMember(target: any, key: string): any
	if target == nil then
		return nil
	end

	local ok, value = pcall(function(): any
		return target[key]
	end)
	if ok then
		return value
	end
	return nil
end

local function disposeOne(disposable: any)
	if disposable == nil then
		return
	end

	if type(disposable) == "function" then
		disposable()
		return
	end

	local dispose = readMember(disposable, "dispose")
		or readMember(disposable, "Disconnect")
		or readMember(disposable, "disconnect")
		or readMember(disposable, "Destroy")
	if type(dispose) ~= "function" then
		error("disposable must be a function or implement dispose/Disconnect/Destroy", 3)
	end
	dispose(disposable)
end

local Disposer = {}
Disposer.__index = Disposer

function Disposer:add(disposable: any): any
	if disposable == nil then
		return disposable
	end

	if self._disposed then
		disposeOne(disposable)
	else
		table.insert(self._disposables, disposable)
	end
	return disposable
end

function Disposer:dispose()
	if self._disposed then
		return
	end

	self._disposed = true
	local disposables = self._disposables
	self._disposables = {}
	local firstFailure = nil

	for index = #disposables, 1, -1 do
		local ok, message = pcall(disposeOne, disposables[index])
		if not ok and firstFailure == nil then
			firstFailure = message
		end
	end

	if firstFailure ~= nil then
		error(firstFailure, 0)
	end
end

function Disposer:isDisposed(): boolean
	return self._disposed
end

Disposer.Disconnect = Disposer.dispose
Disposer.disconnect = Disposer.dispose
Disposer.Destroy = Disposer.dispose

local function newDisposer(externalScope: any?): any
	local disposer = setmetatable({
		_disposed = false,
		_disposables = {},
	}, Disposer)

	if externalScope ~= nil then
		local add = readMember(externalScope, "add")
		assert(type(add) == "function", "scope must implement :add(disposable)")
		add(externalScope, function()
			disposer:dispose()
		end)
	end

	return disposer
end

local function connectSignal(signal: any, callback: (...any) -> ()): any
	if signal == nil then
		error("signal is missing", 3)
	end

	local connect = readMember(signal, "Connect") or readMember(signal, "connect")
	if type(connect) == "function" then
		local connection = connect(signal, callback)
		if connection == nil then
			error("signal Connect must return an explicit connection/disposer", 3)
		end
		return connection
	end

	if type(signal) == "function" then
		local connection = signal(callback)
		if connection == nil then
			error("signal subscription must return an explicit connection/disposer", 3)
		end
		return connection
	end

	error("signal must implement :Connect(callback)", 3)
end

local function assertRuntime(runtime: any, operation: string)
	assert(type(runtime) == "table", operation .. " requires a Runtime")
	assert(type(runtime.transaction) == "function", operation .. " requires Runtime:transaction()")
end

local function assertPhase(value: any): Phase
	local phase = if value == nil then "Heartbeat" else value
	if type(phase) ~= "string" or not VALID_PHASES[phase] then
		error("phase must be 'Stepped', 'Heartbeat', or 'RenderStepped'", 3)
	end
	return phase :: Phase
end

local function resolveRunService(options: any): any
	if options.runService ~= nil then
		return options.runService
	end

	if type(options.getRunService) == "function" then
		local resolved = options.getRunService()
		assert(resolved ~= nil, "getRunService returned nil")
		return resolved
	end

	-- Deliberately inside attach/sample rather than at module load. Tests and
	-- non-engine runtimes should inject runService and never execute this branch.
	local serviceProvider = options.game
	if serviceProvider == nil then
		serviceProvider = game
	end

	assert(serviceProvider ~= nil, "attach requires runService or a game service provider")
	local getService = readMember(serviceProvider, "GetService") or readMember(serviceProvider, "getService")
	assert(type(getService) == "function", "game service provider must implement :GetService(name)")
	local runService = getService(serviceProvider, "RunService")
	assert(runService ~= nil, "game:GetService('RunService') returned nil")
	return runService
end

local function resolvePhaseSignal(runService: any, phase: Phase, options: any): any
	if options.signal ~= nil then
		return options.signal
	end

	local signal = readMember(runService, phase)
	if signal == nil and type(options.getSignal) == "function" then
		signal = options.getSignal(runService, phase)
	end
	assert(signal ~= nil, string.format("RunService.%s signal is unavailable", phase))
	return signal
end

type NormalizedCallback = {
	callback: (any?, number, number?) -> (),
	priority: number,
	order: number,
}

local function normalizeCallbacks(options: any): { NormalizedCallback }
	if options.callback ~= nil and options.callbacks ~= nil then
		error("attach accepts either callback or callbacks, not both", 3)
	end

	local callbacks: { NormalizedCallback } = {}
	if options.callback ~= nil then
		assert(type(options.callback) == "function", "callback must be a function")
		local priority = options.priority or 0
		assert(type(priority) == "number" and isFinite(priority), "callback priority must be finite")
		table.insert(callbacks, {
			callback = options.callback,
			priority = priority,
			order = 1,
		})
	elseif options.callbacks ~= nil then
		assert(type(options.callbacks) == "table", "callbacks must be an array")
		for index, entry in ipairs(options.callbacks) do
			local callback
			local priority = 0
			if type(entry) == "function" then
				callback = entry
			elseif type(entry) == "table" then
				callback = entry.callback or entry.run or entry[1]
				priority = entry.priority or 0
			else
				error(string.format("callbacks[%d] must be a function or callback entry", index), 3)
			end

			assert(type(callback) == "function", string.format("callbacks[%d].callback must be a function", index))
			assert(
				type(priority) == "number" and isFinite(priority),
				string.format("callbacks[%d].priority must be finite", index)
			)
			table.insert(callbacks, {
				callback = callback,
				priority = priority,
				order = index,
			})
		end
	else
		error("attach requires callback or callbacks", 3)
	end

	assert(#callbacks > 0, "callbacks must contain at least one callback")
	table.sort(callbacks, function(left, right)
		if left.priority == right.priority then
			return left.order < right.order
		end
		return left.priority < right.priority
	end)
	return callbacks
end

local function copyMetadata(metadata: any?): any
	local result = {}
	if metadata ~= nil then
		assert(type(metadata) == "table", "metadata must be a table")
		for key, value in pairs(metadata) do
			result[key] = value
		end
	end
	return result
end

local function frameMetadata(options: any, phase: Phase): any
	local metadata = copyMetadata(options.metadata)
	metadata.cause = options.cause or "overdare"
	metadata.phase = phase
	return metadata
end

local function extractDelta(phase: Phase, options: any, ...: any): number
	local delta
	if type(options.getDelta) == "function" then
		delta = options.getDelta(...)
	elseif options.delta ~= nil then
		delta = options.delta
	elseif options.deltaIndex ~= nil then
		assert(
			type(options.deltaIndex) == "number" and options.deltaIndex >= 1 and options.deltaIndex % 1 == 0,
			"deltaIndex must be a positive integer"
		)
		delta = select(options.deltaIndex, ...)
	elseif phase == "Stepped" and type(select(2, ...)) == "number" then
		-- Compatible with both (elapsed, delta) and a one-argument fake signal.
		delta = select(2, ...)
	else
		delta = select(1, ...)
	end

	if type(delta) ~= "number" or not isFinite(delta) or delta < 0 then
		error(string.format("RunService.%s delta must be a finite, non-negative number", phase), 3)
	end
	return delta
end

local function notifyOverflow(runtime: any, options: any, event: OverflowEvent)
	if type(options.onOverflow) == "function" then
		options.onOverflow(event)
	end

	if type(options.trace) == "function" then
		options.trace("overdare.overflow", event)
		return
	end

	-- Trace is intentionally duck-typed so the adapter does not require Debug.
	local trace = readMember(runtime, "trace") or readMember(runtime, "emitTrace")
	if type(trace) == "function" then
		trace(runtime, "overdare.overflow", event)
	end
end

local function normalizeInitialTick(runtime: any, value: any): number
	local initialTick = value
	if initialTick == nil then
		local currentTick = nil
		if type(runtime.getTick) == "function" then
			currentTick = runtime:getTick()
		end
		initialTick = (currentTick or 0) + 1
	end

	if type(initialTick) ~= "number" or not isFinite(initialTick) or initialTick < 0 or initialTick % 1 ~= 0 then
		error("initialTick must be a finite, non-negative integer", 3)
	end
	return initialTick
end

-- Connect a Runtime-owned callback batch to one RunService phase. Without a
-- fixedDelta, each signal fires one transaction. With fixedDelta, each due
-- substep fires one Runtime:step and all callbacks share its StepContext.
function Overdare.attach(runtime: any, options: any?): any
	assertRuntime(runtime, "Overdare.attach")
	options = options or {}
	assert(type(options) == "table", "Overdare.attach options must be a table")

	local phase = assertPhase(options.phase)
	local callbacks = normalizeCallbacks(options)
	local fixedDelta = options.fixedDelta
	local maxSubsteps = options.maxSubsteps or DEFAULT_MAX_SUBSTEPS
	local overflow = options.overflow or "drop"

	if fixedDelta ~= nil then
		if type(fixedDelta) ~= "number" or not isFinite(fixedDelta) or fixedDelta <= 0 then
			error("fixedDelta must be a finite number greater than zero", 2)
		end
		assert(type(runtime.step) == "function", "fixedDelta attach requires Runtime:step()")
	end
	if type(maxSubsteps) ~= "number" or not isFinite(maxSubsteps) or maxSubsteps < 1 or maxSubsteps % 1 ~= 0 then
		error("maxSubsteps must be a positive integer", 2)
	end
	if overflow ~= "drop" and overflow ~= "clamp" and overflow ~= "error" then
		error("overflow must be 'drop', 'clamp', or 'error'", 2)
	end
	if options.onOverflow ~= nil then
		assert(type(options.onOverflow) == "function", "onOverflow must be a function")
	end
	if options.onError ~= nil then
		assert(type(options.onError) == "function", "onError must be a function")
	end
	local errorPolicy = options.errorPolicy or "raise"
	if errorPolicy ~= "raise" and errorPolicy ~= "continue" and errorPolicy ~= "disconnect" then
		error("errorPolicy must be 'raise', 'continue', or 'disconnect'", 2)
	end
	if errorPolicy == "continue" and options.onError == nil then
		error("errorPolicy 'continue' requires onError", 2)
	end

	-- A directly injected signal is sufficient for tiny unit-test fakes. In
	-- normal engine use the signal is resolved from the injected/lazy service.
	local runService = if options.signal ~= nil then nil else resolveRunService(options)
	local signal = resolvePhaseSignal(runService, phase, options)
	local disposer = newDisposer(options.scope)
	local accumulator = 0
	local nextTick = normalizeInitialTick(runtime, options.initialTick)
	local lastOverflow: OverflowEvent? = nil
	local metadata = frameMetadata(options, phase)

	local function invokeBatch(context: any?, delta: number, tick: number?)
		for _, entry in ipairs(callbacks) do
			entry.callback(context, delta, tick)
		end
	end

	local function runVariableFrame(frameDelta: number)
		runtime:transaction(function()
			invokeBatch(nil, frameDelta, nil)
		end, metadata)
	end

	local function runFixedFrame(frameDelta: number)
		local delta = fixedDelta :: number
		local accumulatorBefore = accumulator
		local accumulated = accumulatorBefore + frameDelta
		if not isFinite(accumulated) then
			error("fixed-step accumulator overflowed the finite number range", 2)
		end

		local ratio = accumulated / delta
		if not isFinite(ratio) then
			error("fixed-step accumulator represents too many substeps", 2)
		end
		local requestedSteps = math.floor(ratio)
		if requestedSteps + 1 - ratio <= 1e-12 then
			requestedSteps += 1
		end
		local fractionalRemainder = accumulated - requestedSteps * delta
		if fractionalRemainder < 0 and fractionalRemainder > -delta * 1e-10 then
			fractionalRemainder = 0
		end

		local stepsToRun = requestedSteps
		local adjustedAccumulator = accumulated
		local droppedDelta = 0
		if requestedSteps > maxSubsteps then
			stepsToRun = maxSubsteps
			local remainingAfterSteps = (requestedSteps - stepsToRun) * delta + fractionalRemainder
			if overflow == "drop" then
				droppedDelta = (requestedSteps - stepsToRun) * delta
				adjustedAccumulator = stepsToRun * delta + fractionalRemainder
			elseif overflow == "clamp" then
				local retainedRemainder = math.min(remainingAfterSteps, delta)
				droppedDelta = remainingAfterSteps - retainedRemainder
				adjustedAccumulator = stepsToRun * delta + retainedRemainder
			end

			local retainedDelta = adjustedAccumulator - stepsToRun * delta
			local event: OverflowEvent = {
				policy = overflow :: OverflowPolicy,
				phase = phase,
				fixedDelta = delta,
				frameDelta = frameDelta,
				maxSubsteps = maxSubsteps,
				requestedSubsteps = requestedSteps,
				executedSubsteps = if overflow == "error" then 0 else stepsToRun,
				overflowSubsteps = if overflow == "error" then requestedSteps else requestedSteps - stepsToRun,
				droppedDelta = droppedDelta,
				retainedDelta = retainedDelta,
				accumulatorBefore = accumulatorBefore,
				accumulatorAfterInput = accumulated,
				tick = nextTick - 1,
			}
			lastOverflow = event
			notifyOverflow(runtime, options, event)
			if overflow == "error" then
				error(string.format(
					"Overdare.attach fixed-step overflow at tick %d: %d substeps requested, maximum is %d",
					nextTick - 1,
					requestedSteps,
					maxSubsteps
				), 2)
			end
		end

		accumulator = adjustedAccumulator
		for _ = 1, stepsToRun do
			local tick = nextTick
			local previousAccumulator = accumulator
			accumulator = previousAccumulator - delta
			local ok, message = pcall(function()
				runtime:step(tick, function(stepContext: any)
					invokeBatch(stepContext, delta, tick)
				end, metadata)
			end)
			if not ok then
				accumulator = previousAccumulator
				error(message, 0)
			end
			nextTick += 1
		end

		if accumulator < 0 and accumulator > -delta * 1e-10 then
			accumulator = 0
		end
	end

	local function runFrame(...: any)
		if disposer:isDisposed() then
			return
		end
		local frameDelta = extractDelta(phase, options, ...)
		if fixedDelta == nil then
			runVariableFrame(frameDelta)
		else
			runFixedFrame(frameDelta)
		end
	end

	local function onSignal(...: any)
		if errorPolicy == "raise" and options.onError == nil then
			runFrame(...)
			return
		end

		local arguments = { ... }
		local argumentCount = select("#", ...)
		local ok, message = pcall(function()
			runFrame(table.unpack(arguments, 1, argumentCount))
		end)
		if ok then
			return
		end

		if options.onError ~= nil then
			options.onError(message, {
				phase = phase,
				fixedDelta = fixedDelta,
				tick = nextTick,
			})
		end
		if errorPolicy == "disconnect" then
			disposer:dispose()
		elseif errorPolicy == "raise" then
			error(message, 0)
		end
	end

	local connection = connectSignal(signal, onSignal)
	disposer:add(connection)

	function disposer:getPhase(): Phase
		return phase
	end

	function disposer:getAccumulator(): number
		return accumulator
	end

	function disposer:getInterpolationAlpha(): number
		if fixedDelta == nil then
			return 0
		end
		return accumulator / (fixedDelta :: number)
	end

	function disposer:getNextTick(): number
		return nextTick
	end

	function disposer:getLastOverflow(): OverflowEvent?
		return lastOverflow
	end

	return disposer
end

local function resolveRuntime(options: any, source: any, operation: string): any
	local runtime = options.runtime
	if runtime == nil then
		local getRuntime = readMember(source, "getRuntime")
		if type(getRuntime) == "function" then
			runtime = getRuntime(source)
		else
			runtime = readMember(source, "_runtime") or readMember(source, "runtime")
		end
	end

	assert(runtime ~= nil, operation .. " requires options.runtime (or a Runtime-owned source)")
	assertRuntime(runtime, operation)
	return runtime
end

local function connectDestroying(instance: any, disposer: any, options: any)
	if options.disconnectOnDestroy == false then
		return
	end

	local destroying = options.destroySignal
	if destroying == nil then
		destroying = readMember(instance, "Destroying")
	end
	if destroying ~= nil then
		disposer:add(connectSignal(destroying, function()
			disposer:dispose()
		end))
	end
end

local function validateMappedValue(options: any, value: any, operation: string)
	if options.validate == nil then
		return
	end
	assert(type(options.validate) == "function", operation .. " validate must be a function")
	local accepted, message = options.validate(value)
	if not accepted then
		error(message or (operation .. " rejected a value"), 3)
	end
end

-- One-way Source -> Instance projection. Runtime:watch provides the required
-- post-commit boundary; this adapter never listens to the property in reverse.
function Overdare.bind(instance: any, property: string, source: any, options: any?): () -> ()
	options = options or {}
	assert(type(options) == "table", "Overdare.bind options must be a table")
	assert(instance ~= nil, "Overdare.bind requires an instance")
	assert(type(property) == "string" and property ~= "", "property must be a non-empty string")
	assert(type(source) == "table" and type(source.get) == "function", "source must implement :get()")
	if options.sourceOfTruth ~= "source" then
		error("Overdare.bind requires sourceOfTruth = 'source' for its one-way binding", 2)
	end
	if options.twoWay == true then
		error("Overdare.bind is one-way; use an explicit bridge for two-way synchronization", 2)
	end

	local runtime = resolveRuntime(options, source, "Overdare.bind")
	assert(type(runtime.watch) == "function", "Overdare.bind requires Runtime:watch()")
	if options.map ~= nil then
		assert(type(options.map) == "function", "Overdare.bind map must be a function")
	end
	if options.write ~= nil then
		assert(type(options.write) == "function", "Overdare.bind write must be a function")
	end

	local disposer = newDisposer(options.scope)
	local watchOptions = {
		priority = options.priority,
		equality = options.equality,
		initial = options.initial ~= false,
		replay = options.replay or "coalesce",
		label = options.label or ("Overdare.bind(" .. property .. ")"),
	}
	local stopWatch = runtime:watch(source, function(value: any, previous: any, changeSet: any)
		local mapped = value
		if options.map ~= nil then
			mapped = options.map(value, previous, changeSet)
		end
		validateMappedValue(options, mapped, "Overdare.bind")
		if options.write ~= nil then
			options.write(instance, property, mapped, changeSet)
		else
			instance[property] = mapped
		end
	end, watchOptions)
	disposer:add(stopWatch)
	local destroyOk, destroyMessage = pcall(connectDestroying, instance, disposer, options)
	if not destroyOk then
		disposer:dispose()
		error(destroyMessage, 0)
	end

	local function stop()
		disposer:dispose()
	end
	return stop
end

local SAMPLE_ATTACH_KEYS = {
	"runService",
	"game",
	"getRunService",
	"signal",
	"getSignal",
	"phase",
	"priority",
	"fixedDelta",
	"maxSubsteps",
	"overflow",
	"initialTick",
	"onOverflow",
	"trace",
	"onError",
	"errorPolicy",
	"getDelta",
	"delta",
	"deltaIndex",
	"scope",
}

-- Instance -> Atom polling for physics/transform properties. Sampling is phase
-- based by construction; no property Changed event is consulted.
function Overdare.sample(instance: any, property: string, atom: any, options: any?): any
	options = options or {}
	assert(type(options) == "table", "Overdare.sample options must be a table")
	assert(instance ~= nil, "Overdare.sample requires an instance")
	assert(type(property) == "string" and property ~= "", "property must be a non-empty string")
	assert(type(atom) == "table" and type(atom.set) == "function", "atom must implement :set(value)")
	if options.sourceOfTruth ~= nil and options.sourceOfTruth ~= "instance" then
		error("Overdare.sample requires sourceOfTruth = 'instance'", 2)
	end
	if options.callback ~= nil or options.callbacks ~= nil then
		error("Overdare.sample owns its phase callback; callback(s) options are not allowed", 2)
	end
	if options.read ~= nil then
		assert(type(options.read) == "function", "Overdare.sample read must be a function")
	end
	if options.map ~= nil then
		assert(type(options.map) == "function", "Overdare.sample map must be a function")
	end

	local runtime = resolveRuntime(options, atom, "Overdare.sample")
	local phase = assertPhase(options.phase)
	local function readSample(delta: number?, tick: number?): any
		local value
		if options.read ~= nil then
			value = options.read(instance, property, delta, tick)
		else
			value = instance[property]
		end
		if options.map ~= nil then
			value = options.map(value, delta, tick)
		end
		validateMappedValue(options, value, "Overdare.sample")
		return value
	end

	local attachOptions = {}
	for _, key in ipairs(SAMPLE_ATTACH_KEYS) do
		attachOptions[key] = options[key]
	end
	attachOptions.phase = phase
	attachOptions.callback = function(_context: any?, delta: number, tick: number?)
		atom:set(readSample(delta, tick))
	end
	attachOptions.cause = options.cause or "overdare.sample"
	attachOptions.metadata = options.metadata

	local disposer = Overdare.attach(runtime, attachOptions)
	local destroyOk, destroyMessage = pcall(connectDestroying, instance, disposer, options)
	if not destroyOk then
		disposer:dispose()
		error(destroyMessage, 0)
	end

	if options.initial ~= false then
		local ok, message = pcall(function()
			local initialMetadata = copyMetadata(options.metadata)
			initialMetadata.cause = options.cause or "overdare.sample"
			initialMetadata.phase = phase
			runtime:transaction(function()
				atom:set(readSample(nil, nil))
			end, initialMetadata)
		end)
		if not ok then
			disposer:dispose()
			error(message, 0)
		end
	end

	return disposer
end

local function success(value: any?): Status
	return {
		ok = true,
		value = value,
	}
end

local function failure(code: string, message: any): Status
	return {
		ok = false,
		code = code,
		message = tostring(message),
	}
end

local function validateTransportValue(
	value: any,
	maxDepth: number,
	maxEntries: number,
	seen: { [any]: boolean },
	depth: number,
	entryCounter: { number }
): (boolean, string?)
	local valueType = type(value)
	if value == nil or valueType == "boolean" or valueType == "string" then
		return true, nil
	elseif valueType == "number" then
		if not isFinite(value) then
			return false, "payload contains a non-finite number"
		end
		return true, nil
	elseif valueType ~= "table" then
		return false, string.format("payload contains unsupported type %s", valueType)
	end

	if depth >= maxDepth then
		return false, string.format("payload exceeds maximum depth %d", maxDepth)
	end
	if getmetatable(value) ~= nil then
		return false, "payload tables must not have metatables"
	end
	if seen[value] then
		return false, "payload contains a table cycle or repeated table reference"
	end

	seen[value] = true
	for key, child in pairs(value) do
		entryCounter[1] += 1
		if entryCounter[1] > maxEntries then
			seen[value] = nil
			return false, string.format("payload exceeds maximum entry count %d", maxEntries)
		end

		local keyType = type(key)
		if keyType ~= "string" and keyType ~= "number" then
			seen[value] = nil
			return false, "payload table keys must be strings or numbers"
		end
		if keyType == "number" and not isFinite(key) then
			seen[value] = nil
			return false, "payload contains a non-finite numeric key"
		end

		local keyOk, keyMessage = validateTransportValue(key, maxDepth, maxEntries, seen, depth + 1, entryCounter)
		if not keyOk then
			seen[value] = nil
			return false, keyMessage
		end
		local childOk, childMessage = validateTransportValue(child, maxDepth, maxEntries, seen, depth + 1, entryCounter)
		if not childOk then
			seen[value] = nil
			return false, childMessage
		end
	end
	seen[value] = nil
	return true, nil
end

local function structuralValidation(options: any, payload: any): Status
	local maxDepth = options.maxPayloadDepth or DEFAULT_MAX_PAYLOAD_DEPTH
	local maxEntries = options.maxPayloadEntries or DEFAULT_MAX_PAYLOAD_ENTRIES
	if type(maxDepth) ~= "number" or maxDepth < 1 or maxDepth % 1 ~= 0 then
		return failure("invalid_configuration", "maxPayloadDepth must be a positive integer")
	end
	if type(maxEntries) ~= "number" or maxEntries < 1 or maxEntries % 1 ~= 0 then
		return failure("invalid_configuration", "maxPayloadEntries must be a positive integer")
	end

	local accepted, message = validateTransportValue(payload, maxDepth, maxEntries, {}, 0, { 0 })
	if not accepted then
		return failure("invalid_payload", message)
	end
	return success(payload)
end

local function normalizeValidationResult(payload: any, accepted: any, detail: any): Status
	if type(accepted) == "table" and type(accepted.ok) == "boolean" then
		if accepted.ok then
			if accepted.value == nil then
				accepted.value = payload
			end
			return accepted
		end
		if accepted.code == nil then
			accepted.code = "rejected"
		end
		if accepted.message == nil then
			accepted.message = tostring(detail or "payload rejected")
		end
		return accepted
	elseif accepted == true then
		if detail ~= nil and type(detail) ~= "string" then
			return success(detail)
		end
		return success(payload)
	elseif accepted == false or accepted == nil then
		return failure("rejected", detail or "payload rejected")
	end

	-- A validator may directly return a decoded/normalized payload.
	return success(accepted)
end

local function validatePayload(options: any, validator: any, payload: any, peer: any, kind: string): Status
	local structural = structuralValidation(options, payload)
	if not structural.ok then
		return structural
	end
	if validator == nil then
		return structural
	end
	if type(validator) ~= "function" then
		return failure("invalid_configuration", kind .. " validator must be a function")
	end

	local ok, accepted, detail = pcall(validator, payload, peer, kind)
	if not ok then
		return failure("validator_error", accepted)
	end
	return normalizeValidationResult(payload, accepted, detail)
end

local function normalizeHandlerResult(ok: boolean, result: any, detail: any): Status
	if not ok then
		return failure("handler_error", result)
	end
	if type(result) == "table" and type(result.ok) == "boolean" then
		return result
	end
	if result == false then
		return failure("rejected", detail or "handler rejected payload")
	end
	return success(result)
end

local function optionOrMethod(options: any, optionNames: { string }, target: any, methodNames: { string }): any
	for _, name in ipairs(optionNames) do
		if options[name] ~= nil then
			return options[name]
		end
	end
	for _, name in ipairs(methodNames) do
		local method = readMember(target, name)
		if type(method) == "function" then
			return function(...: any)
				return method(target, ...)
			end
		end
	end
	return nil
end

local function notifyStatus(adapter: any, status: Status, context: any)
	adapter._lastStatus = status
	if type(adapter._options.onStatus) == "function" then
		adapter._options.onStatus(status, context)
	end
	if not status.ok then
		if status.code == "handler_error" or status.code == "validator_error" or status.code == "transport_error" then
			if type(adapter._options.onError) == "function" then
				adapter._options.onError(status, context)
			end
		elseif type(adapter._options.onReject) == "function" then
			adapter._options.onReject(status, context)
		end
	end
end

local function resolveSubscription(options: any, transport: any, side: string, callback: (...any) -> ()): any
	if options.connect == false then
		return nil
	end
	if type(options.subscribe) == "function" then
		return options.subscribe(callback)
	end

	local explicitSignal = options.signal
	if explicitSignal ~= nil then
		return connectSignal(explicitSignal, callback)
	end

	local signalName = if side == "server" then "OnServerEvent" else "OnClientEvent"
	local signal = readMember(transport, signalName)
	if signal ~= nil then
		return connectSignal(signal, callback)
	end

	local subscribe = optionOrMethod(
		options,
		if side == "server" then { "subscribeServer" } else { "subscribeClient" },
		transport,
		if side == "server" then { "subscribeServer", "connectServer" } else { "subscribeClient", "connectClient" }
	)
	if subscribe ~= nil then
		local connection = subscribe(callback)
		if connection == nil then
			error("transport subscription must return an explicit connection/disposer", 3)
		end
		return connection
	end

	error(string.format(
		"%s adapter requires a signal/subscription (or connect = false for manual delivery)",
		side
	), 3)
end

local ServerAdapter = {}
ServerAdapter.__index = ServerAdapter

function ServerAdapter:isConnected(): boolean
	return not self._scope:isDisposed()
end

function ServerAdapter:getLastStatus(): Status?
	return self._lastStatus
end

function ServerAdapter:receiveIntent(clientId: any, payload: any): Status
	if not self:isConnected() then
		return failure("disconnected", "server adapter is disconnected")
	end

	local validated = validatePayload(self._options, self._validateIntent, payload, clientId, "intent")
	if not validated.ok then
		notifyStatus(self, validated, { direction = "inbound", clientId = clientId, kind = "intent" })
		return validated
	end

	local ok, result, detail = pcall(self._receiveIntent, clientId, validated.value)
	local status = normalizeHandlerResult(ok, result, detail)
	notifyStatus(self, status, { direction = "inbound", clientId = clientId, kind = "intent" })
	return status
end

ServerAdapter.acceptIntent = ServerAdapter.receiveIntent

function ServerAdapter:send(clientId: any, payload: any, kind: string?): Status
	if not self:isConnected() then
		return failure("disconnected", "server adapter is disconnected")
	end
	if self._send == nil then
		return failure("missing_transport", "server transport does not implement send/FireClient")
	end

	local messageKind = kind or "message"
	local validated = validatePayload(self._options, self._validateOutgoing, payload, clientId, messageKind)
	if not validated.ok then
		notifyStatus(self, validated, { direction = "outbound", clientId = clientId, kind = messageKind })
		return validated
	end

	local ok, result, detail = pcall(self._send, clientId, validated.value)
	local status = normalizeHandlerResult(ok, result, detail)
	if not ok then
		status.code = "transport_error"
	end
	notifyStatus(self, status, { direction = "outbound", clientId = clientId, kind = messageKind })
	return status
end

function ServerAdapter:broadcast(payload: any, kind: string?): Status
	if not self:isConnected() then
		return failure("disconnected", "server adapter is disconnected")
	end
	if self._broadcast == nil then
		return failure("missing_transport", "server transport does not implement broadcast/FireAllClients")
	end

	local messageKind = kind or "message"
	local validated = validatePayload(self._options, self._validateOutgoing, payload, nil, messageKind)
	if not validated.ok then
		notifyStatus(self, validated, { direction = "outbound", kind = messageKind, broadcast = true })
		return validated
	end
	local ok, result, detail = pcall(self._broadcast, validated.value)
	local status = normalizeHandlerResult(ok, result, detail)
	if not ok then
		status.code = "transport_error"
	end
	notifyStatus(self, status, { direction = "outbound", kind = messageKind, broadcast = true })
	return status
end

local function extractProducedPayload(status: Status, fallbackKind: string): (Status?, any)
	if not status.ok then
		return status, nil
	end
	local value = status.value
	if type(value) == "table" and type(value.ok) == "boolean" then
		if not value.ok then
			return value, nil
		end
		return nil, value.payload or value.value
	end
	if value == nil then
		return failure("empty_payload", fallbackKind .. " producer returned nil"), nil
	end
	return nil, value
end

function ServerAdapter:snapshot(clientId: any, ...: any): Status
	if self._snapshot == nil then
		return failure("missing_replicator_method", "replicator does not implement snapshot")
	end
	local ok, result, detail = pcall(self._snapshot, clientId, ...)
	return normalizeHandlerResult(ok, result, detail)
end

function ServerAdapter:patch(clientId: any, ...: any): Status
	if self._patch == nil then
		return failure("missing_replicator_method", "replicator does not implement patch")
	end
	local ok, result, detail = pcall(self._patch, clientId, ...)
	return normalizeHandlerResult(ok, result, detail)
end

function ServerAdapter:sendSnapshot(clientId: any, ...: any): Status
	local producerStatus = self:snapshot(clientId, ...)
	local failed, payload = extractProducedPayload(producerStatus, "snapshot")
	if failed ~= nil then
		return failed
	end
	return self:send(clientId, payload, "snapshot")
end

function ServerAdapter:sendPatch(clientId: any, ...: any): Status
	local producerStatus = self:patch(clientId, ...)
	local failed, payload = extractProducedPayload(producerStatus, "patch")
	if failed ~= nil then
		return failed
	end
	return self:send(clientId, payload, "patch")
end

function ServerAdapter:disconnect()
	self._scope:dispose()
end

ServerAdapter.dispose = ServerAdapter.disconnect
ServerAdapter.Disconnect = ServerAdapter.disconnect
ServerAdapter.Destroy = ServerAdapter.disconnect

local ClientAdapter = {}
ClientAdapter.__index = ClientAdapter

function ClientAdapter:isConnected(): boolean
	return not self._scope:isDisposed()
end

function ClientAdapter:getLastStatus(): Status?
	return self._lastStatus
end

function ClientAdapter:receive(payload: any): Status
	if not self:isConnected() then
		return failure("disconnected", "client adapter is disconnected")
	end

	local validated = validatePayload(self._options, self._validateIncoming, payload, nil, "replication")
	if not validated.ok then
		notifyStatus(self, validated, { direction = "inbound", kind = "replication" })
		return validated
	end
	local ok, result, detail = pcall(self._receive, validated.value)
	local status = normalizeHandlerResult(ok, result, detail)
	notifyStatus(self, status, { direction = "inbound", kind = "replication" })
	return status
end

function ClientAdapter:sendIntent(payload: any): Status
	if not self:isConnected() then
		return failure("disconnected", "client adapter is disconnected")
	end
	if self._sendIntent == nil then
		return failure("missing_transport", "client transport does not implement send/FireServer")
	end

	local validated = validatePayload(self._options, self._validateIntent, payload, nil, "intent")
	if not validated.ok then
		notifyStatus(self, validated, { direction = "outbound", kind = "intent" })
		return validated
	end
	local ok, result, detail = pcall(self._sendIntent, validated.value)
	local status = normalizeHandlerResult(ok, result, detail)
	if not ok then
		status.code = "transport_error"
	end
	notifyStatus(self, status, { direction = "outbound", kind = "intent" })
	return status
end

ClientAdapter.send = ClientAdapter.sendIntent

function ClientAdapter:disconnect()
	self._scope:dispose()
end

ClientAdapter.dispose = ClientAdapter.disconnect
ClientAdapter.Disconnect = ClientAdapter.disconnect
ClientAdapter.Destroy = ClientAdapter.disconnect

local function assertAdapterOptions(options: any, name: string): any
	options = options or {}
	assert(type(options) == "table", name .. " options must be a table")
	if options.onStatus ~= nil then
		assert(type(options.onStatus) == "function", name .. " onStatus must be a function")
	end
	if options.onReject ~= nil then
		assert(type(options.onReject) == "function", name .. " onReject must be a function")
	end
	if options.onError ~= nil then
		assert(type(options.onError) == "function", name .. " onError must be a function")
	end
	return options
end

-- Wrap a supplied server replicator and RemoteEvent-like transport. The
-- replicator retains protocol ownership; this object only validates, forwards,
-- sends snapshots/patches, and owns the signal connection.
function Overdare.createServerReplication(options: any): any
	options = assertAdapterOptions(options, "Overdare.createServerReplication")
	local replicator = options.replicator
	assert(replicator ~= nil or type(options.receiveIntent) == "function" or type(options.onIntent) == "function",
		"server adapter requires replicator or receiveIntent callback")

	local receiveIntent = optionOrMethod(
		options,
		{ "receiveIntent", "onIntent", "acceptIntent" },
		replicator,
		{ "receiveIntent", "acceptIntent" }
	)
	assert(type(receiveIntent) == "function", "server replicator must implement receiveIntent/acceptIntent")

	local transport = options.remoteEvent or options.remote or options.transport
	if options.connect ~= false then
		assert(transport ~= nil or options.signal ~= nil or options.subscribe ~= nil,
			"server adapter requires remoteEvent/transport or explicit signal")
	end

	local send = optionOrMethod(options, { "send", "sendClient" }, transport, { "FireClient", "fireClient", "sendClient", "send" })
	local broadcast = optionOrMethod(options, { "broadcast" }, transport, { "FireAllClients", "fireAllClients", "broadcast" })
	local adapter = setmetatable({
		_options = options,
		_scope = newDisposer(options.scope),
		_lastStatus = nil,
		_receiveIntent = receiveIntent,
		_validateIntent = optionOrMethod(options, { "validateIntent", "validate" }, replicator, { "validateIntent" }),
		_validateOutgoing = optionOrMethod(options, { "validateOutgoing", "validateReplication" }, replicator, { "validateOutgoing", "validateReplication" }),
		_send = send,
		_broadcast = broadcast,
		_snapshot = optionOrMethod(options, { "snapshot" }, replicator, { "snapshot" }),
		_patch = optionOrMethod(options, { "patch" }, replicator, { "patch" }),
	}, ServerAdapter)

	local connection = resolveSubscription(options, transport, "server", function(clientId: any, payload: any)
		adapter:receiveIntent(clientId, payload)
	end)
	if connection ~= nil then
		adapter._scope:add(connection)
	end
	return adapter
end

-- Wrap a supplied client prediction/replication consumer and RemoteEvent-like
-- transport. No RemoteEvent is created and no global service is consulted.
function Overdare.createClientPrediction(options: any): any
	options = assertAdapterOptions(options, "Overdare.createClientPrediction")
	local replicator = options.replicator or options.prediction
	assert(replicator ~= nil or type(options.receive) == "function" or type(options.onMessage) == "function",
		"client adapter requires replicator/prediction or receive callback")

	local receive = optionOrMethod(options, { "receive", "onMessage" }, replicator, { "receive", "apply", "accept" })
	assert(type(receive) == "function", "client replicator must implement receive/apply")

	local transport = options.remoteEvent or options.remote or options.transport
	if options.connect ~= false then
		assert(transport ~= nil or options.signal ~= nil or options.subscribe ~= nil,
			"client adapter requires remoteEvent/transport or explicit signal")
	end

	local adapter = setmetatable({
		_options = options,
		_scope = newDisposer(options.scope),
		_lastStatus = nil,
		_receive = receive,
		_validateIncoming = optionOrMethod(options, { "validateIncoming", "validateReplication", "validate" }, replicator,
			{ "validateIncoming", "validateReplication", "validate" }),
		_validateIntent = optionOrMethod(options, { "validateIntent", "validateOutgoing" }, replicator,
			{ "validateIntent", "validateOutgoing" }),
		_sendIntent = optionOrMethod(options, { "sendIntent", "send" }, transport,
			{ "FireServer", "fireServer", "sendIntent", "send" }),
	}, ClientAdapter)

	local connection = resolveSubscription(options, transport, "client", function(payload: any)
		adapter:receive(payload)
	end)
	if connection ~= nil then
		adapter._scope:add(connection)
	end
	return adapter
end

-- Descriptive aliases for users who do not enable prediction.
Overdare.createServerAdapter = Overdare.createServerReplication
Overdare.createClientAdapter = Overdare.createClientPrediction

return Overdare
