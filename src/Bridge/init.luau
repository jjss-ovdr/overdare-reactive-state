--!nonstrict

-- Explicit, one-way, post-commit delivery between two Runtime instances.
-- A Bridge is process-local coordination, not replication or a distributed
-- transaction.

local Bridge = {}

local outgoing = setmetatable({}, { __mode = "k" })

local function runtimeName(runtime)
	local label = rawget(runtime, "_label") or rawget(runtime, "label")
	local identifier = rawget(runtime, "_id") or rawget(runtime, "id")
	if label ~= nil then
		return tostring(label)
	elseif identifier ~= nil then
		return "Runtime#" .. tostring(identifier)
	end
	return "Runtime"
end

local function sameValue(a, b)
	return rawequal(a, b) or (type(a) == "number" and type(b) == "number" and a ~= a and b ~= b)
end

local function neighbors(runtime)
	local entries = outgoing[runtime]
	if entries == nil then
		entries = setmetatable({}, { __mode = "k" })
		outgoing[runtime] = entries
	end
	return entries
end

local function findPath(fromRuntime, targetRuntime, seen, path)
	if fromRuntime == targetRuntime then
		local result = {}
		for index, runtime in ipairs(path) do
			result[index] = runtime
		end
		table.insert(result, fromRuntime)
		return result
	end
	if seen[fromRuntime] then
		return nil
	end
	seen[fromRuntime] = true
	table.insert(path, fromRuntime)

	local edges = outgoing[fromRuntime]
	if edges ~= nil then
		for nextRuntime, count in pairs(edges) do
			if count > 0 then
				local result = findPath(nextRuntime, targetRuntime, seen, path)
				if result ~= nil then
					table.remove(path)
					return result
				end
			end
		end
	end

	table.remove(path)
	return nil
end

local function formatCycle(sourceRuntime, targetRuntime, existingPath)
	local names = { runtimeName(sourceRuntime) }
	for _, runtime in ipairs(existingPath) do
		table.insert(names, runtimeName(runtime))
	end
	return table.concat(names, " -> ")
end

local function addEdge(sourceRuntime, targetRuntime)
	local path = findPath(targetRuntime, sourceRuntime, {}, {})
	if path ~= nil then
		error("Bridge cycle detected: " .. formatCycle(sourceRuntime, targetRuntime, path), 3)
	end

	local entries = neighbors(sourceRuntime)
	entries[targetRuntime] = (entries[targetRuntime] or 0) + 1
	local removed = false
	return function()
		if removed then
			return
		end
		removed = true
		local current = entries[targetRuntime]
		if current == nil or current <= 1 then
			entries[targetRuntime] = nil
		else
			entries[targetRuntime] = current - 1
		end
	end
end

local function addToScope(scope, disposable)
	assert(type(scope) == "table" and type(scope.add) == "function", "Bridge scope must implement :add()")
	scope:add(disposable)
end

function Bridge.connect(options)
	assert(type(options) == "table", "Bridge.connect expects an options table")
	local sourceRuntime = options.sourceRuntime
	local targetRuntime = options.targetRuntime
	local source = options.source
	local target = options.target
	local apply = options.apply

	assert(type(sourceRuntime) == "table" and type(sourceRuntime.watch) == "function", "sourceRuntime must be a Runtime")
	assert(type(targetRuntime) == "table" and type(targetRuntime.transaction) == "function", "targetRuntime must be a Runtime")
	assert(sourceRuntime ~= targetRuntime, "Bridge is only for different Runtime instances; pass the Source directly inside one Runtime")
	assert(type(source) == "table" and type(source.get) == "function", "source must implement the Source protocol")
	assert(options.direction == "one-way", "Bridge direction must be explicitly set to 'one-way'")
	assert(options.sourceOfTruth == sourceRuntime, "Bridge sourceOfTruth must be the sourceRuntime")
	assert((target ~= nil) ~= (apply ~= nil), "Bridge requires exactly one of target or apply")
	if target ~= nil then
		assert(type(target) == "table" and type(target.set) == "function", "Bridge target must be a writable Atom")
	else
		assert(type(apply) == "function", "Bridge apply must be a function")
	end

	local replay = options.replay or "coalesce"
	assert(replay == "coalesce" or replay == "all" or replay == "suppress", "Bridge replay must be 'coalesce', 'all', or 'suppress'")
	local map = options.map or function(value)
		return value
	end
	local equals = options.equals or sameValue
	assert(type(map) == "function", "Bridge map must be a function")
	assert(type(equals) == "function", "Bridge equals must be a function")

	local removeEdge = addEdge(sourceRuntime, targetRuntime)
	local scope = options.scope
	if scope == nil then
		assert(type(sourceRuntime.scope) == "function", "sourceRuntime must implement :scope() when no scope is supplied")
		scope = sourceRuntime:scope()
	end
	addToScope(scope, removeEdge)

	local hasLast = false
	local lastValue = nil
	local stopped = false
	local function deliver(value, previous, changeSet)
		if stopped then
			return
		end
		if replay == "suppress" and changeSet ~= nil and (changeSet.replay == true or changeSet.cause == "replay") then
			return
		end

		local mapped = map(value, previous, changeSet)
		if hasLast and equals(lastValue, mapped) then
			return
		end
		hasLast = true
		lastValue = mapped

		local metadata = {
			cause = "bridge",
			label = options.label or "Bridge.connect",
			tick = changeSet and changeSet.tick or nil,
			sourceTransactionId = changeSet and changeSet.transactionId or nil,
		}
		targetRuntime:transaction(function()
			if target ~= nil then
				target:set(mapped)
			else
				apply(mapped, {
					previous = previous,
					changeSet = changeSet,
					sourceRuntime = sourceRuntime,
					targetRuntime = targetRuntime,
				})
			end
		end, metadata)
	end

	local ok, stopOrError = pcall(function()
		return sourceRuntime:watch(source, deliver, {
			initial = options.initial ~= false,
			priority = options.priority or 0,
			replay = replay,
			label = options.label or "Bridge.connect",
		})
	end)
	if not ok then
		removeEdge()
		if options.scope == nil and type(scope.dispose) == "function" then
			scope:dispose()
		end
		error(stopOrError, 0)
	end

	local stopWatch = stopOrError
	assert(type(stopWatch) == "function", "Runtime:watch must return a stop function")
	local function stop()
		if stopped then
			return
		end
		stopped = true
		stopWatch()
		removeEdge()
	end
	addToScope(scope, stop)

	return scope
end

return Bridge
