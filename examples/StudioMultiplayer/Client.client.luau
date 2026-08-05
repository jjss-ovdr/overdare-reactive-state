--!nonstrict

-- Put this LocalScript in StarterPlayer/StarterPlayerScripts.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local BOOT_ID = string.format("client-%.6f", os.clock())
local BOOT_PREFIX = "[RSMP][v1]"

local function bootstrapLine(kind, fields)
	local parts = { BOOT_PREFIX, kind, "run=" .. BOOT_ID }
	for _, field in ipairs(fields or {}) do
		local safe = string.gsub(tostring(field), "[%c|]", " ")
		parts[#parts + 1] = safe
	end
	print(table.concat(parts, "|"))
end

-- This marker is deliberately before every assertion, wait, require, and
-- binding. If it is absent, this LocalScript was not copied and started.
bootstrapLine("BOOT", { "role=client", "stage=entry" })

local function bootstrap()
assert(RunService:IsStudio(), "StudioMultiplayer harness must only run in OVERDARE Studio")
assert(RunService:IsClient(), "StudioMultiplayer Client must run in a LocalScript")
bootstrapLine("BOOT", {
	"role=client",
	"stage=context",
	"class=" .. tostring(script.ClassName),
	"enabled=" .. tostring(script.Enabled),
})

local localPlayer = Players.LocalPlayer
assert(localPlayer ~= nil, "Players.LocalPlayer is unavailable")

local packageRoot = ReplicatedStorage:WaitForChild("ReactiveState", 15)
assert(packageRoot ~= nil, "ReactiveState package did not replicate")
bootstrapLine("BOOT", { "role=client", "stage=package-found" })

local stateRemote = ReplicatedStorage:WaitForChild("RSMP_State", 15)
assert(stateRemote ~= nil, "RSMP_State did not replicate; server harness did not start")
local frpRemote = ReplicatedStorage:WaitForChild("RSMP_FRP", 15)
assert(frpRemote ~= nil, "RSMP_FRP did not replicate; server harness did not finish RemoteEvent setup")
local controlRemote = ReplicatedStorage:WaitForChild("RSMP_Control", 15)
assert(controlRemote ~= nil, "RSMP_Control did not replicate; server harness did not finish RemoteEvent setup")
bootstrapLine("BOOT", { "role=client", "stage=objects-replicated" })

local State = require(packageRoot)
local Network = require(packageRoot.Network)
local Overdare = require(packageRoot.Overdare)
bootstrapLine("BOOT", { "role=client", "stage=modules-loaded" })

local HARNESS_VERSION = 1
local SCHEMA_VERSION = 31
local PREFIX = "[RSMP][v1]"

local moduleProbeBefore = State.__RSMPProcessProbe ~= nil
State.__RSMPProcessProbe = "client:" .. tostring(localPlayer.UserId)

local runId = nil
local _role = nil
local processToken = tostring(localPlayer.UserId) .. ":" .. tostring({})
local disposed = false

local function localLine(kind, detail)
	print(table.concat({
		PREFIX,
		kind,
		"run=" .. tostring(runId or "pending"),
		"user=" .. tostring(localPlayer.UserId),
		"detail=" .. tostring(detail),
	}, "|"))
end

local function send(message)
	message.runId = runId
	controlRemote:FireServer(message)
end

local steppedOk = false
local heartbeatOk = false
local renderSteppedOk = false

RunService.Stepped:Once(function(elapsed, delta)
	steppedOk = type(elapsed) == "number" and type(delta) == "number" and delta >= 0
end)
RunService.Heartbeat:Once(function(delta)
	heartbeatOk = type(delta) == "number" and delta >= 0
end)
RunService.RenderStepped:Once(function(delta)
	renderSteppedOk = type(delta) == "number" and delta >= 0
end)

local attachClientRemote = Overdare.attachFRPClientRemote
assert(type(attachClientRemote) == "function", table.concat({
	"ReactiveState.Overdare.attachFRPClientRemote is required by this harness.",
	"Expected signature: (driver, remoteEvent, options?) -> binding with :arrivals() and :dispose().",
}, " "))

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

local frpHost = State.newHost()
local frpDriver = Overdare.attachFRP(frpHost, {
	phase = "Heartbeat",
	label = "studio-multiplayer.client." .. tostring(localPlayer.UserId),
})
local frpBinding = attachClientRemote(frpDriver, frpRemote, {
	protocol = frpProtocol,
	initialResync = false,
	label = "studio-multiplayer.client-packets",
})
bootstrapLine("BOOT", { "role=client", "stage=frp-binding-ready" })
assert(type(frpBinding) == "table" and type(frpBinding.arrivals) == "function",
	"attachFRPClientRemote must return a binding with :arrivals()")
assert(type(frpBinding.dispose) == "function", "FRP client remote binding must provide :dispose()")

local frpEvents = {}
local arrivals = frpBinding:authority()
assert(type(arrivals) == "table" and type(arrivals.subscribe) == "function",
	"FRP client remote :authority() must return an Event")
assert(type(frpBinding.bindOutbound) == "function",
	"FRP client remote binding must provide :bindOutbound(event)")

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

local outboundSignal = localSignal()
local outboundEvent, outboundInput = frpDriver:eventFromSignal(outboundSignal, {
	label = "studio-multiplayer.client-outbound",
})
local outboundBinding = frpBinding:bindOutbound(outboundEvent)
assert(outboundBinding ~= nil and type(outboundBinding.dispose) == "function",
	"FRP client :bindOutbound(event) must return a Disposable")

local clientProtocolDecisionLog = {}
local stopClientViolations = frpBinding:violations():subscribe(function(decision)
	clientProtocolDecisionLog[#clientProtocolDecisionLog + 1] = decision
end)

local function packetNonce(packet)
	if type(packet) ~= "table" then
		return nil
	end
	if type(packet.payload) == "table" and type(packet.payload.nonce) == "string" then
		return packet.payload.nonce
	end
	return packet.nonce
end

local stopArrivals = arrivals:subscribe(function(message, occurrenceTime)
	local payload = message.payload
	frpEvents[#frpEvents + 1] = {
		payload = payload,
		time = occurrenceTime,
	}
	clientProtocolDecisionLog[#clientProtocolDecisionLog + 1] = message
	local nonce = packetNonce(payload)
	if runId ~= nil and type(nonce) == "string" then
		send({ kind = "frpArrival", case = nonce, occurrenceTime = occurrenceTime })
	end
end)

local runtime = nil
local client = nil
local networkAdapter = nil
local publicValue = nil
local privateRole = nil
local secret = nil
local score = nil
local networkStatusCount = 0
local payloadBySequence = {}
local lastIntentPayload = nil
local heldIntentPayload = nil

local function stateFields()
	if runtime == nil or disposed then
		return {}
	end
	local secretValue = secret:get()
	local status = client:getStatus()
	return {
		publicValue = publicValue:get(),
		privateRole = privateRole:get(),
		secret = secretValue,
		secretPresent = secretValue ~= nil,
		score = score:get(),
		pendingCount = status.pendingCount,
		ackSequence = status.ackSequence,
		serverSequence = status.serverSequence,
	}
end

local function sendNetworkStatus(status, context)
	networkStatusCount += 1
	local message = stateFields()
	message.kind = "networkStatus"
	message.ok = status.ok
	message.code = status.code
	message.message = status.message
	message.direction = context.direction
	message.statusSequence = status.sequence
	message.statusAckSequence = status.ackSequence
	send(message)
end

local function setupNetwork()
	assert(runtime == nil, "network client was configured twice")
	runtime = State.createStateRuntime({ label = "StudioMultiplayer.client." .. tostring(localPlayer.UserId) })
	publicValue = runtime:atom(-1, { label = "network.public" })
	privateRole = runtime:atom("unset", { label = "network.privateRole" })
	secret = runtime:atom("unseen", { label = "network.secretA" })
	score = runtime:atom(-100, { label = "network.score" })

	local schema = Network.defineSchema({
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
			target = score,
			predict = function(current, value)
				return current + value
			end,
			validate = function(value)
				return type(value) == "number" and value % 1 == 0 and value >= 1 and value <= 5
			end,
		},
		{
			key = "privateRole",
			direction = Network.SERVER_TO_CLIENT,
			target = privateRole,
			validate = function(value)
				return value == "A" or value == "B"
			end,
		},
		{
			key = "publicValue",
			direction = Network.SERVER_TO_CLIENT,
			target = publicValue,
			validate = function(value)
				return type(value) == "number"
			end,
		},
		{
			key = "score",
			direction = Network.SERVER_TO_CLIENT,
			target = score,
			validate = function(value)
				return type(value) == "number" and value >= 0
			end,
		},
		{
			key = "secretA",
			direction = Network.SERVER_TO_CLIENT,
			target = secret,
			validate = function(value)
				return type(value) == "number"
			end,
		},
	}, {
		schemaVersion = SCHEMA_VERSION,
		limits = { maxFields = 16, maxDepth = 6, maxElements = 64, maxStringLength = 256 },
	})

	client = Network.createClient({ schema = schema, runtime = runtime })
	networkAdapter = Overdare.createClientPrediction({
		replicator = client,
		remoteEvent = stateRemote,
		maxPayloadDepth = 6,
		maxPayloadEntries = 64,
		onStatus = sendNetworkStatus,
	})
end

local function buildIntent(value)
	local result = client:createIntent({ move = value }, 10 + #payloadBySequence)
	assert(result.ok, result.message)
	payloadBySequence[result.sequence] = result.payload
	lastIntentPayload = result.payload
	return result
end

local function rawIntent(sequence, schemaVersion, key, value)
	return {
		kind = "intent",
		protocolVersion = Network.PROTOCOL_VERSION,
		schemaVersion = schemaVersion,
		sequence = sequence,
		clientTick = 100 + sequence,
		changes = { { key = key, op = "set", value = value } },
	}
end

local function deepPayload()
	return { child = { child = { child = { child = { child = { child = { value = 1 } } } } } } }
end

local function frpReport(nonce, reportCase)
	local count = 0
	local arrivalTimeOk = true
	for _, entry in ipairs(frpEvents) do
		if packetNonce(entry.payload) == nonce then
			count += 1
			local packetTick = entry.payload.serverTick
			if type(entry.time) ~= "number" or entry.time <= 0 or entry.time == packetTick then
				arrivalTimeOk = false
			end
		end
	end
	local protocolAccepted = 0
	local protocolDuplicate = 0
	for _, decision in ipairs(clientProtocolDecisionLog) do
		if decision.code == "event_accepted" then
			protocolAccepted += 1
		elseif decision.code == "duplicate_event" then
			protocolDuplicate += 1
		end
	end
	send({
		kind = "report",
		case = reportCase,
		count = count,
		arrivalTimeOk = arrivalTimeOk,
		protocolAccepted = protocolAccepted,
		protocolDuplicate = protocolDuplicate,
	})
end

local function handleCommand(message)
	local caseName = message.case
	if caseName == "configure" then
		assert(runId == nil, "configure was delivered twice")
		runId = message.runId
		_role = message.role
		setupNetwork()
		send({
			kind = "report",
			case = "configured",
			processToken = processToken,
			moduleProbeBefore = moduleProbeBefore,
			runServiceOk = steppedOk and heartbeatOk and renderSteppedOk,
			detail = "stepped=" .. tostring(steppedOk)
				.. ",heartbeat=" .. tostring(heartbeatOk)
				.. ",render=" .. tostring(renderSteppedOk),
		})
	elseif message.runId ~= runId then
		return
	elseif caseName == "queryState" then
		local report = stateFields()
		report.kind = "report"
		report.case = message.reportCase
		send(report)
	elseif caseName == "sendValidIntent" then
		local intent = buildIntent(message.value)
		local sent = networkAdapter:sendIntent(intent.payload)
		assert(sent.ok, sent.message)
		send({ kind = "report", case = message.reportCase, sequence = intent.sequence })
	elseif caseName == "prepareReplay" then
		local first = buildIntent(message.first)
		local second = buildIntent(message.second)
		heldIntentPayload = second.payload
		local sent = networkAdapter:sendIntent(first.payload)
		assert(sent.ok, sent.message)
		send({
			kind = "report",
			case = "replay-prepared",
			firstSequence = first.sequence,
			secondSequence = second.sequence,
			detail = tostring(first.sequence) .. "," .. tostring(second.sequence),
		})
	elseif caseName == "sendHeldIntent" then
		assert(heldIntentPayload ~= nil, "no held intent")
		assert(networkAdapter:sendIntent(heldIntentPayload).ok, "held intent send failed")
	elseif caseName == "rawDeep" then
		stateRemote:FireServer(deepPayload())
	elseif caseName == "rawWrongSchema" then
		stateRemote:FireServer(rawIntent(message.nextSequence, SCHEMA_VERSION + 1, "move", 1))
	elseif caseName == "rawWrongDirection" then
		stateRemote:FireServer(rawIntent(message.nextSequence, SCHEMA_VERSION, "score", 9999))
	elseif caseName == "rawUnauthorized" then
		stateRemote:FireServer(rawIntent(message.nextSequence, SCHEMA_VERSION, "admin", true))
	elseif caseName == "resendLastIntent" then
		assert(lastIntentPayload ~= nil, "no last intent")
		stateRemote:FireServer(lastIntentPayload)
	elseif caseName == "resendHeldIntent" then
		assert(heldIntentPayload ~= nil, "no held intent")
		stateRemote:FireServer(heldIntentPayload)
	elseif caseName == "expectDeepInbound" then
		-- The server sends the hostile payload immediately after this command.
	elseif caseName == "frpBurst" then
		outboundSignal:Fire({ messageType = "probe", payload = { nonce = message.nonce }, clientTick = 100 })
		RunService.Heartbeat:Wait()
		local exactPacket = frpBinding:getLastIntentPacket()
		assert(exactPacket ~= nil, "FRP outbound binding did not create an intent packet")
		frpRemote:FireServer(exactPacket)
		send({ kind = "report", case = "frp-burst-sent" })
	elseif caseName == "frpUnauthorized" then
		local result = frpBinding:send("probe", {
			nonce = message.nonce,
			role = "forbidden",
		}, 102)
		assert(result.ok, result.message)
		send({ kind = "report", case = "frp-unauthorized-sent" })
	elseif caseName == "queryFrp" then
		frpReport(message.nonce, message.reportCase)
	elseif caseName == "dispose" then
		local wasConnected = networkAdapter:isConnected()
		networkAdapter:dispose()
		client:dispose()
		stopArrivals()
		stopClientViolations()
		outboundBinding:dispose()
		outboundBinding:dispose()
		outboundInput:dispose()
		frpBinding:dispose()
		frpDriver:dispose()
		frpHost:dispose()
		runtime:dispose()
		disposed = true
		send({
			kind = "report",
			case = "disposed",
			adapterConnected = networkAdapter:isConnected(),
			networkStatusCount = networkStatusCount,
			frpEventCount = #frpEvents,
			detail = "wasConnected=" .. tostring(wasConnected),
		})
	elseif caseName == "postDisposeQuery" then
		send({
			kind = "report",
			case = "post-dispose",
			networkStatusCount = networkStatusCount,
			frpEventCount = #frpEvents,
		})
	else
		error("unknown StudioMultiplayer command: " .. tostring(caseName))
	end
end

controlRemote.OnClientEvent:Connect(function(message)
	if type(message) ~= "table" or message.kind ~= "command" then
		return
	end
	local ok, commandError = pcall(handleCommand, message)
	if not ok then
		localLine("CLIENT_FAIL", commandError)
		send({ kind = "report", case = "client-error", detail = tostring(commandError) })
		error(commandError, 0)
	end
end)

local signalWaited = 0
while not (steppedOk and heartbeatOk and renderSteppedOk) and signalWaited < 5 do
	signalWaited += task.wait(0.05)
end
assert(steppedOk and heartbeatOk and renderSteppedOk, table.concat({
	"client RunService startup signals timed out",
	"stepped=" .. tostring(steppedOk),
	"heartbeat=" .. tostring(heartbeatOk),
	"renderStepped=" .. tostring(renderSteppedOk),
}, ","))

localLine("READY", "client signals and FRP binding ready")
controlRemote:FireServer({
	kind = "ready",
	harnessVersion = HARNESS_VERSION,
	isClient = RunService:IsClient(),
	userId = tostring(localPlayer.UserId),
})
end

local bootstrapOk, bootstrapError = pcall(bootstrap)
if not bootstrapOk then
	bootstrapLine("CLIENT_FAIL", {
		"role=client",
		"stage=startup",
		"error=" .. tostring(bootstrapError),
	})
	error(bootstrapError, 0)
end
