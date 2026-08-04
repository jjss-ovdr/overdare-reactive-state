--!nonstrict

-- Put this Script in ServerScriptService. The harness is intentionally gated
-- to Studio and requires at least two client processes.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

assert(RunService:IsStudio(), "StudioMultiplayer harness must only run in OVERDARE Studio")
assert(RunService:IsServer(), "StudioMultiplayer Server must run in a server Script")

local packageRoot = ReplicatedStorage:WaitForChild("ReactiveState", 15)
assert(packageRoot ~= nil, "ReplicatedStorage.ReactiveState was not installed")

local State = require(packageRoot)
local Network = require(packageRoot.Network)
local Overdare = require(packageRoot.Overdare)

local HARNESS_VERSION = 1
local SCHEMA_VERSION = 31
local MIN_CLIENTS = 2
local TIMEOUT_SECONDS = 20
local RUN_ID = string.format("%.6f", os.clock())
local PREFIX = "[RSMP][v1]"

-- ModuleScripts must be evaluated independently in each server/client process.
-- A client seeing this server-only sentinel is a hard process-isolation failure.
State.__RSMPProcessProbe = "server:" .. RUN_ID

local passed = 0
local failed = 0

local function line(kind, fields)
	local parts = { PREFIX, kind, "run=" .. RUN_ID }
	for _, field in ipairs(fields or {}) do
		parts[#parts + 1] = field
	end
	print(table.concat(parts, "|"))
end

local function check(id, condition, detail)
	if condition then
		passed += 1
		line("CHECK", { "id=" .. id, "status=PASS", "detail=" .. tostring(detail or "ok") })
		return
	end
	failed += 1
	line("CHECK", { "id=" .. id, "status=FAIL", "detail=" .. tostring(detail or "assertion failed") })
	error("StudioMultiplayer check failed: " .. id .. ": " .. tostring(detail), 0)
end

local function freshRemote(name)
	assert(ReplicatedStorage:FindFirstChild(name) == nil, name .. " already exists; use a clean test World")
	local remote = Instance.new("RemoteEvent")
	remote.Name = name
	remote.Parent = ReplicatedStorage
	return remote
end

local stateRemote = freshRemote("RSMP_State")
local frpRemote = freshRemote("RSMP_FRP")
local controlRemote = freshRemote("RSMP_Control")

local controlInbox = {}
controlRemote.OnServerEvent:Connect(function(player, message)
	if type(message) ~= "table" then
		return
	end
	if message.kind ~= "ready" and message.runId ~= RUN_ID then
		return
	end
	controlInbox[#controlInbox + 1] = { player = player, message = message }
end)

local function takeControl(player, kind, caseName)
	for index, entry in ipairs(controlInbox) do
		local message = entry.message
		if (player == nil or entry.player == player)
			and message.kind == kind
			and (caseName == nil or message.case == caseName)
		then
			table.remove(controlInbox, index)
			return entry
		end
	end
	return nil
end

local function waitUntil(label, predicate, timeout)
	local deadline = os.clock() + (timeout or TIMEOUT_SECONDS)
	repeat
		local value = predicate()
		if value ~= nil and value ~= false then
			return value
		end
		RunService.Heartbeat:Wait()
	until os.clock() >= deadline
	error("timeout while waiting for " .. label, 0)
end

local function waitSeconds(seconds)
	local deadline = os.clock() + seconds
	repeat
		RunService.Heartbeat:Wait()
	until os.clock() >= deadline
end

local function waitControl(player, kind, caseName)
	return waitUntil(kind .. "/" .. tostring(caseName), function()
		return takeControl(player, kind, caseName)
	end)
end

local function command(player, caseName, values)
	local message = values or {}
	message.kind = "command"
	message.case = caseName
	message.runId = RUN_ID
	controlRemote:FireClient(player, message)
end

local serverRuntime = State.createStateRuntime({ label = "StudioMultiplayer.server" })
local publicValue = serverRuntime:atom(42, { label = "network.public" })
local privateProjection = serverRuntime:atom("projection", { label = "network.privateProjection" })
local secretA = serverRuntime:atom(700, { label = "network.secretA" })
local scores = serverRuntime:atom({}, { label = "network.scores" })

local roleByPlayer = {}
local acceptedByPlayer = {}

local function projectedScore(values, player)
	return values[tostring(player.UserId)] or 0
end

local serverSchema = Network.defineSchema({
	{
		key = "admin",
		direction = Network.CLIENT_INTENT,
		validate = function(value)
			return type(value) == "boolean"
		end,
	},
	{
		key = "move",
		direction = Network.CLIENT_INTENT,
		validate = function(value)
			return type(value) == "number" and value % 1 == 0 and value >= 1 and value <= 5
		end,
	},
	{
		key = "privateRole",
		direction = Network.SERVER_TO_CLIENT,
		source = privateProjection,
		project = function(_value, player)
			return roleByPlayer[player]
		end,
		validate = function(value)
			return value == "A" or value == "B"
		end,
	},
	{
		key = "publicValue",
		direction = Network.SERVER_TO_CLIENT,
		source = publicValue,
		validate = function(value)
			return type(value) == "number"
		end,
	},
	{
		key = "score",
		direction = Network.SERVER_TO_CLIENT,
		source = scores,
		project = projectedScore,
		validate = function(value)
			return type(value) == "number" and value >= 0
		end,
	},
	{
		key = "secretA",
		direction = Network.SERVER_TO_CLIENT,
		source = secretA,
		visibility = function(player)
			return roleByPlayer[player] == "A"
		end,
		validate = function(value)
			return type(value) == "number"
		end,
	},
}, {
	schemaVersion = SCHEMA_VERSION,
	limits = { maxFields = 16, maxDepth = 6, maxElements = 64, maxStringLength = 256 },
})

local serverReplicator = Network.createServer({
	schema = serverSchema,
	runtime = serverRuntime,
	authorize = function(player, action)
		if roleByPlayer[player] == nil then
			return false, "player has no harness role"
		end
		if action.key == "admin" then
			return false, "admin intent is server-only"
		end
		return true
	end,
	onIntent = function(player, actions)
		for _, action in ipairs(actions) do
			if action.key == "move" then
				-- Deliberately correct the prediction by one point so the client
				-- reconciliation path is observable.
				local authoritativeDelta = math.max(0, action.value - 1)
				scores:update(function(previous)
					local nextValue = {}
					for key, value in pairs(previous) do
						nextValue[key] = value
					end
					local id = tostring(player.UserId)
					nextValue[id] = (nextValue[id] or 0) + authoritativeDelta
					return nextValue
				end)
			end
		end
		acceptedByPlayer[player] = (acceptedByPlayer[player] or 0) + 1
	end,
})

local serverStatuses = {}
local networkAdapter = Overdare.createServerReplication({
	replicator = serverReplicator,
	remoteEvent = stateRemote,
	maxPayloadDepth = 6,
	maxPayloadEntries = 64,
	onStatus = function(status, context)
		if context.direction == "inbound" then
			serverStatuses[#serverStatuses + 1] = {
				player = context.clientId,
				status = status,
			}
		end
	end,
})

local frpProtocol = Network.defineFRPProtocol({
	{
		key = "echo",
		direction = Network.SERVER_TO_CLIENT,
		validate = function(value)
			return type(value) == "table" and type(value.nonce) == "string"
		end,
	},
	{
		key = "probe",
		direction = Network.CLIENT_INTENT,
		validate = function(value)
			return type(value) == "table" and type(value.nonce) == "string"
		end,
	},
}, {
	id = "reactive-state-studio-multiplayer",
	schemaVersion = SCHEMA_VERSION,
	rateLimit = false,
	replayCapacity = 16,
	pendingCapacity = 16,
	maxMessages = 8,
	maxDepth = 6,
	maxElements = 64,
	maxStringLength = 256,
	maxBytes = 4096,
})

local function takeServerStatus(player, code)
	for index, entry in ipairs(serverStatuses) do
		if entry.player == player and entry.status.code == code then
			table.remove(serverStatuses, index)
			return entry.status
		end
	end
	return nil
end

local function waitServerStatus(player, code)
	return waitUntil("server status " .. code, function()
		return takeServerStatus(player, code)
	end)
end

local function takeClientStatus(player, code, direction)
	for index, entry in ipairs(controlInbox) do
		local message = entry.message
		if entry.player == player
			and message.kind == "networkStatus"
			and message.code == code
			and (direction == nil or message.direction == direction)
		then
			table.remove(controlInbox, index)
			return message
		end
	end
	return nil
end

local function waitClientStatus(player, code, direction)
	return waitUntil("client status " .. code, function()
		return takeClientStatus(player, code, direction)
	end)
end

local attachServerRemote = Overdare.attachFRPServerRemote
assert(type(attachServerRemote) == "function", table.concat({
	"ReactiveState.Overdare.attachFRPServerRemote is required by this harness.",
	"Expected signature: (driver, remoteEvent, options?) -> binding with :arrivals() and :dispose().",
}, " "))

local serverHost = State.newHost()
local serverDriver = Overdare.attachFRP(serverHost, {
	phase = "Heartbeat",
	label = "studio-multiplayer.server",
})
local serverRemoteBinding = attachServerRemote(serverDriver, frpRemote, {
	protocol = frpProtocol,
	label = "studio-multiplayer.server-packets",
	playerRemovingSignal = Players.PlayerRemoving,
	heartbeatInterval = 1,
	authorize = function(clientId, messageType, value)
		return messageType == "probe" and type(value.nonce) == "string"
			and value.role ~= "forbidden" and clientId ~= nil
	end,
})
assert(type(serverRemoteBinding) == "table" and type(serverRemoteBinding.arrivals) == "function",
	"attachFRPServerRemote must return a binding with :arrivals()")
assert(type(serverRemoteBinding.dispose) == "function",
	"attachFRPServerRemote binding must provide :dispose()")
local serverPackets = serverRemoteBinding:arrivals()
assert(type(serverPackets) == "table" and type(serverPackets.subscribe) == "function",
	"FRP server remote :arrivals() must return an Event")
assert(type(serverRemoteBinding.bindOutbound) == "function",
	"FRP server remote binding must provide :bindOutbound(event)")

local function localSignal()
	local signal = { listeners = {} }
	function signal:Connect(callback)
		local entry = { callback = callback, connected = true }
		self.listeners[#self.listeners + 1] = entry
		return {
			Disconnect = function()
				entry.connected = false
			end,
		}
	end
	function signal:Fire(value)
		for _, entry in ipairs(self.listeners) do
			if entry.connected then
				entry.callback(value)
			end
		end
	end
	return signal
end

local serverOutboundSignal = localSignal()
local serverOutboundEvent, serverOutboundInput = serverDriver:eventFromSignal(serverOutboundSignal, {
	label = "studio-multiplayer.server-outbound",
})
local serverOutboundBinding = serverRemoteBinding:bindOutbound(serverOutboundEvent)
assert(serverOutboundBinding ~= nil and type(serverOutboundBinding.dispose) == "function",
	"FRP server :bindOutbound(event) must return a Disposable")

local serverPacketLog = {}
local stopServerPackets = serverPackets:subscribe(function(packet, occurrenceTime)
	serverPacketLog[#serverPacketLog + 1] = {
		packet = {
			player = serverRemoteBinding:getPlayer(packet.clientId),
			userId = tostring(packet.clientId),
			payload = packet.packet,
		},
		time = occurrenceTime,
	}
end)

local serverProtocolDecisionLog = {}
local stopServerIntents = serverRemoteBinding:intents():subscribe(function(decision)
	serverProtocolDecisionLog[#serverProtocolDecisionLog + 1] = decision
end)
local stopServerViolations = serverRemoteBinding:violations():subscribe(function(decision)
	serverProtocolDecisionLog[#serverProtocolDecisionLog + 1] = decision
end)

local function matchingServerPackets(player, nonce)
	local matches = {}
	for _, entry in ipairs(serverPacketLog) do
		if entry.packet.player == player
			and type(entry.packet.payload) == "table"
			and type(entry.packet.payload.payload) == "table"
			and entry.packet.payload.payload.nonce == nonce
		then
			matches[#matches + 1] = entry
		end
	end
	return matches
end

local function protocolDecisionCounts(clientId)
	local accepted = 0
	local duplicate = 0
	for _, decision in ipairs(serverProtocolDecisionLog) do
		if tostring(decision.clientId) == tostring(clientId) and decision.code == "intent_accepted" then
			accepted += 1
		elseif tostring(decision.clientId) == tostring(clientId) and decision.code == "duplicate_intent" then
			duplicate += 1
		end
	end
	return accepted, duplicate
end

local function shallowCopy(source)
	local result = {}
	for key, value in pairs(source) do
		result[key] = value
	end
	return result
end

local function buildAndSend(player, method, tick)
	local built = if method == "snapshot"
		then serverReplicator:createSnapshot(player, tick)
		else serverReplicator:createPatch(player, tick)
	check("server-build-" .. method, built.ok, built.message)
	local sent = networkAdapter:send(player, built.payload, method)
	check("server-send-" .. method, sent.ok, sent.message)
	return built.payload
end

local function sendPatchAfterMutation(player, tick, id, mutate, expectedCode)
	local built = serverReplicator:createPatch(player, tick)
	check(id .. "-build", built.ok, built.message)
	local bad = shallowCopy(built.payload)
	mutate(bad)
	stateRemote:FireClient(player, bad)
	local rejected = waitClientStatus(player, expectedCode, "inbound")
	check(id .. "-reject", rejected.ok == false, rejected.message)
	local sent = networkAdapter:send(player, built.payload, "patch")
	check(id .. "-recovery-send", sent.ok, sent.message)
	local applied = waitClientStatus(player, "applied", "inbound")
	check(id .. "-recovery-apply", applied.ok == true, applied.message)
	return built.payload
end

local removedPlayers = {}
Players.PlayerRemoving:Connect(function(player)
	removedPlayers[player] = true
	roleByPlayer[player] = nil
	local reset = serverReplicator:resetClient(player)
	line("CLEANUP", {
		"user=" .. tostring(player.UserId),
		"status=" .. tostring(reset.code),
		"ok=" .. tostring(reset.ok),
	})
end)

local function run()
	check("package-version", type(State.VERSION) == "string", State.VERSION)
	check("network-protocol", Network.PROTOCOL_VERSION == 1, Network.PROTOCOL_VERSION)
	check("server-context", RunService:IsServer() and not RunService:IsClient(), "server context")

	local elapsed, steppedDelta = RunService.Stepped:Wait()
	check("server-stepped-signature", type(elapsed) == "number" and type(steppedDelta) == "number" and steppedDelta >= 0,
		"elapsed=" .. tostring(elapsed) .. ",delta=" .. tostring(steppedDelta))
	local heartbeatDelta = RunService.Heartbeat:Wait()
	check("server-heartbeat-signature", type(heartbeatDelta) == "number" and heartbeatDelta >= 0, heartbeatDelta)

	local participants = {}
	local selected = {}
	while #participants < MIN_CLIENTS do
		local ready = waitControl(nil, "ready", nil)
		if not selected[ready.player] then
			selected[ready.player] = true
			participants[#participants + 1] = ready.player
			check("client-ready-" .. tostring(#participants),
				ready.message.harnessVersion == HARNESS_VERSION and ready.message.isClient == true,
				"user=" .. tostring(ready.player.UserId))
		end
	end

	local playerA = participants[1]
	local playerB = participants[2]
	roleByPlayer[playerA] = "A"
	roleByPlayer[playerB] = "B"
	command(playerA, "configure", { role = "A" })
	command(playerB, "configure", { role = "B" })
	local configuredA = waitControl(playerA, "report", "configured").message
	local configuredB = waitControl(playerB, "report", "configured").message
	check("client-a-runservice", configuredA.runServiceOk == true, configuredA.detail)
	check("client-b-runservice", configuredB.runServiceOk == true, configuredB.detail)
	check("client-memory-isolation", configuredA.processToken ~= configuredB.processToken,
		configuredA.processToken .. " vs " .. configuredB.processToken)
	check("module-process-isolation", configuredA.moduleProbeBefore == false
		and configuredB.moduleProbeBefore == false
		and State.__RSMPProcessProbe == "server:" .. RUN_ID,
		"server/client require caches are isolated")

	local snapshotA = buildAndSend(playerA, "snapshot", 1)
	local appliedA = waitClientStatus(playerA, "applied", "inbound")
	check("snapshot-a-values", appliedA.publicValue == 42 and appliedA.privateRole == "A"
		and appliedA.secret == 700 and appliedA.score == 0, "role A projection")

	command(playerB, "queryState", { reportCase = "before-target" })
	local beforeTarget = waitControl(playerB, "report", "before-target").message
	check("fireclient-targeting", beforeTarget.publicValue == -1 and beforeTarget.privateRole == "unset"
		and beforeTarget.secretPresent == true and beforeTarget.score == -100,
		"B stayed untouched while A received snapshot")

	local snapshotB = buildAndSend(playerB, "snapshot", 1)
	local appliedB = waitClientStatus(playerB, "applied", "inbound")
	check("snapshot-b-values", appliedB.publicValue == 42 and appliedB.privateRole == "B"
		and appliedB.secretPresent == false and appliedB.score == 0, "role B projection")
	check("visibility-hash-differs", snapshotA.stateHash ~= snapshotB.stateHash,
		snapshotA.stateHash .. " vs " .. snapshotB.stateHash)

	command(playerA, "sendValidIntent", { value = 2, reportCase = "initial-a" })
	command(playerB, "sendValidIntent", { value = 3, reportCase = "initial-b" })
	waitServerStatus(playerA, "intent_accepted")
	waitServerStatus(playerB, "intent_accepted")
	check("server-authoritative-a", projectedScore(scores:get(), playerA) == 1, projectedScore(scores:get(), playerA))
	check("server-authoritative-b", projectedScore(scores:get(), playerB) == 2, projectedScore(scores:get(), playerB))
	buildAndSend(playerA, "patch", 2)
	buildAndSend(playerB, "patch", 2)
	local correctedA = waitClientStatus(playerA, "applied", "inbound")
	local correctedB = waitClientStatus(playerB, "applied", "inbound")
	check("prediction-correction-a", correctedA.score == 1 and correctedA.pendingCount == 0 and correctedA.ackSequence == 1,
		"score=" .. tostring(correctedA.score))
	check("prediction-correction-b", correctedB.score == 2 and correctedB.pendingCount == 0 and correctedB.ackSequence == 1,
		"score=" .. tostring(correctedB.score))

	command(playerA, "prepareReplay", { first = 2, second = 3 })
	local prepared = waitControl(playerA, "report", "replay-prepared").message
	check("replay-sequences", prepared.firstSequence == 2 and prepared.secondSequence == 3, prepared.detail)
	waitServerStatus(playerA, "intent_accepted")
	buildAndSend(playerA, "patch", 3)
	local replayed = waitClientStatus(playerA, "applied", "inbound")
	check("pending-replay", replayed.ackSequence == 2 and replayed.pendingCount == 1 and replayed.score == 5,
		"score=" .. tostring(replayed.score) .. ",pending=" .. tostring(replayed.pendingCount))
	command(playerA, "sendHeldIntent", {})
	waitServerStatus(playerA, "intent_accepted")
	buildAndSend(playerA, "patch", 4)
	local replaySettled = waitClientStatus(playerA, "applied", "inbound")
	check("pending-settled", replaySettled.ackSequence == 3 and replaySettled.pendingCount == 0 and replaySettled.score == 4,
		"score=" .. tostring(replaySettled.score))

	local inboundFaults = {
		{ case = "rawDeep", code = "invalid_payload" },
		{ case = "rawWrongSchema", code = "schema_mismatch" },
		{ case = "rawWrongDirection", code = "intent_rejected" },
		{ case = "rawUnauthorized", code = "unauthorized_intent" },
	}
	for _, fault in ipairs(inboundFaults) do
		command(playerA, fault.case, { nextSequence = 4 })
		local rejected = waitServerStatus(playerA, fault.code)
		check("server-reject-" .. fault.case, rejected.ok == false, rejected.message)
		local status = serverReplicator:getClientStatus(playerA)
		check("server-sequence-stable-" .. fault.case, status.ackSequence == 3, status.ackSequence)
	end

	command(playerA, "sendValidIntent", { value = 2, reportCase = "post-reject" })
	local acceptedFour = waitServerStatus(playerA, "intent_accepted")
	check("rejected-sequence-reusable", acceptedFour.sequence == 4, acceptedFour.sequence)
	buildAndSend(playerA, "patch", 5)
	local postRejectApplied = waitClientStatus(playerA, "applied", "inbound")
	check("post-reject-authority", postRejectApplied.score == 5 and postRejectApplied.pendingCount == 0,
		postRejectApplied.score)
	command(playerA, "resendLastIntent", {})
	check("duplicate-intent", waitServerStatus(playerA, "duplicate_intent").ok == false, "duplicate rejected")
	command(playerA, "resendHeldIntent", {})
	check("stale-intent", waitServerStatus(playerA, "stale_intent").ok == false, "stale rejected")

	local lastGood = sendPatchAfterMutation(playerA, 6, "client-schema-mismatch", function(payload)
		payload.schemaVersion += 1
	end, "schema_mismatch")
	lastGood = sendPatchAfterMutation(playerA, 7, "client-sequence-gap", function(payload)
		payload.sequence += 1
	end, "sequence_gap")
	lastGood = sendPatchAfterMutation(playerA, 8, "client-stale-tick", function(payload)
		payload.tick = 0
	end, "stale_payload")
	lastGood = sendPatchAfterMutation(playerA, 9, "client-hash-tamper", function(payload)
		payload.stateHash = "0000000000000000"
	end, "state_hash_mismatch")
	lastGood = sendPatchAfterMutation(playerA, 10, "client-unknown-field", function(payload)
		payload.unknown = true
	end, "malformed_payload")
	stateRemote:FireClient(playerA, lastGood)
	check("client-duplicate-payload", waitClientStatus(playerA, "duplicate_payload", "inbound").ok == false,
		"duplicate rejected")
	command(playerA, "expectDeepInbound", {})
	local tooDeep = { child = { child = { child = { child = { child = { child = { value = 1 } } } } } } }
	stateRemote:FireClient(playerA, tooDeep)
	check("client-depth-limit", waitClientStatus(playerA, "invalid_payload", "inbound").ok == false,
		"deep payload rejected at adapter")

	local nonceA = "server-inbound-A"
	local nonceB = "server-inbound-B"
	command(playerA, "frpBurst", { nonce = nonceA, serverTick = -100 })
	command(playerB, "frpBurst", { nonce = nonceB, serverTick = -100 })
	waitControl(playerA, "report", "frp-burst-sent")
	waitControl(playerB, "report", "frp-burst-sent")
	local packetsA = waitUntil("two A FRP occurrences", function()
		local matches = matchingServerPackets(playerA, nonceA)
		return if #matches >= 2 then matches else nil
	end)
	local packetsB = waitUntil("two B FRP occurrences", function()
		local matches = matchingServerPackets(playerB, nonceB)
		return if #matches >= 2 then matches else nil
	end)
	check("frp-server-duplicates-a", #packetsA == 2, #packetsA)
	check("frp-server-duplicates-b", #packetsB == 2, #packetsB)
	for index, entry in ipairs(packetsA) do
		check("frp-server-arrival-time-a" .. tostring(index), entry.time > 0 and entry.time ~= entry.packet.payload.clientTick,
			"eventTime=" .. tostring(entry.time))
	end
	for index, entry in ipairs(packetsB) do
		check("frp-server-identity-b" .. tostring(index), entry.packet.player == playerB
			and entry.packet.userId == tostring(playerB.UserId), entry.packet.userId)
	end
	local acceptedA, duplicateA = protocolDecisionCounts(tostring(playerA.UserId))
	local acceptedB, duplicateB = protocolDecisionCounts(tostring(playerB.UserId))
	check("frp-protocol-deduplicates-a", acceptedA == 1 and duplicateA == 1,
		"accepted=" .. tostring(acceptedA) .. ",duplicate=" .. tostring(duplicateA))
	check("frp-protocol-deduplicates-b", acceptedB == 1 and duplicateB == 1,
		"accepted=" .. tostring(acceptedB) .. ",duplicate=" .. tostring(duplicateB))
	command(playerA, "frpUnauthorized", { nonce = "server-unauthorized-A" })
	waitControl(playerA, "report", "frp-unauthorized-sent")
	local unauthorized = waitUntil("FRP unauthorized decision", function()
		for _, decision in ipairs(serverProtocolDecisionLog) do
			if tostring(decision.clientId) == tostring(playerA.UserId) and decision.code == "unauthorized" then
				return decision
			end
		end
		return nil
	end)
	check("frp-authority-reject", unauthorized.ok == false and unauthorized.consumed == true,
		unauthorized.message)

	local targetNonce = "client-target"
	serverOutboundSignal:Fire({
		peer = playerA,
		messageType = "echo",
		payload = { nonce = targetNonce, serverTick = 200 },
		serverTick = 200,
	})
	serverOutboundSignal:Fire({
		peer = playerA,
		messageType = "echo",
		payload = { nonce = targetNonce, serverTick = 200 },
		serverTick = 200,
	})
	waitControl(playerA, "frpArrival", targetNonce)
	waitControl(playerA, "frpArrival", targetNonce)
	command(playerA, "queryFrp", { nonce = targetNonce, reportCase = "frp-target-a" })
	command(playerB, "queryFrp", { nonce = targetNonce, reportCase = "frp-target-b" })
	local targetA = waitControl(playerA, "report", "frp-target-a").message
	local targetB = waitControl(playerB, "report", "frp-target-b").message
	check("frp-fireclient-target-a", targetA.count == 2 and targetA.arrivalTimeOk == true
		and targetA.protocolAccepted >= 2 and targetA.protocolDuplicate == 0, targetA.count)
	check("frp-fireclient-target-b", targetB.count == 0, targetB.count)

	local broadcastNonce = "client-broadcast"
	local broadcast = serverRemoteBinding:broadcast(
		{ playerA, playerB },
		"echo",
		{ nonce = broadcastNonce, serverTick = 300 },
		300
	)
	check("frp-per-client-broadcast", broadcast.ok, broadcast.code)
	waitControl(playerA, "frpArrival", broadcastNonce)
	waitControl(playerB, "frpArrival", broadcastNonce)
	command(playerA, "queryFrp", { nonce = broadcastNonce, reportCase = "frp-broadcast-a" })
	command(playerB, "queryFrp", { nonce = broadcastNonce, reportCase = "frp-broadcast-b" })
	local broadcastA = waitControl(playerA, "report", "frp-broadcast-a").message
	local broadcastB = waitControl(playerB, "report", "frp-broadcast-b").message
	check("frp-fireallclients-a", broadcastA.count == 1 and broadcastA.arrivalTimeOk == true, broadcastA.count)
	check("frp-fireallclients-b", broadcastB.count == 1 and broadcastB.arrivalTimeOk == true, broadcastB.count)

	command(playerA, "dispose", {})
	command(playerB, "dispose", {})
	local disposedA = waitControl(playerA, "report", "disposed").message
	local disposedB = waitControl(playerB, "report", "disposed").message
	check("client-dispose-a", disposedA.adapterConnected == false, disposedA.detail)
	check("client-dispose-b", disposedB.adapterConnected == false, disposedB.detail)

	stateRemote:FireClient(playerA, lastGood)
	frpRemote:FireClient(playerA, { nonce = "after-dispose", serverTick = 400 })
	waitSeconds(1)
	command(playerA, "postDisposeQuery", {})
	local postDispose = waitControl(playerA, "report", "post-dispose").message
	check("client-dispose-stops-network", postDispose.networkStatusCount == disposedA.networkStatusCount,
		postDispose.networkStatusCount)
	check("client-dispose-stops-frp", postDispose.frpEventCount == disposedA.frpEventCount,
		postDispose.frpEventCount)

	local wasConnected = networkAdapter:isConnected()
	networkAdapter:dispose()
	stopServerPackets()
	stopServerIntents()
	stopServerViolations()
	serverOutboundBinding:dispose()
	serverOutboundBinding:dispose()
	serverOutboundInput:dispose()
	serverRemoteBinding:dispose()
	serverDriver:dispose()
	serverHost:dispose()
	serverReplicator:dispose()
	serverRuntime:dispose()
	check("server-adapter-dispose", wasConnected and not networkAdapter:isConnected(), "connection closed")
	check("server-post-dispose-send", networkAdapter:send(playerA, {}, "probe").code == "disconnected",
		"send rejected")
end

line("START", {
	"stateVersion=" .. tostring(State.VERSION),
	"protocol=" .. tostring(Network.PROTOCOL_VERSION),
	"schema=" .. tostring(SCHEMA_VERSION),
	"minClients=" .. tostring(MIN_CLIENTS),
})

local ok, runError = pcall(run)
if not ok then
	failed += 1
	line("FINAL", {
		"status=FAIL",
		"passed=" .. tostring(passed),
		"failed=" .. tostring(failed),
		"error=" .. tostring(runError),
	})
	error(runError, 0)
end

line("FINAL", {
	"status=PASS",
	"passed=" .. tostring(passed),
	"failed=" .. tostring(failed),
	"clients=" .. tostring(MIN_CLIENTS),
})
