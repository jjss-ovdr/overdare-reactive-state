--!nonstrict

-- Network is the engine-neutral protocol layer.  It never opens a connection
-- and never treats client data as authoritative state.  An engine adapter is
-- expected to transport the plain payload tables returned by this module.

local Codec
local Hash

if script ~= nil then
	Codec = require(script.Parent.Core.Codec)
	Hash = require(script.Parent.Core.Hash)
else
	-- Standalone Luau hosts disagree on whether a nested require is resolved
	-- from this file, the entry script, or the process working directory.  Try
	-- the local package layouts we support; none of these paths performs
	-- dynamic/network loading.
	local function requireCore(name)
		local attempts = {
			"../Core/" .. name,
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
		error("Network could not load Core/" .. name .. ": " .. table.concat(messages, " | "), 0)
	end
	Codec = requireCore("Codec")
	Hash = requireCore("Hash")
end

local Network = {}

Network.PROTOCOL_VERSION = 1
Network.CANONICAL_VERSION = Hash.CANONICAL_VERSION
Network.SERVER_TO_CLIENT = "serverToClient"
Network.CLIENT_INTENT = "clientIntent"

local MAX_SAFE_INTEGER = 9007199254740991
local SCHEMA_TAG = {}
local DELETE = {}
Network.DELETE = DELETE

local DEFAULT_LIMITS = {
	maxFields = 64,
	maxDepth = 8,
	maxElements = 1024,
	maxStringLength = 4096,
}

local function copyTable(value)
	local result = {}
	for key, child in next, value do
		result[key] = child
	end
	return result
end

local function success(code, values)
	local result = values or {}
	result.ok = true
	result.code = code
	result.status = code
	return result
end

local function failure(code, message, values)
	local result = values or {}
	result.ok = false
	result.code = code
	result.status = code
	result.message = message
	return result
end

local function resyncFailure(code, message, values)
	local result = failure(code, message, values)
	result.requestResync = true
	return result
end

local function isFinite(value)
	return value == value and value ~= math.huge and value ~= -math.huge
end

local function isSafeInteger(value, minimum)
	return type(value) == "number"
		and isFinite(value)
		and value % 1 == 0
		and value >= minimum
		and value <= MAX_SAFE_INTEGER
end

local function assertPositiveInteger(value, label)
	if not isSafeInteger(value, 1) then
		error(string.format("%s must be a positive safe integer", label), 3)
	end
	return value
end

local function readConfiguredLimit(options, inherited, key)
	local value = nil
	if options ~= nil and options.limits ~= nil then
		value = options.limits[key]
	end
	if value == nil and options ~= nil then
		value = options[key]
	end
	if value == nil and inherited ~= nil then
		value = inherited[key]
	end
	if value == nil then
		value = DEFAULT_LIMITS[key]
	end
	return assertPositiveInteger(value, "Network limit '" .. key .. "'")
end

local function compileLimits(options, inherited)
	return {
		maxFields = readConfiguredLimit(options, inherited, "maxFields"),
		maxDepth = readConfiguredLimit(options, inherited, "maxDepth"),
		maxElements = readConfiguredLimit(options, inherited, "maxElements"),
		maxStringLength = readConfiguredLimit(options, inherited, "maxStringLength"),
	}
end

local DIRECTION_ALIASES = {
	["serverToClient"] = Network.SERVER_TO_CLIENT,
	["server-to-client"] = Network.SERVER_TO_CLIENT,
	["server_to_client"] = Network.SERVER_TO_CLIENT,
	state = Network.SERVER_TO_CLIENT,
	["clientIntent"] = Network.CLIENT_INTENT,
	["client-intent"] = Network.CLIENT_INTENT,
	["client_intent"] = Network.CLIENT_INTENT,
	intent = Network.CLIENT_INTENT,
	["client-to-server"] = Network.CLIENT_INTENT,
	["client_to_server"] = Network.CLIENT_INTENT,
}

local function normalizeDirection(direction, key)
	local normalized = DIRECTION_ALIASES[direction]
	if normalized == nil then
		error(string.format(
			"Network field '%s' has invalid direction '%s'; expected '%s' or '%s'",
			key,
			tostring(direction),
			Network.SERVER_TO_CLIENT,
			Network.CLIENT_INTENT
		), 3)
	end
	return normalized
end

local function allowsServerState(field)
	return field.direction == Network.SERVER_TO_CLIENT
end

local function allowsClientIntent(field)
	return field.direction == Network.CLIENT_INTENT
end

local function assertMethod(value, methodName, label)
	if value ~= nil and (type(value) ~= "table" or type(value[methodName]) ~= "function") then
		error(string.format("%s must provide :%s()", label, methodName), 3)
	end
end

local Schema = {}
Schema.__index = Schema

function Schema:getField(key)
	return self._byKey[key]
end

function Schema:getFields()
	local result = {}
	for index, field in ipairs(self._ordered) do
		result[index] = field
	end
	return result
end

local function collectFieldDefinitions(fields)
	if type(fields) ~= "table" or getmetatable(fields) ~= nil then
		error("Network.defineSchema fields must be a plain array or key-to-field table", 3)
	end

	local numeric = {}
	local named = {}
	for key, value in next, fields do
		if type(key) == "number" then
			if not isSafeInteger(key, 1) then
				error("Network.defineSchema array indices must be positive integers", 3)
			end
			numeric[#numeric + 1] = { index = key, value = value }
		elseif type(key) == "string" then
			named[#named + 1] = { key = key, value = value }
		else
			error("Network.defineSchema fields may only use numeric array indices or string network keys", 3)
		end
	end

	if #numeric > 0 and #named > 0 then
		error("Network.defineSchema fields cannot mix array indices and named entries", 3)
	end

	local result = {}
	if #numeric > 0 then
		table.sort(numeric, function(left, right)
			return left.index < right.index
		end)
		for index, entry in ipairs(numeric) do
			if entry.index ~= index then
				error(string.format("Network.defineSchema fields array is sparse at index %d", index), 3)
			end
			result[index] = entry.value
		end
	else
		table.sort(named, function(left, right)
			return left.key < right.key
		end)
		for index, entry in ipairs(named) do
			if type(entry.value) ~= "table" then
				error(string.format("Network field '%s' must be a table", entry.key), 3)
			end
			local definition = copyTable(entry.value)
			if definition.key == nil then
				definition.key = entry.key
			elseif definition.key ~= entry.key then
				error(string.format("Network named field '%s' declares mismatched key '%s'", entry.key, tostring(definition.key)), 3)
			end
			result[index] = definition
		end
	end
	return result
end

function Network.defineSchema(fields, options)
	options = options or {}
	if type(options) ~= "table" then
		error("Network.defineSchema options must be a table", 2)
	end

	local schemaVersion = options.schemaVersion or options.version or 1
	assertPositiveInteger(schemaVersion, "Network schemaVersion")
	local protocolVersion = options.protocolVersion or Network.PROTOCOL_VERSION
	if protocolVersion ~= Network.PROTOCOL_VERSION then
		error(string.format(
			"Network protocolVersion %s is unsupported by this module (expected %d)",
			tostring(protocolVersion),
			Network.PROTOCOL_VERSION
		), 2)
	end

	local limits = compileLimits(options, nil)
	local definitions = collectFieldDefinitions(fields)
	if #definitions == 0 then
		error("Network.defineSchema requires at least one field", 2)
	end
	if #definitions > limits.maxFields then
		error(string.format(
			"Network schema has %d fields, exceeding maxFields=%d",
			#definitions,
			limits.maxFields
		), 2)
	end

	local ordered = {}
	local byKey = {}
	for index, definition in ipairs(definitions) do
		if type(definition) ~= "table" or getmetatable(definition) ~= nil then
			error(string.format("Network field #%d must be a plain table", index), 2)
		end
		local key = definition.key
		if type(key) ~= "string" or key == "" then
			error(string.format("Network field #%d requires a non-empty stable string key", index), 2)
		end
		if #key > limits.maxStringLength then
			error(string.format("Network field key '%s' exceeds maxStringLength=%d", key, limits.maxStringLength), 2)
		end
		if byKey[key] ~= nil then
			error(string.format("Network schema contains duplicate field key '%s'", key), 2)
		end

		assertMethod(definition.source, "get", "Network field '" .. key .. "' source")
		assertMethod(definition.target, "set", "Network field '" .. key .. "' target")
		if definition.validate ~= nil and type(definition.validate) ~= "function" then
			error(string.format("Network field '%s' validate must be a function", key), 2)
		end
		if definition.project ~= nil and type(definition.project) ~= "function" then
			error(string.format("Network field '%s' project must be a function", key), 2)
		end
		if definition.visibility ~= nil and type(definition.visibility) ~= "function" then
			error(string.format("Network field '%s' visibility must be a function", key), 2)
		end
		local predictType = type(definition.predict)
		if definition.predict ~= nil
			and predictType ~= "boolean"
			and predictType ~= "function"
			and not (predictType == "table" and type(definition.predict.apply) == "function")
		then
			error(string.format("Network field '%s' predict must be a boolean, function, or { apply = function }", key), 2)
		end

		local codec = definition.codec or Codec.default
		if type(codec) ~= "table" or type(codec.encode) ~= "function" or type(codec.decode) ~= "function" then
			error(string.format("Network field '%s' codec must provide encode() and decode()", key), 2)
		end
		if codec.validate ~= nil and type(codec.validate) ~= "function" then
			error(string.format("Network field '%s' codec.validate must be a function", key), 2)
		end

		local field = copyTable(definition)
		field.key = key
		field.direction = normalizeDirection(definition.direction, key)
		field.codec = codec
		ordered[#ordered + 1] = field
		byKey[key] = field
	end

	table.sort(ordered, function(left, right)
		return left.key < right.key
	end)

	local publicFields = {}
	for index, field in ipairs(ordered) do
		publicFields[index] = field
	end

	return setmetatable({
		_tag = SCHEMA_TAG,
		_ordered = ordered,
		_byKey = byKey,
		_limits = limits,
		protocolVersion = protocolVersion,
		schemaVersion = schemaVersion,
		version = schemaVersion,
		id = options.id,
		fields = publicFields,
	}, Schema)
end

local function assertSchema(schema, constructorName)
	if type(schema) ~= "table" or schema._tag ~= SCHEMA_TAG then
		error(constructorName .. " requires a schema returned by Network.defineSchema", 3)
	end
	return schema
end

local function appendPath(path, key)
	if type(key) == "string" then
		return path .. "[" .. string.format("%q", key) .. "]"
	end
	return path .. "[" .. tostring(key) .. "]"
end

local function inspectWireValue(value, path, depth, limits, budget, active)
	local valueType = type(value)
	if valueType == "nil" or valueType == "boolean" then
		return true
	elseif valueType == "number" then
		if not isFinite(value) then
			return false, path .. " contains NaN or infinity, which is not allowed on the wire"
		end
		return true
	elseif valueType == "string" then
		if #value > limits.maxStringLength then
			return false, tostring(path)
				.. " string length "
				.. tostring(#value)
				.. " exceeds maxStringLength="
				.. tostring(limits.maxStringLength)
		end
		return true
	elseif valueType ~= "table" then
		return false, tostring(path) .. " contains unsupported wire type '" .. tostring(valueType) .. "'"
	end

	if getmetatable(value) ~= nil then
		return false, path .. " must be a plain table without a metatable"
	end
	if depth >= limits.maxDepth then
		return false, tostring(path) .. " exceeds maxDepth=" .. tostring(limits.maxDepth)
	end
	if active[value] ~= nil then
		return false, "cycle detected at " .. tostring(path) .. " (already active at " .. tostring(active[value]) .. ")"
	end

	active[value] = path
	for key, child in next, value do
		local keyType = type(key)
		if keyType ~= "boolean" and keyType ~= "number" and keyType ~= "string" then
			active[value] = nil
			return false, tostring(path) .. " has unsupported key type '" .. tostring(keyType) .. "'"
		end
		if keyType == "number" and not isFinite(key) then
			active[value] = nil
			return false, path .. " has a NaN or infinite numeric key"
		end
		if keyType == "string" and #key > limits.maxStringLength then
			active[value] = nil
			return false, tostring(path) .. " key exceeds maxStringLength=" .. tostring(limits.maxStringLength)
		end

		budget.elements = budget.elements + 1
		if budget.elements > limits.maxElements then
			active[value] = nil
			return false, "wire values exceed maxElements=" .. tostring(limits.maxElements) .. " at " .. tostring(path)
		end
		local ok, message = inspectWireValue(child, appendPath(path, key), depth + 1, limits, budget, active)
		if not ok then
			active[value] = nil
			return false, message
		end
	end
	active[value] = nil
	return true
end

local function validateValueBudget(value, path, limits, budget)
	return inspectWireValue(value, path, 0, limits, budget or { elements = 0 }, {})
end

local function callValidator(validator, value, context, label)
	if validator == nil then
		return true
	end
	local called, valid, message = pcall(validator, value, context)
	if not called then
		return false, string.format("%s raised an error: %s", label, tostring(valid))
	end
	if valid ~= true then
		return false, string.format("%s rejected the value%s", label, if message ~= nil then ": " .. tostring(message) else "")
	end
	return true
end

local function validateDecodedField(field, value, context)
	local ok, message = callValidator(field.codec.validate, value, context, "codec validator for field '" .. field.key .. "'")
	if not ok then
		return false, message
	end
	return callValidator(field.validate, value, context, "validator for field '" .. field.key .. "'")
end

local function encodeField(field, value, context, limits, budget)
	local valid, validationMessage = validateDecodedField(field, value, context)
	if not valid then
		return false, nil, validationMessage
	end
	local called, encoded = pcall(field.codec.encode, value)
	if not called then
		return false, nil, string.format("codec.encode for field '%s' failed: %s", field.key, tostring(encoded))
	end
	if encoded == nil then
		return true, nil, nil
	end
	local wireOk, wireMessage = validateValueBudget(encoded, "$changes[" .. string.format("%q", field.key) .. "].value", limits, budget)
	if not wireOk then
		return false, nil, wireMessage
	end
	local cloneOk, cloned = pcall(Codec.default.clone, encoded)
	if not cloneOk then
		return false, nil, string.format("encoded field '%s' could not be cloned: %s", field.key, tostring(cloned))
	end
	return true, cloned, nil
end

local function decodeField(field, encoded, context, limits, budget)
	if encoded ~= nil then
		local wireOk, wireMessage = validateValueBudget(encoded, "$changes[" .. string.format("%q", field.key) .. "].value", limits, budget)
		if not wireOk then
			return false, nil, wireMessage
		end
	end
	local called, decoded = pcall(field.codec.decode, encoded)
	if not called then
		return false, nil, string.format("codec.decode for field '%s' failed: %s", field.key, tostring(decoded))
	end
	local decodedOk, decodedMessage = validateValueBudget(decoded, "$decoded[" .. string.format("%q", field.key) .. "]", limits, budget)
	if not decodedOk then
		return false, nil, "decoded value is unsafe: " .. decodedMessage
	end
	local valid, validationMessage = validateDecodedField(field, decoded, context)
	if not valid then
		return false, nil, validationMessage
	end
	return true, decoded, nil
end

local function cloneWire(value)
	if value == nil then
		return nil
	end
	return Codec.default.clone(value)
end

local function wireEquals(left, right)
	if left == nil or right == nil then
		return left == right
	end
	return Codec.default.equals(left, right)
end

local function validatePlainArray(value, label, maximum)
	if type(value) ~= "table" or getmetatable(value) ~= nil then
		return false, nil, label .. " must be a plain array"
	end
	local count = 0
	local largest = 0
	for key in next, value do
		if not isSafeInteger(key, 1) then
			return false, nil, label .. " must contain only positive integer indices"
		end
		count = count + 1
		if key > largest then
			largest = key
		end
	end
	if largest ~= count then
		return false, nil, label .. " must not be sparse"
	end
	if count > maximum then
		return false, nil, string.format("%s has %d entries, exceeding maxFields=%d", label, count, maximum)
	end
	return true, count, nil
end

local function rejectUnknownKeys(value, allowed, label)
	for key in next, value do
		if type(key) ~= "string" or not allowed[key] then
			return false, string.format("%s contains unknown key '%s'", label, tostring(key))
		end
	end
	return true
end

local CHANGE_KEYS = { key = true, op = true, value = true }

local function parseChanges(changes, schema, limits, directionTest, context, encodedInput, requireFull)
	local arrayOk, count, arrayMessage = validatePlainArray(changes, "payload.changes", limits.maxFields)
	if not arrayOk then
		return false, nil, nil, arrayMessage
	end

	local parsed = {}
	local seen = {}
	local previousKey = nil
	local budget = { elements = 0 }
	for index = 1, count do
		local change = changes[index]
		if type(change) ~= "table" or getmetatable(change) ~= nil then
			return false, nil, nil, string.format("payload.changes[%d] must be a plain table", index)
		end
		local keysOk, keysMessage = rejectUnknownKeys(change, CHANGE_KEYS, "payload.changes[" .. tostring(index) .. "]")
		if not keysOk then
			return false, nil, nil, keysMessage
		end
		local key = change.key
		if type(key) ~= "string" or key == "" or #key > limits.maxStringLength then
			return false, nil, nil, string.format("payload.changes[%d].key must be a bounded non-empty string", index)
		end
		if previousKey ~= nil and key <= previousKey then
			return false, nil, nil, "payload.changes must use unique keys in canonical ascending order"
		end
		previousKey = key
		local field = schema._byKey[key]
		if field == nil then
			return false, nil, nil, string.format("payload references unregistered field '%s'", key)
		end
		if not directionTest(field) then
			return false, nil, nil, string.format("field '%s' is not allowed in this payload direction", key)
		end
		if seen[key] then
			return false, nil, nil, string.format("payload contains duplicate field '%s'", key)
		end
		seen[key] = true

		local op = change.op or "set"
		if op ~= "set" and op ~= "delete" then
			return false, nil, nil, string.format("field '%s' has invalid op '%s'", key, tostring(op))
		end
		if op == "set" and rawget(change, "value") == nil then
			return false, nil, nil, string.format("field '%s' set operation requires a non-nil encoded value; use op='delete' for nil", key)
		end

		local decoded
		local wire
		if op == "delete" then
			-- A server-state delete also represents visibility loss, so it must be
			-- able to clear a target whose ordinary value validator rejects nil.
			-- Client-originated deletes are opt-in because they are untrusted intent.
			if directionTest == allowsClientIntent and field.allowDelete ~= true then
				return false, nil, nil, string.format("client intent field '%s' does not allow delete", key)
			end
			decoded = nil
		else
			if encodedInput then
				local decodedOk, decodedValue, decodedMessage = decodeField(field, change.value, context, limits, budget)
				if not decodedOk then
					return false, nil, nil, decodedMessage
				end
				wire = cloneWire(change.value)
				decoded = decodedValue
			else
				local encodedOk, encodedValue, encodedMessage = encodeField(field, change.value, context, limits, budget)
				if not encodedOk then
					return false, nil, nil, encodedMessage
				end
				wire = encodedValue
				decoded = change.value
				if wire == nil then
					op = "delete"
				end
			end
		end
		parsed[#parsed + 1] = { key = key, field = field, op = op, wire = wire, value = decoded }
	end

	if requireFull then
		for _, field in ipairs(schema._ordered) do
			if allowsServerState(field) and not seen[field.key] then
				return false, nil, nil, string.format("snapshot is missing registered server field '%s'", field.key)
			end
		end
	end

	return true, parsed, seen, nil
end

local function makeCanonicalChanges(parsed)
	local changes = {}
	for index, item in ipairs(parsed) do
		local change = { key = item.key, op = item.op }
		if item.op == "set" then
			change.value = cloneWire(item.wire)
		end
		changes[index] = change
	end
	return changes
end

local function hashProjection(schema, wireByKey)
	local fields = {}
	for _, field in ipairs(schema._ordered) do
		if allowsServerState(field) then
			local wire = wireByKey[field.key]
			local entry = { key = field.key, op = if wire == nil then "delete" else "set" }
			if wire ~= nil then
				entry.value = wire
			end
			fields[#fields + 1] = entry
		end
	end
	return Hash.hash({
		protocolVersion = schema.protocolVersion,
		schemaVersion = schema.schemaVersion,
		canonicalVersion = Hash.CANONICAL_VERSION,
		fields = fields,
	})
end

local function resolveTick(explicitTick, context, runtime, getTick)
	local tick = explicitTick
	if tick == nil and type(context) == "table" then
		tick = context.tick or context.serverTick or context.clientTick
	end
	if tick == nil and getTick ~= nil then
		local ok, value = pcall(getTick, context)
		if ok then
			tick = value
		else
			return false, nil, "tick provider failed: " .. tostring(value)
		end
	end
	if tick == nil and runtime ~= nil and type(runtime.getTick) == "function" then
		local ok, value = pcall(runtime.getTick, runtime)
		if ok then
			tick = value
		end
	end
	if tick == nil then
		tick = 0
	end
	if not isSafeInteger(tick, 0) then
		return false, nil, "tick must be a non-negative safe integer"
	end
	return true, tick, nil
end

-- Server --------------------------------------------------------------------

local Server = {}
Server.__index = Server

local function newServerClientState()
	return {
		revision = 0,
		outSequence = 0,
		lastIntentSequence = 0,
		lastIntentTick = 0,
		lastServerTick = 0,
		baseline = {},
	}
end

function Network.createServer(options)
	if type(options) ~= "table" then
		error("Network.createServer options must be a table", 2)
	end
	local schema = assertSchema(options.schema, "Network.createServer")
	for _, field in ipairs(schema._ordered) do
		if allowsServerState(field) and (field.source == nil or type(field.source.get) ~= "function") then
			error(string.format("Network.createServer field '%s' requires a readable source", field.key), 2)
		end
	end
	if options.runtime ~= nil and type(options.runtime.transaction) ~= "function" then
		error("Network.createServer runtime must provide :transaction()", 2)
	end
	if options.onIntent ~= nil and type(options.onIntent) ~= "function" then
		error("Network.createServer onIntent must be a function", 2)
	end
	if options.authorize ~= nil and type(options.authorize) ~= "function" then
		error("Network.createServer authorize must be a function", 2)
	end
	return setmetatable({
		_schema = schema,
		_limits = compileLimits(options, schema._limits),
		_runtime = options.runtime,
		_getTick = options.getTick,
		_onIntent = options.onIntent,
		_authorize = options.authorize,
		_clients = {},
		_disposed = false,
	}, Server)
end

function Server:_client(clientId, create)
	local state = self._clients[clientId]
	if state == nil and create then
		state = newServerClientState()
		self._clients[clientId] = state
	end
	return state
end

function Server:_project(clientId, context)
	local wireByKey = {}
	local budget = { elements = 0 }
	for _, field in ipairs(self._schema._ordered) do
		if allowsServerState(field) then
			local readOk, value = pcall(field.source.get, field.source)
			if not readOk then
				return false, nil, string.format("source read for field '%s' failed: %s", field.key, tostring(value))
			end
			local included = true
			if field.visibility ~= nil then
				local visibleOk, visible = pcall(field.visibility, clientId, value, context)
				if not visibleOk then
					return false, nil, string.format("visibility for field '%s' failed: %s", field.key, tostring(visible))
				end
				included = visible == true
			end
			if included and field.project ~= nil then
				local projectOk, projected, projectIncluded = pcall(field.project, value, clientId, context)
				if not projectOk then
					return false, nil, string.format("project for field '%s' failed: %s", field.key, tostring(projected))
				end
				value = projected
				if projectIncluded == false then
					included = false
				end
			end
			if included then
				local encodedOk, wire, encodedMessage = encodeField(field, value, {
					phase = "serverEncode",
					clientId = clientId,
					context = context,
				}, self._limits, budget)
				if not encodedOk then
					return false, nil, encodedMessage
				end
				if wire ~= nil then
					wireByKey[field.key] = wire
				end
			end
		end
	end
	return true, wireByKey, nil
end

function Server:_build(kind, clientId, tickOrContext, context)
	if self._disposed then
		return failure("disposed", "Network server is disposed")
	end
	if clientId == nil then
		return failure("invalid_client", "clientId must not be nil")
	end
	local explicitTick = tickOrContext
	if type(tickOrContext) == "table" and context == nil then
		context = tickOrContext
		explicitTick = nil
	end
	context = context or {}
	local tickOk, tick, tickMessage = resolveTick(explicitTick, context, self._runtime, self._getTick)
	if not tickOk then
		return failure("invalid_tick", tickMessage)
	end

	local state = self:_client(clientId, true)
	if tick < state.lastServerTick then
		return failure("stale_tick", string.format("server tick %d is older than client baseline tick %d", tick, state.lastServerTick))
	end
	local projectOk, wireByKey, projectMessage = self:_project(clientId, context)
	if not projectOk then
		return failure("encode_failed", projectMessage)
	end

	local parsed = {}
	for _, field in ipairs(self._schema._ordered) do
		if allowsServerState(field) then
			local wire = wireByKey[field.key]
			local changed = kind == "snapshot" or not wireEquals(wire, state.baseline[field.key])
			if changed then
				parsed[#parsed + 1] = {
					key = field.key,
					op = if wire == nil then "delete" else "set",
					wire = wire,
				}
			end
		end
	end

	local hashOk, stateHash = pcall(hashProjection, self._schema, wireByKey)
	if not hashOk then
		return failure("hash_failed", "could not hash projected state: " .. tostring(stateHash))
	end
	local baseRevision = if kind == "snapshot" then 0 else state.revision
	local revision = state.revision + 1
	local sequence = state.outSequence + 1
	local payload = {
		kind = kind,
		protocolVersion = self._schema.protocolVersion,
		schemaVersion = self._schema.schemaVersion,
		sequence = sequence,
		baseRevision = baseRevision,
		revision = revision,
		tick = tick,
		stateHash = stateHash,
		ackSequence = state.lastIntentSequence,
		changes = makeCanonicalChanges(parsed),
	}

	local baseline = {}
	for _, field in ipairs(self._schema._ordered) do
		if allowsServerState(field) and wireByKey[field.key] ~= nil then
			baseline[field.key] = cloneWire(wireByKey[field.key])
		end
	end
	state.baseline = baseline
	state.revision = revision
	state.outSequence = sequence
	state.lastServerTick = tick

	return success(kind .. "_created", {
		payload = payload,
		kind = kind,
		sequence = sequence,
		baseRevision = baseRevision,
		revision = revision,
		stateHash = stateHash,
	})
end

function Server:createSnapshot(clientId, tickOrContext, context)
	return self:_build("snapshot", clientId, tickOrContext, context)
end

function Server:createPatch(clientId, tickOrContext, context)
	return self:_build("patch", clientId, tickOrContext, context)
end

Server.snapshot = Server.createSnapshot
Server.patch = Server.createPatch
Server.buildSnapshot = Server.createSnapshot
Server.buildPatch = Server.createPatch

local INTENT_KEYS = {
	kind = true,
	protocolVersion = true,
	schemaVersion = true,
	sequence = true,
	clientTick = true,
	tick = true,
	changes = true,
}

function Server:acceptIntent(clientId, payload, context)
	if self._disposed then
		return failure("disposed", "Network server is disposed")
	end
	if clientId == nil then
		return failure("invalid_client", "clientId must not be nil")
	end
	if type(payload) ~= "table" or getmetatable(payload) ~= nil then
		return failure("malformed_intent", "intent payload must be a plain table")
	end
	local keysOk, keysMessage = rejectUnknownKeys(payload, INTENT_KEYS, "intent payload")
	if not keysOk then
		return failure("malformed_intent", keysMessage)
	end
	if payload.kind ~= "intent" then
		return failure("malformed_intent", "intent payload.kind must be 'intent'")
	end
	if payload.protocolVersion ~= self._schema.protocolVersion then
		return failure("protocol_mismatch", string.format("intent protocolVersion %s does not match %d", tostring(payload.protocolVersion), self._schema.protocolVersion))
	end
	if payload.schemaVersion ~= self._schema.schemaVersion then
		return failure("schema_mismatch", string.format("intent schemaVersion %s does not match %d", tostring(payload.schemaVersion), self._schema.schemaVersion))
	end
	if not isSafeInteger(payload.sequence, 1) then
		return failure("malformed_intent", "intent sequence must be a positive safe integer")
	end
	local clientTick = payload.clientTick
	if clientTick == nil then
		clientTick = payload.tick
	end
	if not isSafeInteger(clientTick, 0) then
		return failure("malformed_intent", "intent clientTick must be a non-negative safe integer")
	end

	local state = self:_client(clientId, true)
	if payload.sequence <= state.lastIntentSequence then
		local code = if payload.sequence == state.lastIntentSequence then "duplicate_intent" else "stale_intent"
		return failure(code, string.format("intent sequence %d is not newer than last accepted sequence %d", payload.sequence, state.lastIntentSequence), {
			ackSequence = state.lastIntentSequence,
		})
	end
	local expectedSequence = state.lastIntentSequence + 1
	if payload.sequence > expectedSequence then
		return failure("intent_sequence_gap", string.format(
			"intent sequence %d skipped expected sequence %d",
			payload.sequence,
			expectedSequence
		), {
			ackSequence = state.lastIntentSequence,
			expectedSequence = expectedSequence,
			requestResync = true,
		})
	end
	if clientTick < state.lastIntentTick then
		return failure("stale_intent_tick", string.format("intent clientTick %d is older than last accepted tick %d", clientTick, state.lastIntentTick))
	end

	context = context or {}
	local parseContext = {
		phase = "serverIntent",
		clientId = clientId,
		sequence = payload.sequence,
		clientTick = clientTick,
		context = context,
	}
	local parsedOk, parsed, _, parsedMessage = parseChanges(
		payload.changes,
		self._schema,
		self._limits,
		allowsClientIntent,
		parseContext,
		true,
		false
	)
	if not parsedOk then
		return failure("intent_rejected", parsedMessage, { ackSequence = state.lastIntentSequence })
	end

	local actions = {}
	for index, item in ipairs(parsed) do
		local action = {
			key = item.key,
			value = item.value,
			sequence = payload.sequence,
			clientTick = clientTick,
			clientId = clientId,
			field = item.field,
		}
		if self._authorize ~= nil then
			local called, allowed, message = pcall(self._authorize, clientId, action, context)
			if not called then
				return failure("authorization_error", string.format("authorize failed for field '%s': %s", item.key, tostring(allowed)))
			end
			if allowed ~= true then
				return failure("unauthorized_intent", string.format("intent field '%s' was not authorized%s", item.key, if message ~= nil then ": " .. tostring(message) else ""), {
					ackSequence = state.lastIntentSequence,
				})
			end
		end
		actions[index] = action
	end

	if self._onIntent ~= nil then
		local function applyActions()
			local accepted, message = self._onIntent(clientId, actions, parseContext)
			if accepted == false then
				error("intent handler rejected the action batch" .. (if message ~= nil then ": " .. tostring(message) else ""), 0)
			end
		end
		local called, applyError
		if self._runtime ~= nil then
			called, applyError = pcall(self._runtime.transaction, self._runtime, applyActions, {
				cause = "network",
				phase = "intent",
				tick = clientTick,
				sequence = payload.sequence,
				clientId = clientId,
			})
		else
			called, applyError = pcall(applyActions)
		end
		if not called then
			return failure("intent_handler_failed", "intent action batch was not committed: " .. tostring(applyError), {
				ackSequence = state.lastIntentSequence,
			})
		end
	end

	state.lastIntentSequence = payload.sequence
	state.lastIntentTick = clientTick
	return success("intent_accepted", {
		sequence = payload.sequence,
		ackSequence = payload.sequence,
		clientTick = clientTick,
		actions = actions,
	})
end

function Server:getClientStatus(clientId)
	local state = self:_client(clientId, false)
	if state == nil then
		return success("client_unknown", { exists = false })
	end
	return success("client_status", {
		exists = true,
		revision = state.revision,
		sequence = state.outSequence,
		ackSequence = state.lastIntentSequence,
		tick = state.lastServerTick,
	})
end

function Server:resetClient(clientId)
	if self._disposed then
		return failure("disposed", "Network server is disposed")
	end
	local existed = self._clients[clientId] ~= nil
	self._clients[clientId] = nil
	return success("client_reset", { existed = existed })
end

function Server:dispose()
	if self._disposed then
		return success("already_disposed")
	end
	self._disposed = true
	self._clients = {}
	return success("disposed")
end

Server.Destroy = Server.dispose

-- Client --------------------------------------------------------------------

local Client = {}
Client.__index = Client

function Network.createClient(options)
	if type(options) ~= "table" then
		error("Network.createClient options must be a table", 2)
	end
	local schema = assertSchema(options.schema, "Network.createClient")
	local runtime = options.runtime
	if type(runtime) ~= "table" or type(runtime.transaction) ~= "function" then
		error("Network.createClient requires a runtime with :transaction() so payloads apply atomically", 2)
	end
	for _, field in ipairs(schema._ordered) do
		if allowsServerState(field) and (field.target == nil or type(field.target.set) ~= "function") then
			error(string.format("Network.createClient field '%s' requires a writable target Atom", field.key), 2)
		end
	end
	if options.onResyncNeeded ~= nil and type(options.onResyncNeeded) ~= "function" then
		error("Network.createClient onResyncNeeded must be a function", 2)
	end
	if options.onAcknowledge ~= nil and type(options.onAcknowledge) ~= "function" then
		error("Network.createClient onAcknowledge must be a function", 2)
	end
	if options.onReconcile ~= nil and type(options.onReconcile) ~= "function" then
		error("Network.createClient onReconcile must be a function", 2)
	end
	return setmetatable({
		_schema = schema,
		_limits = compileLimits(options, schema._limits),
		_runtime = runtime,
		_getTick = options.getTick,
		_onResyncNeeded = options.onResyncNeeded,
		_onAcknowledge = options.onAcknowledge,
		_onReconcile = options.onReconcile,
		_applyPrediction = options.applyPrediction,
		_revision = 0,
		_serverSequence = 0,
		_intentSequence = 0,
		_ackSequence = 0,
		_tick = 0,
		_confirmed = {},
		_confirmedWire = {},
		_pending = {},
		_hasSnapshot = false,
		_disposed = false,
	}, Client)
end

function Client:_notifyResync(result, context)
	if self._onResyncNeeded ~= nil then
		local called, callbackError = pcall(self._onResyncNeeded, result, context)
		if not called then
			result.hookError = "onResyncNeeded failed: " .. tostring(callbackError)
		end
	end
	return result
end

local STATE_KEYS = {
	kind = true,
	protocolVersion = true,
	schemaVersion = true,
	sequence = true,
	baseRevision = true,
	revision = true,
	tick = true,
	stateHash = true,
	ackSequence = true,
	changes = true,
}

local function copyValueMap(source)
	local result = {}
	for key, value in next, source do
		result[key] = cloneWire(value)
	end
	return result
end

function Client:_applyPredictionAction(action, replayContext)
	if self._applyPrediction ~= nil then
		self._applyPrediction(action, replayContext)
		return
	end
	local field = action.field
	local predictor = field.predict
	if predictor == nil or predictor == false then
		return
	end
	if predictor == true then
		if field.target == nil then
			error(string.format("predicted field '%s' requires a target Atom", field.key), 0)
		end
		field.target:set(action.value)
	elseif type(predictor) == "function" then
		local current = if field.target ~= nil and type(field.target.get) == "function" then field.target:get() else nil
		local predicted = predictor(current, action.value, replayContext)
		if field.target ~= nil and predicted ~= nil then
			field.target:set(predicted)
		end
	else
		predictor.apply(field.target, action.value, replayContext)
	end
end

function Client:_replay(pending, context)
	for _, entry in ipairs(pending) do
		for _, action in ipairs(entry.actions) do
			self:_applyPredictionAction(action, {
				phase = "replay",
				sequence = entry.sequence,
				clientTick = entry.clientTick,
				context = context,
			})
		end
	end
end

local function collectIntentChanges(schema, values)
	local changes = {}
	if values == nil then
		for _, field in ipairs(schema._ordered) do
			if allowsClientIntent(field) then
				if field.source == nil or type(field.source.get) ~= "function" then
					return false, nil, string.format("client intent field '%s' requires a source when createIntent values are omitted", field.key)
				end
				local readOk, value = pcall(field.source.get, field.source)
				if not readOk then
					return false, nil, string.format("source read for intent field '%s' failed: %s", field.key, tostring(value))
				end
				changes[#changes + 1] = { key = field.key, op = if value == nil then "delete" else "set", value = value }
			end
		end
		return true, changes, nil
	end
	if type(values) ~= "table" or getmetatable(values) ~= nil then
		return false, nil, "createIntent values must be a plain key/value table or canonical change array"
	end

	local arrayLike = rawget(values, 1) ~= nil
	if arrayLike then
		local arrayOk, count, arrayMessage = validatePlainArray(values, "createIntent values", MAX_SAFE_INTEGER)
		if not arrayOk then
			return false, nil, arrayMessage
		end
		for index = 1, count do
			local input = values[index]
			if type(input) ~= "table" then
				return false, nil, string.format("createIntent values[%d] must be a table", index)
			end
			local op = input.op or (if input.value == DELETE or input.value == nil then "delete" else "set")
			changes[#changes + 1] = { key = input.key, op = op, value = if input.value == DELETE then nil else input.value }
		end
	else
		for key, value in next, values do
			if type(key) ~= "string" then
				return false, nil, "createIntent value-map keys must be strings"
			end
			changes[#changes + 1] = { key = key, op = if value == DELETE then "delete" else "set", value = if value == DELETE then nil else value }
		end
	end
	table.sort(changes, function(left, right)
		return tostring(left.key) < tostring(right.key)
	end)
	return true, changes, nil
end

function Client:createIntent(values, tickOrContext, context)
	if self._disposed then
		return failure("disposed", "Network client is disposed")
	end
	local explicitTick = tickOrContext
	if type(tickOrContext) == "table" and context == nil then
		context = tickOrContext
		explicitTick = nil
	end
	context = context or {}
	local tickOk, tick, tickMessage = resolveTick(explicitTick, context, self._runtime, self._getTick)
	if not tickOk then
		return failure("invalid_tick", tickMessage)
	end
	local collectedOk, rawChanges, collectedMessage = collectIntentChanges(self._schema, values)
	if not collectedOk then
		return failure("intent_build_failed", collectedMessage)
	end
	local parsedOk, parsed, _, parsedMessage = parseChanges(
		rawChanges,
		self._schema,
		self._limits,
		allowsClientIntent,
		{ phase = "clientIntent", clientTick = tick, context = context },
		false,
		false
	)
	if not parsedOk then
		return failure("intent_build_failed", parsedMessage)
	end

	local sequence = self._intentSequence + 1
	local actions = {}
	for index, item in ipairs(parsed) do
		actions[index] = {
			key = item.key,
			value = item.value,
			field = item.field,
			sequence = sequence,
			clientTick = tick,
		}
	end
	local predictionOk, predictionError = pcall(self._runtime.transaction, self._runtime, function()
		for _, action in ipairs(actions) do
			self:_applyPredictionAction(action, {
				phase = "predict",
				sequence = sequence,
				clientTick = tick,
				context = context,
			})
		end
	end, { cause = "network", phase = "predict", tick = tick, sequence = sequence })
	if not predictionOk then
		return failure("prediction_failed", "intent was not queued because prediction failed: " .. tostring(predictionError))
	end

	local payload = {
		kind = "intent",
		protocolVersion = self._schema.protocolVersion,
		schemaVersion = self._schema.schemaVersion,
		sequence = sequence,
		clientTick = tick,
		changes = makeCanonicalChanges(parsed),
	}
	self._intentSequence = sequence
	self._pending[#self._pending + 1] = {
		sequence = sequence,
		clientTick = tick,
		actions = actions,
		payload = payload,
	}
	return success("intent_created", { payload = payload, sequence = sequence, clientTick = tick })
end

Client.buildIntent = Client.createIntent

function Client:receive(payload, context)
	if self._disposed then
		return failure("disposed", "Network client is disposed")
	end
	if type(payload) ~= "table" or getmetatable(payload) ~= nil then
		return failure("malformed_payload", "network payload must be a plain table")
	end
	local keysOk, keysMessage = rejectUnknownKeys(payload, STATE_KEYS, "network payload")
	if not keysOk then
		return failure("malformed_payload", keysMessage)
	end
	if payload.kind ~= "snapshot" and payload.kind ~= "patch" then
		return failure("malformed_payload", "payload.kind must be 'snapshot' or 'patch'")
	end
	if payload.protocolVersion ~= self._schema.protocolVersion then
		return self:_notifyResync(resyncFailure("protocol_mismatch", string.format("payload protocolVersion %s does not match %d", tostring(payload.protocolVersion), self._schema.protocolVersion)), context)
	end
	if payload.schemaVersion ~= self._schema.schemaVersion then
		return self:_notifyResync(resyncFailure("schema_mismatch", string.format("payload schemaVersion %s does not match %d", tostring(payload.schemaVersion), self._schema.schemaVersion)), context)
	end
	if not isSafeInteger(payload.sequence, 1)
		or not isSafeInteger(payload.baseRevision, 0)
		or not isSafeInteger(payload.revision, 1)
		or not isSafeInteger(payload.tick, 0)
		or not isSafeInteger(payload.ackSequence, 0)
	then
		return failure("malformed_payload", "payload sequence/revisions/tick/ackSequence must be non-negative safe integers")
	end
	if type(payload.stateHash) ~= "string" or payload.stateHash == "" or #payload.stateHash > self._limits.maxStringLength then
		return failure("malformed_payload", "payload.stateHash must be a bounded non-empty string")
	end
	if payload.ackSequence > self._intentSequence then
		return failure("malformed_payload", string.format("payload acknowledges unseen intent sequence %d (latest local sequence is %d)", payload.ackSequence, self._intentSequence))
	end
	if payload.sequence <= self._serverSequence then
		local code = if payload.sequence == self._serverSequence then "duplicate_payload" else "stale_payload"
		return failure(code, string.format("payload sequence %d is not newer than %d", payload.sequence, self._serverSequence))
	end
	if payload.kind == "patch" and payload.sequence ~= self._serverSequence + 1 then
		return self:_notifyResync(resyncFailure("sequence_gap", string.format("patch sequence %d does not follow %d", payload.sequence, self._serverSequence)), context)
	end
	if payload.kind == "patch" and not self._hasSnapshot then
		return self:_notifyResync(resyncFailure("snapshot_required", "a full snapshot must be applied before the first patch"), context)
	end
	if payload.kind == "patch" and payload.baseRevision ~= self._revision then
		return self:_notifyResync(resyncFailure("revision_gap", string.format("patch baseRevision %d does not match client revision %d", payload.baseRevision, self._revision)), context)
	end
	if payload.kind == "patch" and payload.revision ~= payload.baseRevision + 1 then
		return self:_notifyResync(resyncFailure("revision_gap", "patch revision must equal baseRevision + 1"), context)
	end
	if payload.kind == "snapshot" and payload.baseRevision ~= 0 then
		return failure("malformed_payload", "snapshot baseRevision must be 0")
	end
	if payload.kind == "snapshot" and payload.revision <= self._revision then
		return failure(
			"stale_payload",
			"snapshot revision "
				.. tostring(payload.revision)
				.. " is not newer than client revision "
				.. tostring(self._revision)
		)
	end
	if payload.tick < self._tick then
		return failure("stale_payload", string.format("payload tick %d is older than confirmed tick %d", payload.tick, self._tick))
	end

	context = context or {}
	local parsedOk, parsed, _, parsedMessage = parseChanges(
		payload.changes,
		self._schema,
		self._limits,
		allowsServerState,
		{ phase = "clientReceive", sequence = payload.sequence, tick = payload.tick, context = context },
		true,
		payload.kind == "snapshot"
	)
	if not parsedOk then
		return failure("payload_rejected", parsedMessage)
	end

	local nextWire = if payload.kind == "snapshot" then {} else copyValueMap(self._confirmedWire)
	local nextConfirmed = if payload.kind == "snapshot" then {} else copyValueMap(self._confirmed)
	for _, item in ipairs(parsed) do
		if item.op == "delete" then
			nextWire[item.key] = nil
			nextConfirmed[item.key] = nil
		else
			nextWire[item.key] = cloneWire(item.wire)
			local cloneOk, clonedValue = pcall(item.field.codec.decode, item.wire)
			if not cloneOk then
				return failure("payload_rejected", string.format("could not clone decoded field '%s': %s", item.key, tostring(clonedValue)))
			end
			nextConfirmed[item.key] = clonedValue
		end
	end
	local hashOk, actualHash = pcall(hashProjection, self._schema, nextWire)
	if not hashOk then
		return failure("hash_failed", "could not hash received state: " .. tostring(actualHash))
	end
	if actualHash ~= payload.stateHash then
		return self:_notifyResync(resyncFailure("state_hash_mismatch", string.format("payload stateHash %s does not match canonical hash %s", payload.stateHash, actualHash)), context)
	end

	local acknowledged = {}
	local pending = {}
	for _, entry in ipairs(self._pending) do
		if entry.sequence <= payload.ackSequence then
			acknowledged[#acknowledged + 1] = entry
		else
			pending[#pending + 1] = entry
		end
	end
	local transactionOk, transactionError = pcall(self._runtime.transaction, self._runtime, function()
		for _, field in ipairs(self._schema._ordered) do
			if allowsServerState(field) then
				field.target:set(nextConfirmed[field.key])
			end
		end
		self:_replay(pending, context)
	end, {
		cause = "network",
		phase = "reconcile",
		tick = payload.tick,
		sequence = payload.sequence,
		revision = payload.revision,
	})
	if not transactionOk then
		return failure("apply_failed", "payload transaction failed without advancing the client baseline: " .. tostring(transactionError))
	end

	self._confirmed = nextConfirmed
	self._confirmedWire = nextWire
	self._pending = pending
	self._revision = payload.revision
	self._serverSequence = payload.sequence
	self._ackSequence = payload.ackSequence
	self._tick = payload.tick
	self._hasSnapshot = true

	local hookErrors = {}
	if self._onAcknowledge ~= nil and #acknowledged > 0 then
		local called, hookError = pcall(self._onAcknowledge, payload.ackSequence, acknowledged, context)
		if not called then
			hookErrors[#hookErrors + 1] = "onAcknowledge failed: " .. tostring(hookError)
		end
	end
	local result = success("applied", {
		kind = payload.kind,
		sequence = payload.sequence,
		baseRevision = payload.baseRevision,
		revision = payload.revision,
		tick = payload.tick,
		ackSequence = payload.ackSequence,
		acknowledgedCount = #acknowledged,
		pendingCount = #pending,
		stateHash = actualHash,
	})
	if self._onReconcile ~= nil then
		local called, hookError = pcall(self._onReconcile, result, context)
		if not called then
			hookErrors[#hookErrors + 1] = "onReconcile failed: " .. tostring(hookError)
		end
	end
	if #hookErrors > 0 then
		result.hookErrors = hookErrors
	end
	return result
end

Client.apply = Client.receive
Client.receivePayload = Client.receive

function Client:getPendingInputs()
	local result = {}
	for index, entry in ipairs(self._pending) do
		result[index] = {
			sequence = entry.sequence,
			clientTick = entry.clientTick,
			payload = entry.payload,
		}
	end
	return result
end

function Client:getStatus()
	return success("client_status", {
		revision = self._revision,
		serverSequence = self._serverSequence,
		intentSequence = self._intentSequence,
		ackSequence = self._ackSequence,
		tick = self._tick,
		pendingCount = #self._pending,
		disposed = self._disposed,
	})
end

function Client:reset()
	if self._disposed then
		return failure("disposed", "Network client is disposed")
	end
	self._revision = 0
	self._serverSequence = 0
	self._ackSequence = 0
	self._tick = 0
	self._confirmed = {}
	self._confirmedWire = {}
	self._pending = {}
	self._hasSnapshot = false
	return success("reset")
end

function Client:dispose()
	if self._disposed then
		return success("already_disposed")
	end
	self._disposed = true
	self._confirmed = {}
	self._confirmedWire = {}
	self._pending = {}
	self._hasSnapshot = false
	return success("disposed")
end

Client.Destroy = Client.dispose

-- The FRP event protocol is deliberately a separate implementation from the
-- StateRuntime snapshot/patch protocol above. Sharing the public Network
-- namespace keeps installation simple while preventing the legacy mutable
-- replicator from becoming the denotation of Event traffic.
local EventProtocol
if script ~= nil then
	EventProtocol = require(script.EventProtocol)
else
	local attempts = {
		"./EventProtocol",
		"./Network/EventProtocol",
		"../Network/EventProtocol",
		"../src/Network/EventProtocol",
		"./src/Network/EventProtocol",
	}
	local messages = {}
	for _, path in ipairs(attempts) do
		local ok, module = pcall(require, path)
		if ok then
			EventProtocol = module
			break
		end
		messages[#messages + 1] = tostring(module)
	end
	if EventProtocol == nil then
		error("Network could not load EventProtocol: " .. table.concat(messages, " | "), 0)
	end
end

Network.EVENT_PROTOCOL_VERSION = EventProtocol.EVENT_PROTOCOL_VERSION
Network.defineEventProtocol = EventProtocol.defineEventProtocol
Network.defineFRPProtocol = EventProtocol.defineEventProtocol
Network.createEventServer = EventProtocol.createEventServer
Network.createFRPServer = EventProtocol.createEventServer
Network.createEventClient = EventProtocol.createEventClient
Network.createFRPClient = EventProtocol.createEventClient

return Network
