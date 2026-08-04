--!nonstrict

-- EventProtocol is the engine-neutral, multiplayer-first wire protocol used by
-- the FRP RemoteEvent adapter. It owns validation, authority, sequence, rate
-- limiting, acknowledgement, replay, and snapshot epochs, but never opens an
-- engine connection. OVERDARE integration lives in Overdare/init.luau.

local Codec

if script ~= nil then
	Codec = require(script.Parent.Parent.Core.Codec)
else
	local function requireCodec()
		local attempts = {
			"../../Core/Codec",
			"../Core/Codec",
			"./Core/Codec",
			"../src/Core/Codec",
			"./src/Core/Codec",
		}
		local messages = {}
		for _, path in ipairs(attempts) do
			local ok, module = pcall(require, path)
			if ok then
				return module
			end
			messages[#messages + 1] = tostring(module)
		end
		error("Network.EventProtocol could not load Core/Codec: " .. table.concat(messages, " | "), 0)
	end
	Codec = requireCodec()
end

local EventProtocol = {}

EventProtocol.EVENT_PROTOCOL_VERSION = 1
EventProtocol.SERVER_TO_CLIENT = "serverToClient"
EventProtocol.CLIENT_INTENT = "clientIntent"

local MAX_SAFE_INTEGER = 9007199254740991
local PROTOCOL_TAG = {}
local SERVER_TAG = {}
local CLIENT_TAG = {}

local DEFAULT_LIMITS = {
	maxMessages = 64,
	maxDepth = 8,
	maxElements = 1024,
	maxStringLength = 4096,
	maxBytes = 16384,
}

local DEFAULT_RATE_LIMIT = {
	capacity = 60,
	refillPerSecond = 30,
}

local function isFinite(value)
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function isSafeInteger(value, minimum)
	return isFinite(value) and value % 1 == 0 and value >= minimum and value <= MAX_SAFE_INTEGER
end

local function assertPositiveInteger(value, label)
	if not isSafeInteger(value, 1) then
		error(label .. " must be a positive safe integer", 3)
	end
	return value
end

local function copyTable(value)
	local result = {}
	for key, child in next, value do
		result[key] = child
	end
	return result
end

local function cloneWire(value)
	if value == nil then
		return nil
	end
	return Codec.default.clone(value)
end

local function packArguments(...)
	return { n = select("#", ...), ... }
end

local function callNoYield(callback, ...)
	local arguments = packArguments(...)
	local thread = coroutine.create(function()
		return callback(table.unpack(arguments, 1, arguments.n))
	end)
	local results = packArguments(coroutine.resume(thread))
	if not results[1] then
		return false, results[2]
	end
	if coroutine.status(thread) ~= "dead" then
		return false, "callback may not yield"
	end
	return true, table.unpack(results, 2, results.n)
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

local function readLimit(options, key)
	local value = nil
	if type(options.limits) == "table" then
		value = options.limits[key]
	end
	if value == nil then
		value = options[key]
	end
	if value == nil then
		value = DEFAULT_LIMITS[key]
	end
	return assertPositiveInteger(value, "Network event limit '" .. key .. "'")
end

local function compileLimits(options)
	return {
		maxMessages = readLimit(options, "maxMessages"),
		maxDepth = readLimit(options, "maxDepth"),
		maxElements = readLimit(options, "maxElements"),
		maxStringLength = readLimit(options, "maxStringLength"),
		maxBytes = readLimit(options, "maxBytes"),
	}
end

local function compileRateLimit(value)
	if value == false then
		return nil
	end
	value = value or DEFAULT_RATE_LIMIT
	if type(value) ~= "table" then
		error("Network event rateLimit must be false or a table", 3)
	end
	local capacity = value.capacity or DEFAULT_RATE_LIMIT.capacity
	local refill = value.refillPerSecond or value.refill or DEFAULT_RATE_LIMIT.refillPerSecond
	if not isFinite(capacity) or capacity < 1 then
		error("Network event rateLimit.capacity must be a finite number >= 1", 3)
	end
	if not isFinite(refill) or refill < 0 then
		error("Network event rateLimit.refillPerSecond must be finite and non-negative", 3)
	end
	return { capacity = capacity, refillPerSecond = refill }
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
		budget.bytes += 1
		if budget.bytes > limits.maxBytes then
			return false, path .. " exceeds maxBytes=" .. tostring(limits.maxBytes)
		end
		return true
	elseif valueType == "number" then
		if not isFinite(value) then
			return false, path .. " contains NaN or infinity"
		end
		budget.bytes += 8
		if budget.bytes > limits.maxBytes then
			return false, path .. " exceeds maxBytes=" .. tostring(limits.maxBytes)
		end
		return true
	elseif valueType == "string" then
		if #value > limits.maxStringLength then
			return false, path .. " exceeds maxStringLength=" .. tostring(limits.maxStringLength)
		end
		budget.bytes += #value + 4
		if budget.bytes > limits.maxBytes then
			return false, path .. " exceeds maxBytes=" .. tostring(limits.maxBytes)
		end
		return true
	elseif valueType ~= "table" then
		return false, path .. " contains unsupported wire type '" .. valueType .. "'"
	end

	if getmetatable(value) ~= nil then
		return false, path .. " must be a plain table"
	end
	if depth >= limits.maxDepth then
		return false, path .. " exceeds maxDepth=" .. tostring(limits.maxDepth)
	end
	if active[value] ~= nil then
		return false, "cycle detected at " .. path .. " (already active at " .. active[value] .. ")"
	end

	active[value] = path
	budget.bytes += 1
	for key, child in next, value do
		local keyType = type(key)
		if keyType ~= "boolean" and keyType ~= "number" and keyType ~= "string" then
			active[value] = nil
			return false, path .. " has unsupported key type '" .. keyType .. "'"
		end
		if keyType == "number" and not isFinite(key) then
			active[value] = nil
			return false, path .. " has a NaN or infinite key"
		end
		if keyType == "string" and #key > limits.maxStringLength then
			active[value] = nil
			return false, path .. " has a key exceeding maxStringLength"
		end
		if keyType == "string" then
			budget.bytes += #key + 4
		elseif keyType == "number" then
			budget.bytes += 8
		else
			budget.bytes += 1
		end
		if budget.bytes > limits.maxBytes then
			active[value] = nil
			return false, path .. " exceeds maxBytes=" .. tostring(limits.maxBytes)
		end
		budget.elements += 1
		if budget.elements > limits.maxElements then
			active[value] = nil
			return false, "wire value exceeds maxElements=" .. tostring(limits.maxElements) .. " at " .. path
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

local function validateWire(value, path, limits)
	return inspectWireValue(value, path, 0, limits, { elements = 0, bytes = 0 }, {})
end

local function rejectUnknownKeys(value, allowed, label)
	for key in next, value do
		if type(key) ~= "string" or not allowed[key] then
			return false, label .. " contains unknown key '" .. tostring(key) .. "'"
		end
	end
	return true
end

local function stableClientId(value)
	if type(value) == "string" then
		return value ~= "" and #value <= 256
	end
	return isSafeInteger(value, 0)
end

local DIRECTION_ALIASES = {
	serverToClient = EventProtocol.SERVER_TO_CLIENT,
	["server-to-client"] = EventProtocol.SERVER_TO_CLIENT,
	["server_to_client"] = EventProtocol.SERVER_TO_CLIENT,
	state = EventProtocol.SERVER_TO_CLIENT,
	clientIntent = EventProtocol.CLIENT_INTENT,
	["client-intent"] = EventProtocol.CLIENT_INTENT,
	["client_intent"] = EventProtocol.CLIENT_INTENT,
	["client-to-server"] = EventProtocol.CLIENT_INTENT,
	["client_to_server"] = EventProtocol.CLIENT_INTENT,
	intent = EventProtocol.CLIENT_INTENT,
}

local function normalizeDirection(value, key)
	local direction = DIRECTION_ALIASES[value]
	if direction == nil then
		error("Network event message '" .. key .. "' has an invalid direction", 3)
	end
	return direction
end

local function collectDefinitions(messages)
	if type(messages) ~= "table" or getmetatable(messages) ~= nil then
		error("Network.defineEventProtocol messages must be a plain array or key-to-message table", 3)
	end
	local numeric = {}
	local named = {}
	for key, value in next, messages do
		if type(key) == "number" then
			if not isSafeInteger(key, 1) then
				error("Network.defineEventProtocol array indices must be positive integers", 3)
			end
			numeric[#numeric + 1] = { index = key, value = value }
		elseif type(key) == "string" then
			named[#named + 1] = { key = key, value = value }
		else
			error("Network.defineEventProtocol message keys must be strings or array indices", 3)
		end
	end
	if #numeric > 0 and #named > 0 then
		error("Network.defineEventProtocol messages cannot mix array and named entries", 3)
	end
	local result = {}
	if #numeric > 0 then
		table.sort(numeric, function(left, right)
			return left.index < right.index
		end)
		for index, entry in ipairs(numeric) do
			if entry.index ~= index then
				error("Network.defineEventProtocol messages array is sparse", 3)
			end
			result[index] = entry.value
		end
	else
		table.sort(named, function(left, right)
			return left.key < right.key
		end)
		for index, entry in ipairs(named) do
			if type(entry.value) ~= "table" then
				error("Network event message '" .. entry.key .. "' must be a table", 3)
			end
			local definition = copyTable(entry.value)
			if definition.key == nil then
				definition.key = entry.key
			elseif definition.key ~= entry.key then
				error("Network event message '" .. entry.key .. "' declares a mismatched key", 3)
			end
			result[index] = definition
		end
	end
	return result
end

local Protocol = {}
Protocol.__index = Protocol

function Protocol:getMessage(key)
	local message = self._byKey[key]
	return if message ~= nil then copyTable(message) else nil
end

function Protocol:getMessages()
	local messages = {}
	for index, message in ipairs(self._ordered) do
		messages[index] = copyTable(message)
	end
	return messages
end

function EventProtocol.defineEventProtocol(messages, options)
	options = options or {}
	if type(options) ~= "table" then
		error("Network.defineEventProtocol options must be a table", 2)
	end
	local id = options.id
	if type(id) ~= "string" or id == "" then
		error("Network.defineEventProtocol requires a non-empty stable options.id", 2)
	end
	local limits = compileLimits(options)
	if #id > limits.maxStringLength then
		error("Network event protocol id exceeds maxStringLength", 2)
	end
	local schemaVersion = options.schemaVersion or options.version or 1
	assertPositiveInteger(schemaVersion, "Network event schemaVersion")
	local protocolVersion = options.protocolVersion or EventProtocol.EVENT_PROTOCOL_VERSION
	if protocolVersion ~= EventProtocol.EVENT_PROTOCOL_VERSION then
		error("unsupported Network event protocolVersion " .. tostring(protocolVersion), 2)
	end

	local definitions = collectDefinitions(messages)
	if #definitions == 0 then
		error("Network.defineEventProtocol requires at least one message", 2)
	end
	if #definitions > limits.maxMessages then
		error("Network event protocol exceeds maxMessages=" .. tostring(limits.maxMessages), 2)
	end

	local ordered = {}
	local byKey = {}
	for index, definition in ipairs(definitions) do
		if type(definition) ~= "table" or getmetatable(definition) ~= nil then
			error("Network event message #" .. tostring(index) .. " must be a plain table", 2)
		end
		local key = definition.key
		if type(key) ~= "string" or key == "" or #key > limits.maxStringLength then
			error("Network event message #" .. tostring(index) .. " requires a bounded stable string key", 2)
		end
		if byKey[key] ~= nil then
			error("duplicate Network event message key '" .. key .. "'", 2)
		end
		if definition.validate ~= nil and type(definition.validate) ~= "function" then
			error("Network event message '" .. key .. "' validate must be a function", 2)
		end
		if definition.authorize ~= nil and type(definition.authorize) ~= "function" then
			error("Network event message '" .. key .. "' authorize must be a function", 2)
		end
		local codec = definition.codec or Codec.default
		if type(codec) ~= "table" or type(codec.encode) ~= "function" or type(codec.decode) ~= "function" then
			error("Network event message '" .. key .. "' codec must provide encode() and decode()", 2)
		end
		if codec.validate ~= nil and type(codec.validate) ~= "function" then
			error("Network event message '" .. key .. "' codec.validate must be a function", 2)
		end
		local message = copyTable(definition)
		message.key = key
		message.direction = normalizeDirection(definition.direction, key)
		message.codec = codec
		ordered[#ordered + 1] = message
		byKey[key] = message
	end
	 table.sort(ordered, function(left, right)
		return left.key < right.key
	end)

	return setmetatable({
		_tag = PROTOCOL_TAG,
		_ordered = ordered,
		_byKey = byKey,
		_limits = limits,
		_rateLimit = compileRateLimit(options.rateLimit),
		_replayCapacity = assertPositiveInteger(options.replayCapacity or 128, "Network event replayCapacity"),
		_pendingCapacity = assertPositiveInteger(options.pendingCapacity or 128, "Network event pendingCapacity"),
		id = id,
		protocolVersion = protocolVersion,
		schemaVersion = schemaVersion,
		version = schemaVersion,
	}, Protocol)
end

local function assertProtocol(protocol, operation)
	if type(protocol) ~= "table" or protocol._tag ~= PROTOCOL_TAG then
		error(operation .. " requires a protocol returned by Network.defineEventProtocol", 3)
	end
	return protocol
end

local function callValidation(callback, value, context, label)
	if callback == nil then
		return true
	end
	local called, accepted, message = callNoYield(callback, value, context)
	if not called then
		return false, label .. " raised: " .. tostring(accepted)
	end
	if accepted ~= true then
		return false, label .. " rejected the payload" .. (if message ~= nil then ": " .. tostring(message) else "")
	end
	return true
end

local function encodeMessage(protocol, direction, messageType, value, context)
	local message = protocol._byKey[messageType]
	if message == nil then
		return failure("unknown_message", "unknown messageType '" .. tostring(messageType) .. "'")
	end
	if message.direction ~= direction then
		return failure("wrong_direction", "messageType '" .. messageType .. "' is not allowed in this direction")
	end
	local valid, validationMessage = callValidation(message.codec.validate, value, context, "codec validator for '" .. messageType .. "'")
	if valid then
		valid, validationMessage = callValidation(message.validate, value, context, "validator for '" .. messageType .. "'")
	end
	if not valid then
		return failure("payload_rejected", validationMessage)
	end
	local called, encoded = callNoYield(message.codec.encode, value)
	if not called then
		return failure("codec_error", "codec.encode for '" .. messageType .. "' failed: " .. tostring(encoded))
	end
	local wireOk, wireMessage = validateWire(encoded, "$payload", protocol._limits)
	if not wireOk then
		return failure("payload_rejected", wireMessage)
	end
	local cloneOk, cloned = pcall(cloneWire, encoded)
	if not cloneOk then
		return failure("codec_error", "encoded payload could not be cloned: " .. tostring(cloned))
	end
	return success("encoded", { message = message, payload = cloned })
end

local function decodeMessage(protocol, direction, messageType, encoded, context)
	local message = protocol._byKey[messageType]
	if message == nil then
		return failure("unknown_message", "unknown messageType '" .. tostring(messageType) .. "'")
	end
	if message.direction ~= direction then
		return failure("wrong_direction", "messageType '" .. messageType .. "' is not allowed in this direction")
	end
	local wireOk, wireMessage = validateWire(encoded, "$payload", protocol._limits)
	if not wireOk then
		return failure("payload_rejected", wireMessage)
	end
	local called, decoded = callNoYield(message.codec.decode, encoded)
	if not called then
		return failure("codec_error", "codec.decode for '" .. messageType .. "' failed: " .. tostring(decoded))
	end
	local decodedWireOk, decodedWireMessage = validateWire(decoded, "$decoded", protocol._limits)
	if not decodedWireOk then
		return failure("payload_rejected", "decoded payload is unsafe: " .. decodedWireMessage)
	end
	local valid, validationMessage = callValidation(message.codec.validate, decoded, context, "codec validator for '" .. messageType .. "'")
	if valid then
		valid, validationMessage = callValidation(message.validate, decoded, context, "validator for '" .. messageType .. "'")
	end
	if not valid then
		return failure("payload_rejected", validationMessage)
	end
	return success("decoded", { message = message, value = decoded })
end

local COMMON_KEYS = {
	kind = true,
	protocolVersion = true,
	protocolId = true,
	schemaVersion = true,
}

local INTENT_KEYS = copyTable(COMMON_KEYS)
INTENT_KEYS.sequence = true
INTENT_KEYS.clientTick = true
INTENT_KEYS.messageType = true
INTENT_KEYS.payload = true

local RESYNC_KEYS = copyTable(COMMON_KEYS)
RESYNC_KEYS.epoch = true
RESYNC_KEYS.expectedSequence = true

local EVENT_KEYS = copyTable(COMMON_KEYS)
EVENT_KEYS.epoch = true
EVENT_KEYS.sequence = true
EVENT_KEYS.serverTick = true
EVENT_KEYS.ackSequence = true
EVENT_KEYS.messageType = true
EVENT_KEYS.payload = true

local HEARTBEAT_KEYS = copyTable(COMMON_KEYS)
HEARTBEAT_KEYS.epoch = true
HEARTBEAT_KEYS.sequence = true
HEARTBEAT_KEYS.serverTick = true
HEARTBEAT_KEYS.ackSequence = true

local ACK_KEYS = copyTable(COMMON_KEYS)
ACK_KEYS.ackSequence = true

local INTENT_GAP_KEYS = copyTable(ACK_KEYS)
INTENT_GAP_KEYS.expectedSequence = true

local RESYNC_UNAVAILABLE_KEYS = copyTable(COMMON_KEYS)
RESYNC_UNAVAILABLE_KEYS.epoch = true
RESYNC_UNAVAILABLE_KEYS.expectedSequence = true

local function validateCommon(protocol, packet)
	if type(packet) ~= "table" or getmetatable(packet) ~= nil then
		return failure("malformed_packet", "packet must be a plain table")
	end
	local wireOk, wireMessage = validateWire(packet, "$packet", protocol._limits)
	if not wireOk then
		return failure("malformed_packet", wireMessage)
	end
	if packet.protocolVersion ~= protocol.protocolVersion then
		return failure("protocol_mismatch", "packet protocolVersion does not match")
	end
	if packet.protocolId ~= protocol.id then
		return failure("protocol_mismatch", "packet protocolId does not match")
	end
	if packet.schemaVersion ~= protocol.schemaVersion then
		return failure("schema_mismatch", "packet schemaVersion does not match")
	end
	return success("header_valid")
end

local function basePacket(protocol, kind)
	return {
		kind = kind,
		protocolVersion = protocol.protocolVersion,
		protocolId = protocol.id,
		schemaVersion = protocol.schemaVersion,
	}
end

local function validatePacketBudget(protocol, packet)
	local ok, message = validateWire(packet, "$packet", protocol._limits)
	if not ok then
		return failure("packet_budget", message)
	end
	return success("packet_valid")
end

local function clonePacket(packet)
	return Codec.default.clone(packet)
end

local function copyClientInbound(state, clientId, rateLimit, now)
	local clients = copyTable(state.clients)
	local previous = clients[clientId]
	local client
	if previous == nil then
		client = {
			lastIntentSequence = 0,
			lastClientTick = 0,
			tokens = if rateLimit ~= nil then rateLimit.capacity else 0,
			lastRateTime = now,
		}
	else
		client = copyTable(previous)
	end
	clients[clientId] = client
	return clients, client
end

local function consumeRate(client, rateLimit, now)
	if rateLimit == nil then
		return true
	end
	if not isFinite(now) or now < 0 then
		return false, "receivedAt must be a finite non-negative number"
	end
	local elapsed = now - client.lastRateTime
	if elapsed < 0 then
		return false, "receivedAt moved backwards for this client"
	end
	client.tokens = math.min(rateLimit.capacity, client.tokens + elapsed * rateLimit.refillPerSecond)
	client.lastRateTime = now
	if client.tokens < 1 then
		return false, "client exceeded the RemoteEvent rate limit"
	end
	client.tokens -= 1
	return true
end

local Server = {}
Server.__index = Server

function EventProtocol.createEventServer(options)
	if type(options) ~= "table" then
		error("Network.createEventServer options must be a table", 2)
	end
	local protocol = assertProtocol(options.protocol, "Network.createEventServer")
	if options.authorize ~= nil and type(options.authorize) ~= "function" then
		error("Network.createEventServer authorize must be a function", 2)
	end
	if options.buildSnapshot ~= nil and type(options.buildSnapshot) ~= "function" then
		error("Network.createEventServer buildSnapshot must be a function", 2)
	end
	return setmetatable({
		_tag = SERVER_TAG,
		_protocol = protocol,
		_authorize = options.authorize,
		_buildSnapshot = options.buildSnapshot,
		_rateLimit = if options.rateLimit ~= nil then compileRateLimit(options.rateLimit) else protocol._rateLimit,
		_replayCapacity = assertPositiveInteger(options.replayCapacity or protocol._replayCapacity,
			"Network event replayCapacity"),
		_outbound = {},
		_disposed = false,
	}, Server)
end

function Server:initialInboundState()
	return { clients = {}, decision = nil }
end

local function serverDecision(clients, decision)
	decision.lastIntentSequence = decision.lastIntentSequence or 0
	return { clients = clients, decision = decision }
end

function Server:reduceInbound(state, input)
	if self._disposed then
		return serverDecision(state.clients, failure("disposed", "event server is disposed"))
	end
	if type(state) ~= "table" or type(state.clients) ~= "table" then
		error("Network event server received invalid reducer state", 2)
	end
	if type(input) ~= "table" then
		return serverDecision(state.clients, failure("malformed_input", "server input must be a table"))
	end
	local clientId = input.clientId
	if not stableClientId(clientId) then
		return serverDecision(state.clients, failure("invalid_client_id", "clientId must be a stable string or non-negative safe integer"))
	end
	local stateKey = input.stateKey or clientId
	if not stableClientId(stateKey) then
		return serverDecision(state.clients, failure("invalid_client_id", "stateKey must be a stable string or non-negative safe integer"))
	end
	if input.transportKind == "disconnect" then
		local clients = copyTable(state.clients)
		local previous = clients[stateKey]
		clients[stateKey] = nil
		return serverDecision(clients, success("client_disconnected", {
			kind = "disconnect",
			clientId = clientId,
			lastIntentSequence = if previous ~= nil then previous.lastIntentSequence else 0,
		}))
	end

	local now = input.receivedAt
	if not isFinite(now) or now < 0 then
		return serverDecision(state.clients, failure("invalid_time", "receivedAt must be a finite non-negative number", {
			kind = "rejected", clientId = clientId,
		}))
	end
	local clients, client = copyClientInbound(state, stateKey, self._rateLimit, now)
	local rateOk, rateMessage = consumeRate(client, self._rateLimit, now)
	if not rateOk then
		return serverDecision(clients, failure("rate_limited", rateMessage, {
			kind = "rejected",
			clientId = clientId,
			lastIntentSequence = client.lastIntentSequence,
		}))
	end

	local packet = input.packet
	local header = validateCommon(self._protocol, packet)
	if not header.ok then
		header.kind = "rejected"
		header.clientId = clientId
		header.lastIntentSequence = client.lastIntentSequence
		return serverDecision(clients, header)
	end

	if packet.kind == "intent" then
		local keysOk, keysMessage = rejectUnknownKeys(packet, INTENT_KEYS, "intent packet")
		if not keysOk then
			return serverDecision(clients, failure("malformed_packet", keysMessage, {
				kind = "rejected", clientId = clientId, lastIntentSequence = client.lastIntentSequence,
			}))
		end
		if not isSafeInteger(packet.sequence, 1) or not isSafeInteger(packet.clientTick, 0) then
			return serverDecision(clients, failure("malformed_packet", "intent sequence/clientTick must be safe integers", {
				kind = "rejected", clientId = clientId, lastIntentSequence = client.lastIntentSequence,
			}))
		end
		local expected = client.lastIntentSequence + 1
		if packet.sequence < expected then
			local code = if packet.sequence == client.lastIntentSequence then "duplicate_intent" else "stale_intent"
			return serverDecision(clients, failure(code, "intent sequence is older than expected", {
				kind = "rejected",
				clientId = clientId,
				sequence = packet.sequence,
				expectedSequence = expected,
				lastIntentSequence = client.lastIntentSequence,
			}))
		elseif packet.sequence > expected then
			return serverDecision(clients, failure("intent_sequence_gap", "intent sequence skipped an input", {
				kind = "intent_gap",
				clientId = clientId,
				sequence = packet.sequence,
				expectedSequence = expected,
				lastIntentSequence = client.lastIntentSequence,
			}))
		end
		if packet.clientTick < client.lastClientTick then
			client.lastIntentSequence = packet.sequence
			return serverDecision(clients, failure("stale_client_tick", "clientTick moved backwards", {
				kind = "rejected", clientId = clientId, sequence = packet.sequence,
				lastIntentSequence = client.lastIntentSequence,
				consumed = true,
			}))
		end
		if type(packet.messageType) ~= "string" or packet.messageType == "" then
			return serverDecision(clients, failure("malformed_packet", "intent messageType must be a non-empty string", {
				kind = "rejected", clientId = clientId, lastIntentSequence = client.lastIntentSequence,
			}))
		end
		local context = input.context or { clientId = clientId, receivedAt = now }
		local decoded = decodeMessage(self._protocol, EventProtocol.CLIENT_INTENT, packet.messageType, packet.payload, context)
		if not decoded.ok then
			-- A structurally valid exact-sequence intent is consumed even when
			-- its domain payload is invalid. Otherwise one bad intent would
			-- permanently deadlock every later sequence behind replay of the
			-- same rejected payload.
			client.lastIntentSequence = packet.sequence
			client.lastClientTick = packet.clientTick
			decoded.kind = "rejected"
			decoded.clientId = clientId
			decoded.sequence = packet.sequence
			decoded.lastIntentSequence = client.lastIntentSequence
			decoded.consumed = true
			return serverDecision(clients, decoded)
		end
		local authorized, authorizationMessage = callValidation(decoded.message.authorize, decoded.value, context,
			"authority for '" .. packet.messageType .. "'")
		if authorized and self._authorize ~= nil then
			local called, accepted, message = callNoYield(self._authorize, clientId, packet.messageType, decoded.value, context)
			if not called then
				authorized = false
				authorizationMessage = "server authorize raised: " .. tostring(accepted)
			elseif accepted ~= true then
				authorized = false
				authorizationMessage = "server authorize rejected the intent" .. (if message ~= nil then ": " .. tostring(message) else "")
			end
		end
		if not authorized then
			client.lastIntentSequence = packet.sequence
			client.lastClientTick = packet.clientTick
			return serverDecision(clients, failure("unauthorized", authorizationMessage, {
				kind = "rejected", clientId = clientId, sequence = packet.sequence,
				lastIntentSequence = client.lastIntentSequence,
				consumed = true,
			}))
		end

		client.lastIntentSequence = packet.sequence
		client.lastClientTick = packet.clientTick
		return serverDecision(clients, success("intent_accepted", {
			kind = "intent",
			clientId = clientId,
			messageType = packet.messageType,
			payload = decoded.value,
			sequence = packet.sequence,
			clientTick = packet.clientTick,
			receivedAt = now,
			lastIntentSequence = client.lastIntentSequence,
		}))
	elseif packet.kind == "resync" then
		local keysOk, keysMessage = rejectUnknownKeys(packet, RESYNC_KEYS, "resync packet")
		if not keysOk or not isSafeInteger(packet.epoch, 0) or not isSafeInteger(packet.expectedSequence, 1) then
			return serverDecision(clients, failure("malformed_packet", keysMessage or "resync epoch/expectedSequence are invalid", {
				kind = "rejected", clientId = clientId, lastIntentSequence = client.lastIntentSequence,
			}))
		end
		return serverDecision(clients, success("resync_requested", {
			kind = "resync",
			clientId = clientId,
			epoch = packet.epoch,
			expectedSequence = packet.expectedSequence,
			lastIntentSequence = client.lastIntentSequence,
			receivedAt = now,
		}))
	end

	return serverDecision(clients, failure("unknown_packet_kind", "server rejected packet kind '" .. tostring(packet.kind) .. "'", {
		kind = "rejected", clientId = clientId, lastIntentSequence = client.lastIntentSequence,
	}))
end

function Server:getInboundStatus(state, clientId)
	local client = state.clients[clientId]
	return {
		lastIntentSequence = if client ~= nil then client.lastIntentSequence else 0,
		lastClientTick = if client ~= nil then client.lastClientTick else 0,
	}
end

function Server:_outboundState(clientId)
	if not stableClientId(clientId) then
		return nil, failure("invalid_client_id", "clientId must be a stable string or non-negative safe integer")
	end
	local state = self._outbound[clientId]
	if state == nil then
		state = { epoch = 1, sequence = 0, outbox = {} }
		self._outbound[clientId] = state
	end
	return state, nil
end

local function appendOutbox(state, packet, capacity)
	state.outbox[#state.outbox + 1] = clonePacket(packet)
	while #state.outbox > capacity do
		table.remove(state.outbox, 1)
	end
end

function Server:encodeEvent(clientId, messageType, value, serverTick, ackSequence, kind)
	if self._disposed then
		return failure("disposed", "event server is disposed")
	end
	if not isSafeInteger(serverTick, 0) then
		return failure("invalid_tick", "serverTick must be a non-negative safe integer")
	end
	ackSequence = ackSequence or 0
	if not isSafeInteger(ackSequence, 0) then
		return failure("invalid_ack", "ackSequence must be a non-negative safe integer")
	end
	kind = kind or "event"
	if kind ~= "event" and kind ~= "snapshot" then
		return failure("invalid_kind", "authoritative kind must be 'event' or 'snapshot'")
	end
	local encoded = encodeMessage(self._protocol, EventProtocol.SERVER_TO_CLIENT, messageType, value, {
		clientId = clientId,
		serverTick = serverTick,
		kind = kind,
	})
	if not encoded.ok then
		return encoded
	end
	local state, stateFailure = self:_outboundState(clientId)
	if stateFailure ~= nil then
		return stateFailure
	end
	local nextEpoch = state.epoch
	local sequence = state.sequence + 1
	if kind == "snapshot" then
		nextEpoch = if state.sequence == 0 and #state.outbox == 0 then state.epoch else state.epoch + 1
		sequence = 1
	end
	if not isSafeInteger(nextEpoch, 1) or not isSafeInteger(sequence, 1) then
		return failure("sequence_exhausted", "authoritative epoch or sequence exceeded the safe integer range")
	end
	local packet = basePacket(self._protocol, kind)
	packet.epoch = nextEpoch
	packet.sequence = sequence
	packet.serverTick = serverTick
	packet.ackSequence = ackSequence
	packet.messageType = messageType
	packet.payload = encoded.payload
	local packetBudget = validatePacketBudget(self._protocol, packet)
	if not packetBudget.ok then
		return packetBudget
	end
	if kind == "snapshot" then
		state.epoch = nextEpoch
		state.outbox = {}
	end
	state.sequence = sequence
	appendOutbox(state, packet, self._replayCapacity)
	return success("event_encoded", {
		packet = clonePacket(packet),
		epoch = packet.epoch,
		sequence = sequence,
		ackSequence = ackSequence,
		kind = kind,
	})
end

function Server:encodeHeartbeat(clientId, serverTick, ackSequence)
	if self._disposed then
		return failure("disposed", "event server is disposed")
	end
	if not isSafeInteger(serverTick, 0) or not isSafeInteger(ackSequence, 0) then
		return failure("invalid_heartbeat", "heartbeat tick/ack must be non-negative safe integers")
	end
	local state, stateFailure = self:_outboundState(clientId)
	if stateFailure ~= nil then
		return stateFailure
	end
	if not isSafeInteger(state.sequence + 1, 1) then
		return failure("sequence_exhausted", "authoritative sequence exceeded the safe integer range")
	end
	local packet = basePacket(self._protocol, "heartbeat")
	packet.epoch = state.epoch
	packet.sequence = state.sequence + 1
	packet.serverTick = serverTick
	packet.ackSequence = ackSequence
	local packetBudget = validatePacketBudget(self._protocol, packet)
	if not packetBudget.ok then
		return packetBudget
	end
	state.sequence = packet.sequence
	appendOutbox(state, packet, self._replayCapacity)
	return success("heartbeat_encoded", {
		packet = clonePacket(packet),
		epoch = packet.epoch,
		sequence = packet.sequence,
		ackSequence = ackSequence,
		kind = "heartbeat",
	})
end

function Server:encodeAck(clientId, ackSequence)
	if self._disposed then
		return failure("disposed", "event server is disposed")
	end
	if not stableClientId(clientId) or not isSafeInteger(ackSequence, 0) then
		return failure("invalid_ack", "ack requires a valid clientId and non-negative safe integer")
	end
	local packet = basePacket(self._protocol, "ack")
	packet.ackSequence = ackSequence
	local packetBudget = validatePacketBudget(self._protocol, packet)
	if not packetBudget.ok then
		return packetBudget
	end
	return success("ack_encoded", { packet = packet })
end

function Server:encodeIntentGap(clientId, expectedSequence, ackSequence)
	if self._disposed then
		return failure("disposed", "event server is disposed")
	end
	if not stableClientId(clientId) or not isSafeInteger(expectedSequence, 1) or not isSafeInteger(ackSequence, 0) then
		return failure("invalid_intent_gap", "intent gap control values are invalid")
	end
	local packet = basePacket(self._protocol, "intentGap")
	packet.expectedSequence = expectedSequence
	packet.ackSequence = ackSequence
	local packetBudget = validatePacketBudget(self._protocol, packet)
	if not packetBudget.ok then
		return packetBudget
	end
	return success("intent_gap_encoded", { packet = packet })
end

function Server:encodeResyncUnavailable(clientId, epoch, expectedSequence)
	if self._disposed then
		return failure("disposed", "event server is disposed")
	end
	if not stableClientId(clientId) or not isSafeInteger(epoch, 0) or not isSafeInteger(expectedSequence, 1) then
		return failure("invalid_resync", "resync control values are invalid")
	end
	local packet = basePacket(self._protocol, "resyncUnavailable")
	packet.epoch = epoch
	packet.expectedSequence = expectedSequence
	local packetBudget = validatePacketBudget(self._protocol, packet)
	if not packetBudget.ok then
		return packetBudget
	end
	return success("resync_unavailable_encoded", { packet = packet })
end

function Server:recover(clientId, request, context)
	if self._disposed then
		return failure("disposed", "event server is disposed")
	end
	if type(request) ~= "table" or not isSafeInteger(request.epoch, 0) or not isSafeInteger(request.expectedSequence, 1) then
		return failure("invalid_resync", "resync request is invalid")
	end
	local state, stateFailure = self:_outboundState(clientId)
	if stateFailure ~= nil then
		return stateFailure
	end
	local replayEpoch = request.epoch
	if replayEpoch == 0 and request.expectedSequence == 1 and state.sequence > 0 then
		-- A client that lost the very first authoritative packet cannot know
		-- the server-created epoch yet. Sequence one is an unambiguous request
		-- for the current epoch prefix.
		replayEpoch = state.epoch
	end
	if replayEpoch == state.epoch then
		if request.expectedSequence == state.sequence + 1 then
			return success("already_current", { mode = "replay", packets = {} })
		end
		local packets = {}
		local expected = request.expectedSequence
		for _, packet in ipairs(state.outbox) do
			if packet.epoch == replayEpoch and packet.sequence >= expected then
				if packet.sequence ~= expected then
					packets = {}
					break
				end
				packets[#packets + 1] = clonePacket(packet)
				expected += 1
			end
		end
		if #packets > 0 and expected == state.sequence + 1 then
			return success("replay_ready", { mode = "replay", packets = packets })
		end
	end

	if self._buildSnapshot == nil then
		return failure("resync_unavailable", "replay buffer cannot cover the gap and no buildSnapshot callback is configured", {
			mode = "unavailable", epoch = state.epoch, expectedSequence = request.expectedSequence,
		})
	end
	local called, snapshot = callNoYield(self._buildSnapshot, clientId, request, context)
	if not called then
		return failure("snapshot_failed", "buildSnapshot raised: " .. tostring(snapshot))
	end
	if type(snapshot) ~= "table" then
		return failure("snapshot_failed", "buildSnapshot must return { messageType, payload, serverTick }")
	end
	local encoded = encodeMessage(self._protocol, EventProtocol.SERVER_TO_CLIENT, snapshot.messageType, snapshot.payload, {
		clientId = clientId,
		serverTick = snapshot.serverTick,
		kind = "snapshot",
	})
	if not encoded.ok then
		return failure("snapshot_failed", encoded.message, { cause = encoded })
	end
	if not isSafeInteger(snapshot.serverTick, 0) then
		return failure("snapshot_failed", "snapshot serverTick must be a non-negative safe integer")
	end
	local ackSequence = snapshot.ackSequence or 0
	if not isSafeInteger(ackSequence, 0) then
		return failure("snapshot_failed", "snapshot ackSequence must be a non-negative safe integer")
	end
	local nextEpoch = if state.sequence == 0 and request.epoch == 0 then 1 else state.epoch + 1
	if not isSafeInteger(nextEpoch, 1) then
		return failure("snapshot_failed", "snapshot epoch exceeded the safe integer range")
	end
	local packet = basePacket(self._protocol, "snapshot")
	packet.epoch = nextEpoch
	packet.sequence = 1
	packet.serverTick = snapshot.serverTick
	packet.ackSequence = ackSequence
	packet.messageType = snapshot.messageType
	packet.payload = encoded.payload
	local packetBudget = validatePacketBudget(self._protocol, packet)
	if not packetBudget.ok then
		return failure("snapshot_failed", packetBudget.message, { cause = packetBudget })
	end
	state.epoch = nextEpoch
	state.sequence = 1
	state.outbox = {}
	appendOutbox(state, packet, self._replayCapacity)
	return success("snapshot_ready", { mode = "snapshot", packets = { clonePacket(packet) }, epoch = nextEpoch })
end

function Server:getOutboundStatus(clientId)
	local state = self._outbound[clientId]
	if state == nil then
		return { epoch = 1, sequence = 0, replayCount = 0 }
	end
	return { epoch = state.epoch, sequence = state.sequence, replayCount = #state.outbox }
end

function Server:forgetClient(clientId)
	self._outbound[clientId] = nil
end

function Server:dispose()
	if self._disposed then
		return
	end
	self._disposed = true
	self._outbound = {}
end

Server.Destroy = Server.dispose

local Client = {}
Client.__index = Client

function EventProtocol.createEventClient(options)
	if type(options) ~= "table" then
		error("Network.createEventClient options must be a table", 2)
	end
	local protocol = assertProtocol(options.protocol, "Network.createEventClient")
	return setmetatable({
		_tag = CLIENT_TAG,
		_protocol = protocol,
		_pendingCapacity = assertPositiveInteger(options.pendingCapacity or protocol._pendingCapacity,
			"Network event pendingCapacity"),
		_intentSequence = 0,
		_ackSequence = 0,
		_pending = {},
		_disposed = false,
	}, Client)
end

function Client:initialInboundState()
	return { epoch = 0, sequence = 0, ackSequence = 0, serverTick = 0, decision = nil }
end

local function clientState(state, decision, epoch, sequence, ackSequence, serverTick)
	return {
		epoch = epoch or state.epoch,
		sequence = sequence or state.sequence,
		ackSequence = ackSequence or state.ackSequence,
		serverTick = serverTick or state.serverTick,
		decision = decision,
	}
end

local function resyncDecision(state, code, message)
	return failure(code, message, {
		kind = "resync",
		epoch = state.epoch,
		expectedSequence = state.sequence + 1,
		requestResync = true,
	})
end

function Client:reduceInbound(state, input)
	if self._disposed then
		return clientState(state, failure("disposed", "event client is disposed"))
	end
	if type(state) ~= "table" or type(input) ~= "table" then
		error("Network event client received invalid reducer input", 2)
	end
	local packet = input.packet
	local header = validateCommon(self._protocol, packet)
	if not header.ok then
		header.kind = "rejected"
		return clientState(state, header)
	end
	local localIntentSequence = input.intentSequence or self._intentSequence
	if not isSafeInteger(localIntentSequence, 0) then
		return clientState(state, failure("malformed_input", "intentSequence must be a non-negative safe integer", {
			kind = "rejected",
		}))
	end

	if packet.kind == "event" or packet.kind == "snapshot" or packet.kind == "heartbeat" then
		local allowedKeys = if packet.kind == "heartbeat" then HEARTBEAT_KEYS else EVENT_KEYS
		local keysOk, keysMessage = rejectUnknownKeys(packet, allowedKeys, packet.kind .. " packet")
		if not keysOk
			or not isSafeInteger(packet.epoch, 1)
			or not isSafeInteger(packet.sequence, 1)
			or not isSafeInteger(packet.serverTick, 0)
			or not isSafeInteger(packet.ackSequence, 0)
		then
			return clientState(state, failure("malformed_packet", keysMessage or "authoritative packet counters are invalid", {
				kind = "rejected",
			}))
		end
		if packet.ackSequence > localIntentSequence then
			return clientState(state, failure("invalid_ack", "server acknowledged an intent sequence the client has not sent", {
				kind = "rejected",
			}))
		end
		if packet.serverTick < state.serverTick then
			return clientState(state, failure("stale_server_tick", "serverTick moved backwards", {
				kind = "rejected",
			}))
		end
		local nextEpoch = state.epoch
		local expected = state.sequence + 1
		if packet.epoch < state.epoch then
			return clientState(state, failure("stale_epoch", "authoritative packet belongs to an old epoch", { kind = "rejected" }))
		elseif packet.epoch > state.epoch then
			if state.epoch == 0 and packet.epoch == 1 and packet.sequence == 1 then
				nextEpoch = 1
				expected = 1
			elseif packet.kind == "snapshot" and packet.sequence == 1 then
				nextEpoch = packet.epoch
				expected = 1
			else
				return clientState(state, resyncDecision(state, "snapshot_required", "a new epoch must begin with snapshot sequence 1"))
			end
		end
		if packet.epoch == state.epoch then
			expected = state.sequence + 1
		end
		if packet.sequence < expected then
			local code = if packet.sequence == expected - 1 then "duplicate_event" else "stale_event"
			return clientState(state, failure(code, "authoritative packet sequence is older than expected", { kind = "rejected" }))
		elseif packet.sequence > expected then
			return clientState(state, resyncDecision(state, "server_sequence_gap", "authoritative packet sequence skipped an event"))
		end
		local ack = math.max(state.ackSequence, packet.ackSequence)
		if packet.kind == "heartbeat" then
			return clientState(state, success("heartbeat_received", {
				kind = "heartbeat",
				epoch = packet.epoch,
				sequence = packet.sequence,
				serverTick = packet.serverTick,
				ackSequence = packet.ackSequence,
				receivedAt = input.receivedAt,
			}), nextEpoch, packet.sequence, ack, packet.serverTick)
		end
		if type(packet.messageType) ~= "string" or packet.messageType == "" then
			return clientState(state, failure("malformed_packet", "messageType must be a non-empty string", { kind = "rejected" }))
		end
		local decoded = decodeMessage(self._protocol, EventProtocol.SERVER_TO_CLIENT, packet.messageType, packet.payload, {
			serverTick = packet.serverTick,
			kind = packet.kind,
			receivedAt = input.receivedAt,
		})
		if not decoded.ok then
			decoded.kind = "rejected"
			return clientState(state, decoded)
		end
		return clientState(state, success("event_accepted", {
			kind = packet.kind,
			messageType = packet.messageType,
			payload = decoded.value,
			epoch = packet.epoch,
			sequence = packet.sequence,
			serverTick = packet.serverTick,
			ackSequence = packet.ackSequence,
			receivedAt = input.receivedAt,
		}), nextEpoch, packet.sequence, ack, packet.serverTick)
	elseif packet.kind == "ack" then
		local keysOk, keysMessage = rejectUnknownKeys(packet, ACK_KEYS, "ack packet")
		if not keysOk or not isSafeInteger(packet.ackSequence, 0) or packet.ackSequence > localIntentSequence then
			return clientState(state, failure("invalid_ack", keysMessage or "ackSequence is invalid", { kind = "rejected" }))
		end
		if packet.ackSequence < state.ackSequence then
			return clientState(state, failure("stale_ack", "ackSequence moved backwards", { kind = "rejected" }))
		end
		return clientState(state, success("ack_received", {
			kind = "ack", ackSequence = packet.ackSequence,
		}), nil, nil, packet.ackSequence)
	elseif packet.kind == "intentGap" then
		local keysOk, keysMessage = rejectUnknownKeys(packet, INTENT_GAP_KEYS, "intentGap packet")
		if not keysOk
			or not isSafeInteger(packet.expectedSequence, 1)
			or not isSafeInteger(packet.ackSequence, 0)
			or packet.ackSequence > localIntentSequence
			or packet.expectedSequence > localIntentSequence + 1
		then
			return clientState(state, failure("invalid_intent_gap", keysMessage or "intentGap counters are invalid", { kind = "rejected" }))
		end
		local ack = math.max(state.ackSequence, packet.ackSequence)
		return clientState(state, success("intent_gap_received", {
			kind = "intent_gap",
			expectedSequence = packet.expectedSequence,
			ackSequence = packet.ackSequence,
		}), nil, nil, ack)
	elseif packet.kind == "resyncUnavailable" then
		local keysOk, keysMessage = rejectUnknownKeys(packet, RESYNC_UNAVAILABLE_KEYS, "resyncUnavailable packet")
		if not keysOk or not isSafeInteger(packet.epoch, 0) or not isSafeInteger(packet.expectedSequence, 1) then
			return clientState(state, failure("malformed_packet", keysMessage or "resyncUnavailable counters are invalid", { kind = "rejected" }))
		end
		return clientState(state, failure("resync_unavailable", "server could not replay or snapshot the requested authoritative gap", {
			kind = "resync_unavailable", epoch = packet.epoch, expectedSequence = packet.expectedSequence,
		}))
	end

	return clientState(state, failure("unknown_packet_kind", "client rejected packet kind '" .. tostring(packet.kind) .. "'", {
		kind = "rejected",
	}))
end

function Client:prepareIntent(messageType, value, clientTick)
	if self._disposed then
		return failure("disposed", "event client is disposed")
	end
	if not isSafeInteger(clientTick, 0) then
		return failure("invalid_tick", "clientTick must be a non-negative safe integer")
	end
	if #self._pending >= self._pendingCapacity then
		return failure("pending_capacity", "unacknowledged intent capacity is full")
	end
	local encoded = encodeMessage(self._protocol, EventProtocol.CLIENT_INTENT, messageType, value, {
		clientTick = clientTick,
	})
	if not encoded.ok then
		return encoded
	end
	if not isSafeInteger(self._intentSequence + 1, 1) then
		return failure("sequence_exhausted", "client intent sequence exceeded the safe integer range")
	end
	local packet = basePacket(self._protocol, "intent")
	packet.sequence = self._intentSequence + 1
	packet.clientTick = clientTick
	packet.messageType = messageType
	packet.payload = encoded.payload
	local packetBudget = validatePacketBudget(self._protocol, packet)
	if not packetBudget.ok then
		return packetBudget
	end
	return success("intent_prepared", { packet = packet, sequence = packet.sequence, clientTick = clientTick })
end

function Client:commitIntent(packet)
	if self._disposed then
		return failure("disposed", "event client is disposed")
	end
	if type(packet) ~= "table" or packet.kind ~= "intent" or packet.sequence ~= self._intentSequence + 1 then
		return failure("intent_commit_order", "prepared intent is no longer the next sequence")
	end
	if #self._pending >= self._pendingCapacity then
		return failure("pending_capacity", "unacknowledged intent capacity is full")
	end
	self._intentSequence = packet.sequence
	self._pending[#self._pending + 1] = clonePacket(packet)
	return success("intent_committed", { sequence = packet.sequence, pendingCount = #self._pending })
end

function Client:acknowledge(sequence)
	if self._disposed then
		return failure("disposed", "event client is disposed")
	end
	if not isSafeInteger(sequence, 0) or sequence > self._intentSequence then
		return failure("invalid_ack", "acknowledgement is outside the sent intent range")
	end
	if sequence < self._ackSequence then
		return failure("stale_ack", "acknowledgement moved backwards")
	end
	self._ackSequence = sequence
	local pending = {}
	for _, packet in ipairs(self._pending) do
		if packet.sequence > sequence then
			pending[#pending + 1] = packet
		end
	end
	self._pending = pending
	return success("acknowledged", { ackSequence = sequence, pendingCount = #pending })
end

function Client:pendingFrom(expectedSequence)
	if self._disposed then
		return failure("disposed", "event client is disposed")
	end
	if not isSafeInteger(expectedSequence, 1) then
		return failure("invalid_sequence", "expectedSequence must be a positive safe integer")
	end
	local packets = {}
	local expected = expectedSequence
	for _, packet in ipairs(self._pending) do
		if packet.sequence >= expectedSequence then
			if packet.sequence ~= expected then
				return failure("pending_gap", "client no longer has a contiguous pending intent range")
			end
			packets[#packets + 1] = clonePacket(packet)
			expected += 1
		end
	end
	if expectedSequence <= self._intentSequence and #packets == 0 then
		return failure("pending_gap", "client no longer has the requested pending intent")
	end
	return success("pending_ready", { packets = packets })
end

function Client:encodeResync(epoch, expectedSequence)
	if self._disposed then
		return failure("disposed", "event client is disposed")
	end
	if not isSafeInteger(epoch, 0) or not isSafeInteger(expectedSequence, 1) then
		return failure("invalid_resync", "resync epoch/expectedSequence are invalid")
	end
	local packet = basePacket(self._protocol, "resync")
	packet.epoch = epoch
	packet.expectedSequence = expectedSequence
	local packetBudget = validatePacketBudget(self._protocol, packet)
	if not packetBudget.ok then
		return packetBudget
	end
	return success("resync_encoded", { packet = packet })
end

function Client:getStatus(inboundState)
	inboundState = inboundState or { epoch = 0, sequence = 0 }
	return {
		intentSequence = self._intentSequence,
		ackSequence = self._ackSequence,
		pendingCount = #self._pending,
		epoch = inboundState.epoch or 0,
		serverSequence = inboundState.sequence or 0,
		disposed = self._disposed,
	}
end

function Client:getPendingIntents()
	local packets = {}
	for index, packet in ipairs(self._pending) do
		packets[index] = clonePacket(packet)
	end
	return packets
end

function Client:dispose()
	if self._disposed then
		return
	end
	self._disposed = true
	self._pending = {}
end

Client.Destroy = Client.dispose

return EventProtocol
