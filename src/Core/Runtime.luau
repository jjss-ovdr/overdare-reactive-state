--!nonstrict

-- ReactiveState's engine-neutral core. Every durable piece of graph,
-- transaction, timeline, and scheduling state belongs to a Runtime instance.
-- The only module-local execution context is a synchronous computation frame;
-- it exists so a Source can reject a read from a different Runtime. Computed
-- getters are not allowed to yield, so that frame never survives a call.

local Codec
local Hash

if script ~= nil then
	Codec = require(script.Parent.Codec)
	Hash = require(script.Parent.Hash)
else
	Codec = require("./Codec")
	Hash = require("./Hash")
end

local Runtime = {}
Runtime.__index = Runtime

local Atom = {}
Atom.__index = Atom

local Computed = {}
Computed.__index = Computed

local Scope = {}
Scope.__index = Scope

local Store = {}
Store.__index = Store

local ReadonlySource = {}
ReadonlySource.__index = ReadonlySource

local RUNTIME_TAG = {}
local NIL = {}
local CLEAN = "clean"
local DIRTY = "dirty"
local PENDING = "pending"
local EVALUATION_DEPTH_MESSAGE = "ReactiveState Computed evaluation depth limit"

-- Computations are synchronous and non-yielding. A short-lived shared frame
-- lets a Source notice cross-Runtime reads without putting graph state in a
-- module singleton.
local ACTIVE_COMPUTATION = nil

local function pack(...)
	return { n = select("#", ...), ... }
end

local function unpackPacked(values, first)
	return table.unpack(values, first or 1, values.n)
end

local function box(value)
	if value == nil then
		return NIL
	end
	return value
end

local function unbox(value)
	if value == NIL then
		return nil
	end
	return value
end

local function sameValue(left, right)
	if rawequal(left, right) then
		return true
	end
	return type(left) == "number" and type(right) == "number" and left ~= left and right ~= right
end

local function isFinite(value)
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function assertInteger(value, label, minimum, level)
	if not isFinite(value) or value % 1 ~= 0 or value < minimum then
		error(label .. " must be an integer >= " .. tostring(minimum), level or 3)
	end
	return value
end

local function copyTable(source)
	local result = {}
	if source ~= nil then
		for key, value in next, source do
			result[key] = value
		end
	end
	return result
end

local function historyCount(history)
	return if history == nil then 0 else history.count
end

local function historySlot(history, offset)
	return (history.head + offset - 2) % history.capacity + 1
end

local function storeHistorySnapshot(history, snapshot)
	local existingSlot = history.byTick[snapshot.tick]
	if existingSlot ~= nil then
		history.entries[existingSlot] = snapshot
		return
	end

	local slot
	if history.count < history.capacity then
		history.count += 1
		slot = historySlot(history, history.count)
	else
		slot = history.head
		local evicted = history.entries[slot]
		if evicted ~= nil then
			history.byTick[evicted.tick] = nil
		end
		history.head = history.head % history.capacity + 1
	end
	local previous = history.entries[slot]
	if previous ~= nil then
		history.byTick[previous.tick] = nil
	end
	history.entries[slot] = snapshot
	history.byTick[snapshot.tick] = slot
end

local function chronologicalHistory(history)
	local entries = {}
	if history == nil then
		return entries
	end
	for offset = 1, history.count do
		entries[offset] = history.entries[historySlot(history, offset)]
	end
	return entries
end

local function resetHistory(history, chronologicalEntries)
	history.entries = {}
	history.byTick = {}
	history.head = 1
	history.count = 0
	for _, snapshot in ipairs(chronologicalEntries) do
		storeHistorySnapshot(history, snapshot)
	end
end

local function cloneHistoryStorage(history)
	return {
		entries = copyTable(history.entries),
		byTick = copyTable(history.byTick),
		head = history.head,
		count = history.count,
	}
end

local function restoreHistoryStorage(history, backup)
	history.entries = backup.entries
	history.byTick = backup.byTick
	history.head = backup.head
	history.count = backup.count
end

local function runNoYield(callback, ...)
	local arguments = pack(...)
	local thread = coroutine.create(function()
		return callback(unpackPacked(arguments))
	end)
	local resumed = pack(coroutine.resume(thread))
	if not resumed[1] then
		return false, resumed[2]
	end
	if coroutine.status(thread) ~= "dead" then
		return false, "ReactiveState callback yielded; reactive callbacks must finish synchronously"
	end
	return true, unpackPacked(resumed, 2)
end

local function callableResult(callback, label, ...)
	local results = pack(runNoYield(callback, ...))
	if not results[1] then
		error(label .. " failed: " .. tostring(results[2]), 3)
	end
	return unpackPacked(results, 2)
end

local function readMember(target, key)
	if target == nil then
		return nil
	end
	local ok, value = pcall(function()
		return target[key]
	end)
	return if ok then value else nil
end

local function disposeOne(disposable)
	if type(disposable) == "function" then
		disposable()
	elseif disposable ~= nil then
		local dispose = readMember(disposable, "dispose")
		local destroy = readMember(disposable, "Destroy")
		local disconnect = readMember(disposable, "Disconnect")
		local lowerDestroy = readMember(disposable, "destroy")
		if type(dispose) == "function" then
			disposable:dispose()
		elseif destroy ~= nil then
			disposable:Destroy()
		elseif disconnect ~= nil then
			disposable:Disconnect()
		elseif type(lowerDestroy) == "function" then
			disposable:destroy()
		else
			local disconnected, disconnectError = pcall(function()
				disposable:Disconnect()
			end)
			if disconnected then
				return
			end
			local destroyed, destroyError = pcall(function()
				disposable:Destroy()
			end)
			if not destroyed then
				error(
					"disposable must provide dispose, Destroy, Disconnect, or destroy (Disconnect: "
						.. tostring(disconnectError)
						.. "; Destroy: "
						.. tostring(destroyError)
						.. ")",
					3
				)
			end
		end
	else
		error("disposable must be a function or disposable object", 3)
	end
end

local function nodeLabel(node)
	return node._label or (node._kind .. "#" .. tostring(node._id))
end

local function observerCount(node)
	local count = 0
	for _ in next, node._observers do
		count += 1
	end
	return count
end

local function dependencyInfo(node)
	local result = {}
	for _, dependency in ipairs(node._dependencies or {}) do
		result[#result + 1] = {
			id = dependency._id,
			label = dependency._label,
			kind = dependency._kind,
			revision = dependency._revision,
		}
	end
	return result
end

local function assertCodec(codec, label)
	if type(codec) ~= "table" or type(codec.encode) ~= "function" or type(codec.decode) ~= "function" then
		error(label .. " codec must provide encode() and decode()", 3)
	end
	if codec.clone ~= nil and type(codec.clone) ~= "function" then
		error(label .. " codec.clone must be a function", 3)
	end
	return codec
end

local function cloneWithCodec(codec, value, label)
	if type(codec.clone) == "function" then
		return callableResult(codec.clone, label .. " codec.clone", value)
	end
	local encoded = callableResult(codec.encode, label .. " codec.encode", value)
	return callableResult(codec.decode, label .. " codec.decode", encoded)
end

local function encodeDetached(codec, value, label)
	local encoded = callableResult(codec.encode, label .. " codec.encode", value)
	return callableResult(Codec.clone, label .. " encoded value", encoded)
end

local function validateValue(validator, value, label)
	if validator == nil then
		return
	end
	local results = pack(runNoYield(validator, value))
	if not results[1] then
		error(label .. " validator failed: " .. tostring(results[2]), 3)
	end
	if results[2] == false then
		local suffix = if results.n >= 3 and results[3] ~= nil then ": " .. tostring(results[3]) else ""
		error(label .. " validator rejected the value" .. suffix, 3)
	end
end

local function valuesEqual(equality, left, right, label)
	local results = pack(runNoYield(equality, left, right))
	if not results[1] then
		error(label .. " equality failed: " .. tostring(results[2]), 3)
	end
	return results[2] == true
end

function Runtime.isRuntime(value)
	return type(value) == "table" and rawget(value, "_tag") == RUNTIME_TAG
end

function Runtime:_assertUsable(operation)
	if self._disposed then
		error(operation .. " cannot use a disposed Runtime", 3)
	end
	if self._faulted then
		error(operation .. " cannot use a faulted Runtime: " .. tostring(self._faultReason), 3)
	end
end

function Runtime:_trace(eventName, ...)
	local handler = self._traceHandler
	if handler == nil then
		return
	end
	local fieldCount = select("#", ...)
	local event
	if fieldCount == 1 and type(select(1, ...)) == "table" then
		event = select(1, ...)
	else
		if fieldCount % 2 ~= 0 then
			error("internal trace fields must be a table or key/value pairs", 2)
		end
		event = {}
		for index = 1, fieldCount, 2 do
			event[select(index, ...)] = select(index + 1, ...)
		end
	end
	event.event = eventName
	event.runtimeId = self._id
	event.runtimeLabel = self._label
	event.tick = if event.tick ~= nil then event.tick else self._tick
	local ok, message = pcall(handler, event)
	if not ok and self._onError ~= nil then
		pcall(self._onError, {
			kind = "trace",
			message = tostring(message),
			event = eventName,
		})
	end
end

function Runtime:trace(eventName, fields)
	if type(eventName) ~= "string" or eventName == "" then
		error("Runtime:trace eventName must be a non-empty string", 2)
	end
	if fields ~= nil and type(fields) ~= "table" then
		error("Runtime:trace fields must be a table", 2)
	end
	if fields == nil then
		self:_trace(eventName)
	else
		self:_trace(eventName, fields)
	end
end

Runtime.emitTrace = Runtime.trace

function Runtime:_reportError(kind, message, context)
	local detail = context or {}
	detail.kind = kind
	detail.message = tostring(message)
	detail.runtimeId = self._id
	detail.tick = self._tick
	self:_trace("runtime:error", detail)
	if self._onError ~= nil then
		pcall(self._onError, detail)
	end
end

function Runtime:_newNodeId()
	self._nextNodeId += 1
	return self._nextNodeId
end

function Runtime:_registerNode(node)
	self._nodes[#self._nodes + 1] = node
	self._nodesById[node._id] = node
	self:_trace(node._kind .. ":create", "nodeId", node._id, "label", node._label)
end

function Runtime:_recordDependency(source)
	local frame = ACTIVE_COMPUTATION
	if frame == nil then
		return
	end
	if frame.runtime ~= source._runtime then
		error(string.format(
			"cross-Runtime dependency is not allowed: %s in Runtime %s read %s from Runtime %s; use Bridge or Network",
			nodeLabel(frame.node),
			tostring(frame.runtime._label or frame.runtime._id),
			nodeLabel(source),
			tostring(source._runtime._label or source._runtime._id)
		), 3)
	end
	if frame.depSet[source] == nil then
		frame.depSet[source] = true
		frame.dependencies[#frame.dependencies + 1] = source
	end
end

function Runtime:_cycleError(node)
	local names = {}
	local start = 1
	for index, current in ipairs(self._evaluationStack) do
		if current == node then
			start = index
			break
		end
	end
	for index = start, #self._evaluationStack do
		names[#names + 1] = nodeLabel(self._evaluationStack[index])
	end
	names[#names + 1] = nodeLabel(node)
	return "Computed cycle detected: " .. table.concat(names, " -> ")
end

function Runtime:_runGetter(node, mode)
	local nextDepth = #self._evaluationStack + 1
	if nextDepth > self._maxEvaluationDepth then
		local path = {}
		local first = math.max(1, #self._evaluationStack - 7)
		for index = first, #self._evaluationStack do
			path[#path + 1] = nodeLabel(self._evaluationStack[index])
		end
		path[#path + 1] = nodeLabel(node)
		error(string.format(
			"%s %d exceeded at '%s' (path tail: %s); flatten the graph or raise maxEvaluationDepth only after validating the host VM",
			EVALUATION_DEPTH_MESSAGE,
			self._maxEvaluationDepth,
			nodeLabel(node),
			table.concat(path, " -> ")
		), 3)
	end
	for _, evaluating in ipairs(self._evaluationStack) do
		if evaluating == node then
			error(self:_cycleError(node), 3)
		end
	end

	local frame = {
		runtime = self,
		node = node,
		mode = mode,
		dependencies = {},
		depSet = {},
		parent = ACTIVE_COMPUTATION,
	}
	self._evaluationStack[#self._evaluationStack + 1] = node
	ACTIVE_COMPUTATION = frame
	self:_trace("computed:evaluate:start", "nodeId", node._id, "label", node._label, "mode", mode)
	local results = pack(runNoYield(node._getter))
	ACTIVE_COMPUTATION = frame.parent
	self._evaluationStack[#self._evaluationStack] = nil
	if not results[1] then
		self:_trace(
			"computed:evaluate:error",
			"nodeId", node._id,
			"label", node._label,
			"mode", mode,
			"message", tostring(results[2])
		)
		local transaction = self._activeTransaction
		if transaction ~= nil then
			transaction.rollbackOnly = true
			transaction.failure = transaction.failure or results[2]
		end
		if string.find(tostring(results[2]), EVALUATION_DEPTH_MESSAGE, 1, true) ~= nil then
			error(results[2], 0)
		end
		error("Computed '" .. nodeLabel(node) .. "' failed: " .. tostring(results[2]), 3)
	end
	node._evaluationCount += 1
	self:_trace("computed:evaluate:end", "nodeId", node._id, "label", node._label, "mode", mode)
	return box(results[2]), frame.dependencies
end

function Runtime:_replaceDependencies(node, dependencies)
	local nextSet = {}
	for _, dependency in ipairs(dependencies) do
		nextSet[dependency] = true
	end
	for _, dependency in ipairs(node._dependencies) do
		if nextSet[dependency] == nil then
			dependency._observers[node] = nil
			self:_trace("dependency:disconnect", "fromNodeId", dependency._id, "toNodeId", node._id)
		end
	end
	for _, dependency in ipairs(dependencies) do
		if node._dependencySet[dependency] == nil then
			dependency._observers[node] = true
			self:_trace("dependency:connect", "fromNodeId", dependency._id, "toNodeId", node._id)
		end
	end
	node._dependencies = dependencies
	node._dependencySet = nextSet
	local revisions = {}
	for _, dependency in ipairs(dependencies) do
		revisions[dependency] = dependency._revision
	end
	node._dependencyRevisions = revisions
end

function Runtime:_evaluateCommitted(node)
	local boxedValue, dependencies = self:_runGetter(node, "committed")
	local changed = not node._hasValue
	if node._hasValue then
		changed = not valuesEqual(node._equality, unbox(node._value), unbox(boxedValue), "Computed '" .. nodeLabel(node) .. "'")
	end
	self:_replaceDependencies(node, dependencies)
	node._value = boxedValue
	node._hasValue = true
	node._state = CLEAN
	if changed then
		node._revision += 1
	end
	return unbox(boxedValue)
end

function Runtime:_getCommittedComputed(node)
	if node._state == CLEAN and node._hasValue then
		self:_trace("computed:cache-hit", "nodeId", node._id, "label", node._label)
		return unbox(node._value)
	end
	if node._state == PENDING and node._hasValue then
		for _, dependency in ipairs(node._dependencies) do
			if dependency._kind == "computed" then
				self:_getCommittedComputed(dependency)
			end
		end
		local changed = false
		for _, dependency in ipairs(node._dependencies) do
			if node._dependencyRevisions[dependency] ~= dependency._revision then
				changed = true
				break
			end
		end
		if not changed then
			node._state = CLEAN
			self:_trace("computed:verified-clean", "nodeId", node._id, "label", node._label)
			return unbox(node._value)
		end
	end
	return self:_evaluateCommitted(node)
end

function Runtime:_getSpeculativeComputed(node, transaction)
	local cached = transaction.speculative[node]
	if cached ~= nil and cached.generation == transaction.generation then
		if transaction.captureCandidates then
			cached.commitCandidate = true
		end
		return unbox(cached.value)
	end
	local boxedValue, dependencies = self:_runGetter(node, "speculative")
	local changed = not node._hasValue
	if node._hasValue then
		changed = not valuesEqual(node._equality, unbox(node._value), unbox(boxedValue), "Computed '" .. nodeLabel(node) .. "'")
	end
	local entry = {
		generation = transaction.generation,
		value = boxedValue,
		dependencies = dependencies,
		changed = changed,
		commitCandidate = transaction.captureCandidates == true,
	}
	transaction.speculative[node] = entry
	transaction.speculativeOrder[#transaction.speculativeOrder + 1] = { node = node, entry = entry }
	return unbox(boxedValue)
end

function Runtime:_markTransactionFailure(message)
	local transaction = self._activeTransaction
	if transaction ~= nil then
		transaction.rollbackOnly = true
		transaction.failure = transaction.failure or message
	end
end

function Runtime:_stageAtom(atom, value, force)
	self:_assertUsable("Atom:set")
	if ACTIVE_COMPUTATION ~= nil then
		local message = "state writes are not allowed while evaluating Computed '" .. nodeLabel(ACTIVE_COMPUTATION.node) .. "'"
		self:_markTransactionFailure(message)
		error(message, 3)
	end
	if self._phase == "notifying" then
		self:transaction(function()
			self:_stageAtom(atom, value, force)
		end, { cause = "watch-write" })
		return nil
	end
	local transaction = self._activeTransaction
	if transaction == nil then
		return self:transaction(function()
			self:_stageAtom(atom, value, force)
		end, { cause = "atom:set", nodeId = atom._id })
	end
	if self._phase ~= "mutating" then
		local message = "state writes are only allowed during the transaction mutation phase"
		self:_markTransactionFailure(message)
		error(message, 3)
	end
	local entry = transaction.writes[atom]
	if entry == nil then
		entry = {
			before = atom._value,
			after = box(value),
			force = force == true,
		}
		transaction.writes[atom] = entry
		transaction.writeOrder[#transaction.writeOrder + 1] = atom
	else
		entry.after = box(value)
		entry.force = entry.force or force == true
	end
	transaction.generation += 1
	return nil
end

function Runtime:_readAtom(atom)
	self:_assertUsable("Atom:get")
	local transaction = self._activeTransaction
	if transaction ~= nil then
		local entry = transaction.writes[atom]
		if entry ~= nil then
			self:_recordDependency(atom)
			return unbox(entry.after)
		end
	end
	self:_recordDependency(atom)
	return unbox(atom._value)
end

function Atom:get()
	return self._runtime:_readAtom(self)
end

function Atom:set(value)
	return self._runtime:_stageAtom(self, value, false)
end

function Atom:update(updater)
	if type(updater) ~= "function" then
		error("Atom:update updater must be a function", 2)
	end
	local runtime = self._runtime
	if runtime._activeTransaction == nil and runtime._phase ~= "notifying" then
		return runtime:transaction(function()
			self:update(updater)
		end, { cause = "atom:update", nodeId = self._id })
	end
	local results = pack(runNoYield(updater, self:get()))
	if not results[1] then
		runtime:_markTransactionFailure(results[2])
		error("Atom:update for '" .. nodeLabel(self) .. "' failed: " .. tostring(results[2]), 2)
	end
	return runtime:_stageAtom(self, results[2], false)
end

function Atom:mutate(mutator)
	if type(mutator) ~= "function" then
		error("Atom:mutate mutator must be a function", 2)
	end
	local runtime = self._runtime
	if runtime._activeTransaction == nil and runtime._phase ~= "notifying" then
		return runtime:transaction(function()
			self:mutate(mutator)
		end, { cause = "atom:mutate", nodeId = self._id })
	end
	local cloneOk, copy = pcall(cloneWithCodec, self._codec, self:get(), "Atom '" .. nodeLabel(self) .. "'")
	if not cloneOk then
		runtime:_markTransactionFailure(copy)
		error(copy, 0)
	end
	local results = pack(runNoYield(mutator, copy))
	if not results[1] then
		runtime:_markTransactionFailure(results[2])
		error("Atom:mutate for '" .. nodeLabel(self) .. "' failed: " .. tostring(results[2]), 2)
	end
	return runtime:_stageAtom(self, copy, false)
end

function Atom:touch()
	return self._runtime:_stageAtom(self, self:get(), true)
end

function Atom:getRevision()
	return self._revision
end

function Atom:getRuntime()
	return self._runtime
end

function Atom:getDebugInfo()
	return {
		id = self._id,
		label = self._label,
		kind = self._kind,
		state = CLEAN,
		revision = self._revision,
		observers = observerCount(self),
		dependencies = {},
	}
end

function Atom:asReadonly()
	if self._readonly == nil then
		self._readonly = setmetatable({ _atom = self }, ReadonlySource)
	end
	return self._readonly
end

function ReadonlySource:get()
	return self._atom:get()
end

function ReadonlySource:getRevision()
	return self._atom:getRevision()
end

function ReadonlySource:getRuntime()
	return self._atom:getRuntime()
end

function ReadonlySource:getDebugInfo()
	local info = self._atom:getDebugInfo()
	info.readonly = true
	return info
end

function Computed:get()
	local runtime = self._runtime
	runtime:_assertUsable("Computed:get")
	local transaction = runtime._activeTransaction
	local value
	if transaction ~= nil then
		value = runtime:_getSpeculativeComputed(self, transaction)
	else
		value = runtime:_getCommittedComputed(self)
	end
	runtime:_recordDependency(self)
	return value
end

function Computed:peek()
	local runtime = self._runtime
	runtime:_assertUsable("Computed:peek")
	local transaction = runtime._activeTransaction
	if transaction ~= nil then
		return runtime:_getSpeculativeComputed(self, transaction)
	end
	return runtime:_getCommittedComputed(self)
end

function Computed:getRevision()
	return self._revision
end

function Computed:getRuntime()
	return self._runtime
end

function Computed:getDebugInfo()
	return {
		id = self._id,
		label = self._label,
		kind = self._kind,
		state = self._state,
		revision = self._revision,
		observers = observerCount(self),
		evaluationCount = self._evaluationCount,
		lastInvalidator = self._lastInvalidator,
		dependencies = dependencyInfo(self),
	}
end

function Runtime:_markObservers(source, direct)
	for observer in next, source._observers do
		if observer._kind == "computed" then
			local nextState = if direct then DIRTY else PENDING
			if observer._state == CLEAN or (observer._state == PENDING and nextState == DIRTY) then
				observer._state = nextState
				observer._lastInvalidator = source._id
				self:_markObservers(observer, false)
			end
		end
	end
end

function Runtime:_collectAffectedWatchers(changedAtoms)
	local watchers = {}
	local seenNodes = {}
	local seenWatchers = {}
	local function visit(node)
		if seenNodes[node] then
			return
		end
		seenNodes[node] = true
		for observer in next, node._observers do
			if observer._kind == "watch" then
				if observer._active and not seenWatchers[observer] then
					seenWatchers[observer] = true
					watchers[#watchers + 1] = observer
				end
			elseif observer._kind == "computed" then
				visit(observer)
			end
		end
	end
	for _, atom in ipairs(changedAtoms) do
		visit(atom)
	end
	table.sort(watchers, function(left, right)
		if left._priority ~= right._priority then
			return left._priority < right._priority
		end
		return left._id < right._id
	end)
	return watchers
end

function Scope:add(disposable)
	if disposable == nil then
		error("Scope:add requires a disposable", 2)
	end
	if self._disposed then
		local ok, message = pcall(disposeOne, disposable)
		if not ok then
			self._runtime:_reportError("scope", message, { scopeId = self._id })
		end
		return disposable
	end
	self._cleanups[#self._cleanups + 1] = disposable
	return disposable
end

function Scope:isDisposed()
	return self._disposed
end

function Scope:dispose()
	if self._disposed then
		return
	end
	if self._runtime._activeTransaction ~= nil then
		error("Scope:dispose cannot change ownership during an active transaction", 2)
	end
	self._disposed = true
	self._runtime._scopes[self] = nil
	for index = #self._cleanups, 1, -1 do
		local ok, message = pcall(disposeOne, self._cleanups[index])
		if not ok then
			self._runtime:_reportError("scope", message, { scopeId = self._id })
		end
		self._cleanups[index] = nil
	end
	self._runtime:_trace("scope:dispose", "scopeId", self._id, "label", self._label)
end

Scope.Destroy = Scope.dispose

function Runtime:_markSpeculativeTree(transaction, node, seen)
	if node == nil or node._kind ~= "computed" then
		return
	end
	seen = seen or {}
	if seen[node] then
		return
	end
	seen[node] = true
	local entry = transaction.speculative[node]
	if entry == nil or entry.generation ~= transaction.generation then
		return
	end
	entry.commitCandidate = true
	for _, dependency in ipairs(entry.dependencies) do
		if dependency._kind == "computed" then
			self:_markSpeculativeTree(transaction, dependency, seen)
		end
	end
end

function Runtime:_prepareTransaction(transaction)
	self._phase = "preparing"
	local changedAtoms = {}
	local changes = {}

	for _, atom in ipairs(transaction.writeOrder) do
		local entry = transaction.writes[atom]
		local before = unbox(entry.before)
		local after = unbox(entry.after)
		local equal = valuesEqual(atom._equality, before, after, "Atom '" .. nodeLabel(atom) .. "'")
		entry.changed = entry.force or not equal
		if entry.changed then
			validateValue(atom._validator, after, "Atom '" .. nodeLabel(atom) .. "'")
			changedAtoms[#changedAtoms + 1] = atom
			changes[#changes + 1] = {
				node = atom,
				nodeId = atom._id,
				label = atom._label,
				before = before,
				after = after,
				forced = entry.force == true,
			}
		end
	end

	local affectedWatchers = self:_collectAffectedWatchers(changedAtoms)
	local notifications = {}
	transaction.captureCandidates = true
	for _, watcher in ipairs(affectedWatchers) do
		if watcher._active then
			local value = watcher._source:get()
			if watcher._sourceNode._kind == "computed" then
				self:_markSpeculativeTree(transaction, watcher._sourceNode)
			end
			local changed = not watcher._hasValue
			if watcher._hasValue then
				changed = not valuesEqual(
					watcher._equality,
					unbox(watcher._lastValue),
					value,
					"Watch '" .. watcher._label .. "'"
				)
			end
			if changed then
				local replayMode = watcher._replay
				local replaying = transaction.replay == true
				notifications[#notifications + 1] = {
					watcher = watcher,
					value = box(value),
					previous = watcher._lastValue,
					hadPrevious = watcher._hasValue,
					deliver = not (replaying and (
						replayMode == "suppress"
						or (replayMode == "coalesce" and self._coalescingReplay)
					)),
				}
			end
		end
	end
	transaction.captureCandidates = false

	local actions = {}
	for index, action in ipairs(transaction.actions) do
		if self._history ~= nil then
			actions[index] = callableResult(Codec.clone, "timeline action", action)
		else
			actions[index] = action
		end
	end

	local commands = {}
	for index, command in ipairs(transaction.commands) do
		commands[index] = command
	end

	local tick = transaction.stepTick
	if tick == nil then
		tick = self._tick
	end
	local historySnapshot = nil
	if self._history ~= nil and tick ~= nil and not transaction.suppressHistory then
		historySnapshot = self:_makeSnapshot(transaction, tick)
	end

	local changeSet = {
		transactionId = transaction.id,
		tick = tick,
		cause = transaction.cause,
		changedNodes = changedAtoms,
		changes = changes,
		actions = actions,
		commands = commands,
		metadata = transaction.metadata,
		replay = transaction.replay == true,
		watchErrors = {},
	}
	return {
		changedAtoms = changedAtoms,
		changes = changes,
		notifications = notifications,
		changeSet = changeSet,
		historySnapshot = historySnapshot,
	}
end

function Runtime:_applySpeculativeCandidates(transaction)
	local applied = {}
	for _, item in ipairs(transaction.speculativeOrder) do
		local node = item.node
		local entry = item.entry
		if not applied[node]
			and transaction.speculative[node] == entry
			and entry.generation == transaction.generation
			and entry.commitCandidate
		then
			applied[node] = true
			self:_replaceDependencies(node, entry.dependencies)
			node._value = entry.value
			node._hasValue = true
			node._state = CLEAN
			if entry.changed then
				node._revision += 1
			end
		end
	end
end

function Runtime:_recordHistorySnapshot(snapshot)
	local history = self._history
	if history == nil or snapshot == nil then
		return
	end
	storeHistorySnapshot(history, snapshot)
	self:_trace("history:snapshot", "tick", snapshot.tick, "stateHash", snapshot.stateHash)
end

function Runtime:_publishTransaction(transaction, plan)
	self._phase = "publishing"
	for _, atom in ipairs(plan.changedAtoms) do
		local entry = transaction.writes[atom]
		atom._value = entry.after
		atom._revision += 1
		self:_trace(
			"atom:set",
			"nodeId", atom._id,
			"label", atom._label,
			"revision", atom._revision,
			"transactionId", transaction.id
		)
	end
	for _, atom in ipairs(plan.changedAtoms) do
		self:_markObservers(atom, true)
	end
	self:_applySpeculativeCandidates(transaction)
	if transaction.stepTick ~= nil then
		self._tick = transaction.stepTick
	end
	for _, command in ipairs(plan.changeSet.commands) do
		self._outbox[#self._outbox + 1] = command
	end
	self:_recordHistorySnapshot(plan.historySnapshot)
	for _, change in ipairs(plan.changes) do
		change.revision = change.node._revision
	end
end

function Runtime:_notifyTransaction(plan)
	self._phase = "notifying"
	for _, notification in ipairs(plan.notifications) do
		local watcher = notification.watcher
		if watcher._active then
			watcher._lastValue = notification.value
			watcher._hasValue = true
			if notification.deliver then
				self:_trace(
					"watch:run",
					"watchId", watcher._id,
					"label", watcher._label,
					"transactionId", plan.changeSet.transactionId
				)
				local ok, message = runNoYield(
					watcher._callback,
					unbox(notification.value),
					if notification.hadPrevious then unbox(notification.previous) else nil,
					plan.changeSet
				)
				if not ok then
					local detail = {
						watchId = watcher._id,
						label = watcher._label,
						message = tostring(message),
						committed = true,
					}
					plan.changeSet.watchErrors[#plan.changeSet.watchErrors + 1] = detail
					self:_reportError("watch", message, detail)
				end
			end
		end
	end
	self._phase = "idle"
end

function Runtime:_abortTransaction(transaction, message)
	self._activeTransaction = nil
	self._phase = "idle"
	self:_trace(
		"transaction:abort",
		"transactionId", transaction.id,
		"cause", transaction.cause,
		"message", tostring(message)
	)
	error(string.format(
		"ReactiveState transaction #%d (%s) aborted: %s",
		transaction.id,
		transaction.cause,
		tostring(message)
	), 3)
end

function Runtime:_drainQueuedTransactions()
	if self._drainingTransactions or #self._queuedTransactions == 0 then
		return
	end
	self._drainingTransactions = true
	local index = 1
	local count = 0
	while index <= #self._queuedTransactions do
		count += 1
		if count > self._maxReactionChain then
			self._queuedTransactions = {}
			self:_reportError("reaction-cycle", "queued transaction chain exceeded " .. tostring(self._maxReactionChain), {
				limit = self._maxReactionChain,
			})
			break
		end
		local queued = self._queuedTransactions[index]
		index += 1
		local ok, message = pcall(self.transaction, self, queued.callback, queued.metadata)
		if not ok then
			self:_reportError("queued-transaction", message, { metadata = queued.metadata })
		end
	end
	self._queuedTransactions = {}
	self._drainingTransactions = false
end

function Runtime:transaction(callback, metadata)
	self:_assertUsable("Runtime:transaction")
	if type(callback) ~= "function" then
		error("Runtime:transaction callback must be a function", 2)
	end
	if metadata ~= nil and type(metadata) ~= "table" then
		error("Runtime:transaction metadata must be a table", 2)
	end
	if self._phase == "notifying" then
		self._queuedTransactions[#self._queuedTransactions + 1] = {
			callback = callback,
			metadata = metadata,
		}
		return nil
	end

	local active = self._activeTransaction
	if active ~= nil then
		if self._phase ~= "mutating" then
			error("nested transaction is only allowed while the root transaction callback is mutating", 2)
		end
		active.depth += 1
		local results = pack(runNoYield(callback))
		active.depth -= 1
		if not results[1] then
			active.rollbackOnly = true
			active.failure = active.failure or results[2]
			error(results[2], 0)
		end
		return nil
	end

	if self._phase ~= "idle" then
		error("Runtime:transaction cannot start during phase '" .. tostring(self._phase) .. "'", 2)
	end
	self._nextTransactionId += 1
	local options = metadata or {}
	local transaction = {
		id = self._nextTransactionId,
		depth = 1,
		cause = options.cause or "transaction",
		metadata = options,
		writes = {},
		writeOrder = {},
		generation = 0,
		speculative = {},
		speculativeOrder = {},
		captureCandidates = false,
		actions = {},
		commands = {},
		rollbackOnly = false,
		failure = nil,
		stepTick = options._stepTick,
		replay = options.replay == true or options.cause == "rollback" or options.cause == "replay",
		suppressHistory = options._suppressHistory == true,
	}
	self._activeTransaction = transaction
	self._phase = "mutating"
	self:_trace("transaction:start", "transactionId", transaction.id, "cause", transaction.cause)

	local callbackResults = pack(runNoYield(callback))
	if not callbackResults[1] then
		transaction.rollbackOnly = true
		transaction.failure = transaction.failure or callbackResults[2]
	end
	if transaction.rollbackOnly then
		return self:_abortTransaction(transaction, transaction.failure or "marked rollback-only")
	end

	local prepared, plan = pcall(self._prepareTransaction, self, transaction)
	if not prepared then
		return self:_abortTransaction(transaction, plan)
	end
	local published, publishError = pcall(self._publishTransaction, self, transaction, plan)
	if not published then
		self._activeTransaction = nil
		self._phase = "idle"
		self._faulted = true
		self._faultReason = publishError
		self:_reportError("runtime-fault", publishError, { transactionId = transaction.id })
		error("ReactiveState Runtime faulted while publishing transaction: " .. tostring(publishError), 2)
	end
	self._activeTransaction = nil
	self:_notifyTransaction(plan)
	self:_trace(
		"transaction:commit",
		"transactionId", transaction.id,
		"cause", transaction.cause,
		"changedCount", #plan.changedAtoms
	)
	if not self._drainingTransactions then
		self:_drainQueuedTransactions()
	end
	return plan.changeSet
end

Runtime.batch = Runtime.transaction

local function resolveSourceNode(source, operation)
	if type(source) ~= "table" or type(source.get) ~= "function" or type(source.getRevision) ~= "function" then
		error(operation .. " requires an Atom, Computed, or read-only Source", 3)
	end
	local node = rawget(source, "_atom") or source
	if type(node) ~= "table" or (node._kind ~= "atom" and node._kind ~= "computed") then
		error(operation .. " received an unsupported Source implementation", 3)
	end
	return node
end

function Runtime:atom(initialValue, options)
	self:_assertUsable("Runtime:atom")
	if self._phase ~= "idle" or self._activeTransaction ~= nil then
		error("Runtime:atom cannot change graph structure during a transaction or notification", 2)
	end
	options = options or {}
	if type(options) ~= "table" then
		error("Runtime:atom options must be a table", 2)
	end
	if options.label ~= nil and type(options.label) ~= "string" then
		error("Runtime:atom label must be a string", 2)
	end
	if historyCount(self._history) > 0 then
		error("Runtime:atom cannot add timeline state after history has started", 2)
	end
	local equality = options.equality or sameValue
	if type(equality) ~= "function" then
		error("Runtime:atom equality must be a function", 2)
	end
	if options.validate ~= nil and type(options.validate) ~= "function" then
		error("Runtime:atom validate must be a function", 2)
	end
	local codec = assertCodec(options.codec or Codec.default, "Runtime:atom")
	validateValue(options.validate, initialValue, "Atom '" .. tostring(options.label or self._nextNodeId + 1) .. "'")
	local atom = setmetatable({
		_runtime = self,
		_id = self:_newNodeId(),
		_label = options.label,
		_kind = "atom",
		_value = box(initialValue),
		_revision = 0,
		_observers = {},
		_equality = equality,
		_validator = options.validate,
		_codec = codec,
		_historyTracked = options.history ~= false and options.transient ~= true,
		_readonly = nil,
	}, Atom)
	self:_registerNode(atom)
	return atom
end

function Runtime:computed(getter, options)
	self:_assertUsable("Runtime:computed")
	if self._phase ~= "idle" or self._activeTransaction ~= nil then
		error("Runtime:computed cannot change graph structure during a transaction or notification", 2)
	end
	if type(getter) ~= "function" then
		error("Runtime:computed getter must be a function", 2)
	end
	options = options or {}
	if type(options) ~= "table" then
		error("Runtime:computed options must be a table", 2)
	end
	if options.label ~= nil and type(options.label) ~= "string" then
		error("Runtime:computed label must be a string", 2)
	end
	local equality = options.equality or sameValue
	if type(equality) ~= "function" then
		error("Runtime:computed equality must be a function", 2)
	end
	local computed = setmetatable({
		_runtime = self,
		_id = self:_newNodeId(),
		_label = options.label,
		_kind = "computed",
		_getter = getter,
		_equality = equality,
		_value = NIL,
		_hasValue = false,
		_revision = 0,
		_state = DIRTY,
		_dependencies = {},
		_dependencySet = {},
		_dependencyRevisions = {},
		_observers = {},
		_evaluationCount = 0,
		_lastInvalidator = nil,
	}, Computed)
	self:_registerNode(computed)
	return computed
end

function Runtime:watch(source, callback, options)
	self:_assertUsable("Runtime:watch")
	if self._phase ~= "idle" or self._activeTransaction ~= nil then
		error("Runtime:watch cannot change graph structure during a transaction or notification", 2)
	end
	if type(callback) ~= "function" then
		error("Runtime:watch callback must be a function", 2)
	end
	options = options or {}
	if type(options) ~= "table" then
		error("Runtime:watch options must be a table", 2)
	end
	if options.label ~= nil and type(options.label) ~= "string" then
		error("Runtime:watch label must be a string", 2)
	end
	local sourceNode = resolveSourceNode(source, "Runtime:watch")
	if sourceNode._runtime ~= self then
		error("Runtime:watch cannot observe a Source owned by another Runtime", 2)
	end
	local equality = options.equality or sameValue
	if type(equality) ~= "function" then
		error("Runtime:watch equality must be a function", 2)
	end
	local priority = options.priority or 0
	if not isFinite(priority) then
		error("Runtime:watch priority must be a finite number", 2)
	end
	local replay = options.replay or "coalesce"
	if replay ~= "coalesce" and replay ~= "all" and replay ~= "suppress" then
		error("Runtime:watch replay must be 'coalesce', 'all', or 'suppress'", 2)
	end
	local value = source:get()
	self._nextWatchId += 1
	local watcher = {
		_kind = "watch",
		_id = self._nextWatchId,
		_label = options.label or ("watch#" .. tostring(self._nextWatchId)),
		_priority = priority,
		_source = source,
		_sourceNode = sourceNode,
		_callback = callback,
		_equality = equality,
		_replay = replay,
		_lastValue = box(value),
		_hasValue = true,
		_active = true,
	}
	self._watchers[watcher] = true
	sourceNode._observers[watcher] = true
	self:_trace(
		"watch:create",
		"watchId", watcher._id,
		"label", watcher._label,
		"sourceNodeId", sourceNode._id
	)

	if options.initial ~= false then
		local ok, message = runNoYield(callback, value, nil, nil)
		if not ok then
			self:_reportError("watch", message, {
				watchId = watcher._id,
				label = watcher._label,
				initial = true,
				committed = true,
			})
			watcher._active = false
			self._watchers[watcher] = nil
			sourceNode._observers[watcher] = nil
			error("Runtime:watch initial callback failed: " .. tostring(message), 2)
		end
	end

	local stopped = false
	return function()
		if stopped then
			return
		end
		if self._activeTransaction ~= nil then
			error("watch disposal cannot change graph structure during an active transaction", 2)
		end
		stopped = true
		watcher._active = false
		self._watchers[watcher] = nil
		sourceNode._observers[watcher] = nil
		self:_trace("watch:dispose", "watchId", watcher._id, "label", watcher._label)
	end
end

function Runtime:scope(callback, options)
	self:_assertUsable("Runtime:scope")
	if callback ~= nil and type(callback) ~= "function" then
		error("Runtime:scope callback must be a function", 2)
	end
	options = options or {}
	self._nextScopeId += 1
	local scope = setmetatable({
		_runtime = self,
		_id = self._nextScopeId,
		_label = options.label,
		_cleanups = {},
		_disposed = false,
	}, Scope)
	self._scopes[scope] = true
	self:_trace("scope:create", "scopeId", scope._id, "label", scope._label)
	if callback ~= nil then
		local ok, message = runNoYield(callback, scope)
		if not ok then
			scope:dispose()
			error("Runtime:scope callback failed: " .. tostring(message), 2)
		end
	end
	return scope
end

function Runtime:store(options)
	self:_assertUsable("Runtime:store")
	if type(options) ~= "table" then
		error("Runtime:store options must be a table", 2)
	end
	if type(options.reducer) ~= "function" then
		error("Runtime:store requires a reducer function", 2)
	end
	local state = self:atom(options.initialState, {
		label = if options.label ~= nil then options.label .. ".state" else nil,
		equality = options.equality,
		validate = options.validate,
		codec = options.codec,
		history = options.history,
	})
	return setmetatable({
		_runtime = self,
		_label = options.label,
		_state = state,
		_reducer = options.reducer,
	}, Store)
end

function Store:getState()
	return self._state:get()
end

function Store:getRuntime()
	return self._runtime
end

function Store:dispatch(action)
	local runtime = self._runtime
	local function reduce()
		local results = pack(runNoYield(self._reducer, self._state:get(), action))
		if not results[1] then
			runtime:_markTransactionFailure(results[2])
			error("Store reducer '" .. tostring(self._label or "store") .. "' failed: " .. tostring(results[2]), 2)
		end
		self._state:set(results[2])
		local transaction = runtime._activeTransaction
		transaction.actions[#transaction.actions + 1] = action
	end
	if runtime._activeTransaction ~= nil then
		reduce()
		return nil
	end
	return runtime:transaction(reduce, { cause = "action", store = self._label })
end

function Store:select(selector, options)
	if type(selector) ~= "function" then
		error("Store:select selector must be a function", 2)
	end
	return self._runtime:computed(function()
		return selector(self._state:get())
	end, options)
end

local StepContext = {}
StepContext.__index = StepContext

function StepContext:emit(commandType, payload, options)
	if not self._active then
		error("StepContext:emit can only be used synchronously inside Runtime:step", 2)
	end
	if type(commandType) ~= "string" or commandType == "" then
		error("StepContext:emit commandType must be a non-empty string", 2)
	end
	options = options or {}
	if type(options) ~= "table" then
		error("StepContext:emit options must be a table", 2)
	end
	local policy = options.policy or self._runtime._effectPolicy
	if policy ~= "speculative" and policy ~= "confirmed" and policy ~= "local" then
		error("StepContext:emit policy must be 'speculative', 'confirmed', or 'local'", 2)
	end
	local codec = assertCodec(options.codec or Codec.default, "StepContext:emit")
	local encodedOk, encoded = pcall(encodeDetached, codec, payload, "Command '" .. commandType .. "'")
	if not encodedOk then
		self._runtime:_markTransactionFailure(encoded)
		error(encoded, 0)
	end
	local decodedOk, clonedPayload = pcall(callableResult, codec.decode, "Command '" .. commandType .. "' codec.decode", encoded)
	if not decodedOk then
		self._runtime:_markTransactionFailure(clonedPayload)
		error(clonedPayload, 0)
	end
	local cancellationKey = nil
	if options.cancellationKey ~= nil then
		local keyOk, keyError = Codec.validate(options.cancellationKey)
		if not keyOk then
			local message = "Command cancellationKey is not serializable: " .. tostring(keyError)
			self._runtime:_markTransactionFailure(message)
			error(message, 2)
		end
		cancellationKey = Codec.clone(options.cancellationKey)
	end
	local transaction = self._runtime._activeTransaction
	if transaction == nil then
		error("StepContext:emit lost its active transaction", 2)
	end
	local ordinal = #transaction.commands + 1
	local id = self._runtime._commandNamespace .. ":" .. tostring(self.tick) .. ":" .. tostring(ordinal)
	local command = {
		id = id,
		type = commandType,
		payload = clonedPayload,
		encodedPayload = encoded,
		policy = policy,
		tick = self.tick,
		ordinal = ordinal,
		confirmed = false,
		cancellationKey = cancellationKey,
	}
	transaction.commands[#transaction.commands + 1] = command
	self._runtime:_trace(
		"command:emit",
		"commandId", id,
		"commandType", commandType,
		"policy", policy,
		"tick", self.tick
	)
	return id
end

function StepContext:action(action)
	if not self._active then
		error("StepContext:action can only be used synchronously inside Runtime:step", 2)
	end
	local transaction = self._runtime._activeTransaction
	transaction.actions[#transaction.actions + 1] = action
end

function Runtime:step(tick, callback, metadata)
	self:_assertUsable("Runtime:step")
	assertInteger(tick, "Runtime:step tick", 0, 2)
	if type(callback) ~= "function" then
		error("Runtime:step callback must be a function", 2)
	end
	if self._activeTransaction ~= nil or self._phase ~= "idle" then
		error("Runtime:step cannot start inside another transaction or notification", 2)
	end
	if self._tick ~= nil then
		local expected = self._tick + 1
		if self._deterministic and tick ~= expected then
			error(string.format("Runtime:step expected tick %d, got %d", expected, tick), 2)
		elseif tick <= self._tick then
			error("Runtime:step tick must advance monotonically", 2)
		end
	end
	if self._history ~= nil and historyCount(self._history) == 0 and self._tick == nil and tick > 0 then
		self:_recordHistorySnapshot(self:_makeSnapshot(nil, tick - 1))
	end
	local transactionMetadata = copyTable(metadata)
	transactionMetadata.cause = transactionMetadata.cause or "step"
	transactionMetadata._stepTick = tick
	if transactionMetadata.replay == nil then
		transactionMetadata.replay = self._coalescingReplay == true
	end
	local context = setmetatable({
		_runtime = self,
		_active = true,
		tick = tick,
		metadata = transactionMetadata,
	}, StepContext)
	local result = self:transaction(function()
		local results = pack(runNoYield(callback, context))
		context._active = false
		if not results[1] then
			error(results[2], 0)
		end
	end, transactionMetadata)
	context._active = false
	return result
end

function Runtime:_snapshotProjection(transaction)
	local state = {}
	for _, node in ipairs(self._nodes) do
		if node._kind == "atom" and node._historyTracked then
			local boxedValue = node._value
			if transaction ~= nil then
				local write = transaction.writes[node]
				if write ~= nil then
					boxedValue = write.after
				end
			end
			state[#state + 1] = {
				id = node._id,
				label = node._label,
				hasValue = true,
				data = encodeDetached(node._codec, unbox(boxedValue), "Atom '" .. nodeLabel(node) .. "' snapshot"),
			}
		end
	end
	return state
end

function Runtime:_schemaHash()
	local schema = {}
	for _, node in ipairs(self._nodes) do
		if node._kind == "atom" and node._historyTracked then
			schema[#schema + 1] = { id = node._id, label = node._label }
		end
	end
	return Hash.hash({ apiVersion = 1, schema = schema })
end

function Runtime:_makeSnapshot(transaction, tick)
	local state = self:_snapshotProjection(transaction)
	local projection = {
		apiVersion = 1,
		schemaHash = self:_schemaHash(),
		tick = tick,
		state = state,
	}
	return {
		apiVersion = 1,
		schemaHash = projection.schemaHash,
		tick = tick,
		state = state,
		stateHash = Hash.hash(projection),
	}
end

function Runtime:_findHistorySnapshot(tick)
	if self._history == nil then
		return nil
	end
	local slot = self._history.byTick[tick]
	return if slot == nil then nil else self._history.entries[slot]
end

function Runtime:snapshot(tick)
	self:_assertUsable("Runtime:snapshot")
	if self._activeTransaction ~= nil or self._phase ~= "idle" then
		error("Runtime:snapshot requires an idle Runtime", 2)
	end
	if tick ~= nil then
		assertInteger(tick, "Runtime:snapshot tick", 0, 2)
		if tick ~= self._tick then
			local stored = self:_findHistorySnapshot(tick)
			if stored == nil then
				error("Runtime:snapshot has no retained state for tick " .. tostring(tick), 2)
			end
			return Codec.clone(stored)
		end
	end
	return self:_makeSnapshot(nil, if tick ~= nil then tick else self._tick)
end

function Runtime:_decodeSnapshot(snapshot)
	if type(snapshot) ~= "table" or getmetatable(snapshot) ~= nil then
		error("snapshot must be a plain table", 3)
	end
	if snapshot.apiVersion ~= 1 then
		error("unsupported snapshot apiVersion " .. tostring(snapshot.apiVersion), 3)
	end
	if snapshot.schemaHash ~= self:_schemaHash() then
		error("snapshot schema does not match this Runtime", 3)
	end
	if snapshot.tick ~= nil then
		assertInteger(snapshot.tick, "snapshot tick", 0, 3)
	end
	if type(snapshot.state) ~= "table" then
		error("snapshot.state must be an array", 3)
	end
	local expected = {}
	for _, node in ipairs(self._nodes) do
		if node._kind == "atom" and node._historyTracked then
			expected[#expected + 1] = node
		end
	end
	if #snapshot.state ~= #expected then
		error("snapshot state count does not match this Runtime", 3)
	end
	local decoded = {}
	for index, atom in ipairs(expected) do
		local entry = snapshot.state[index]
		if type(entry) ~= "table" or entry.id ~= atom._id then
			error("snapshot state order/id mismatch at index " .. tostring(index), 3)
		end
		local value = callableResult(atom._codec.decode, "Atom '" .. nodeLabel(atom) .. "' snapshot decode", entry.data)
		validateValue(atom._validator, value, "Atom '" .. nodeLabel(atom) .. "'")
		decoded[#decoded + 1] = { atom = atom, value = value }
	end
	local projection = {
		apiVersion = 1,
		schemaHash = snapshot.schemaHash,
		tick = snapshot.tick,
		state = snapshot.state,
	}
	local actualHash = Hash.hash(projection)
	if snapshot.stateHash ~= nil and snapshot.stateHash ~= actualHash then
		error("snapshot stateHash mismatch; expected " .. tostring(snapshot.stateHash) .. ", got " .. actualHash, 3)
	end
	return decoded, snapshot.tick
end

function Runtime:_restoreSnapshot(snapshot, cause)
	local decoded, targetTick = self:_decodeSnapshot(snapshot)
	local metadata = {
		cause = cause,
		replay = cause == "rollback" or cause == "replay" or cause == "replay-recover",
		_stepTick = targetTick,
		_suppressHistory = true,
	}
	local changeSet = self:transaction(function()
		for _, item in ipairs(decoded) do
			item.atom:set(item.value)
		end
	end, metadata)
	if targetTick == nil then
		self._tick = nil
	end
	return changeSet
end

function Runtime:restore(snapshot)
	self:_assertUsable("Runtime:restore")
	if self._activeTransaction ~= nil or self._phase ~= "idle" then
		error("Runtime:restore requires an idle Runtime", 2)
	end
	return self:_restoreSnapshot(snapshot, "restore")
end

function Runtime:rollback(tick)
	self:_assertUsable("Runtime:rollback")
	assertInteger(tick, "Runtime:rollback tick", 0, 2)
	if self._history == nil then
		error("Runtime:rollback requires history to be enabled", 2)
	end
	if self._confirmedTick ~= nil and tick < self._confirmedTick then
		error(string.format("Runtime:rollback cannot cross confirmed tick %d", self._confirmedTick), 2)
	end
	if self._activeTransaction ~= nil or self._phase ~= "idle" then
		error("Runtime:rollback requires an idle Runtime", 2)
	end
	local snapshot = self:_findHistorySnapshot(tick)
	if snapshot == nil then
		error("Runtime:rollback has no retained snapshot for tick " .. tostring(tick), 2)
	end
	self:_trace("timeline:rollback", "fromTick", self._tick, "tick", tick)
	return self:_restoreSnapshot(snapshot, "rollback")
end

function Runtime:_captureReplayWatchValues()
	local values = {}
	for watcher in next, self._watchers do
		if watcher._active and watcher._replay == "coalesce" then
			values[watcher] = {
				value = watcher._lastValue,
				hasValue = watcher._hasValue,
			}
		end
	end
	return values
end

function Runtime:_flushReplayWatches(startValues, fromTick, toTick)
	local ordered = {}
	for watcher, original in next, startValues do
		if watcher._active then
			ordered[#ordered + 1] = { watcher = watcher, original = original }
		end
	end
	table.sort(ordered, function(left, right)
		if left.watcher._priority ~= right.watcher._priority then
			return left.watcher._priority < right.watcher._priority
		end
		return left.watcher._id < right.watcher._id
	end)
	local changeSet = {
		transactionId = self._nextTransactionId,
		tick = self._tick,
		cause = "replay",
		changedNodes = {},
		changes = {},
		actions = {},
		commands = {},
		replay = true,
		fromTick = fromTick,
		toTick = toTick,
		watchErrors = {},
	}
	self._phase = "notifying"
	for _, item in ipairs(ordered) do
		local watcher = item.watcher
		local original = item.original
		local changed = original.hasValue ~= watcher._hasValue
		if not changed and original.hasValue then
			local ok, equalOrError = pcall(
				valuesEqual,
				watcher._equality,
				unbox(original.value),
				unbox(watcher._lastValue),
				"Watch '" .. watcher._label .. "' replay"
			)
			if not ok then
				self:_reportError("watch", equalOrError, { watchId = watcher._id, replay = true })
				changed = false
			else
				changed = not equalOrError
			end
		end
		if changed then
			local ok, message = runNoYield(
				watcher._callback,
				unbox(watcher._lastValue),
				if original.hasValue then unbox(original.value) else nil,
				changeSet
			)
			if not ok then
				self:_reportError("watch", message, { watchId = watcher._id, replay = true, committed = true })
			end
		end
	end
	self._phase = "idle"
	if not self._drainingTransactions then
		self:_drainQueuedTransactions()
	end
end

function Runtime:replay(fromTick, toTick, inputProvider)
	self:_assertUsable("Runtime:replay")
	assertInteger(fromTick, "Runtime:replay fromTick", 0, 2)
	assertInteger(toTick, "Runtime:replay toTick", fromTick, 2)
	if type(inputProvider) ~= "function" then
		error("Runtime:replay inputProvider must be a function", 2)
	end
	if self._history == nil then
		error("Runtime:replay requires history to be enabled", 2)
	end
	local checkpoint = self:snapshot()
	local historyBackup = cloneHistoryStorage(self._history)
	local outboxBackup = {}
	for index, command in ipairs(self._outbox) do
		outboxBackup[index] = command
	end
	local startValues = self:_captureReplayWatchValues()
	self._coalescingReplay = true
	local ok, message = pcall(function()
		if self._tick ~= fromTick then
			self:rollback(fromTick)
		end
		self:discardAfter(fromTick)
		for tick = fromTick + 1, toTick do
			self:step(tick, function(context)
				inputProvider(context, tick)
			end, { cause = "replay", replay = true })
		end
	end)
	if not ok then
		local recoveryOk, recoveryError = pcall(self._restoreSnapshot, self, checkpoint, "replay-recover")
		restoreHistoryStorage(self._history, historyBackup)
		self._outbox = outboxBackup
		self._coalescingReplay = false
		self:_flushReplayWatches(startValues, fromTick, toTick)
		if not recoveryOk then
			self._faulted = true
			self._faultReason = recoveryError
			error("Runtime:replay failed and recovery also failed: " .. tostring(message) .. "; " .. tostring(recoveryError), 2)
		end
		error("Runtime:replay failed: " .. tostring(message), 2)
	end
	self._coalescingReplay = false
	self:_flushReplayWatches(startValues, fromTick, toTick)
	self:_trace("timeline:replay", "fromTick", fromTick, "toTick", toTick)
end

function Runtime:confirm(tick)
	self:_assertUsable("Runtime:confirm")
	if self._activeTransaction ~= nil or self._phase ~= "idle" then
		error("Runtime:confirm requires an idle Runtime", 2)
	end
	assertInteger(tick, "Runtime:confirm tick", 0, 2)
	if self._tick ~= nil and tick > self._tick then
		error("Runtime:confirm cannot confirm beyond the current tick", 2)
	end
	if self._confirmedTick ~= nil and tick < self._confirmedTick then
		error("Runtime:confirm tick must be monotonic", 2)
	end
	local confirmed = {}
	for _, command in ipairs(self._outbox) do
		if command.policy == "confirmed" and not command.confirmed and command.tick <= tick then
			command.confirmed = true
			confirmed[#confirmed + 1] = command
			self:_trace("command:confirm", "commandId", command.id, "tick", command.tick)
		end
	end
	self._confirmedTick = tick
	return confirmed
end

function Runtime:discardAfter(tick)
	self:_assertUsable("Runtime:discardAfter")
	assertInteger(tick, "Runtime:discardAfter tick", 0, 2)
	if self._confirmedTick ~= nil and tick < self._confirmedTick then
		error("Runtime:discardAfter cannot cross the confirmed tick", 2)
	end
	if self._activeTransaction ~= nil or self._phase ~= "idle" then
		error("Runtime:discardAfter requires an idle Runtime", 2)
	end
	for _, command in ipairs(self._outbox) do
		if command.tick > tick and command.confirmed then
			error("cannot discard a confirmed command at tick " .. tostring(command.tick), 2)
		end
	end
	local retainedHistory = nil
	if self._history ~= nil then
		retainedHistory = {}
		for _, snapshot in ipairs(chronologicalHistory(self._history)) do
			if snapshot.tick <= tick then
				retainedHistory[#retainedHistory + 1] = snapshot
			end
		end
	end
	local retainedCommands = {}
	local cancelled = {}
	for _, command in ipairs(self._outbox) do
		if command.tick <= tick then
			retainedCommands[#retainedCommands + 1] = command
		else
			cancelled[#cancelled + 1] = command
		end
	end
	if self._history ~= nil then
		resetHistory(self._history, retainedHistory)
	end
	self._outbox = retainedCommands
	return cancelled
end

function Runtime:getTick()
	return self._tick
end

function Runtime:getStateHash()
	self:_assertUsable("Runtime:getStateHash")
	local state = self:_snapshotProjection(nil)
	return Hash.hash({ apiVersion = 1, schemaHash = self:_schemaHash(), tick = self._tick, state = state })
end

function Runtime:getPendingCommands()
	local result = {}
	for _, command in ipairs(self._outbox) do
		if not command.confirmed then
			result[#result + 1] = command
		end
	end
	return result
end

function Runtime:getConfirmedTick()
	return self._confirmedTick
end

function Runtime:getDebugSnapshot()
	local nodes = {}
	for _, node in ipairs(self._nodes) do
		nodes[#nodes + 1] = node:getDebugInfo()
	end
	return {
		id = self._id,
		label = self._label,
		tick = self._tick,
		confirmedTick = self._confirmedTick,
		phase = self._phase,
		disposed = self._disposed,
		faulted = self._faulted,
		faultReason = self._faultReason,
		maxEvaluationDepth = self._maxEvaluationDepth,
		nodes = nodes,
		watcherCount = (function()
			local count = 0
			for _ in next, self._watchers do
				count += 1
			end
			return count
		end)(),
		historyCount = historyCount(self._history),
		outboxCount = #self._outbox,
	}
end

Runtime.inspect = Runtime.getDebugSnapshot

function Runtime:getDebugInfo()
	return self:getDebugSnapshot()
end

function Runtime:dispose()
	if self._disposed then
		return
	end
	if self._activeTransaction ~= nil or self._phase ~= "idle" then
		error("Runtime:dispose cannot run during an active transaction", 2)
	end
	self._phase = "disposing"
	for watcher in next, self._watchers do
		watcher._active = false
		watcher._sourceNode._observers[watcher] = nil
		self._watchers[watcher] = nil
	end
	local scopes = {}
	for scope in next, self._scopes do
		scopes[#scopes + 1] = scope
	end
	for _, scope in ipairs(scopes) do
		scope:dispose()
	end
	for _, node in ipairs(self._nodes) do
		if node._kind == "computed" then
			for _, dependency in ipairs(node._dependencies) do
				dependency._observers[node] = nil
			end
			node._dependencies = {}
			node._dependencySet = {}
			node._dependencyRevisions = {}
		end
		node._observers = {}
	end
	self:_trace("runtime:dispose")
	self._nodes = {}
	self._nodesById = {}
	self._watchers = {}
	self._scopes = {}
	self._queuedTransactions = {}
	self._evaluationStack = {}
	self._activeTransaction = nil
	self._drainingTransactions = false
	self._history = nil
	self._outbox = {}
	self._clock = nil
	self._coalescingReplay = false
	self._traceHandler = nil
	self._onError = nil
	self._disposed = true
	self._phase = "disposed"
end

Runtime.Destroy = Runtime.dispose

function Runtime.new(options)
	options = options or {}
	if type(options) ~= "table" then
		error("Runtime.new options must be a table", 2)
	end
	if options.label ~= nil and type(options.label) ~= "string" then
		error("Runtime.new label must be a string", 2)
	end
	if options.commandNamespace ~= nil and type(options.commandNamespace) ~= "string" then
		error("Runtime.new commandNamespace must be a string", 2)
	end
	if options.onError ~= nil and type(options.onError) ~= "function" then
		error("Runtime.new onError must be a function", 2)
	end
	local traceHandler = options.traceHandler
	if traceHandler == nil then
		if type(options.trace) == "function" then
			traceHandler = options.trace
		elseif type(options.trace) == "table" then
			traceHandler = options.trace.handler
		end
	end
	if traceHandler ~= nil and type(traceHandler) ~= "function" then
		error("Runtime.new trace handler must be a function", 2)
	end
	local maxReactionChain = options.maxReactionChain or 100
	assertInteger(maxReactionChain, "Runtime.new maxReactionChain", 1, 2)
	local maxEvaluationDepth = options.maxEvaluationDepth or 128
	assertInteger(maxEvaluationDepth, "Runtime.new maxEvaluationDepth", 1, 2)
	local effectPolicy = options.effects or "confirmed"
	if effectPolicy ~= "speculative" and effectPolicy ~= "confirmed" and effectPolicy ~= "local" then
		error("Runtime.new effects must be 'speculative', 'confirmed', or 'local'", 2)
	end
	local history = nil
	if options.history ~= nil and options.history ~= false then
		local historyOptions = if options.history == true then {} else options.history
		if type(historyOptions) ~= "table" then
			error("Runtime.new history must be true, false, or a table", 2)
		end
		local capacity = historyOptions.capacity or 120
		assertInteger(capacity, "Runtime.new history.capacity", 1, 2)
		local strategy = historyOptions.strategy or "snapshot"
		if strategy ~= "snapshot" then
			error("Runtime.new preview currently supports history.strategy = 'snapshot'", 2)
		end
		history = {
			capacity = capacity,
			strategy = strategy,
			entries = {},
			byTick = {},
			head = 1,
			count = 0,
		}
	end
	local runtime = setmetatable({
		_tag = RUNTIME_TAG,
		_id = false,
		_label = options.label,
		_commandNamespace = options.commandNamespace or options.label or "runtime",
		_phase = "idle",
		_disposed = false,
		_faulted = false,
		_faultReason = nil,
		_deterministic = options.deterministic == true,
		_clock = options.clock,
		_effectPolicy = effectPolicy,
		_traceHandler = traceHandler,
		_onError = options.onError,
		_nodes = {},
		_nodesById = {},
		_watchers = {},
		_scopes = {},
		_nextNodeId = 0,
		_nextWatchId = 0,
		_nextScopeId = 0,
		_nextTransactionId = 0,
		_activeTransaction = nil,
		_evaluationStack = {},
		_queuedTransactions = {},
		_drainingTransactions = false,
		_maxReactionChain = maxReactionChain,
		_maxEvaluationDepth = maxEvaluationDepth,
		_tick = options.initialTick,
		_confirmedTick = nil,
		_history = history,
		_outbox = {},
		_coalescingReplay = false,
	}, Runtime)
	if runtime._tick ~= nil then
		assertInteger(runtime._tick, "Runtime.new initialTick", 0, 2)
	end
	runtime._id = options.id or tostring(runtime)
	runtime:_trace("runtime:create", "deterministic", runtime._deterministic, "history", history ~= nil)
	return runtime
end

Runtime.create = Runtime.new

return Runtime
