--!strict

-- Clocks are passive.  They never connect to an engine signal or own a loop;
-- callers explicitly run/step/advance them from the phase they control.

local Clock = {}

export type OverflowPolicy = "drop" | "clamp" | "error"

export type OverflowEvent = {
	policy: OverflowPolicy,
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

export type AdvanceResult = {
	steps: number,
	requestedSteps: number,
	tick: number,
	simulatedDelta: number,
	accumulator: number,
	alpha: number,
	overflowed: boolean,
	droppedDelta: number,
}

export type StepCallback = (delta: number, tick: number, stepIndex: number) -> ()

export type FixedOptions = {
	maxSubsteps: number?,
	overflow: OverflowPolicy?,
	callback: StepCallback?,
	onOverflow: ((event: OverflowEvent) -> ())?,
}

type ManualState = {
	_tick: number,
	_time: number,
}

type FixedState = {
	delta: number,
	maxSubsteps: number,
	overflow: OverflowPolicy,
	_tick: number,
	_accumulator: number,
	_callback: StepCallback?,
	_onOverflow: ((event: OverflowEvent) -> ())?,
}

local DEFAULT_MAX_SUBSTEPS = 8

local function isFinite(value: number): boolean
	return value == value and value ~= math.huge and value ~= -math.huge
end

local function assertNonNegativeFinite(value: any, name: string, level: number): number
	if type(value) ~= "number" or not isFinite(value) or value < 0 then
		error(string.format("%s must be a finite, non-negative number", name), level)
	end

	return value
end

local function assertCallback(callback: any, name: string, level: number): StepCallback
	if type(callback) ~= "function" then
		error(string.format("%s must be a function", name), level)
	end

	return callback
end

local Immediate = {}
Immediate.__index = Immediate

function Immediate.getTick(_self: any): nil
	return nil
end

function Immediate.run(_self: any, callback: (...any) -> ...any, ...: any): ...any
	if type(callback) ~= "function" then
		error("Clock.immediate:run callback must be a function", 2)
	end

	return callback(...)
end

local Manual = {}
Manual.__index = Manual

function Manual.getTick(self: ManualState): number
	return self._tick
end

function Manual.getTime(self: ManualState): number
	return self._time
end

function Manual.reset(self: ManualState, tick: number?, elapsed: number?)
	local nextTick = if tick == nil then 0 else tick
	local nextElapsed = if elapsed == nil then 0 else elapsed

	if type(nextTick) ~= "number" or not isFinite(nextTick) or nextTick < 0 or nextTick % 1 ~= 0 then
		error("Clock.manual:reset tick must be a finite, non-negative integer", 2)
	end
	assertNonNegativeFinite(nextElapsed, "Clock.manual:reset elapsed", 2)

	self._tick = nextTick
	self._time = nextElapsed
end

function Manual.advance(self: ManualState, delta: number, callback: StepCallback?): AdvanceResult
	local checkedDelta = assertNonNegativeFinite(delta, "Clock.manual:advance delta", 2)
	local previousTick = self._tick
	local previousTime = self._time
	local nextTick = previousTick + 1

	if callback ~= nil then
		local checkedCallback = assertCallback(callback, "Clock.manual:advance callback", 2)
		-- Make the current tick observable during the callback, but restore the
		-- clock if that callback rejects the step.
		self._tick = nextTick
		self._time += checkedDelta
		local ok, message = pcall(function(): any
			checkedCallback(checkedDelta, nextTick, 1)
			return nil
		end)
		if not ok then
			self._tick = previousTick
			self._time = previousTime
			error(message, 0)
		end
	else
		self._tick = nextTick
		self._time += checkedDelta
	end

	return {
		steps = 1,
		requestedSteps = 1,
		tick = self._tick,
		simulatedDelta = checkedDelta,
		accumulator = 0,
		alpha = 0,
		overflowed = false,
		droppedDelta = 0,
	}
end

Manual.step = Manual.advance

local Fixed = {}
Fixed.__index = Fixed

function Fixed.getTick(self: FixedState): number
	return self._tick
end

function Fixed.getTime(self: FixedState): number
	return self._tick * self.delta
end

function Fixed.getAccumulator(self: FixedState): number
	return self._accumulator
end

function Fixed.getAlpha(self: FixedState): number
	return self._accumulator / self.delta
end

function Fixed.reset(self: FixedState, tick: number?, accumulator: number?)
	local nextTick = if tick == nil then 0 else tick
	local nextAccumulator = if accumulator == nil then 0 else accumulator

	if type(nextTick) ~= "number" or not isFinite(nextTick) or nextTick < 0 or nextTick % 1 ~= 0 then
		error("Clock.fixed:reset tick must be a finite, non-negative integer", 2)
	end
	assertNonNegativeFinite(nextAccumulator, "Clock.fixed:reset accumulator", 2)

	if nextAccumulator > self.delta then
		error("Clock.fixed:reset accumulator must not exceed fixed delta", 2)
	end

	self._tick = nextTick
	self._accumulator = nextAccumulator
end

function Fixed.advance(self: FixedState, frameDelta: number, callback: StepCallback?): AdvanceResult
	local checkedFrameDelta = assertNonNegativeFinite(frameDelta, "Clock.fixed:advance frameDelta", 2)
	local stepCallback = callback or self._callback
	if stepCallback ~= nil then
		stepCallback = assertCallback(stepCallback, "Clock.fixed:advance callback", 2)
	end

	local accumulatorBefore = self._accumulator
	local accumulated = accumulatorBefore + checkedFrameDelta
	if not isFinite(accumulated) then
		error("Clock.fixed:advance accumulator overflowed the finite number range", 2)
	end

	local ratio = accumulated / self.delta
	if not isFinite(ratio) then
		error("Clock.fixed:advance represents too many fixed substeps", 2)
	end
	local requestedSteps = math.floor(ratio)
	-- Repeated addition can leave a value a few ulps below an exact fixed-step
	-- boundary.  Snap only that tiny boundary error, not ordinary fractions.
	if requestedSteps + 1 - ratio <= 1e-12 then
		requestedSteps += 1
	end
	local fractionalRemainder = accumulated - requestedSteps * self.delta
	if fractionalRemainder < 0 and fractionalRemainder > -self.delta * 1e-10 then
		fractionalRemainder = 0
	end
	local stepsToRun = requestedSteps
	local overflowed = requestedSteps > self.maxSubsteps
	local droppedDelta = 0
	local adjustedAccumulator = accumulated

	if overflowed then
		stepsToRun = self.maxSubsteps
		local remainingAfterSteps = (requestedSteps - stepsToRun) * self.delta + fractionalRemainder

		if self.overflow == "drop" then
			-- Discard whole unprocessed ticks, but keep the sub-tick fraction so
			-- interpolation remains continuous.
			droppedDelta = (requestedSteps - stepsToRun) * self.delta
			adjustedAccumulator = stepsToRun * self.delta + fractionalRemainder
		elseif self.overflow == "clamp" then
			-- Keep at most one pending fixed tick for a later explicit advance.
			local retainedRemainder = math.min(remainingAfterSteps, self.delta)
			droppedDelta = remainingAfterSteps - retainedRemainder
			adjustedAccumulator = stepsToRun * self.delta + retainedRemainder
		end

		local retainedDelta = adjustedAccumulator - stepsToRun * self.delta
		local event: OverflowEvent = {
			policy = self.overflow,
			fixedDelta = self.delta,
			frameDelta = checkedFrameDelta,
			maxSubsteps = self.maxSubsteps,
			requestedSubsteps = requestedSteps,
			executedSubsteps = if self.overflow == "error" then 0 else stepsToRun,
			overflowSubsteps = if self.overflow == "error" then requestedSteps else requestedSteps - stepsToRun,
			droppedDelta = droppedDelta,
			retainedDelta = retainedDelta,
			accumulatorBefore = accumulatorBefore,
			accumulatorAfterInput = accumulated,
			tick = self._tick,
		}

		-- Notify before mutating the clock.  A failing observer cannot leave a
		-- partially advanced accumulator behind.
		if self._onOverflow ~= nil then
			self._onOverflow(event)
		end

		if self.overflow == "error" then
			error(string.format(
				"Clock.fixed overflow at tick %d: %d substeps requested, maximum is %d",
				self._tick,
				requestedSteps,
				self.maxSubsteps
			), 2)
		end
	end

	if stepsToRun > 0 and stepCallback == nil then
		error("Clock.fixed:advance requires a callback when one or more substeps are ready", 2)
	end

	self._accumulator = adjustedAccumulator
	local completedSteps = 0

	for stepIndex = 1, stepsToRun do
		local previousTick = self._tick
		local previousAccumulator = self._accumulator
		local nextTick = previousTick + 1
		self._tick = nextTick
		self._accumulator = previousAccumulator - self.delta

		local ok, message = pcall(function(): any
			(stepCallback :: StepCallback)(self.delta, nextTick, stepIndex)
			return nil
		end)
		if not ok then
			-- Only the failing substep is restored.  Earlier callbacks succeeded
			-- and therefore remain reflected by the clock.
			self._tick = previousTick
			self._accumulator = previousAccumulator
			error(message, 0)
		end

		completedSteps += 1
	end

	-- Avoid tiny negative residues from repeated floating-point subtraction.
	if self._accumulator < 0 and self._accumulator > -self.delta * 1e-10 then
		self._accumulator = 0
	end

	return {
		steps = completedSteps,
		requestedSteps = requestedSteps,
		tick = self._tick,
		simulatedDelta = completedSteps * self.delta,
		accumulator = self._accumulator,
		alpha = self._accumulator / self.delta,
		overflowed = overflowed,
		droppedDelta = droppedDelta,
	}
end

Fixed.step = Fixed.advance

function Clock.immediate()
	return setmetatable({
		kind = "immediate",
	}, Immediate)
end

function Clock.manual()
	return setmetatable({
		kind = "manual",
		_tick = 0,
		_time = 0,
	}, Manual)
end

function Clock.fixed(delta: number, options: FixedOptions?)
	if type(delta) ~= "number" or not isFinite(delta) or delta <= 0 then
		error("Clock.fixed delta must be a finite number greater than zero", 2)
	end

	local resolvedOptions: FixedOptions = options or {}
	if type(resolvedOptions) ~= "table" then
		error("Clock.fixed options must be a table", 2)
	end

	local maxSubsteps = resolvedOptions.maxSubsteps or DEFAULT_MAX_SUBSTEPS
	if type(maxSubsteps) ~= "number" or not isFinite(maxSubsteps) or maxSubsteps < 1 or maxSubsteps % 1 ~= 0 then
		error("Clock.fixed maxSubsteps must be a positive integer", 2)
	end

	local overflow = resolvedOptions.overflow or "drop"
	if overflow ~= "drop" and overflow ~= "clamp" and overflow ~= "error" then
		error("Clock.fixed overflow must be 'drop', 'clamp', or 'error'", 2)
	end

	if resolvedOptions.callback ~= nil then
		assertCallback(resolvedOptions.callback, "Clock.fixed callback", 2)
	end

	if resolvedOptions.onOverflow ~= nil and type(resolvedOptions.onOverflow) ~= "function" then
		error("Clock.fixed onOverflow must be a function", 2)
	end

	return setmetatable({
		kind = "fixed",
		delta = delta,
		maxSubsteps = maxSubsteps,
		overflow = overflow,
		_tick = 0,
		_accumulator = 0,
		_callback = resolvedOptions.callback,
		_onOverflow = resolvedOptions.onOverflow,
	}, Fixed)
end

return Clock
