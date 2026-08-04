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

export type FRPFrame = {
	phase: Phase,
	time: number,
	delta: number,
	arguments: any,
}

export type FRPSignalOptions = {
	map: ((...any) -> any)?,
	label: string?,
	maxPending: number?,
	onOverflow: ((any) -> ())?,
}

export type FRPDriverOptions = {
	phase: Phase?,
	signal: any?,
	runService: any?,
	getRunService: (() -> any)?,
	getSignal: ((any, Phase) -> any)?,
	getDelta: ((...any) -> number)?,
	getTime: ((number, number, ...any) -> number)?,
	errorPolicy: ("raise" | "continue" | "disconnect")?,
	onError: ((any) -> ())?,
	scope: any?,
	label: string?,
}

export type FRPBinding = {
	dispose: (self: FRPBinding) -> (),
	Disconnect: (self: FRPBinding) -> (),
}

export type FRPDriver = {
	eventFromSignal: (self: FRPDriver, signal: any, options: FRPSignalOptions?) -> (any, FRPBinding),
	frames: (self: FRPDriver) -> any,
	dispose: (self: FRPDriver) -> (),
	Disconnect: (self: FRPDriver) -> (),
}

local VALID_PHASES: { [string]: boolean } = {
	Stepped = true,
	Heartbeat = true,
	RenderStepped = true,
}

local DEFAULT_MAX_SUBSTEPS = 8
local DEFAULT_MAX_PAYLOAD_DEPTH = 16
local DEFAULT_MAX_PAYLOAD_ENTRIES = 2048
local ACTIVE_FRP_DRIVERS = setmetatable({}, { __mode = "k" })

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

local function assertFRPHost(host: any)
	assert(type(host) == "table", "Overdare.attachFRP requires an FRP Host")
	assert(type(host.frame) == "function", "FRP Host must implement :frame(time, callback)")
	assert(type(host.source) == "function", "FRP Host must implement :source()")
	assert(type(host.now) == "function", "FRP Host must implement :now()")
end

local function packArguments(...: any): any
	return { n = select("#", ...), ... }
end

local function runSynchronous(callback: (...any) -> any, ...: any): (boolean, any)
	local arguments = packArguments(...)
	local thread = coroutine.create(function()
		return callback(table.unpack(arguments, 1, arguments.n))
	end)
	local resumed = packArguments(coroutine.resume(thread))
	if not resumed[1] then
		return false, resumed[2]
	end
	if coroutine.status(thread) ~= "dead" then
		return false, "OVERDARE FRP callbacks may not yield"
	end
	return true, resumed[2]
end

local FRPDriver = {}
FRPDriver.__index = FRPDriver

function FRPDriver:eventFromSignal(signal: any, options: FRPSignalOptions?): (any, any)
	if self._disposed then
		error("OVERDARE FRP driver is disposed", 2)
	end
	options = options or {}
	if options.map ~= nil and type(options.map) ~= "function" then
		error("eventFromSignal map must be a function", 2)
	end
	if options.maxPending ~= nil
		and (type(options.maxPending) ~= "number" or options.maxPending < 1 or options.maxPending % 1 ~= 0)
	then
		error("eventFromSignal maxPending must be a positive integer", 2)
	end
	if options.onOverflow ~= nil and type(options.onOverflow) ~= "function" then
		error("eventFromSignal onOverflow must be a function", 2)
	end

	local event, fire = self._host:source({ label = options.label })
	self._nextBindingId += 1
	local binding = {
		_id = self._nextBindingId,
		_active = true,
		_driver = self,
		_connection = nil,
		_pendingCount = 0,
	}

	function binding:dispose()
		if not self._active then
			return
		end
		self._active = false
		local driver = self._driver
		driver._bindings[self] = nil
		local retained = {}
		for _, entry in ipairs(driver._pending) do
			if entry.binding ~= self then
				retained[#retained + 1] = entry
			end
		end
		driver._pending = retained
		self._pendingCount = 0
		local connection = self._connection
		self._connection = nil
		if connection ~= nil then
			disposeOne(connection)
		end
	end
	binding.Disconnect = binding.dispose
	binding.disconnect = binding.dispose
	binding.Destroy = binding.dispose

	local function receive(...: any)
		if self._disposed or not binding._active then
			return
		end
		if options.maxPending ~= nil and binding._pendingCount >= options.maxPending then
			if options.onOverflow ~= nil then
				local ok, message = runSynchronous(options.onOverflow, {
					bindingId = binding._id,
					maxPending = options.maxPending,
					phase = self._phase,
					droppedCount = 1,
				})
				if not ok then
					self:_handleError(message, "signal-overflow-hook", 1)
				end
			end
			return
		end
		local arguments = packArguments(...)
		local value
		if options.map ~= nil then
			local ok, result = runSynchronous(options.map, table.unpack(arguments, 1, arguments.n))
			if not ok then
				self:_handleError(result, "signal-map", 1)
				return
			end
			value = result
		elseif arguments.n == 1 then
			value = arguments[1]
		else
			value = arguments
		end
		self._pending[#self._pending + 1] = {
			binding = binding,
			fire = fire,
			value = value,
		}
		binding._pendingCount += 1
	end

	binding._connection = connectSignal(signal, receive)
	self._bindings[binding] = true
	return event, binding
end

function FRPDriver:frames(): any
	return self._frames
end

function FRPDriver:_handleError(message: any, stage: string, droppedCount: number)
	local detail = {
		stage = stage,
		message = tostring(message),
		droppedCount = droppedCount,
		phase = self._phase,
	}
	if type(self._options.onError) == "function" then
		self._options.onError(detail)
	end
	if self._errorPolicy == "disconnect" then
		self:dispose()
		return
	elseif self._errorPolicy == "continue" then
		return
	end
	error(message, 0)
end

function FRPDriver:_flush(arguments: any)
	if self._disposed then
		return
	end
	local currentTime = self._host:now()
	local timingOk, timing = runSynchronous(function()
		local delta = extractDelta(self._phase, self._options, table.unpack(arguments, 1, arguments.n))
		local time
		if type(self._options.getTime) == "function" then
			time = self._options.getTime(currentTime, delta, table.unpack(arguments, 1, arguments.n))
		else
			time = currentTime + delta
		end
		return { delta = delta, time = time }
	end)
	if not timingOk then
		local droppedCount = #self._pending
		for _, entry in ipairs(self._pending) do
			entry.binding._pendingCount = math.max(0, entry.binding._pendingCount - 1)
		end
		self._pending = {}
		self:_handleError(timing, "clock", droppedCount)
		return
	end
	local delta = timing.delta
	local time = timing.time
	if type(time) ~= "number" or not isFinite(time) or time <= currentTime then
		local droppedCount = #self._pending
		for _, entry in ipairs(self._pending) do
			entry.binding._pendingCount = math.max(0, entry.binding._pendingCount - 1)
		end
		self._pending = {}
		self:_handleError("FRP driver time must be finite and strictly increasing", "clock", droppedCount)
		return
	end

	local pending = self._pending
	self._pending = {}
	for _, entry in ipairs(pending) do
		entry.binding._pendingCount = math.max(0, entry.binding._pendingCount - 1)
	end
	local frameValue: FRPFrame = {
		phase = self._phase,
		time = time,
		delta = delta,
		arguments = arguments,
	}
	local ok, message = pcall(function()
		self._host:frame(time, function()
			for _, entry in ipairs(pending) do
				if entry.binding._active then
					entry.fire(entry.value)
				end
			end
			self._fireFrame(frameValue)
		end)
	end)
	if not ok then
		self:_handleError(message, "host-frame", #pending)
	end
end

function FRPDriver:dispose()
	if self._disposed then
		return
	end
	self._disposed = true
	ACTIVE_FRP_DRIVERS[self._host] = nil
	self._pending = {}
	local bindings = {}
	for binding in pairs(self._bindings) do
		bindings[#bindings + 1] = binding
	end
	local firstFailure = nil
	for _, binding in ipairs(bindings) do
		local ok, message = pcall(binding.dispose, binding)
		if not ok and firstFailure == nil then
			firstFailure = message
		end
	end
	self._bindings = {}
	local clockConnection = self._clockConnection
	self._clockConnection = nil
	if clockConnection ~= nil then
		local ok, message = pcall(disposeOne, clockConnection)
		if not ok and firstFailure == nil then
			firstFailure = message
		end
	end
	if firstFailure ~= nil then
		error(firstFailure, 0)
	end
end

FRPDriver.Disconnect = FRPDriver.dispose
FRPDriver.disconnect = FRPDriver.dispose
FRPDriver.Destroy = FRPDriver.dispose

function Overdare.attachFRP(host: any, options: any?): any
	assertFRPHost(host)
	options = options or {}
	assert(type(options) == "table", "Overdare.attachFRP options must be a table")
	if ACTIVE_FRP_DRIVERS[host] ~= nil then
		error("an FRP Host may have only one active OVERDARE driver", 2)
	end
	local phase = assertPhase(options.phase)
	local errorPolicy = options.errorPolicy or "raise"
	if errorPolicy ~= "raise" and errorPolicy ~= "continue" and errorPolicy ~= "disconnect" then
		error("errorPolicy must be 'raise', 'continue', or 'disconnect'", 2)
	end
	if errorPolicy == "continue" and type(options.onError) ~= "function" then
		error("errorPolicy 'continue' requires onError", 2)
	end
	if options.onError ~= nil and type(options.onError) ~= "function" then
		error("onError must be a function", 2)
	end

	local runService = if options.signal ~= nil then nil else resolveRunService(options)
	local phaseSignal = resolvePhaseSignal(runService, phase, options)
	local frames, fireFrame = host:source({ label = options.label or ("overdare." .. phase) })
	local driver = setmetatable({
		_host = host,
		_options = options,
		_phase = phase,
		_errorPolicy = errorPolicy,
		_frames = frames,
		_fireFrame = fireFrame,
		_pending = {},
		_bindings = {},
		_nextBindingId = 0,
		_clockConnection = nil,
		_disposed = false,
	}, FRPDriver)
	ACTIVE_FRP_DRIVERS[host] = driver
	local ok, connectionOrError = pcall(connectSignal, phaseSignal, function(...: any)
		driver:_flush(packArguments(...))
	end)
	if not ok then
		ACTIVE_FRP_DRIVERS[host] = nil
		error(connectionOrError, 2)
	end
	driver._clockConnection = connectionOrError
	if options.scope ~= nil then
		local add = readMember(options.scope, "add")
		assert(type(add) == "function", "scope must implement :add(disposable)")
		add(options.scope, driver)
	end
	return driver
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

-- -------------------------------------------------------------------------
-- FRP-native multiplayer RemoteEvent adapter
-- -------------------------------------------------------------------------

local NETWORK_MODULE = nil

local function copyRemoteTable(value: any): any
	local result = {}
	for key, child in pairs(value) do
		result[key] = child
	end
	return result
end

local function loadNetworkModule(): any
	if NETWORK_MODULE ~= nil then
		return NETWORK_MODULE
	end
	if script ~= nil then
		NETWORK_MODULE = require(script.Parent.Network)
		return NETWORK_MODULE
	end
	local attempts = {
		"../Network",
		"./Network",
		"../src/Network",
		"./src/Network",
	}
	local messages = {}
	for _, path in ipairs(attempts) do
		local ok, module = pcall(require, path)
		if ok then
			NETWORK_MODULE = module
			return module
		end
		messages[#messages + 1] = tostring(module)
	end
	error("Overdare FRP RemoteEvent adapter could not load Network: " .. table.concat(messages, " | "), 0)
end

local function assertFRPDriver(driver: any, operation: string)
	assert(type(driver) == "table", operation .. " requires an FRP driver")
	assert(type(driver.eventFromSignal) == "function", operation .. " driver must implement :eventFromSignal()")
	assert(type(driver.frames) == "function", operation .. " driver must implement :frames()")
end

local function defaultClientId(player: any): any
	local userId = readMember(player, "UserId")
	if type(userId) == "number"
		and isFinite(userId)
		and userId >= 0
		and userId % 1 == 0
	then
		return userId
	end
	if type(userId) == "string" and userId ~= "" then
		return userId
	end
	error("RemoteEvent Player must expose a stable non-negative UserId, or options.getClientId must be provided", 2)
end

local function isStableRemoteClientId(value: any): boolean
	if type(value) == "string" then
		return value ~= ""
	end
	return type(value) == "number" and isFinite(value) and value >= 0 and value % 1 == 0
end

local function sessionStateKey(clientId: any, generation: number): string
	return type(clientId) .. ":" .. tostring(clientId) .. "#" .. tostring(generation)
end

local function resolveRemoteSignal(remoteEvent: any, name: string, injected: any): any
	local signal = injected or readMember(remoteEvent, name)
	assert(signal ~= nil, "RemoteEvent must expose " .. name .. " (or an explicit signal)")
	return signal
end

local function resolvePlayersService(options: any): any
	if options.players ~= nil then
		return options.players
	end
	if type(options.getPlayersService) == "function" then
		local ok, players = runSynchronous(options.getPlayersService)
		assert(ok and players ~= nil, "getPlayersService must synchronously return Players")
		return players
	end
	local serviceProvider = options.game
	if serviceProvider == nil then
		serviceProvider = game
	end
	if serviceProvider == nil then
		return nil
	end
	local getService = readMember(serviceProvider, "GetService") or readMember(serviceProvider, "getService")
	if type(getService) ~= "function" then
		return nil
	end
	local ok, players = runSynchronous(getService, serviceProvider, "Players")
	if ok then
		return players
	end
	return nil
end

local function newAdapterSignal(): any
	local signal = { _listeners = {} }
	function signal:Connect(callback: any): any
		local entry = { callback = callback, connected = true }
		self._listeners[#self._listeners + 1] = entry
		local connection = {}
		function connection:Disconnect()
			entry.connected = false
		end
		connection.disconnect = connection.Disconnect
		connection.dispose = connection.Disconnect
		return connection
	end
	function signal:Fire(value: any)
		for _, entry in ipairs(self._listeners) do
			if entry.connected then
				entry.callback(value)
			end
		end
	end
	return signal
end

local function invokeTransport(callback: any, label: string, ...: any): (boolean, any)
	if type(callback) ~= "function" then
		return false, label .. " transport method is unavailable"
	end
	local ok, result = runSynchronous(callback, ...)
	if not ok then
		return false, label .. " failed: " .. tostring(result)
	end
	return true, result
end

local function remoteMethod(remoteEvent: any, names: { string }): any
	for _, name in ipairs(names) do
		local method = readMember(remoteEvent, name)
		if type(method) == "function" then
			return function(...: any)
				return method(remoteEvent, ...)
			end
		end
	end
	return nil
end

local function callOptionalHook(channel: any, hook: any, value: any, label: string)
	if type(hook) ~= "function" then
		return
	end
	local ok, message = runSynchronous(hook, value)
	if not ok then
		channel._lastHookError = label .. " failed: " .. tostring(message)
	end
end

local function normalizeFRPRemoteArguments(remoteEvent: any, options: any): (any, any)
	if options == nil and type(remoteEvent) == "table"
		and (remoteEvent.remoteEvent ~= nil or remoteEvent.remote ~= nil or remoteEvent.transport ~= nil)
	then
		options = remoteEvent
		remoteEvent = options.remoteEvent or options.remote or options.transport
	end
	options = options or {}
	assert(type(options) == "table", "FRP RemoteEvent adapter options must be a table")
	remoteEvent = remoteEvent or options.remoteEvent or options.remote or options.transport
	assert(remoteEvent ~= nil, "FRP RemoteEvent adapter requires a RemoteEvent-like transport")
	return remoteEvent, options
end

local FRPServerRemote = {}
FRPServerRemote.__index = FRPServerRemote

function FRPServerRemote:_recordStatus(status: any)
	self._lastStatus = status
	callOptionalHook(self, self._options.onStatus, status, "onStatus")
	if status.ok == false then
		callOptionalHook(self, self._options.onViolation, status, "onViolation")
	end
end

function FRPServerRemote:_sendPacket(clientId: any, packet: any): any
	if self._disposed then
		return { ok = false, code = "disposed", message = "server RemoteEvent channel is disposed" }
	end
	local player = self._players[clientId]
	if player == nil then
		return { ok = false, code = "unknown_client", message = "no live Player is registered for clientId" }
	end
	local ok, message = invokeTransport(self._fireClient, "FireClient", player, packet)
	if not ok then
		local status = { ok = false, code = "transport_error", message = message, clientId = clientId }
		self:_recordStatus(status)
		return status
	end
	return { ok = true, code = "sent", clientId = clientId, packet = packet }
end

function FRPServerRemote:_clientId(target: any): (any, any)
	if self._disposed then
		return nil, { ok = false, code = "disposed", message = "server RemoteEvent channel is disposed" }
	end
	if self._players[target] ~= nil then
		return target, self._players[target]
	end
	local ok, clientId = runSynchronous(self._getClientId, target)
	if not ok or not isStableRemoteClientId(clientId) then
		return nil, { ok = false, code = "invalid_client", message = tostring(clientId) }
	end
	self._players[clientId] = target
	return clientId, target
end

function FRPServerRemote:arrivals(): any
	return self._arrivals
end

function FRPServerRemote:intents(): any
	return self._intents
end

function FRPServerRemote:violations(): any
	return self._violations
end

function FRPServerRemote:disconnects(): any
	return self._disconnects
end

function FRPServerRemote:getPlayer(clientId: any): any
	return self._players[clientId]
end

function FRPServerRemote:getPeerStatus(clientId: any): any
	local generation = self._generations[clientId] or 0
	local inbound = self._state.clients[sessionStateKey(clientId, generation)]
	local outbound = self._endpoint:getOutboundStatus(clientId)
	return {
		clientId = clientId,
		connected = self._players[clientId] ~= nil,
		generation = generation,
		lastIntentSequence = if inbound ~= nil then inbound.lastIntentSequence else 0,
		lastClientTick = if inbound ~= nil then inbound.lastClientTick else 0,
		epoch = outbound.epoch,
		serverSequence = outbound.sequence,
		replayCount = outbound.replayCount,
	}
end

function FRPServerRemote:send(target: any, messageType: string, payload: any, serverTick: number, kind: string?): any
	if self._disposed then
		return { ok = false, code = "disposed", message = "server RemoteEvent channel is disposed" }
	end
	if type(serverTick) ~= "number" or not isFinite(serverTick) or serverTick < 0 or serverTick % 1 ~= 0 then
		return { ok = false, code = "invalid_tick", message = "serverTick must be a non-negative finite integer" }
	end
	local clientId, playerOrFailure = self:_clientId(target)
	if clientId == nil then
		return playerOrFailure
	end
	local lastTick = self._lastServerTick[clientId] or 0
	if serverTick < lastTick then
		return { ok = false, code = "stale_server_tick", message = "serverTick moved backwards for this client" }
	end
	local peerStatus = self:getPeerStatus(clientId)
	local encoded = self._endpoint:encodeEvent(
		clientId,
		messageType,
		payload,
		serverTick,
		peerStatus.lastIntentSequence,
		kind
	)
	if not encoded.ok then
		return encoded
	end
	self._lastServerTick[clientId] = serverTick
	return self:_sendPacket(clientId, encoded.packet)
end

function FRPServerRemote:sendSnapshot(target: any, messageType: string, payload: any, serverTick: number): any
	return self:send(target, messageType, payload, serverTick, "snapshot")
end

function FRPServerRemote:sendHeartbeat(target: any, serverTick: number?): any
	if self._disposed then
		return { ok = false, code = "disposed", message = "server RemoteEvent channel is disposed" }
	end
	if serverTick ~= nil
		and (type(serverTick) ~= "number" or not isFinite(serverTick) or serverTick < 0 or serverTick % 1 ~= 0)
	then
		return { ok = false, code = "invalid_tick", message = "heartbeat serverTick must be a non-negative finite integer" }
	end
	local clientId, playerOrFailure = self:_clientId(target)
	if clientId == nil then
		return playerOrFailure
	end
	local lastTick = self._lastServerTick[clientId] or 0
	serverTick = serverTick or lastTick
	if type(serverTick) ~= "number" or not isFinite(serverTick) or serverTick < 0 or serverTick % 1 ~= 0 then
		return { ok = false, code = "invalid_tick", message = "heartbeat serverTick must be a non-negative finite integer" }
	end
	if serverTick < lastTick then
		return { ok = false, code = "stale_server_tick", message = "heartbeat serverTick moved backwards" }
	end
	local peerStatus = self:getPeerStatus(clientId)
	local encoded = self._endpoint:encodeHeartbeat(clientId, serverTick, peerStatus.lastIntentSequence)
	if not encoded.ok then
		return encoded
	end
	self._lastServerTick[clientId] = serverTick
	return self:_sendPacket(clientId, encoded.packet)
end

function FRPServerRemote:broadcast(players: any, messageType: string, payload: any, serverTick: number): any
	if self._disposed then
		return { ok = false, code = "disposed", message = "server RemoteEvent channel is disposed" }
	end
	if players == nil then
		if type(self._options.getPlayers) == "function" then
			local ok, resolved = runSynchronous(self._options.getPlayers)
			if not ok then
				return { ok = false, code = "players_error", message = tostring(resolved) }
			end
			players = resolved
		elseif self._playersService ~= nil and type(readMember(self._playersService, "GetPlayers")) == "function" then
			local ok, resolved = runSynchronous(readMember(self._playersService, "GetPlayers"), self._playersService)
			if not ok then
				return { ok = false, code = "players_error", message = tostring(resolved) }
			end
			players = resolved
		else
			players = {}
			for _, player in pairs(self._players) do
				players[#players + 1] = player
			end
		end
	end
	if type(players) ~= "table" then
		return { ok = false, code = "invalid_players", message = "broadcast players must be an array" }
	end
	local results = {}
	local allOk = true
	for _, player in ipairs(players) do
		local result = self:send(player, messageType, payload, serverTick)
		results[#results + 1] = result
		if not result.ok then
			allOk = false
		end
	end
	return { ok = allOk, code = if allOk then "broadcast_sent" else "broadcast_partial", results = results }
end

function FRPServerRemote:bindOutbound(event: any): any
	assert(not self._disposed, "server RemoteEvent channel is disposed")
	assert(type(event) == "table" and type(event.subscribe) == "function", "bindOutbound requires an FRP Event")
	local stop = event:subscribe(function(request: any)
		if type(request) ~= "table" then
			self:_recordStatus({ ok = false, code = "invalid_outbound", message = "server outbound Event must emit a table" })
			return
		end
		local target = request.player or request.peer or request.clientId
		local result = self:send(target, request.messageType or request.channel, request.payload, request.serverTick or 0, request.kind)
		self:_recordStatus(result)
	end)
	local binding = newDisposer()
	binding:add(stop)
	self._scope:add(binding)
	return binding
end

function FRPServerRemote:removePeer(target: any): any
	if self._disposed then
		return { ok = false, code = "disposed", message = "server RemoteEvent channel is disposed" }
	end
	local clientId = target
	if self._players[clientId] == nil and not isStableRemoteClientId(clientId) then
		local ok, resolved = runSynchronous(self._getClientId, target)
		if not ok or not isStableRemoteClientId(resolved) then
			return { ok = false, code = "invalid_client", message = tostring(resolved) }
		end
		clientId = resolved
	end
	local generation = self._generations[clientId] or 0
	self._players[clientId] = nil
	self._endpoint:forgetClient(clientId)
	self._lastServerTick[clientId] = nil
	self._generations[clientId] = generation + 1
	self._disconnectSignal:Fire({
		transportKind = "disconnect",
		clientId = clientId,
		stateKey = sessionStateKey(clientId, generation),
	})
	return { ok = true, code = "peer_removal_queued", clientId = clientId, generation = generation + 1 }
end

function FRPServerRemote:isConnected(): boolean
	return not self._disposed
end

function FRPServerRemote:dispose()
	if self._disposed then
		return
	end
	self._disposed = true
	self._scope:dispose()
	self._endpoint:dispose()
	self._players = {}
	self._playersService = nil
	self._generations = {}
	self._lastServerTick = {}
	self._state = { clients = {}, decision = nil }
	self._disconnectSignal = nil
end

FRPServerRemote.Disconnect = FRPServerRemote.dispose
FRPServerRemote.disconnect = FRPServerRemote.dispose
FRPServerRemote.Destroy = FRPServerRemote.dispose

local FRPClientRemote = {}
FRPClientRemote.__index = FRPClientRemote

function FRPClientRemote:_recordStatus(status: any)
	self._lastStatus = status
	callOptionalHook(self, self._options.onStatus, status, "onStatus")
	if status.ok == false then
		callOptionalHook(self, self._options.onViolation, status, "onViolation")
	end
end

function FRPClientRemote:_sendRaw(packet: any): any
	if self._disposed then
		return { ok = false, code = "disposed", message = "client RemoteEvent channel is disposed" }
	end
	local ok, message = invokeTransport(self._fireServer, "FireServer", packet)
	if not ok then
		local status = { ok = false, code = "transport_error", message = message }
		self:_recordStatus(status)
		return status
	end
	return { ok = true, code = "sent", packet = packet }
end

function FRPClientRemote:arrivals(): any
	return self._arrivals
end

function FRPClientRemote:authority(): any
	return self._authority
end

function FRPClientRemote:snapshots(): any
	return self._snapshots
end

function FRPClientRemote:violations(): any
	return self._violations
end

function FRPClientRemote:status(): any
	local status = self._endpoint:getStatus(self._state)
	status.connected = not self._disposed
	status.serverTick = self._state.serverTick or 0
	status.resyncPending = self._resyncPending
	return status
end

function FRPClientRemote:pending(): any
	return self._endpoint:getPendingIntents()
end

function FRPClientRemote:getLastIntentPacket(): any
	return self._lastIntentPacket
end

function FRPClientRemote:send(messageType: string, payload: any, clientTick: number?): any
	if self._disposed then
		return { ok = false, code = "disposed", message = "client RemoteEvent channel is disposed" }
	end
	if clientTick == nil then
		if type(self._options.getClientTick) == "function" then
			local ok, resolved = runSynchronous(self._options.getClientTick)
			if not ok then
				return { ok = false, code = "tick_error", message = tostring(resolved) }
			end
			clientTick = resolved
		else
			self._localTick += 1
			clientTick = self._localTick
		end
	end
	local prepared = self._endpoint:prepareIntent(messageType, payload, clientTick)
	if not prepared.ok then
		return prepared
	end
	local sent = self:_sendRaw(prepared.packet)
	if not sent.ok then
		return sent
	end
	local committed = self._endpoint:commitIntent(prepared.packet)
	if not committed.ok then
		self:_recordStatus(committed)
		return committed
	end
	self._lastIntentPacket = prepared.packet
	self._retry[prepared.sequence] = { sentAt = self._time, attempts = 0, exhaustedNotified = false }
	return {
		ok = true,
		code = "intent_sent",
		sequence = prepared.sequence,
		clientTick = clientTick,
		packet = prepared.packet,
	}
end

function FRPClientRemote:requestResync(): any
	if self._disposed then
		return { ok = false, code = "disposed", message = "client RemoteEvent channel is disposed" }
	end
	local encoded = self._endpoint:encodeResync(self._state.epoch, self._state.sequence + 1)
	if not encoded.ok then
		return encoded
	end
	self._resyncPacket = encoded.packet
	self._resyncPending = true
	self._resyncSentAt = self._time
	local sent = self:_sendRaw(encoded.packet)
	return sent
end

function FRPClientRemote:bindOutbound(event: any): any
	assert(not self._disposed, "client RemoteEvent channel is disposed")
	assert(type(event) == "table" and type(event.subscribe) == "function", "bindOutbound requires an FRP Event")
	local stop = event:subscribe(function(request: any)
		if type(request) ~= "table" then
			self:_recordStatus({ ok = false, code = "invalid_outbound", message = "client outbound Event must emit a table" })
			return
		end
		local result = self:send(request.messageType or request.channel, request.payload, request.clientTick)
		self:_recordStatus(result)
	end)
	local binding = newDisposer()
	binding:add(stop)
	self._scope:add(binding)
	return binding
end

function FRPClientRemote:_applyAck(sequence: any)
	if type(sequence) ~= "number" then
		return
	end
	local result = self._endpoint:acknowledge(sequence)
	if result.ok then
		for pendingSequence in pairs(self._retry) do
			if pendingSequence <= sequence then
				self._retry[pendingSequence] = nil
			end
		end
	else
		self:_recordStatus(result)
	end
end

function FRPClientRemote:_retryOldest(frame: any)
	if self._disposed then
		return
	end
	self._time = frame.time
	local pending = self._endpoint:getPendingIntents()
	if #pending == 0 then
		return
	end
	local packet = pending[1]
	local retry = self._retry[packet.sequence]
	if retry == nil then
		retry = { sentAt = frame.time, attempts = 0, exhaustedNotified = false }
		self._retry[packet.sequence] = retry
	end
	local delay = math.min(self._maxRetryDelay, self._ackTimeout * (self._retryBackoff ^ retry.attempts))
	if frame.time - retry.sentAt < delay then
		return
	end
	local sent = self:_sendRaw(packet)
	retry.sentAt = frame.time
	retry.attempts = math.min(self._maxRetries, retry.attempts + 1)
	if retry.attempts >= self._maxRetries and not retry.exhaustedNotified then
		retry.exhaustedNotified = true
		local status = {
			ok = false,
			code = "intent_retry_exhausted",
			message = "intent remains unacknowledged after the configured retries; capped retries continue",
			sequence = packet.sequence,
		}
		self:_recordStatus(status)
		callOptionalHook(self, self._options.onRetryExhausted, status, "onRetryExhausted")
		if not self._resyncPending then
			self:requestResync()
		end
	end
	return sent
end

function FRPClientRemote:_retryResync(frame: any)
	if self._disposed or not self._resyncPending or self._resyncPacket == nil then
		return
	end
	if frame.time - self._resyncSentAt < self._resyncRetryInterval then
		return
	end
	self:_sendRaw(self._resyncPacket)
	self._resyncSentAt = frame.time
end

function FRPClientRemote:isConnected(): boolean
	return not self._disposed
end

function FRPClientRemote:dispose()
	if self._disposed then
		return
	end
	self._disposed = true
	self._scope:dispose()
	self._endpoint:dispose()
	self._retry = {}
	self._resyncPending = false
	self._resyncPacket = nil
	self._lastIntentPacket = nil
	self._state = { epoch = 0, sequence = 0, ackSequence = 0, serverTick = 0, decision = nil }
end

FRPClientRemote.Disconnect = FRPClientRemote.dispose
FRPClientRemote.disconnect = FRPClientRemote.dispose
FRPClientRemote.Destroy = FRPClientRemote.dispose

function Overdare.attachFRPServerRemote(driver: any, remoteEvent: any, options: any?): any
	assertFRPDriver(driver, "Overdare.attachFRPServerRemote")
	remoteEvent, options = normalizeFRPRemoteArguments(remoteEvent, options)
	local Network = loadNetworkModule()
	local protocol = options.protocol
	assert(protocol ~= nil, "attachFRPServerRemote requires options.protocol")
	local getClientId = options.getClientId or defaultClientId
	assert(type(getClientId) == "function", "getClientId must be a function")
	local playersService = resolvePlayersService(options)
	local disconnectSignal = newAdapterSignal()

	local channel
	local endpoint = Network.createFRPServer({
		protocol = protocol,
		authorize = options.authorize,
		rateLimit = options.rateLimit,
		replayCapacity = options.replayCapacity,
		buildSnapshot = if options.buildSnapshot == nil then nil else function(clientId: any, request: any, context: any)
			local provided = options.buildSnapshot(clientId, request, context)
			if type(provided) == "table" then
				local snapshot = copyRemoteTable(provided)
				if snapshot.ackSequence == nil and channel ~= nil then
					snapshot.ackSequence = channel:getPeerStatus(clientId).lastIntentSequence
				end
				return snapshot
			end
			return provided
		end,
	})
	channel = setmetatable({
		_options = options,
		_endpoint = endpoint,
		_scope = newDisposer(options.scope),
		_getClientId = getClientId,
		_fireClient = options.fireClient or options.sendClient or remoteMethod(remoteEvent, { "FireClient", "fireClient" }),
		_players = {},
		_playersService = playersService,
		_generations = {},
		_lastServerTick = {},
		_state = endpoint:initialInboundState(),
		_lastStatus = nil,
		_lastHookError = nil,
		_lastIntentPacket = nil,
		_disconnectSignal = disconnectSignal,
		_disposed = false,
	}, FRPServerRemote)

	local signal = resolveRemoteSignal(remoteEvent, "OnServerEvent", options.signal)
	local raw, rawBinding = driver:eventFromSignal(signal, {
		label = options.label or "network.server.arrivals",
		maxPending = options.maxPendingPerFrame or 128,
		onOverflow = function(detail: any)
			channel:_recordStatus({
				ok = false,
				code = "frame_queue_overflow",
				message = "server RemoteEvent frame queue is full",
				detail = detail,
			})
		end,
		map = function(...: any)
			local arguments = packArguments(...)
			local player = arguments[1]
			local clientId = getClientId(player)
			assert(isStableRemoteClientId(clientId), "getClientId must return a stable string or non-negative integer")
			channel._players[clientId] = player
			local generation = channel._generations[clientId] or 0
			return {
				transportKind = "packet",
				clientId = clientId,
				stateKey = sessionStateKey(clientId, generation),
				packet = if arguments.n == 2 then arguments[2] else { adapterMalformedArgumentCount = arguments.n },
			}
		end,
	})
	channel._scope:add(rawBinding)
	local arrivals = raw:mapWithTime(function(input: any, time: number)
		local value = copyRemoteTable(input)
		value.receivedAt = time
		value.context = { clientId = input.clientId, receivedAt = time }
		return value
	end, { label = "network.server.timed-arrivals" })
	local manualRemoved, manualRemovalBinding = driver:eventFromSignal(disconnectSignal, {
		label = "network.server.manual-peer-removing",
		maxPending = options.maxPendingPerFrame or 128,
		onOverflow = function(detail: any)
			channel:_recordStatus({
				ok = false,
				code = "frame_queue_overflow",
				message = "manual peer-removal queue is full",
				detail = detail,
			})
		end,
	})
	channel._scope:add(manualRemovalBinding)
	arrivals = arrivals:merge(manualRemoved:mapWithTime(function(input: any, time: number)
		local value = copyRemoteTable(input)
		value.receivedAt = time
		return value
	end))

	local playerRemoving = options.playerRemovingSignal
	if playerRemoving == nil and playersService ~= nil then
		playerRemoving = readMember(playersService, "PlayerRemoving")
	end
	if playerRemoving ~= nil then
		local removed, removalBinding = driver:eventFromSignal(playerRemoving, {
			label = "network.server.player-removing",
			maxPending = options.maxPendingPerFrame or 128,
			map = function(player: any)
				local clientId = getClientId(player)
				assert(isStableRemoteClientId(clientId), "getClientId must return a stable string or non-negative integer")
				local generation = channel._generations[clientId] or 0
				channel._generations[clientId] = generation + 1
				channel._players[clientId] = nil
				return {
					transportKind = "disconnect",
					clientId = clientId,
					stateKey = sessionStateKey(clientId, generation),
				}
			end,
		})
		channel._scope:add(removalBinding)
		arrivals = arrivals:merge(removed:mapWithTime(function(input: any, time: number)
			local value = copyRemoteTable(input)
			value.receivedAt = time
			return value
		end))
	end

	local scanned = arrivals:scan(endpoint:initialInboundState(), function(state: any, input: any)
		return endpoint:reduceInbound(state, input)
	end, { label = "network.server.protocol-state" })
	local decisions = scanned:map(function(state: any)
		return state.decision
	end, { label = "network.server.decisions" })
	channel._arrivals = arrivals
	channel._intents = decisions:filter(function(decision: any)
		return decision ~= nil and decision.ok and decision.kind == "intent"
	end):map(function(decision: any)
		return decision
	end, { label = "network.server.intents" })
	channel._violations = decisions:filter(function(decision: any)
		return decision ~= nil and not decision.ok
	end)
	channel._disconnects = decisions:filter(function(decision: any)
		return decision ~= nil and decision.kind == "disconnect"
	end)

	channel._scope:add(scanned:subscribe(function(state: any)
		channel._state = state
		local decision = state.decision
		if decision == nil then
			return
		end
		channel:_recordStatus(decision)
		local clientId = decision.clientId
		if decision.kind == "intent" or decision.consumed
			or decision.code == "duplicate_intent" or decision.code == "stale_intent"
		then
			local encoded = endpoint:encodeAck(clientId, decision.lastIntentSequence or 0)
			if encoded.ok then
				channel:_sendPacket(clientId, encoded.packet)
			end
		elseif decision.kind == "intent_gap" then
			local encoded = endpoint:encodeIntentGap(clientId, decision.expectedSequence, decision.lastIntentSequence or 0)
			if encoded.ok then
				channel:_sendPacket(clientId, encoded.packet)
			end
		elseif decision.kind == "resync" and decision.ok then
			local recovered = endpoint:recover(clientId, decision, { receivedAt = decision.receivedAt })
			if recovered.ok then
				if #recovered.packets == 0 then
					channel:sendHeartbeat(clientId)
				else
					for _, packet in ipairs(recovered.packets) do
						channel:_sendPacket(clientId, packet)
					end
				end
			else
				channel:_recordStatus(recovered)
				local unavailable = endpoint:encodeResyncUnavailable(clientId, decision.epoch, decision.expectedSequence)
				if unavailable.ok then
					channel:_sendPacket(clientId, unavailable.packet)
				end
			end
		elseif decision.kind == "disconnect" then
			endpoint:forgetClient(clientId)
			channel._lastServerTick[clientId] = nil
		end
	end, { priority = -10000 }))

	local heartbeatInterval = options.heartbeatInterval
	if heartbeatInterval == nil then
		heartbeatInterval = 1
	end
	if heartbeatInterval ~= false then
		assert(type(heartbeatInterval) == "number" and heartbeatInterval > 0,
			"heartbeatInterval must be false or a positive number")
		local lastHeartbeat = 0
		channel._scope:add(driver:frames():subscribe(function(frame: any)
			if frame.time - lastHeartbeat < heartbeatInterval then
				return
			end
			lastHeartbeat = frame.time
			for clientId, player in pairs(channel._players) do
				channel:sendHeartbeat(player)
			end
		end, { priority = 10000 }))
	end
	return channel
end

function Overdare.attachFRPClientRemote(driver: any, remoteEvent: any, options: any?): any
	assertFRPDriver(driver, "Overdare.attachFRPClientRemote")
	remoteEvent, options = normalizeFRPRemoteArguments(remoteEvent, options)
	local Network = loadNetworkModule()
	local protocol = options.protocol
	assert(protocol ~= nil, "attachFRPClientRemote requires options.protocol")
	local endpoint = Network.createFRPClient({
		protocol = protocol,
		pendingCapacity = options.pendingCapacity,
	})
	local channel = setmetatable({
		_options = options,
		_endpoint = endpoint,
		_scope = newDisposer(options.scope),
		_fireServer = options.fireServer or options.sendServer or remoteMethod(remoteEvent, { "FireServer", "fireServer" }),
		_state = endpoint:initialInboundState(),
		_retry = {},
		_time = 0,
		_localTick = 0,
		_ackTimeout = options.ackTimeout or 1,
		_retryBackoff = options.retryBackoff or 2,
		_maxRetryDelay = options.maxRetryDelay or 8,
		_maxRetries = options.maxRetries or 8,
		_resyncPending = false,
		_resyncPacket = nil,
		_resyncSentAt = 0,
		_resyncRetryInterval = options.resyncRetryInterval or 1,
		_lastStatus = nil,
		_lastHookError = nil,
		_disposed = false,
	}, FRPClientRemote)
	assert(type(channel._ackTimeout) == "number" and channel._ackTimeout > 0, "ackTimeout must be positive")
	assert(type(channel._retryBackoff) == "number" and channel._retryBackoff >= 1, "retryBackoff must be >= 1")
	assert(type(channel._maxRetryDelay) == "number" and channel._maxRetryDelay > 0, "maxRetryDelay must be positive")
	assert(type(channel._maxRetries) == "number" and channel._maxRetries >= 1 and channel._maxRetries % 1 == 0,
		"maxRetries must be a positive integer")
	assert(type(channel._resyncRetryInterval) == "number" and channel._resyncRetryInterval > 0,
		"resyncRetryInterval must be positive")

	local signal = resolveRemoteSignal(remoteEvent, "OnClientEvent", options.signal)
	local raw, rawBinding = driver:eventFromSignal(signal, {
		label = options.label or "network.client.arrivals",
		maxPending = options.maxPendingPerFrame or 128,
		onOverflow = function(detail: any)
			channel:_recordStatus({
				ok = false,
				code = "frame_queue_overflow",
				message = "client RemoteEvent frame queue is full",
				detail = detail,
			})
		end,
		map = function(...: any)
			local arguments = packArguments(...)
			return { packet = if arguments.n == 1 then arguments[1] else { adapterMalformedArgumentCount = arguments.n } }
		end,
	})
	channel._scope:add(rawBinding)
	local arrivals = raw:mapWithTime(function(input: any, time: number)
		return {
			packet = input.packet,
			receivedAt = time,
			intentSequence = endpoint:getStatus(channel._state).intentSequence,
		}
	end, { label = "network.client.timed-arrivals" })
	local scanned = arrivals:scan(endpoint:initialInboundState(), function(state: any, input: any)
		return endpoint:reduceInbound(state, input)
	end, { label = "network.client.protocol-state" })
	local decisions = scanned:map(function(state: any)
		return state.decision
	end, { label = "network.client.decisions" })
	channel._arrivals = arrivals:map(function(input: any)
		return input.packet
	end, { label = "network.client.raw-packets" })
	channel._authority = decisions:filter(function(decision: any)
		return decision ~= nil and decision.ok and (decision.kind == "event" or decision.kind == "snapshot")
	end)
	channel._snapshots = decisions:filter(function(decision: any)
		return decision ~= nil and decision.ok and decision.kind == "snapshot"
	end)
	channel._violations = decisions:filter(function(decision: any)
		return decision ~= nil and not decision.ok
	end)

	channel._scope:add(scanned:subscribe(function(state: any)
		channel._state = state
		local decision = state.decision
		if decision == nil then
			return
		end
		channel:_recordStatus(decision)
		if decision.ackSequence ~= nil then
			channel:_applyAck(decision.ackSequence)
		end
		if decision.kind == "intent_gap" and decision.ok then
			local pending = endpoint:pendingFrom(decision.expectedSequence)
			if pending.ok then
				for _, packet in ipairs(pending.packets) do
					channel:_sendRaw(packet)
					local retry = channel._retry[packet.sequence]
					if retry ~= nil then
						retry.sentAt = channel._time
					end
				end
			else
				channel:_recordStatus(pending)
			end
		elseif decision.kind == "resync" and decision.requestResync then
			if not channel._resyncPending then
				channel:requestResync()
			end
		elseif decision.kind == "resync_unavailable" then
			channel._resyncPending = false
			channel._resyncPacket = nil
		elseif decision.ok and (decision.kind == "event" or decision.kind == "snapshot" or decision.kind == "heartbeat") then
			channel._resyncPending = false
			channel._resyncPacket = nil
		end
	end, { priority = -10000 }))
	channel._scope:add(driver:frames():subscribe(function(frame: any)
		channel:_retryOldest(frame)
		channel:_retryResync(frame)
	end, { priority = 10000 }))

	if options.initialResync ~= false then
		channel:requestResync()
	end
	return channel
end

Overdare.attachRemoteEventServer = Overdare.attachFRPServerRemote
Overdare.attachRemoteEventClient = Overdare.attachFRPClientRemote

-- Descriptive aliases for users who do not enable prediction.
Overdare.createServerAdapter = Overdare.createServerReplication
Overdare.createClientAdapter = Overdare.createClientPrediction

return Overdare
