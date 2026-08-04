--!nonstrict

-- A strict-Luau adaptation of Conal Elliott's 2009 push-pull FRP model.
--
-- Denotationally:
--   Behavior a = Time -> a
--   Reactive a = initial `Stepper` Event a
--   Event a    ~= Future (Reactive a)
--   Behavior a = Reactive (Fun Time a)
--
-- Haskell laziness, improving values, and unambiguous parallel choice are
-- replaced at the host boundary by pushed, time-stamped occurrences and a
-- monotonic single-threaded evaluator. Event graphs are awakened by pushed
-- source occurrences and pulled only by Reactive values and explicit sinks.

local FRP = {}

local Host = {}
Host.__index = Host

local Event = {}
Event.__index = Event

local Reactive = {}
Reactive.__index = Reactive

local Behavior = {}
Behavior.__index = Behavior

local Future = {}
Future.__index = Future

local TimeFunction = {}
TimeFunction.__index = TimeFunction

local HOST_TAG = {}
local EVENT_TAG = {}
local REACTIVE_TAG = {}
local BEHAVIOR_TAG = {}
local FUTURE_TAG = {}
local TIME_FUNCTION_TAG = {}

local NEG_INFINITY = -math.huge
local POS_INFINITY = math.huge
local EMPTY = {}

local function pack(...)
	return { n = select("#", ...), ... }
end

local function unpackPacked(values, first)
	return table.unpack(values, first or 1, values.n)
end

local function isTime(value)
	return type(value) == "number" and value == value
end

local function isFiniteTime(value)
	return isTime(value) and value ~= NEG_INFINITY and value ~= POS_INFINITY
end

local function assertFiniteTime(value, label, level)
	if not isFiniteTime(value) then
		error((label or "time") .. " must be a finite non-NaN number", level or 3)
	end
	return value
end

local function runNoYield(callback, ...)
	local arguments = pack(...)
	local thread = coroutine.create(function()
		return callback(unpackPacked(arguments))
	end)
	local results = pack(coroutine.resume(thread))
	if not results[1] then
		return false, results[2]
	end
	if coroutine.status(thread) ~= "dead" then
		return false, "FRP callbacks must finish synchronously and may not yield"
	end
	return true, table.unpack(results, 2, results.n)
end

local function call(label, callback, ...)
	local results = pack(runNoYield(callback, ...))
	if not results[1] then
		error(label .. " failed: " .. tostring(results[2]), 0)
	end
	return table.unpack(results, 2, results.n)
end

local function assertHost(host, level)
	if type(host) ~= "table" or host._tag ~= HOST_TAG then
		error("expected an FRP Host", level or 3)
	end
	if host._phase == "disposed" then
		error("FRP Host is disposed", level or 3)
	end
	return host
end

local function assertEvent(event, level)
	if type(event) ~= "table" or event._tag ~= EVENT_TAG then
		error("expected an FRP Event", level or 3)
	end
	assertHost(event._host, (level or 3) + 1)
	return event
end

local function assertReactive(reactive, level)
	if type(reactive) ~= "table" or reactive._tag ~= REACTIVE_TAG then
		error("expected an FRP Reactive value", level or 3)
	end
	assertHost(reactive._host, (level or 3) + 1)
	return reactive
end

local function assertBehavior(behavior, level)
	if type(behavior) ~= "table" or behavior._tag ~= BEHAVIOR_TAG then
		error("expected an FRP Behavior", level or 3)
	end
	assertHost(behavior._host, (level or 3) + 1)
	return behavior
end

local function assertFuture(future, level)
	if type(future) ~= "table" or future._tag ~= FUTURE_TAG then
		error("expected an FRP Future", level or 3)
	end
	return future
end

local function assertSameHost(left, right, label, level)
	if left._host ~= right._host then
		error((label or "FRP values") .. " must belong to the same Host", level or 3)
	end
end

local function copyArray(values)
	local copy = {}
	for index, value in ipairs(values) do
		copy[index] = value
	end
	return copy
end

local function occurrence(time, value, order)
	return {
		time = time,
		value = value,
		order = order or 0,
	}
end

local function mappedOccurrence(original, value)
	return occurrence(original.time, value, original.order)
end

local function stableMerge(left, right)
	local output = {}
	local leftIndex = 1
	local rightIndex = 1
	while leftIndex <= #left or rightIndex <= #right do
		local leftItem = left[leftIndex]
		local rightItem = right[rightIndex]
		if rightItem == nil or (leftItem ~= nil and leftItem.time <= rightItem.time) then
			output[#output + 1] = leftItem
			leftIndex += 1
		else
			output[#output + 1] = rightItem
			rightIndex += 1
		end
	end
	return output
end

local function addDependent(event, dependent)
	event._dependents[dependent] = true
	local frame = event._host._activeFrame
	if frame ~= nil and event._dirtyFrame == frame.id then
		dependent:_markDirty(frame)
	end
end

local function removeDependent(event, dependent)
	event._dependents[dependent] = nil
end

local function newEvent(host, options)
	assertHost(host, 3)
	options = options or {}
	host._nextNodeId += 1
	local rank = 0
	for _, parent in ipairs(options.parents or EMPTY) do
		assertEvent(parent, 3)
		assertSameHost({ _host = host }, parent, "Event parents", 3)
		rank = math.max(rank, parent._rank + 1)
	end
	local event = setmetatable({
		_tag = EVENT_TAG,
		_host = host,
		_id = host._nextNodeId,
		_label = options.label or ("event#" .. tostring(host._nextNodeId)),
		_kind = options.kind or "derived",
		_rank = rank,
		_parents = options.parents or {},
		-- Dependents are weak: a child holds its parents strongly, while a parent
		-- must not keep an otherwise discarded downstream graph alive forever.
		_dependents = setmetatable({}, { __mode = "k" }),
		_compute = options.compute,
		_computeInitial = options.computeInitial,
		_pastCompute = options.pastCompute,
		_catchUpCompute = options.catchUpCompute,
		_dirtyFrame = nil,
		_memoFrame = nil,
		_memo = nil,
		_evaluatingFrame = nil,
		_initialComputed = false,
		_initialComputing = false,
		_initialOccurrences = nil,
		_sourceHistory = {},
		_pastComputing = false,
		_state = options.state,
		_always = options.always == true,
	}, Event)
	for _, parent in ipairs(event._parents) do
		addDependent(parent, event)
	end
	host._events[event] = true
	if event._always then
		host._alwaysEvents[event] = true
		local frame = host._activeFrame
		if frame ~= nil and frame.hasInput then
			event:_markDirty(frame)
		end
	end
	return event
end

function Event:_markDirty(frame)
	if self._dirtyFrame == frame.id then
		return
	end
	self._dirtyFrame = frame.id
	for dependent in next, self._dependents do
		dependent:_markDirty(frame)
	end
end

function Event:_evaluate(frame)
	if self._memoFrame == frame.id then
		return self._memo
	end
	if self._dirtyFrame ~= frame.id then
		return EMPTY
	end
	if self._evaluatingFrame == frame.id then
		error("FRP Event cycle while evaluating '" .. self._label .. "'", 0)
	end
	self._evaluatingFrame = frame.id
	local values
	if self._kind == "source" then
		values = frame.sourceInputs[self] or EMPTY
	elseif self._compute ~= nil then
		values = self._compute(self, frame) or EMPTY
	else
		values = EMPTY
	end
	self._evaluatingFrame = nil
	self._memoFrame = frame.id
	self._memo = values
	return values
end

function Event:_initial()
	if self._initialComputed then
		return self._initialOccurrences
	end
	if self._initialComputing then
		error("FRP Event cycle while evaluating initial occurrences of '" .. self._label .. "'", 0)
	end
	self._initialComputing = true
	local values = EMPTY
	if self._computeInitial ~= nil then
		local ok, result = pcall(self._computeInitial, self)
		self._initialComputing = false
		if not ok then
			error(result, 0)
		end
		values = result or EMPTY
	else
		self._initialComputing = false
	end
	self._initialComputed = true
	self._initialOccurrences = values
	return values
end

-- Pulls the already-closed finite prefix of an Event. This is the strict-Luau
-- counterpart of the paper's lazy Event tail: a dynamically selected inner
-- Event must still expose occurrences that predate its selection so bind can
-- clamp them with max(outerTime, innerTime).
function Event:_pastFinite(cutoff, inclusive, frame, commitState)
	if self._pastComputing then
		error("FRP Event cycle while reconstructing the past of '" .. self._label .. "'", 0)
	end
	self:_initial()
	self._pastComputing = true
	local diagnosticPull = frame == nil and commitState ~= true
	if diagnosticPull then
		self._host._pastPullDepth += 1
	end
	local values
	if self._kind == "source" then
		values = {}
		for _, item in ipairs(self._sourceHistory) do
			if item.time < cutoff or (inclusive and item.time == cutoff) then
				values[#values + 1] = item
			else
				break
			end
		end
	elseif self._pastCompute ~= nil then
		local ok, result = pcall(
			self._pastCompute,
			self,
			cutoff,
			inclusive,
			frame,
			commitState == true or frame ~= nil
		)
		if diagnosticPull then
			self._host._pastPullDepth -= 1
		end
		self._pastComputing = false
		if not ok then
			error(result, 0)
		end
		values = result or EMPTY
	else
		values = EMPTY
		if diagnosticPull then
			self._host._pastPullDepth -= 1
		end
	end
	if self._kind == "source" and diagnosticPull then
		self._host._pastPullDepth -= 1
	end
	self._pastComputing = false
	return values
end

function Event:_catchUp(cutoff)
	if self._catchUpCompute ~= nil then
		self._catchUpCompute(self, cutoff)
	end
end

function Event:getHost()
	return self._host
end

function Event:getDebugInfo()
	local dependents = 0
	for _ in next, self._dependents do
		dependents += 1
	end
	return {
		id = self._id,
		label = self._label,
		kind = self._kind,
		rank = self._rank,
		dependents = dependents,
	}
end

function Event:occurrences(untilTime)
	assertEvent(self, 2)
	local cutoff = untilTime
	if cutoff == nil then
		cutoff = self._host._time
	else
		assertFiniteTime(cutoff, "Event:occurrences time", 2)
		if cutoff > self._host._time then
			self._host:advanceTo(cutoff)
		end
	end
	local output = copyArray(self:_initial())
	for _, item in ipairs(self:_pastFinite(cutoff, true, nil)) do
		output[#output + 1] = item
	end
	return output
end

local function mapEvent(parent, mapper, options, withTime, label)
	options = options or {}
	return newEvent(parent._host, {
		label = options.label,
		parents = { parent },
		compute = function(_, frame)
			local output = {}
			for _, item in ipairs(parent:_evaluate(frame)) do
				local value = if withTime
					then call(label, mapper, item.value, item.time)
					else call(label, mapper, item.value)
				output[#output + 1] = mappedOccurrence(item, value)
			end
			return output
		end,
		computeInitial = function()
			local output = {}
			for _, item in ipairs(parent:_initial()) do
				local value = if withTime
					then call(label, mapper, item.value, item.time)
					else call(label, mapper, item.value)
				output[#output + 1] = mappedOccurrence(item, value)
			end
			return output
		end,
		pastCompute = function(_, cutoff, inclusive, frame, commitState)
			local output = {}
			for _, item in ipairs(parent:_pastFinite(cutoff, inclusive, frame, commitState)) do
				local value = if withTime
					then call(label, mapper, item.value, item.time)
					else call(label, mapper, item.value)
				output[#output + 1] = mappedOccurrence(item, value)
			end
			return output
		end,
		catchUpCompute = function()
			parent:_catchUp(parent._host._time)
		end,
	})
end

function Event:map(mapper, options)
	assertEvent(self, 2)
	if type(mapper) ~= "function" then
		error("Event:map requires a function", 2)
	end
	return mapEvent(self, mapper, options, false, "Event:map")
end

-- Explicit effect-boundary extension. Keeping occurrence time out of the
-- lawful Functor/Monad callbacks is necessary for Event associativity.
function Event:mapWithTime(mapper, options)
	assertEvent(self, 2)
	if type(mapper) ~= "function" then
		error("Event:mapWithTime requires a function", 2)
	end
	return mapEvent(self, mapper, options, true, "Event:mapWithTime")
end

function Event:filter(predicate, options)
	assertEvent(self, 2)
	if type(predicate) ~= "function" then
		error("Event:filter requires a predicate", 2)
	end
	options = options or {}
	local parent = self
	return newEvent(self._host, {
		label = options.label,
		parents = { parent },
		compute = function(_, frame)
			local output = {}
			for _, item in ipairs(parent:_evaluate(frame)) do
				if call("Event:filter", predicate, item.value) then
					output[#output + 1] = item
				end
			end
			return output
		end,
		computeInitial = function()
			local output = {}
			for _, item in ipairs(parent:_initial()) do
				if call("Event:filter", predicate, item.value) then
					output[#output + 1] = item
				end
			end
			return output
		end,
		pastCompute = function(_, cutoff, inclusive, frame, commitState)
			local output = {}
			for _, item in ipairs(parent:_pastFinite(cutoff, inclusive, frame, commitState)) do
				if call("Event:filter", predicate, item.value) then
					output[#output + 1] = item
				end
			end
			return output
		end,
		catchUpCompute = function()
			parent:_catchUp(parent._host._time)
		end,
	})
end

function Event:merge(other, options)
	assertEvent(self, 2)
	assertEvent(other, 2)
	assertSameHost(self, other, "Event:merge inputs", 2)
	options = options or {}
	local left = self
	local right = other
	return newEvent(self._host, {
		label = options.label,
		parents = { left, right },
		compute = function(_, frame)
			local output = copyArray(left:_evaluate(frame))
			for _, item in ipairs(right:_evaluate(frame)) do
				output[#output + 1] = item
			end
			return output
		end,
		computeInitial = function()
			local output = copyArray(left:_initial())
			for _, item in ipairs(right:_initial()) do
				output[#output + 1] = item
			end
			return output
		end,
		pastCompute = function(_, cutoff, inclusive, frame, commitState)
			return stableMerge(
				left:_pastFinite(cutoff, inclusive, frame, commitState),
				right:_pastFinite(cutoff, inclusive, frame, commitState)
			)
		end,
		catchUpCompute = function()
			left:_catchUp(left._host._time)
			right:_catchUp(right._host._time)
		end,
	})
end

function Event:scan(initialValue, reducer, options)
	assertEvent(self, 2)
	if type(reducer) ~= "function" then
		error("Event:scan requires a reducer", 2)
	end
	options = options or {}
	local parent = self
	local output
	output = newEvent(self._host, {
		label = options.label,
		parents = { parent },
		state = { value = initialValue },
		compute = function(event, frame)
			local staged = frame.stateCommits[event]
			local current = if staged ~= nil then staged.value else event._state.value
			local values = {}
			for _, item in ipairs(parent:_evaluate(frame)) do
				current = call("Event:scan", reducer, current, item.value)
				values[#values + 1] = mappedOccurrence(item, current)
			end
			frame.stateCommits[event] = { value = current }
			return values
		end,
		computeInitial = function(event)
			local current = event._state.value
			local values = {}
			for _, item in ipairs(parent:_initial()) do
				current = call("Event:scan", reducer, current, item.value)
				values[#values + 1] = mappedOccurrence(item, current)
			end
			event._state = { value = current }
			return values
		end,
		pastCompute = function(event, cutoff, inclusive, frame, commitState)
			local current = initialValue
			for _, item in ipairs(parent:_initial()) do
				current = call("Event:scan", reducer, current, item.value)
			end
			local values = {}
			for _, item in ipairs(parent:_pastFinite(cutoff, inclusive, frame, commitState)) do
				current = call("Event:scan", reducer, current, item.value)
				values[#values + 1] = mappedOccurrence(item, current)
			end
			if frame ~= nil and commitState then
				-- If the live current frame has already been evaluated, its state
				-- is newer than this strict past prefix and must not be overwritten.
				if event._memoFrame ~= frame.id then
					frame.stateCommits[event] = { value = current }
				end
			elseif commitState then
				event._state = { value = current }
			end
			return values
		end,
		catchUpCompute = function(event, cutoff)
			event:_pastFinite(cutoff, true, nil, true)
		end,
	})
	return output
end

function Event:bind(mapper, options)
	assertEvent(self, 2)
	if type(mapper) ~= "function" then
		error("Event:bind requires a function returning Event", 2)
	end
	options = options or {}
	local outer = self
	local output
	output = newEvent(self._host, {
		label = options.label,
		parents = { outer },
		always = true,
		state = { active = {} },
		compute = function(event, frame)
			local staged = frame.stateCommits[event]
			local active = copyArray(if staged ~= nil then staged.active else event._state.active)
			local values = {}
			for _, inner in ipairs(active) do
				for _, item in ipairs(inner:_evaluate(frame)) do
					values[#values + 1] = item
				end
			end
			for _, outerItem in ipairs(outer:_evaluate(frame)) do
				local inner = call("Event:bind", mapper, outerItem.value)
				assertEvent(inner, 2)
				assertSameHost(event, inner, "Event:bind result", 2)
				active[#active + 1] = inner
				for _, initialItem in ipairs(inner:_initial()) do
					values[#values + 1] = occurrence(outerItem.time, initialItem.value, outerItem.order)
				end
				for _, pastItem in ipairs(inner:_pastFinite(outerItem.time, false, frame)) do
					values[#values + 1] = occurrence(outerItem.time, pastItem.value, pastItem.order)
				end
				for _, item in ipairs(inner:_evaluate(frame)) do
					values[#values + 1] = occurrence(math.max(outerItem.time, item.time), item.value, item.order)
				end
			end
			frame.stateCommits[event] = { active = active }
			return values
		end,
		computeInitial = function(event)
			local active = {}
			local values = {}
			for _, outerItem in ipairs(outer:_initial()) do
				local inner = call("Event:bind", mapper, outerItem.value)
				assertEvent(inner, 2)
				assertSameHost(event, inner, "Event:bind result", 2)
				active[#active + 1] = inner
				for _, innerItem in ipairs(inner:_initial()) do
					values[#values + 1] = occurrence(
						math.max(outerItem.time, innerItem.time),
						innerItem.value,
						innerItem.order
					)
				end
			end
			event._state = { active = active }
			return values
		end,
		pastCompute = function(event, cutoff, inclusive, frame, commitState)
			local active = {}
			local output = {}
			local outerOccurrences = copyArray(outer:_initial())
			for _, item in ipairs(outer:_pastFinite(cutoff, inclusive, frame, commitState)) do
				outerOccurrences[#outerOccurrences + 1] = item
			end
			for _, outerItem in ipairs(outerOccurrences) do
				local inner = call("Event:bind", mapper, outerItem.value)
				assertEvent(inner, 2)
				assertSameHost(event, inner, "Event:bind result", 2)
				active[#active + 1] = inner
				local generated = {}
				for _, innerItem in ipairs(inner:_initial()) do
					local generatedTime = math.max(outerItem.time, innerItem.time)
					if generatedTime ~= NEG_INFINITY
						and (generatedTime < cutoff or (inclusive and generatedTime == cutoff))
					then
						generated[#generated + 1] = occurrence(
							generatedTime,
							innerItem.value,
							innerItem.order
						)
					end
				end
				for _, innerItem in ipairs(inner:_pastFinite(cutoff, inclusive, frame, commitState)) do
					local generatedTime = math.max(outerItem.time, innerItem.time)
					if generatedTime < cutoff or (inclusive and generatedTime == cutoff) then
						generated[#generated + 1] = occurrence(generatedTime, innerItem.value, innerItem.order)
					end
				end
				output = stableMerge(output, generated)
			end
			if frame ~= nil and commitState then
				if event._memoFrame ~= frame.id then
					frame.stateCommits[event] = { active = active }
				end
			elseif commitState then
				event._state = { active = active }
			end
			return output
		end,
		catchUpCompute = function(event, cutoff)
			event:_pastFinite(cutoff, true, nil, true)
		end,
	})
	return output
end

function Event:join(options)
	return self:bind(function(value)
		return value
	end, options)
end

function Event:ap(argument, options)
	assertEvent(argument, 2)
	assertSameHost(self, argument, "Event:ap inputs", 2)
	return self:bind(function(fn)
		if type(fn) ~= "function" then
			error("Event:ap function event produced a non-function", 0)
		end
		return argument:map(fn)
	end, options)
end

function Event:snapshot(behavior, combine, options)
	assertEvent(self, 2)
	assertBehavior(behavior, 2)
	assertSameHost(self, behavior, "Event:snapshot inputs", 2)
	if combine ~= nil and type(combine) ~= "function" then
		error("Event:snapshot combine must be a function", 2)
	end
	return self:mapWithTime(function(value, time)
		local sampled = behavior:at(time)
		if combine == nil then
			return { event = value, behavior = sampled }
		end
		return call("Event:snapshot", combine, value, sampled, time)
	end, options)
end

function Event:subscribe(callback, options)
	assertEvent(self, 2)
	if type(callback) ~= "function" then
		error("Event:subscribe requires a callback", 2)
	end
	options = options or {}
	local host = self._host
	-- Bring stateful, previously dormant combinators up to the closed Host
	-- frontier without replaying old occurrences to the new subscriber.
	self:_catchUp(host._time)
	host._nextSinkId += 1
	local sink = {
		_depKind = "eventSink",
		_id = host._nextSinkId,
		_priority = options.priority or 0,
		_event = self,
		_callback = callback,
		_active = true,
	}
	function sink:_markDirty(frame)
		if self._active then
			frame.dirtyEventSinks[self] = true
		end
	end
	host._eventSinks[sink] = true
	addDependent(self, sink)
	if options.initial ~= false then
		for _, item in ipairs(self:_initial()) do
			local ok, message = runNoYield(callback, item.value, item.time, item)
			if not ok then
				host:_reportError("event sink", message, { sinkId = sink._id, initial = true })
			end
		end
	end
	local stopped = false
	return function()
		if stopped then
			return
		end
		stopped = true
		sink._active = false
		host._eventSinks[sink] = nil
		if sink._event ~= nil then
			removeDependent(sink._event, sink)
		end
		sink._event = nil
		sink._callback = nil
	end
end

local function newReactive(host, initialValue, changes, options)
	assertHost(host, 3)
	assertEvent(changes, 3)
	assertSameHost({ _host = host }, changes, "Reactive changes", 3)
	options = options or {}
	host._nextNodeId += 1
	local history = { occurrence(NEG_INFINITY, initialValue, 0) }
	local current = initialValue
	for _, item in ipairs(changes:_initial()) do
		current = item.value
		history[#history + 1] = item
	end
	for _, item in ipairs(changes:_pastFinite(host._time, true, nil, true)) do
		current = item.value
		history[#history + 1] = item
	end
	local reactive = setmetatable({
		_tag = REACTIVE_TAG,
		_depKind = "reactive",
		_host = host,
		_id = host._nextNodeId,
		_label = options.label or ("reactive#" .. tostring(host._nextNodeId)),
		_changes = changes,
		_rank = changes._rank + 1,
		_initial = initialValue,
		_current = current,
		_history = history,
		_frameStartId = nil,
		_frameStartValue = nil,
	}, Reactive)
	function reactive:_markDirty(frame)
		frame.dirtyReactives[self] = true
	end
	host._reactives[reactive] = true
	addDependent(changes, reactive)
	return reactive
end

function Reactive:_frameStart(frame)
	if self._frameStartId == frame.id then
		return self._frameStartValue
	end
	return self._current
end

function Reactive:getHost()
	return self._host
end

function Reactive:changes()
	return self._changes
end

function Reactive:current()
	assertReactive(self, 2)
	return self._current
end

function Reactive:at(time)
	assertReactive(self, 2)
	assertFiniteTime(time, "Reactive:at time", 2)
	local visibleFrontier = self._host._time
	if self._host._activeFrame ~= nil then
		visibleFrontier = math.max(visibleFrontier, self._host._activeFrame.time)
	end
	if time > visibleFrontier then
		error("Reactive:at cannot inspect unprocessed future time; call Host:advanceTo first", 2)
	end
	local value = self._initial
	for _, item in ipairs(self._history) do
		if item.time < time then
			value = item.value
		else
			break
		end
	end
	return value
end

function Reactive:initial()
	assertReactive(self, 2)
	return self._initial
end

function Reactive:getDebugInfo()
	return {
		id = self._id,
		label = self._label,
		rank = self._rank,
		historyCount = #self._history,
		changeEvent = self._changes._id,
	}
end

function Reactive:map(mapper, options)
	assertReactive(self, 2)
	if type(mapper) ~= "function" then
		error("Reactive:map requires a function", 2)
	end
	local initial = call("Reactive:map", mapper, self._initial)
	return newReactive(self._host, initial, self._changes:map(mapper, options), options)
end

function Reactive:ap(argument, options)
	assertReactive(self, 2)
	assertReactive(argument, 2)
	assertSameHost(self, argument, "Reactive:ap inputs", 2)
	options = options or {}
	local functions = self
	local values = argument
	if type(functions._initial) ~= "function" then
		error("Reactive:ap function Reactive contains a non-function", 2)
	end
	local initial = call("Reactive:ap", functions._initial, values._initial)
	local changes = newEvent(self._host, {
		label = options.label and (options.label .. ".changes") or nil,
		parents = { functions._changes, values._changes },
		compute = function(_, frame)
			local fn = functions:_frameStart(frame)
			local value = values:_frameStart(frame)
			local output = {}
			for _, item in ipairs(functions._changes:_evaluate(frame)) do
				fn = item.value
				if type(fn) ~= "function" then
					error("Reactive:ap function Reactive produced a non-function", 0)
				end
				output[#output + 1] = mappedOccurrence(item, call("Reactive:ap", fn, value))
			end
			for _, item in ipairs(values._changes:_evaluate(frame)) do
				value = item.value
				output[#output + 1] = mappedOccurrence(item, call("Reactive:ap", fn, value))
			end
			return output
		end,
		computeInitial = function()
			local fn = functions._initial
			local value = values._initial
			local output = {}
			for _, item in ipairs(functions._changes:_initial()) do
				fn = item.value
				if type(fn) ~= "function" then
					error("Reactive:ap function Reactive produced a non-function", 0)
				end
				output[#output + 1] = mappedOccurrence(item, call("Reactive:ap", fn, value))
			end
			for _, item in ipairs(values._changes:_initial()) do
				value = item.value
				output[#output + 1] = mappedOccurrence(item, call("Reactive:ap", fn, value))
			end
			return output
		end,
		pastCompute = function(_, cutoff, inclusive, frame, commitState)
			local fn = functions._initial
			local value = values._initial
			for _, item in ipairs(functions._changes:_initial()) do
				fn = item.value
			end
			for _, item in ipairs(values._changes:_initial()) do
				value = item.value
			end
			local functionItems = functions._changes:_pastFinite(cutoff, inclusive, frame, commitState)
			local valueItems = values._changes:_pastFinite(cutoff, inclusive, frame, commitState)
			local output = {}
			local functionIndex = 1
			local valueIndex = 1
			while functionIndex <= #functionItems or valueIndex <= #valueItems do
				local functionItem = functionItems[functionIndex]
				local valueItem = valueItems[valueIndex]
				if valueItem == nil or (functionItem ~= nil and functionItem.time <= valueItem.time) then
					fn = functionItem.value
					if type(fn) ~= "function" then
						error("Reactive:ap function Reactive produced a non-function", 0)
					end
					output[#output + 1] = mappedOccurrence(functionItem, call("Reactive:ap", fn, value))
					functionIndex += 1
				else
					value = valueItem.value
					output[#output + 1] = mappedOccurrence(valueItem, call("Reactive:ap", fn, value))
					valueIndex += 1
				end
			end
			return output
		end,
		catchUpCompute = function()
			functions._changes:_catchUp(functions._host._time)
			values._changes:_catchUp(values._host._time)
		end,
	})
	return newReactive(self._host, initial, changes, options)
end

function Reactive:bind(mapper, options)
	assertReactive(self, 2)
	if type(mapper) ~= "function" then
		error("Reactive:bind requires a function returning Reactive", 2)
	end
	options = options or {}
	local outer = self
	local selected = call("Reactive:bind", mapper, outer._initial)
	assertReactive(selected, 2)
	assertSameHost(outer, selected, "Reactive:bind result", 2)
	local changes
	changes = newEvent(self._host, {
		label = options.label and (options.label .. ".changes") or nil,
		parents = { outer._changes },
		always = true,
		state = { selected = selected },
		compute = function(event, frame)
			local staged = frame.stateCommits[event]
			local currentInner = if staged ~= nil then staged.selected else event._state.selected
			local output = {}
			for _, item in ipairs(currentInner._changes:_evaluate(frame)) do
				output[#output + 1] = item
			end
			for _, outerItem in ipairs(outer._changes:_evaluate(frame)) do
				local inner = call("Reactive:bind", mapper, outerItem.value)
				assertReactive(inner, 2)
				assertSameHost(outer, inner, "Reactive:bind result", 2)
				currentInner = inner
				output[#output + 1] = occurrence(outerItem.time, inner:_frameStart(frame), outerItem.order)
				for _, innerItem in ipairs(inner._changes:_evaluate(frame)) do
					output[#output + 1] = occurrence(
						math.max(outerItem.time, innerItem.time),
						innerItem.value,
						innerItem.order
					)
				end
			end
			frame.stateCommits[event] = { selected = currentInner }
			return output
		end,
		computeInitial = function(event)
			local currentInner = selected
			local output = copyArray(currentInner._changes:_initial())
			for _, outerItem in ipairs(outer._changes:_initial()) do
				local inner = call("Reactive:bind", mapper, outerItem.value)
				assertReactive(inner, 2)
				assertSameHost(outer, inner, "Reactive:bind result", 2)
				currentInner = inner
				output[#output + 1] = occurrence(outerItem.time, inner._initial, outerItem.order)
				for _, innerItem in ipairs(inner._changes:_initial()) do
					output[#output + 1] = innerItem
				end
			end
			event._state = { selected = currentInner }
			return output
		end,
		pastCompute = function(event, cutoff, inclusive, frame, commitState)
			local outerValue = outer._initial
			for _, item in ipairs(outer._changes:_initial()) do
				outerValue = item.value
			end
			local currentInner = call("Reactive:bind", mapper, outerValue)
			assertReactive(currentInner, 2)
			assertSameHost(outer, currentInner, "Reactive:bind result", 2)

			local outerItems = outer._changes:_pastFinite(cutoff, inclusive, frame, commitState)
			local innerItems = currentInner._changes:_pastFinite(cutoff, inclusive, frame, commitState)
			local outerIndex = 1
			local innerIndex = 1
			local output = {}

			while outerIndex <= #outerItems or innerIndex <= #innerItems do
				local outerItem = outerItems[outerIndex]
				local innerItem = innerItems[innerIndex]
				if outerItem == nil or (innerItem ~= nil and innerItem.time <= outerItem.time) then
					output[#output + 1] = innerItem
					innerIndex += 1
				else
					currentInner = call("Reactive:bind", mapper, outerItem.value)
					assertReactive(currentInner, 2)
					assertSameHost(outer, currentInner, "Reactive:bind result", 2)
					output[#output + 1] = occurrence(
						outerItem.time,
						currentInner:at(outerItem.time),
						outerItem.order
					)
					innerItems = currentInner._changes:_pastFinite(cutoff, inclusive, frame, commitState)
					innerIndex = 1
					while innerIndex <= #innerItems and innerItems[innerIndex].time < outerItem.time do
						innerIndex += 1
					end
					outerIndex += 1
				end
			end
			if frame ~= nil and commitState then
				if event._memoFrame ~= frame.id then
					frame.stateCommits[event] = { selected = currentInner }
				end
			elseif commitState then
				event._state = { selected = currentInner }
			end
			return output
		end,
		catchUpCompute = function(event, cutoff)
			event:_pastFinite(cutoff, true, nil, true)
		end,
	})
	return newReactive(self._host, selected._initial, changes, options)
end

function Reactive:join(options)
	return self:bind(function(value)
		return value
	end, options)
end

function Reactive:switcher(event, options)
	assertEvent(event, 2)
	assertSameHost(self, event, "Reactive:switcher inputs", 2)
	return newReactive(self._host, self, event, options):join(options)
end

function Reactive:subscribe(callback, options)
	assertReactive(self, 2)
	options = options or {}
	local forwarded = {}
	for key, value in next, options do
		forwarded[key] = value
	end
	forwarded.initial = false
	-- Install the change edge before invoking the initial callback. A callback
	-- may synchronously cause the Host's first frame, and that occurrence must
	-- not fall into a subscription gap.
	local stop = self._changes:subscribe(callback, forwarded)
	if options.initial ~= false then
		local ok, message = runNoYield(callback, self._current, self._host._time, nil)
		if not ok then
			self._host:_reportError("reactive sink", message, { initial = true })
		end
	end
	return stop
end

function TimeFunction.constant(value)
	return setmetatable({
		_tag = TIME_FUNCTION_TAG,
		_kind = "constant",
		_value = value,
	}, TimeFunction)
end

function TimeFunction.dynamic(callback)
	if type(callback) ~= "function" then
		error("TimeFunction.dynamic requires a function", 2)
	end
	return setmetatable({
		_tag = TIME_FUNCTION_TAG,
		_kind = "dynamic",
		_callback = callback,
	}, TimeFunction)
end

function TimeFunction:isConstant()
	return self._kind == "constant"
end

function TimeFunction:apply(time)
	assertFiniteTime(time, "TimeFunction:apply time", 2)
	if self._kind == "constant" then
		return self._value
	end
	return call("TimeFunction", self._callback, time)
end

function TimeFunction:map(mapper)
	if type(mapper) ~= "function" then
		error("TimeFunction:map requires a function", 2)
	end
	if self._kind == "constant" then
		return TimeFunction.constant(call("TimeFunction:map", mapper, self._value))
	end
	local source = self
	return TimeFunction.dynamic(function(time)
		return call("TimeFunction:map", mapper, source:apply(time))
	end)
end

function TimeFunction:ap(argument)
	if type(argument) ~= "table" or argument._tag ~= TIME_FUNCTION_TAG then
		error("TimeFunction:ap requires a TimeFunction", 2)
	end
	if self._kind == "constant" and argument._kind == "constant" then
		if type(self._value) ~= "function" then
			error("TimeFunction:ap function value is not a function", 2)
		end
		return TimeFunction.constant(call("TimeFunction:ap", self._value, argument._value))
	end
	local functions = self
	return TimeFunction.dynamic(function(time)
		local fn = functions:apply(time)
		if type(fn) ~= "function" then
			error("TimeFunction:ap function value is not a function", 0)
		end
		return call("TimeFunction:ap", fn, argument:apply(time))
	end)
end

function TimeFunction:bind(mapper)
	if type(mapper) ~= "function" then
		error("TimeFunction:bind requires a function returning TimeFunction", 2)
	end
	if self._kind == "constant" then
		local inner = call("TimeFunction:bind", mapper, self._value)
		if type(inner) ~= "table" or inner._tag ~= TIME_FUNCTION_TAG then
			error("TimeFunction:bind callback must return a TimeFunction", 2)
		end
		return inner
	end
	local source = self
	return TimeFunction.dynamic(function(time)
		local inner = call("TimeFunction:bind", mapper, source:apply(time))
		if type(inner) ~= "table" or inner._tag ~= TIME_FUNCTION_TAG then
			error("TimeFunction:bind callback must return a TimeFunction", 0)
		end
		return inner:apply(time)
	end)
end

function TimeFunction:join()
	return self:bind(function(value)
		return value
	end)
end

local function newBehavior(phases, options)
	assertReactive(phases, 3)
	if type(phases._current) ~= "table" or phases._current._tag ~= TIME_FUNCTION_TAG then
		error("Behavior phases must be Reactive TimeFunctions", 3)
	end
	options = options or {}
	return setmetatable({
		_tag = BEHAVIOR_TAG,
		_host = phases._host,
		_phases = phases,
		_label = options.label,
	}, Behavior)
end

function Behavior:getHost()
	return self._host
end

function Behavior:phases()
	return self._phases
end

function Behavior:at(time)
	assertBehavior(self, 2)
	assertFiniteTime(time, "Behavior:at time", 2)
	return self._phases:at(time):apply(time)
end

function Behavior:current()
	assertBehavior(self, 2)
	return self._phases:current():apply(self._host._time)
end

function Behavior:map(mapper, options)
	assertBehavior(self, 2)
	if type(mapper) ~= "function" then
		error("Behavior:map requires a function", 2)
	end
	return newBehavior(self._phases:map(function(timeFunction)
		return timeFunction:map(mapper)
	end, options), options)
end

function Behavior:ap(argument, options)
	assertBehavior(self, 2)
	assertBehavior(argument, 2)
	assertSameHost(self, argument, "Behavior:ap inputs", 2)
	local phases = self._phases:map(function(functionPhase)
		return function(argumentPhase)
			return functionPhase:ap(argumentPhase)
		end
	end, options):ap(argument._phases, options)
	return newBehavior(phases, options)
end

function Behavior:switcher(event, options)
	assertBehavior(self, 2)
	assertEvent(event, 2)
	assertSameHost(self, event, "Behavior:switcher inputs", 2)
	local phaseEvent = event:map(function(behavior)
		assertBehavior(behavior, 2)
		assertSameHost(self, behavior, "Behavior:switcher phase", 2)
		return behavior._phases
	end, options)
	return newBehavior(self._phases:switcher(phaseEvent, options), options)
end

function Behavior:subscribe(callback, options)
	assertBehavior(self, 2)
	if type(callback) ~= "function" then
		error("Behavior:subscribe requires a callback", 2)
	end
	options = options or {}
	local host = self._host
	host._nextSinkId += 1
	local initialPhase = self._phases:current()
	local wantsInitial = options.initial ~= false
	-- `initial = false` is a demand boundary: do not pull an expensive or
	-- failing dynamic TimeFunction merely to initialize unused sink metadata.
	local initial = if wantsInitial then initialPhase:apply(host._time) else nil
	local sink = {
		_depKind = "behaviorSink",
		_id = host._nextSinkId,
		_priority = options.priority or 0,
		_behavior = self,
		_callback = callback,
		_lastValue = initial,
		_lastPhase = initialPhase,
		_hasValue = wantsInitial,
		_active = true,
	}
	function sink:_markDirty(frame)
		if self._active then
			frame.dirtyBehaviorSinks[self] = true
		end
	end
	host._behaviorSinks[sink] = true
	addDependent(self._phases._changes, sink)
	if wantsInitial then
		local ok, message = runNoYield(callback, initial, host._time, nil)
		if not ok then
			host:_reportError("behavior sink", message, { sinkId = sink._id, initial = true })
		end
	end
	local stopped = false
	return function()
		if stopped then
			return
		end
		stopped = true
		sink._active = false
		host._behaviorSinks[sink] = nil
		if sink._behavior ~= nil then
			removeDependent(sink._behavior._phases._changes, sink)
		end
		sink._behavior = nil
		sink._callback = nil
		sink._lastValue = nil
		sink._lastPhase = nil
	end
end

local function newFutureAt(time, value, never)
	return setmetatable({
		_tag = FUTURE_TAG,
		_time = time,
		_value = value,
		_never = never == true,
	}, Future)
end

function Future.at(time, value)
	assertFiniteTime(time, "Future time", 2)
	return newFutureAt(time, value, false)
end

function Future.never()
	return newFutureAt(POS_INFINITY, nil, true)
end

function Future.pure(value)
	return newFutureAt(NEG_INFINITY, value, false)
end

function Future:isNever()
	return self._never
end

function Future:force()
	assertFuture(self, 2)
	return self._time, self._value
end

function Future:map(mapper)
	assertFuture(self, 2)
	if type(mapper) ~= "function" then
		error("Future:map requires a function", 2)
	end
	if self._never then
		return Future.never()
	end
	return newFutureAt(self._time, call("Future:map", mapper, self._value), false)
end

function Future:ap(argument)
	assertFuture(self, 2)
	assertFuture(argument, 2)
	if self._never or argument._never then
		return Future.never()
	end
	if type(self._value) ~= "function" then
		error("Future:ap function Future contains a non-function", 2)
	end
	return newFutureAt(math.max(self._time, argument._time), call("Future:ap", self._value, argument._value), false)
end

function Future:bind(mapper)
	assertFuture(self, 2)
	if type(mapper) ~= "function" then
		error("Future:bind requires a function returning Future", 2)
	end
	if self._never then
		return Future.never()
	end
	local inner = call("Future:bind", mapper, self._value)
	assertFuture(inner, 2)
	if inner._never then
		return Future.never()
	end
	return newFutureAt(math.max(self._time, inner._time), inner._value, false)
end

function Future:join()
	return self:bind(function(value)
		return value
	end)
end

function Future:earlier(other)
	assertFuture(self, 2)
	assertFuture(other, 2)
	if self._time <= other._time then
		return self
	end
	return other
end

function Future:getTime()
	return self._time
end

function Future:getValue()
	return self._value
end

function Host:_reportError(kind, message, details)
	if self._onError ~= nil then
		local ok = pcall(self._onError, kind, message, details)
		if ok then
			return
		end
	end
	if self._errors ~= nil then
		self._errors[#self._errors + 1] = {
			kind = kind,
			message = tostring(message),
			details = details,
		}
	end
end

function Host:_appendSource(event, value, frame)
	self:_markRootDirty(event, frame)
	local values = frame.sourceInputs[event]
	if values == nil then
		values = {}
		frame.sourceInputs[event] = values
	end
	frame.nextOccurrenceOrder += 1
	values[#values + 1] = occurrence(frame.time, value, frame.nextOccurrenceOrder)
end

function Host:_markRootDirty(event, frame)
	if not frame.hasInput then
		frame.hasInput = true
		for alwaysEvent in next, self._alwaysEvents do
			alwaysEvent:_markDirty(frame)
		end
	end
	event:_markDirty(frame)
end

function Host:_fire(event, value, time)
	assertHost(self, 3)
	assertEvent(event, 3)
	assertSameHost({ _host = self }, event, "source Event", 3)
	if event._kind ~= "source" then
		error("only source Events can be fired", 3)
	end
	if time ~= nil then
		assertFiniteTime(time, "source occurrence time", 3)
	end
	if self._phase == "collecting" then
		if time ~= nil and time ~= self._activeFrame.time then
			error("source occurrence time must equal the active frame time", 3)
		end
		self:_appendSource(event, value, self._activeFrame)
		return
	elseif self._phase == "delivering" then
		local occurrenceTime = time or self._time
		if occurrenceTime < self._time then
			error("source occurrence time cannot move Host time backwards", 3)
		elseif occurrenceTime > self._time then
			self:_schedule(event, occurrenceTime, value)
		else
			error("source occurrence cannot reopen an already closed logical time; schedule a future time", 3)
		end
		return
	elseif self._phase ~= "idle" then
		error("source Events cannot fire during FRP phase '" .. self._phase .. "'", 3)
	end
	local occurrenceTime = time or self._time
	if occurrenceTime < self._time then
		error("source occurrence time cannot move Host time backwards", 3)
	elseif occurrenceTime == self._time and self._hasClosedFrame then
		error("source occurrence cannot reopen an already closed logical time; use one Host:frame", 3)
	elseif occurrenceTime > self._time then
		self:_schedule(event, occurrenceTime, value)
		return
	end
	self:frame(occurrenceTime, function()
		self:_appendSource(event, value, self._activeFrame)
	end)
end

local function endpointLess(left, right)
	if left._priority ~= right._priority then
		return left._priority < right._priority
	end
	return left._id < right._id
end

local function reactiveLess(left, right)
	if left._rank ~= right._rank then
		return left._rank < right._rank
	end
	return left._id < right._id
end

function Host:_prepareAndCommit(frame)
	self._phase = "preparing"
	for reactive in next, self._reactives do
		reactive._frameStartId = frame.id
		reactive._frameStartValue = reactive._current
	end
	if frame.time ~= self._time then
		for sink in next, self._behaviorSinks do
			if sink._active then
				frame.dirtyBehaviorSinks[sink] = true
			end
		end
	end

	-- Reactive Monad callbacks may construct an inner Reactive while this frame
	-- is being prepared. addDependent marks it dirty immediately, so drain a
	-- rank-ordered fixed-point worklist instead of snapshotting dirty nodes once.
	local processedReactives = {}
	while true do
		local reactives = {}
		for reactive in next, frame.dirtyReactives do
			if not processedReactives[reactive] then
				reactives[#reactives + 1] = reactive
			end
		end
		if #reactives == 0 then
			break
		end
		table.sort(reactives, reactiveLess)
		for _, reactive in ipairs(reactives) do
			processedReactives[reactive] = true
			local values = reactive._changes:_evaluate(frame)
			if #values > 0 then
				frame.reactiveCommits[reactive] = {
					current = values[#values].value,
					occurrences = values,
				}
			end
		end
	end

	local eventSinks = {}
	for sink in next, frame.dirtyEventSinks do
		if sink._active then
			eventSinks[#eventSinks + 1] = sink
		end
	end
	table.sort(eventSinks, endpointLess)
	for _, sink in ipairs(eventSinks) do
		frame.eventDeliveries[#frame.eventDeliveries + 1] = {
			sink = sink,
			occurrences = sink._event:_evaluate(frame),
		}
	end

	local behaviorSinks = {}
	for sink in next, frame.dirtyBehaviorSinks do
		if sink._active then
			behaviorSinks[#behaviorSinks + 1] = sink
		end
	end
	table.sort(behaviorSinks, endpointLess)
	for _, sink in ipairs(behaviorSinks) do
		local phases = sink._behavior._phases
		local staged = frame.reactiveCommits[phases]
		if staged ~= nil and #staged.occurrences > 0 then
			-- A Reactive phase can change more than once at one logical time.
			-- Preserve every occurrence (including duplicate/same-object phases),
			-- matching the paper's sink_R phase-by-phase switching semantics.
			for _, phaseOccurrence in ipairs(staged.occurrences) do
				local timeFunction = phaseOccurrence.value
				frame.behaviorDeliveries[#frame.behaviorDeliveries + 1] = {
					sink = sink,
					value = timeFunction:apply(frame.time),
					phase = timeFunction,
					occurrence = phaseOccurrence,
				}
			end
		else
			local timeFunction = phases._current
			if frame.time ~= self._time and timeFunction._kind == "dynamic" then
					frame.behaviorDeliveries[#frame.behaviorDeliveries + 1] = {
						sink = sink,
						value = timeFunction:apply(frame.time),
						phase = timeFunction,
					}
			end
		end
	end

	self._phase = "committing"
	for event, state in next, frame.stateCommits do
		event._state = state
	end
	for event, values in next, frame.sourceInputs do
		for _, item in ipairs(values) do
			event._sourceHistory[#event._sourceHistory + 1] = item
		end
	end
	for reactive, staged in next, frame.reactiveCommits do
		for _, item in ipairs(staged.occurrences) do
			reactive._history[#reactive._history + 1] = item
		end
		reactive._current = staged.current
	end
	for _, entry in ipairs(frame.scheduleAdds) do
		self:_insertScheduled(entry)
	end
	self._time = frame.time
	self._hasClosedFrame = true
	for _, delivery in ipairs(frame.behaviorDeliveries) do
		delivery.sink._lastValue = delivery.value
		delivery.sink._lastPhase = delivery.phase
		delivery.sink._hasValue = true
	end

	self._phase = "delivering"
	for _, delivery in ipairs(frame.eventDeliveries) do
		if delivery.sink._active then
			for _, item in ipairs(delivery.occurrences) do
				local ok, message = runNoYield(delivery.sink._callback, item.value, item.time, item)
				if not ok then
					self:_reportError("event sink", message, { sinkId = delivery.sink._id, time = item.time })
				end
			end
		end
	end
	for _, delivery in ipairs(frame.behaviorDeliveries) do
		if delivery.sink._active then
			local metadata = {
				time = frame.time,
				frameId = frame.id,
				phaseOccurrence = delivery.occurrence,
			}
			local ok, message = runNoYield(
				delivery.sink._callback,
				delivery.value,
				frame.time,
				metadata
			)
			if not ok then
				self:_reportError("behavior sink", message, { sinkId = delivery.sink._id, time = frame.time })
			end
		end
	end
	self._phase = "idle"
end

function Host:_newFrame(time)
	self._nextFrameId += 1
	return {
		id = self._nextFrameId,
		time = time,
		sourceInputs = {},
		hasInput = false,
		nextOccurrenceOrder = 0,
		dirtyReactives = {},
		dirtyEventSinks = {},
		dirtyBehaviorSinks = {},
		stateCommits = {},
		reactiveCommits = {},
		eventDeliveries = {},
		behaviorDeliveries = {},
		scheduleAdds = {},
	}
end

function Host:frame(time, callback)
	assertHost(self, 2)
	assertFiniteTime(time, "Host:frame time", 2)
	if time < self._time then
		error("Host:frame time must be monotonic", 2)
	end
	if self._phase ~= "idle" then
		error("Host:frame cannot start during FRP phase '" .. self._phase .. "'", 2)
	end
	if time == self._time and self._hasClosedFrame then
		error("Host:frame cannot reopen an already closed logical time", 2)
	end
	if callback ~= nil and type(callback) ~= "function" then
		error("Host:frame callback must be a function", 2)
	end
	-- A direct engine barrier may jump over scheduled Futures. Close every
	-- earlier time first, then coalesce the exact-time scheduled roots with the
	-- caller's roots so a logical time is committed exactly once.
	while #self._scheduled > 0 and self._scheduled[1].time < time do
		self:frame(self._scheduled[1].time)
	end
	local scheduledGroup = {}
	local scheduledIndex = 1
	while scheduledIndex <= #self._scheduled and self._scheduled[scheduledIndex].time == time do
		scheduledGroup[#scheduledGroup + 1] = self._scheduled[scheduledIndex]
		scheduledIndex += 1
	end
	local frame = self:_newFrame(time)
	self._activeFrame = frame
	self._phase = "collecting"
	for _, entry in ipairs(scheduledGroup) do
		if entry.kind == "wake" then
			self:_markRootDirty(entry.event, frame)
		else
			self:_appendSource(entry.event, entry.value, frame)
		end
	end
	if callback ~= nil then
		local ok, message = runNoYield(callback, frame)
		if not ok then
			self._activeFrame = nil
			self._phase = "idle"
			error("FRP frame collection failed: " .. tostring(message), 2)
		end
	end
	local ok, message = pcall(self._prepareAndCommit, self, frame)
	self._activeFrame = nil
	if not ok then
		self._phase = "idle"
		error("FRP frame at time " .. tostring(time) .. " aborted: " .. tostring(message), 2)
	end
	for _ = 1, #scheduledGroup do
		table.remove(self._scheduled, 1)
	end
	return { id = frame.id, time = time, occurrenceCount = frame.nextOccurrenceOrder }
end

function Host:_insertScheduled(entry)
	self._scheduled[#self._scheduled + 1] = entry
	table.sort(self._scheduled, function(left, right)
		if left.time ~= right.time then
			return left.time < right.time
		end
		return left.id < right.id
	end)
end

function Host:_stageSchedule(entry)
	local frame = self._activeFrame
	if frame ~= nil and (self._phase == "collecting" or self._phase == "preparing") then
		frame.scheduleAdds[#frame.scheduleAdds + 1] = entry
	else
		self:_insertScheduled(entry)
	end
end

function Host:_schedule(event, time, value)
	if time < self._time or (time == self._time and self._hasClosedFrame) then
		error("scheduled occurrence must be later than the closed Host frontier", 3)
	end
	local frame = self._activeFrame
	if frame ~= nil and (self._phase == "collecting" or self._phase == "preparing") then
		if time < frame.time then
			error("scheduled source occurrence cannot precede the active frame", 3)
		elseif time == frame.time then
			self:_appendSource(event, value, frame)
			return
		end
	end
	self._nextScheduleId += 1
	self:_stageSchedule({
		id = self._nextScheduleId,
		kind = "source",
		time = time,
		event = event,
		value = value,
	})
end

function Host:_scheduleWake(event, time)
	local frame = self._activeFrame
	if frame ~= nil and (self._phase == "collecting" or self._phase == "preparing") then
		if time < frame.time then
			return
		elseif time == frame.time then
			self:_markRootDirty(event, frame)
			return
		end
	elseif time < self._time or (time == self._time and self._hasClosedFrame) then
		return
	end
	self._nextScheduleId += 1
	self:_stageSchedule({
		id = self._nextScheduleId,
		kind = "wake",
		time = time,
		event = event,
	})
end

function Host:advanceTo(time)
	assertHost(self, 2)
	assertFiniteTime(time, "Host:advanceTo time", 2)
	if time < self._time then
		error("Host:advanceTo time must be monotonic", 2)
	end
	while #self._scheduled > 0 and self._scheduled[1].time <= time do
		self:frame(self._scheduled[1].time)
	end
	if time > self._time or (time == self._time and not self._hasClosedFrame) then
		self:frame(time)
	end
	return self._time
end

function Host:source(options)
	assertHost(self, 2)
	options = options or {}
	local event = newEvent(self, {
		label = options.label,
		kind = "source",
	})
	local function fire(value, time)
		return self:_fire(event, value, time)
	end
	return event, fire
end

function Host:eventFromFuture(future, options)
	assertHost(self, 2)
	assertFuture(future, 2)
	if future._never then
		return FRP.never(self, options)
	elseif future._time == NEG_INFINITY then
		return FRP.eventPure(self, future._value, options)
	end
	return self:eventFromOccurrences({
		{ time = future._time, value = future._value },
	}, options)
end

function Host:eventFromOccurrences(entries, options)
	assertHost(self, 2)
	if type(entries) ~= "table" then
		error("Host:eventFromOccurrences entries must be an array", 2)
	end
	local normalized = {}
	local previousTime = NEG_INFINITY
	for index, entry in ipairs(entries) do
		if type(entry) ~= "table" then
			error("occurrence #" .. tostring(index) .. " must be a table", 2)
		end
		local time = entry.time
		if time == nil then
			time = entry[1]
		end
		local value = entry.value
		if entry.value == nil and entry[2] ~= nil then
			value = entry[2]
		end
		assertFiniteTime(time, "occurrence #" .. tostring(index) .. " time", 2)
		if time < previousTime then
			error("Event occurrences must be in nondecreasing time order", 2)
		end
		previousTime = time
		normalized[#normalized + 1] = occurrence(time, value, index)
	end
	local event = newEvent(self, {
		label = options and options.label,
		kind = "scheduled",
		compute = function(_, frame)
			local output = {}
			for _, item in ipairs(normalized) do
				if item.time == frame.time then
					output[#output + 1] = item
				elseif item.time > frame.time then
					break
				end
			end
			return output
		end,
		pastCompute = function(_, cutoff, inclusive)
			local output = {}
			for _, item in ipairs(normalized) do
				if item.time < cutoff or (inclusive and item.time == cutoff) then
					output[#output + 1] = item
				else
					break
				end
			end
			return output
		end,
	})
	local previousWake = nil
	for _, entry in ipairs(normalized) do
		if entry.time ~= previousWake and self._pastPullDepth == 0 then
			self:_scheduleWake(event, entry.time)
			previousWake = entry.time
		end
	end
	return event
end

function Host:sample(behavior, time)
	assertHost(self, 2)
	assertBehavior(behavior, 2)
	assertSameHost({ _host = self }, behavior, "Host:sample Behavior", 2)
	local sampleTime = time or self._time
	if sampleTime > self._time then
		self:advanceTo(sampleTime)
	end
	return behavior:at(sampleTime)
end

function Host:now()
	assertHost(self, 2)
	return self._time
end

function Host:getErrors()
	return copyArray(self._errors)
end

function Host:dispose()
	if self._phase == "disposed" then
		return
	end
	if self._phase ~= "idle" then
		error("Host:dispose requires an idle Host", 2)
	end
	for sink in next, self._eventSinks do
		sink._active = false
		if sink._event ~= nil then
			removeDependent(sink._event, sink)
		end
		sink._event = nil
		sink._callback = nil
	end
	for sink in next, self._behaviorSinks do
		sink._active = false
		if sink._behavior ~= nil then
			removeDependent(sink._behavior._phases._changes, sink)
		end
		sink._behavior = nil
		sink._callback = nil
		sink._lastValue = nil
		sink._lastPhase = nil
	end
	-- A disposed Host is an ownership boundary. Break the graph edges and clear
	-- denotational prefixes so callbacks and captured game objects are not kept
	-- alive by user-held, now-invalid FRP handles.
	for event in next, self._events do
		event._dependents = {}
		event._parents = {}
		event._sourceHistory = {}
		event._initialOccurrences = nil
		event._memo = nil
		event._state = nil
		event._compute = nil
		event._computeInitial = nil
		event._pastCompute = nil
		event._catchUpCompute = nil
	end
	for reactive in next, self._reactives do
		reactive._history = {}
		reactive._changes = nil
		reactive._initial = nil
		reactive._current = nil
		reactive._frameStartValue = nil
	end
	self._eventSinks = {}
	self._behaviorSinks = {}
	self._events = {}
	self._reactives = {}
	self._alwaysEvents = {}
	self._scheduled = {}
	self._activeFrame = nil
	self._onError = nil
	self._errors = {}
	self._phase = "disposed"
end

function Host:Destroy()
	return self:dispose()
end

function FRP.newHost(options)
	options = options or {}
	local startTime = options.startTime or 0
	assertFiniteTime(startTime, "FRP Host startTime", 2)
	return setmetatable({
		_tag = HOST_TAG,
		_time = startTime,
		_hasClosedFrame = false,
		_phase = "idle",
		_activeFrame = nil,
		_nextNodeId = 0,
		_nextSinkId = 0,
		_nextFrameId = 0,
		_nextScheduleId = 0,
		_events = setmetatable({}, { __mode = "k" }),
		_reactives = setmetatable({}, { __mode = "k" }),
		_eventSinks = {},
		_behaviorSinks = {},
		_alwaysEvents = setmetatable({}, { __mode = "k" }),
		_scheduled = {},
		_pastPullDepth = 0,
		_errors = {},
		_onError = options.onError,
	}, Host)
end

function FRP.never(host, options)
	return newEvent(host, {
		label = options and options.label,
		kind = "never",
	})
end

function FRP.eventPure(host, value, options)
	return newEvent(host, {
		label = options and options.label,
		kind = "pure",
		computeInitial = function()
			return { occurrence(NEG_INFINITY, value, 0) }
		end,
	})
end

function FRP.reactivePure(host, value, options)
	return newReactive(host, value, FRP.never(host), options)
end

function FRP.stepper(initialValue, event, options)
	assertEvent(event, 2)
	return newReactive(event._host, initialValue, event, options)
end

function FRP.switcher(initialReactive, event, options)
	assertReactive(initialReactive, 2)
	return initialReactive:switcher(event, options)
end

function FRP.accumReactive(initialValue, eventOfFunctions, options)
	assertEvent(eventOfFunctions, 2)
	local changes = eventOfFunctions:scan(initialValue, function(current, update)
		if type(update) ~= "function" then
			error("accumReactive event must contain functions", 0)
		end
		return call("accumReactive", update, current)
	end, options)
	return FRP.stepper(initialValue, changes, options)
end

function FRP.accumEvent(initialValue, eventOfFunctions, options)
	assertEvent(eventOfFunctions, 2)
	return eventOfFunctions:scan(initialValue, function(current, update)
		if type(update) ~= "function" then
			error("accumEvent event must contain functions", 0)
		end
		return call("accumEvent", update, current)
	end, options)
end

function FRP.constant(host, value, options)
	return newBehavior(FRP.reactivePure(host, TimeFunction.constant(value), options), options)
end

function FRP.fromFunction(host, callback, options)
	return newBehavior(FRP.reactivePure(host, TimeFunction.dynamic(callback), options), options)
end

function FRP.time(host, options)
	return FRP.fromFunction(host, function(time)
		return time
	end, options)
end

function FRP.stepperBehavior(initialValue, event, options)
	assertEvent(event, 2)
	local phaseChanges = event:map(TimeFunction.constant, options)
	return newBehavior(FRP.stepper(TimeFunction.constant(initialValue), phaseChanges, options), options)
end

function FRP.switcherBehavior(initialBehavior, event, options)
	assertBehavior(initialBehavior, 2)
	return initialBehavior:switcher(event, options)
end

function FRP.accumBehavior(initialValue, eventOfFunctions, options)
	local reactive = FRP.accumReactive(initialValue, eventOfFunctions, options)
	return newBehavior(reactive:map(TimeFunction.constant, options), options)
end

function FRP.lift2(callback, left, right, options)
	if type(callback) ~= "function" then
		error("FRP.lift2 requires a function", 2)
	end
	assertBehavior(left, 2)
	assertBehavior(right, 2)
	return left:map(function(leftValue)
		return function(rightValue)
			return call("FRP.lift2", callback, leftValue, rightValue)
		end
	end, options):ap(right, options)
end

function FRP.lift3(callback, first, second, third, options)
	return FRP.lift2(function(fn, value)
		return fn(value)
	end, FRP.lift2(function(a, b)
		return function(c)
			return call("FRP.lift3", callback, a, b, c)
		end
	end, first, second, options), third, options)
end

function FRP.once(host, time, value, options)
	assertHost(host, 2)
	return host:eventFromFuture(Future.at(time, value), options)
end

function FRP.fromOccurrences(host, entries, options)
	assertHost(host, 2)
	return host:eventFromOccurrences(entries, options)
end

function FRP.isHost(value)
	return type(value) == "table" and value._tag == HOST_TAG
end

function FRP.isEvent(value)
	return type(value) == "table" and value._tag == EVENT_TAG
end

function FRP.isReactive(value)
	return type(value) == "table" and value._tag == REACTIVE_TAG
end

function FRP.isBehavior(value)
	return type(value) == "table" and value._tag == BEHAVIOR_TAG
end

function FRP.isFuture(value)
	return type(value) == "table" and value._tag == FUTURE_TAG
end

FRP.Host = Host
FRP.Event = Event
FRP.Reactive = Reactive
FRP.Behavior = Behavior
FRP.Future = Future
FRP.TimeFunction = TimeFunction
FRP.NEG_INFINITY = NEG_INFINITY
FRP.POS_INFINITY = POS_INFINITY

-- Namespace-style constructors mirror the paper's type-directed operations.
-- Existing instance methods remain available, so Event.map(event, f) and
-- event:map(f) are equivalent without emulating Haskell typeclasses.
Event.never = FRP.never
Event.pure = FRP.eventPure
Event.once = FRP.once
Event.fromOccurrences = FRP.fromOccurrences
Event.source = function(host, options)
	return host:source(options)
end
Event.fromFuture = function(host, future, options)
	return host:eventFromFuture(future, options)
end

Reactive.pure = FRP.reactivePure
Reactive.stepper = FRP.stepper
Reactive.switch = FRP.switcher
Reactive.accum = FRP.accumReactive

Behavior.pure = FRP.constant
Behavior.constant = FRP.constant
Behavior.fromFunction = FRP.fromFunction
Behavior.time = FRP.time
Behavior.stepper = FRP.stepperBehavior
Behavior.switch = FRP.switcherBehavior
Behavior.accum = FRP.accumBehavior
Behavior.lift2 = FRP.lift2
Behavior.lift3 = FRP.lift3

TimeFunction.pure = TimeFunction.constant
TimeFunction.fromFunction = TimeFunction.dynamic

Future.alt = Future.earlier

return FRP
