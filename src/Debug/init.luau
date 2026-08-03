--!nonstrict

-- Optional diagnostics. Requiring this module installs no handler and creates
-- no Runtime nodes; allocation begins only when a helper is called.

local Debug = {}

local function shallowCopy(value)
	if type(value) ~= "table" then
		return value
	end
	local copy = {}
	for key, child in pairs(value) do
		copy[key] = child
	end
	return copy
end

local function sourceInfo(source)
	if type(source) == "table" and type(source.getDebugInfo) == "function" then
		return source:getDebugInfo()
	end
	assert(type(source) == "table", "Debug.explain expects a Source")
	local dependencies = rawget(source, "_dependencies") or rawget(source, "dependencies") or {}
	local dependencyInfo = {}
	for key, value in pairs(dependencies) do
		local dependency = if type(key) == "table" then key else value
		if type(dependency) == "table" then
			table.insert(dependencyInfo, {
				id = rawget(dependency, "_id") or rawget(dependency, "id"),
				label = rawget(dependency, "_label") or rawget(dependency, "label"),
				revision = rawget(dependency, "_revision") or rawget(dependency, "revision"),
			})
		end
	end
	table.sort(dependencyInfo, function(a, b)
		local aId = a.id or math.huge
		local bId = b.id or math.huge
		if aId ~= bId then
			return aId < bId
		end
		return tostring(a.label or "") < tostring(b.label or "")
	end)
	return {
		id = rawget(source, "_id") or rawget(source, "id"),
		label = rawget(source, "_label") or rawget(source, "label"),
		kind = rawget(source, "_kind") or rawget(source, "kind"),
		state = rawget(source, "_state") or rawget(source, "state"),
		revision = rawget(source, "_revision") or rawget(source, "revision"),
		lastInvalidator = rawget(source, "_lastInvalidator"),
		dependencies = dependencyInfo,
	}
end

function Debug.explain(source)
	return sourceInfo(source)
end

function Debug.inspect(runtime)
	assert(type(runtime) == "table", "Debug.inspect expects a Runtime")
	if type(runtime.getDebugSnapshot) == "function" then
		return runtime:getDebugSnapshot()
	elseif type(runtime.inspect) == "function" then
		return runtime:inspect()
	end

	local result = {
		id = rawget(runtime, "_id") or rawget(runtime, "id"),
		label = rawget(runtime, "_label") or rawget(runtime, "label"),
		tick = rawget(runtime, "_tick") or rawget(runtime, "tick"),
		disposed = rawget(runtime, "_disposed") == true,
		faulted = rawget(runtime, "_faulted") == true,
		nodes = {},
	}
	local nodes = rawget(runtime, "_nodes") or rawget(runtime, "nodes")
	if type(nodes) == "table" then
		for key, node in pairs(nodes) do
			if type(node) == "table" then
				table.insert(result.nodes, sourceInfo(node))
			elseif type(key) == "table" then
				table.insert(result.nodes, sourceInfo(key))
			end
		end
	end
	table.sort(result.nodes, function(a, b)
		local aId = a.id or math.huge
		local bId = b.id or math.huge
		if aId ~= bId then
			return aId < bId
		end
		return tostring(a.label or "") < tostring(b.label or "")
	end)
	return result
end

local function renderScalar(value)
	if type(value) == "string" then
		return value
	elseif value == nil then
		return "-"
	end
	return tostring(value)
end

function Debug.format(runtime)
	local snapshot = Debug.inspect(runtime)
	local lines = {
		string.format(
			"Runtime %s tick=%s disposed=%s faulted=%s",
			renderScalar(snapshot.label or snapshot.id),
			renderScalar(snapshot.tick),
			tostring(snapshot.disposed == true),
			tostring(snapshot.faulted == true)
		),
	}
	for _, node in ipairs(snapshot.nodes or {}) do
		table.insert(lines, string.format(
			"  [%s] %s %s state=%s revision=%s deps=%d",
			renderScalar(node.id),
			renderScalar(node.kind),
			renderScalar(node.label),
			renderScalar(node.state),
			renderScalar(node.revision),
			#(node.dependencies or {})
		))
	end
	return table.concat(lines, "\n")
end

function Debug.traceBuffer(capacity)
	capacity = capacity or 256
	assert(type(capacity) == "number" and capacity >= 1 and capacity % 1 == 0, "trace capacity must be a positive integer")
	local entries = {}
	local start = 1
	local count = 0

	local buffer = {}
	function buffer.handler(event)
		local stored = shallowCopy(event)
		if count < capacity then
			local index = ((start + count - 1) % capacity) + 1
			entries[index] = stored
			count += 1
		else
			entries[start] = stored
			start = (start % capacity) + 1
		end
	end
	function buffer.get()
		local result = {}
		for offset = 0, count - 1 do
			local index = ((start + offset - 1) % capacity) + 1
			result[offset + 1] = shallowCopy(entries[index])
		end
		return result
	end
	function buffer.clear()
		entries = {}
		start = 1
		count = 0
	end
	function buffer.size()
		return count
	end
	return buffer
end

return Debug
