--!nonstrict

local FRP = require("../src/Core/FRP")
local Network = require("../src/Network")
local Overdare = require("../src/Overdare")

local function callableProxy(callback)
	return setmetatable({}, {
		__call = function(_proxy, ...)
			return callback(...)
		end,
	})
end

local function fakeSignal(proxyMembers)
	local signal = { listeners = {} }
	local function connect(owner, callback)
		local entry = { callback = callback, connected = true }
		owner.listeners[#owner.listeners + 1] = entry
		local connection = {}
		local function disconnect(_connection)
			entry.connected = false
		end
		connection.Disconnect = if proxyMembers then callableProxy(disconnect) else disconnect
		return connection
	end
	signal.Connect = if proxyMembers then callableProxy(connect) else connect
	function signal:Fire(...)
		for _, entry in ipairs(self.listeners) do
			if entry.connected then
				entry.callback(...)
			end
		end
	end
	return signal
end

local function protocol(options)
	options = options or {}
	return Network.defineFRPProtocol({
		move = {
			direction = Network.CLIENT_INTENT,
			validate = options.moveValidate or function(value)
				return type(value) == "table" and type(value.delta) == "number", "move.delta must be a number"
			end,
		},
		state = {
			direction = Network.SERVER_TO_CLIENT,
			validate = function(value)
				return type(value) == "table" and type(value.value) == "number", "state.value must be a number"
			end,
		},
	}, {
		id = options.id or "tests.multiplayer.v1",
		schemaVersion = 3,
		rateLimit = options.rateLimit,
		replayCapacity = options.replayCapacity or 8,
		pendingCapacity = options.pendingCapacity or 8,
		maxBytes = options.maxBytes,
	})
end

local function fakeHub(players, proxyMembers)
	local hub = {
		serverSignal = fakeSignal(proxyMembers),
		clientSignals = {},
		dropClientToServer = nil,
		dropServerToClient = nil,
		clientToServer = {},
		serverToClient = {},
	}
	for _, player in ipairs(players) do
		hub.clientSignals[player] = fakeSignal(proxyMembers)
	end
	local serverRemote = { OnServerEvent = hub.serverSignal }
	local function fireClient(_remote, player, packet)
		hub.serverToClient[#hub.serverToClient + 1] = { player = player, packet = packet }
		if hub.dropServerToClient ~= nil and hub.dropServerToClient(player, packet) then
			return
		end
		hub.clientSignals[player]:Fire(packet)
	end
	serverRemote.FireClient = if proxyMembers then callableProxy(fireClient) else fireClient
	local clientRemotes = {}
	for _, player in ipairs(players) do
		local remote = { OnClientEvent = hub.clientSignals[player] }
		local function fireServer(_remote, packet)
			hub.clientToServer[#hub.clientToServer + 1] = { player = player, packet = packet }
			if hub.dropClientToServer ~= nil and hub.dropClientToServer(player, packet) then
				return
			end
			hub.serverSignal:Fire(player, packet)
		end
		remote.FireServer = if proxyMembers then callableProxy(fireServer) else fireServer
		clientRemotes[player] = remote
	end
	hub.serverRemote = serverRemote
	hub.clientRemotes = clientRemotes
	return hub, serverRemote, clientRemotes
end

local function makeFixture(options)
	options = options or {}
	local players = {
		{ UserId = 101, Name = "A" },
		{ UserId = 202, Name = "B" },
	}
	local hub, serverRemote, clientRemotes = fakeHub(players, options.proxyMembers)
	hub.dropClientToServer = options.dropClientToServer
	hub.dropServerToClient = options.dropServerToClient
	local serverHost = FRP.newHost()
	local serverPhase = fakeSignal(options.proxyMembers)
	local serverDriver = Overdare.attachFRP(serverHost, { signal = serverPhase, errorPolicy = "raise" })
	local playerRemoving = fakeSignal(options.proxyMembers)
	local playersService = {
		PlayerRemoving = playerRemoving,
	}
	local function getPlayers(_service)
		return players
	end
	playersService.GetPlayers = if options.proxyMembers then callableProxy(getPlayers) else getPlayers
	local serviceProvider = {
		GetService = callableProxy(function(_provider, name)
			assert(name == "Players", "unexpected service request")
			return playersService
		end),
	}
	local schema = options.protocol or protocol({ replayCapacity = options.replayCapacity or 8 })
	local snapshotValue = 900
	local serverOptions = {
		protocol = schema,
		playerRemovingSignal = if options.proxyMembers then nil else playerRemoving,
		game = if options.proxyMembers then serviceProvider else nil,
		heartbeatInterval = if options.heartbeatInterval ~= nil then options.heartbeatInterval else false,
		replayCapacity = options.replayCapacity,
		maxPendingPerFrame = options.maxPendingPerFrame,
		authorize = options.authorize,
		buildSnapshot = if options.noSnapshot then nil else function(clientId)
			return {
				messageType = "state",
				payload = { value = snapshotValue + clientId },
				serverTick = 1,
			}
		end,
	}
	local server = Overdare.attachFRPServerRemote(serverDriver, serverRemote, serverOptions)
	local clients = {}
	for index, player in ipairs(players) do
		local host = FRP.newHost()
		local phase = fakeSignal(options.proxyMembers)
		local driver = Overdare.attachFRP(host, { signal = phase, errorPolicy = "raise" })
		local client = Overdare.attachFRPClientRemote(driver, clientRemotes[player], {
			protocol = schema,
			initialResync = options.initialResync ~= false,
			ackTimeout = options.ackTimeout or 10,
			retryBackoff = options.retryBackoff or 1,
			resyncRetryInterval = options.resyncRetryInterval or 1,
		})
		clients[index] = { host = host, phase = phase, driver = driver, channel = client, player = player }
	end
	local serverTime = 0
	local clientTimes = { 0, 0 }
	local fixture = {
		players = players,
		hub = hub,
		server = server,
		serverHost = serverHost,
		serverDriver = serverDriver,
		serverPhase = serverPhase,
		playerRemoving = playerRemoving,
		clients = clients,
	}
	function fixture:flushServer(delta)
		delta = delta or 0.1
		serverTime += delta
		serverPhase:Fire(delta)
	end
	function fixture:flushClient(index, delta)
		delta = delta or 0.1
		clientTimes[index] += delta
		clients[index].phase:Fire(delta)
	end
	function fixture:flushClients(delta)
		self:flushClient(1, delta)
		self:flushClient(2, delta)
	end
	function fixture:dispose()
		for _, entry in ipairs(clients) do
			entry.channel:dispose()
			entry.driver:dispose()
			entry.host:dispose()
		end
		server:dispose()
		serverDriver:dispose()
		serverHost:dispose()
	end
	return fixture
end

return function(h)
	h:test("FRP RemoteEvent adapters accept callable engine proxy members", function()
		local f = makeFixture({ proxyMembers = true, initialResync = false, noSnapshot = true })
		h:equal(type(f.hub.serverSignal.Connect), "table")
		h:equal(type(f.hub.serverRemote.FireClient), "table")
		h:equal(type(f.hub.clientRemotes[f.players[1]].FireServer), "table")

		local intents = {}
		local authority = { {}, {} }
		local stops = {
			f.server:intents():subscribe(function(value)
				intents[#intents + 1] = value
			end),
			f.clients[1].channel:authority():subscribe(function(value)
				authority[1][#authority[1] + 1] = value
			end),
			f.clients[2].channel:authority():subscribe(function(value)
				authority[2][#authority[2] + 1] = value
			end),
		}

		h:truthy(f.clients[1].channel:send("move", { delta = 1 }, 1).ok)
		f:flushServer()
		h:equal(#intents, 1)
		h:equal(intents[1].clientId, 101)
		f:flushClients()
		h:equal(f.clients[1].channel:status().pendingCount, 0)

		local broadcast = f.server:broadcast(nil, "state", { value = 42 }, 2)
		h:truthy(broadcast.ok)
		h:equal(#broadcast.results, 2)
		f:flushClients()
		h:equal(authority[1][1].payload.value, 42)
		h:equal(authority[2][1].payload.value, 42)

		f.playerRemoving:Fire(f.players[1])
		f:flushServer()
		h:falsy(f.server:getPeerStatus(101).connected)
		for _, stop in ipairs(stops) do
			stop()
		end
		f:dispose()
	end)

	h:test("FRP bindOutbound is phase-buffered and retains the exact client packet", function()
		local f = makeFixture({ proxyMembers = true, initialResync = false, noSnapshot = true })
		local clientSignal = fakeSignal(true)
		local clientEvent, clientInput = f.clients[1].driver:eventFromSignal(clientSignal, {
			label = "tests.client-outbound",
		})
		local clientOutput = f.clients[1].channel:bindOutbound(clientEvent)
		local intents = {}
		local violations = {}
		local authority = {}
		local stops = {
			f.server:intents():subscribe(function(value)
				intents[#intents + 1] = value
			end),
			f.server:violations():subscribe(function(value)
				violations[#violations + 1] = value
			end),
			f.clients[1].channel:authority():subscribe(function(value)
				authority[#authority + 1] = value
			end),
		}

		clientSignal:Fire({ messageType = "move", payload = { delta = 9 }, clientTick = 99 })
		h:equal(f.clients[1].channel:getLastIntentPacket(), nil)
		h:equal(#f.hub.clientToServer, 0)
		f:flushClient(1)
		local exactPacket = f.clients[1].channel:getLastIntentPacket()
		h:truthy(exactPacket ~= nil)
		h:equal(exactPacket.kind, "intent")
		h:equal(exactPacket.sequence, 1)
		h:equal(exactPacket.messageType, "move")
		h:equal(exactPacket.clientTick, 99)
		h:equal(exactPacket.payload.delta, 9)
		h:equal(#f.hub.clientToServer, 1)
		h:equal(f.hub.clientToServer[1].packet, exactPacket)

		f.hub.clientRemotes[f.players[1]]:FireServer(exactPacket)
		f:flushServer()
		h:equal(#intents, 1)
		h:equal(intents[1].clientId, 101)
		h:equal(#violations, 1)
		h:equal(violations[1].code, "duplicate_intent")

		local serverSignal = fakeSignal(true)
		local serverEvent, serverInput = f.serverDriver:eventFromSignal(serverSignal, {
			label = "tests.server-outbound",
		})
		local serverOutput = f.server:bindOutbound(serverEvent)
		local sentBefore = #f.hub.serverToClient
		serverSignal:Fire({
			peer = f.players[1],
			messageType = "state",
			payload = { value = 42 },
			serverTick = 2,
		})
		h:equal(#f.hub.serverToClient, sentBefore)
		f:flushServer()
		h:equal(#f.hub.serverToClient, sentBefore + 1)
		f:flushClient(1)
		h:equal(authority[1].payload.value, 42)
		h:equal(#f.serverHost:getErrors(), 0)
		h:equal(#f.clients[1].host:getErrors(), 0)

		serverOutput:dispose()
		serverInput:dispose()
		clientOutput:dispose()
		clientInput:dispose()
		for _, stop in ipairs(stops) do
			stop()
		end
		f:dispose()
	end)

	h:test("FRP RemoteEvent protocol isolates two clients and acknowledges intents", function()
		local f = makeFixture()
		local snapshots = { {}, {} }
		local intents = {}
		local stops = {
			f.clients[1].channel:snapshots():subscribe(function(value)
				snapshots[1][#snapshots[1] + 1] = value
			end),
			f.clients[2].channel:snapshots():subscribe(function(value)
				snapshots[2][#snapshots[2] + 1] = value
			end),
			f.server:intents():subscribe(function(value)
				intents[#intents + 1] = value
			end),
		}

		f:flushServer()
		f:flushClients()
		h:equal(#snapshots[1], 1)
		h:equal(#snapshots[2], 1)
		h:equal(snapshots[1][1].payload.value, 1001)
		h:equal(snapshots[2][1].payload.value, 1102)

		h:truthy(f.clients[1].channel:send("move", { delta = 1 }, 10).ok)
		h:truthy(f.clients[2].channel:send("move", { delta = 2 }, 20).ok)
		f:flushServer()
		h:equal(#intents, 2)
		h:equal(intents[1].clientId, 101)
		h:equal(intents[2].clientId, 202)
		f:flushClients()
		h:equal(f.clients[1].channel:status().pendingCount, 0)
		h:equal(f.clients[2].channel:status().pendingCount, 0)

		local authority = { {}, {} }
		stops[#stops + 1] = f.clients[1].channel:authority():subscribe(function(value)
			authority[1][#authority[1] + 1] = value
		end)
		stops[#stops + 1] = f.clients[2].channel:authority():subscribe(function(value)
			authority[2][#authority[2] + 1] = value
		end)
		h:truthy(f.server:send(f.players[1], "state", { value = 11 }, 2).ok)
		f:flushClients()
		h:equal(#authority[1], 1)
		h:equal(#authority[2], 0)
		h:equal(authority[1][1].payload.value, 11)

		for _, stop in ipairs(stops) do
			stop()
		end
		f:dispose()
	end)

	h:test("a lost initial resync request is retried until the snapshot arrives", function()
		local dropped = false
		local f = makeFixture({
			resyncRetryInterval = 0.2,
			dropClientToServer = function(player, packet)
				if player.UserId == 101 and packet.kind == "resync" and not dropped then
					dropped = true
					return true
				end
				return false
			end,
		})
		local snapshots = {}
		local stop = f.clients[1].channel:snapshots():subscribe(function(value)
			snapshots[#snapshots + 1] = value
		end)
		f:flushServer(0.1)
		f:flushClient(1, 0.1)
		h:equal(#snapshots, 0)
		f:flushClient(1, 0.1)
		f:flushServer(0.1)
		f:flushClient(1, 0.1)
		h:equal(#snapshots, 1)
		h:equal(snapshots[1].payload.value, 1001)
		h:falsy(f.clients[1].channel:status().resyncPending)
		stop()
		f:dispose()
	end)

	h:test("lost client intent is replayed with the same sequence after a gap", function()
		local f = makeFixture({ initialResync = false, noSnapshot = true })
		local dropped = false
		f.hub.dropClientToServer = function(player, packet)
			if player == f.players[1] and packet.kind == "intent" and packet.sequence == 1 and not dropped then
				dropped = true
				return true
			end
			return false
		end
		local accepted = {}
		local stop = f.server:intents():subscribe(function(value)
			if value.clientId == 101 then
				accepted[#accepted + 1] = value.sequence
			end
		end)
		h:truthy(f.clients[1].channel:send("move", { delta = 1 }, 1).ok)
		h:truthy(f.clients[1].channel:send("move", { delta = 2 }, 2).ok)
		f:flushServer()
		h:equal(#accepted, 0)
		f:flushClient(1)
		f:flushServer()
		h:deepEqual(accepted, { 1, 2 })
		f:flushClient(1)
		h:equal(f.clients[1].channel:status().pendingCount, 0)
		local sequenceOneTransmissions = 0
		for _, entry in ipairs(f.hub.clientToServer) do
			if entry.player == f.players[1] and entry.packet.kind == "intent" and entry.packet.sequence == 1 then
				sequenceOneTransmissions += 1
			end
		end
		h:equal(sequenceOneTransmissions, 2)
		stop()
		f:dispose()
	end)

	h:test("a lost final intent is retransmitted after the acknowledgement timeout", function()
		local f = makeFixture({ initialResync = false, noSnapshot = true, ackTimeout = 0.2 })
		local dropped = false
		f.hub.dropClientToServer = function(player, packet)
			if player == f.players[1] and packet.kind == "intent" and not dropped then
				dropped = true
				return true
			end
			return false
		end
		local accepted = 0
		local stop = f.server:intents():subscribe(function(value)
			if value.clientId == 101 then
				accepted += 1
			end
		end)
		h:truthy(f.clients[1].channel:send("move", { delta = 1 }, 1).ok)
		f:flushServer(0.1)
		h:equal(accepted, 0)
		f:flushClient(1, 0.1)
		f:flushClient(1, 0.1)
		f:flushServer(0.1)
		h:equal(accepted, 1)
		f:flushClient(1, 0.1)
		h:equal(f.clients[1].channel:status().pendingCount, 0)
		stop()
		f:dispose()
	end)

	h:test("lost authoritative event is recovered from the per-client replay buffer", function()
		local f = makeFixture({ initialResync = false, noSnapshot = true, replayCapacity = 8 })
		local dropped = false
		f.hub.dropServerToClient = function(player, packet)
			if player == f.players[1] and packet.kind == "event" and packet.sequence == 2 and not dropped then
				dropped = true
				return true
			end
			return false
		end
		local values = {}
		local stop = f.clients[1].channel:authority():subscribe(function(value)
			values[#values + 1] = value.payload.value
		end)
		h:truthy(f.server:send(f.players[1], "state", { value = 1 }, 1).ok)
		h:truthy(f.server:send(f.players[1], "state", { value = 2 }, 2).ok)
		h:truthy(f.server:send(f.players[1], "state", { value = 3 }, 3).ok)
		f:flushClient(1)
		h:deepEqual(values, { 1 })
		f:flushServer()
		f:flushClient(1)
		h:deepEqual(values, { 1, 2, 3 })
		h:equal(f.clients[1].channel:status().serverSequence, 3)
		stop()
		f:dispose()
	end)

	h:test("a heartbeat exposes a lost final authoritative event and triggers replay", function()
		local f = makeFixture({ initialResync = false, noSnapshot = true, heartbeatInterval = 0.05 })
		local dropped = false
		f.hub.dropServerToClient = function(player, packet)
			if player == f.players[1] and packet.kind == "event" and not dropped then
				dropped = true
				return true
			end
			return false
		end
		local values = {}
		local stop = f.clients[1].channel:authority():subscribe(function(value)
			values[#values + 1] = value.payload.value
		end)
		h:truthy(f.server:send(f.players[1], "state", { value = 77 }, 1).ok)
		f:flushServer(0.1)
		f:flushClient(1, 0.1)
		h:equal(#values, 0)
		f:flushServer(0.1)
		f:flushClient(1, 0.1)
		h:deepEqual(values, { 77 })
		stop()
		f:dispose()
	end)

	h:test("heartbeat liveness does not advance the application server tick", function()
		local f = makeFixture({ initialResync = false, noSnapshot = true, heartbeatInterval = 0.05 })
		h:truthy(f.server:send(f.players[1], "state", { value = 1 }, 10).ok)
		f:flushClient(1, 0.1)
		f:flushServer(0.1)
		f:flushClient(1, 0.1)
		h:equal(f.clients[1].channel._state.serverTick, 10)
		h:truthy(f.server:send(f.players[1], "state", { value = 2 }, 10).ok)
		f:dispose()
	end)

	h:test("replay-buffer miss falls back to a new authoritative snapshot epoch", function()
		local f = makeFixture({ initialResync = false, replayCapacity = 1 })
		local dropped = false
		f.hub.dropServerToClient = function(player, packet)
			if player == f.players[1] and packet.kind == "event" and packet.sequence == 2 and not dropped then
				dropped = true
				return true
			end
			return false
		end
		local snapshots = {}
		local stop = f.clients[1].channel:snapshots():subscribe(function(value)
			snapshots[#snapshots + 1] = value
		end)
		h:truthy(f.server:send(f.players[1], "state", { value = 1 }, 1).ok)
		h:truthy(f.server:send(f.players[1], "state", { value = 2 }, 2).ok)
		h:truthy(f.server:send(f.players[1], "state", { value = 3 }, 3).ok)
		f:flushClient(1)
		f:flushServer()
		f:flushClient(1)
		h:equal(#snapshots, 1)
		h:equal(snapshots[1].epoch, 2)
		h:equal(snapshots[1].sequence, 1)
		h:equal(f.clients[1].channel:status().epoch, 2)
		stop()
		f:dispose()
	end)

	h:test("exact invalid or unauthorized intents are consumed while malformed and gaps are not", function()
		local schema = protocol()
		local server = Network.createFRPServer({
			protocol = schema,
			authorize = function(_clientId, _messageType, value)
				return value.delta ~= 13, "forbidden"
			end,
		})
		local client = Network.createFRPClient({ protocol = schema })
		local state = server:initialInboundState()
		local bad = client:prepareIntent("move", { delta = "bad" }, 1)
		h:falsy(bad.ok)

		local denied = client:prepareIntent("move", { delta = 13 }, 1)
		h:truthy(denied.ok)
		h:truthy(client:commitIntent(denied.packet).ok)
		state = server:reduceInbound(state, {
			clientId = 1, packet = denied.packet, receivedAt = 0, context = { clientId = 1 },
		})
		h:equal(state.decision.code, "unauthorized")
		h:truthy(state.decision.consumed)
		h:equal(state.decision.lastIntentSequence, 1)

		local nextIntent = client:prepareIntent("move", { delta = 2 }, 2)
		h:truthy(nextIntent.ok)
		h:truthy(client:commitIntent(nextIntent.packet).ok)
		local malformed = { kind = "intent", protocolVersion = 999 }
		local unchanged = server:reduceInbound(state, { clientId = 1, packet = malformed, receivedAt = 0.1 })
		h:equal(unchanged.decision.code, "protocol_mismatch")
		h:equal(unchanged.clients[1].lastIntentSequence, 1)
		state = server:reduceInbound(unchanged, {
			clientId = 1, packet = nextIntent.packet, receivedAt = 0.2, context = { clientId = 1 },
		})
		h:truthy(state.decision.ok)
		h:equal(state.decision.sequence, 2)

		local gapPacket = Network.createFRPClient({ protocol = schema }):prepareIntent("move", { delta = 1 }, 3).packet
		gapPacket.sequence = 4
		local gap = server:reduceInbound(state, { clientId = 1, packet = gapPacket, receivedAt = 0.3 })
		h:equal(gap.decision.code, "intent_sequence_gap")
		h:equal(gap.clients[1].lastIntentSequence, 2)
		server:dispose()
		client:dispose()
	end)

	h:test("protocol rejects yielding validators and over-budget packets without advancing", function()
		local yielding = protocol({
			id = "tests.yielding",
			moveValidate = function()
				coroutine.yield()
				return true
			end,
		})
		local client = Network.createFRPClient({ protocol = yielding })
		local result = client:prepareIntent("move", { delta = 1 }, 1)
		h:falsy(result.ok)
		h:equal(result.code, "payload_rejected")
		h:equal(client:getStatus().intentSequence, 0)
		client:dispose()

		local bounded = protocol({ id = "tests.bounded", maxBytes = 128 })
		local boundedClient = Network.createFRPClient({ protocol = bounded })
		local oversized = boundedClient:prepareIntent("move", { delta = 1, text = string.rep("x", 256) }, 1)
		h:falsy(oversized.ok)
		h:equal(oversized.code, "payload_rejected")
		h:equal(boundedClient:getStatus().pendingCount, 0)
		boundedClient:dispose()
	end)

	h:test("protocol metadata and invalid arrival time cannot mutate inbound authority", function()
		local schema = protocol({ id = "tests.defensive" })
		local publicMessage = schema:getMessage("move")
		publicMessage.direction = Network.SERVER_TO_CLIENT
		local listed = schema:getMessages()
		listed[1].key = "tampered"
		local client = Network.createFRPClient({ protocol = schema })
		local prepared = client:prepareIntent("move", { delta = 1 }, 1)
		h:truthy(prepared.ok)

		local server = Network.createFRPServer({ protocol = schema })
		local initial = server:initialInboundState()
		local invalid = server:reduceInbound(initial, { clientId = 1, packet = prepared.packet })
		h:equal(invalid.decision.code, "invalid_time")
		h:truthy(invalid.clients == initial.clients)
		local accepted = server:reduceInbound(invalid, {
			clientId = 1,
			packet = prepared.packet,
			receivedAt = 0,
		})
		h:truthy(accepted.decision.ok)
		h:equal(accepted.decision.sequence, 1)
		server:dispose()
		client:dispose()
	end)

	h:test("failed outbound snapshots leave the peer epoch and replay buffer unchanged", function()
		local schema = protocol({ id = "atomic", maxBytes = 320, replayCapacity = 4 })
		local oversizedPayload = { value = 2, text = string.rep("x", 192) }
		local server = Network.createFRPServer({
			protocol = schema,
			buildSnapshot = function()
				return { messageType = "state", payload = oversizedPayload, serverTick = 2 }
			end,
		})
		local first = server:encodeEvent(7, "state", { value = 1 }, 1, 0)
		h:truthy(first.ok)
		local before = server:getOutboundStatus(7)

		local direct = server:encodeEvent(7, "state", oversizedPayload, 2, 0, "snapshot")
		h:falsy(direct.ok)
		h:equal(direct.code, "packet_budget")
		h:deepEqual(server:getOutboundStatus(7), before)

		local recovered = server:recover(7, { epoch = 99, expectedSequence = 1 })
		h:falsy(recovered.ok)
		h:equal(recovered.code, "snapshot_failed")
		h:deepEqual(server:getOutboundStatus(7), before)
		server:dispose()
	end)

	h:test("RemoteEvent queue and Player lifecycle are bounded and disposable", function()
		local f = makeFixture({ initialResync = false, noSnapshot = true, maxPendingPerFrame = 2 })
		local violations = {}
		local disconnects = {}
		local stop = f.server:violations():subscribe(function(value)
			violations[#violations + 1] = value
		end)
		local stopDisconnects = f.server:disconnects():subscribe(function(value)
			disconnects[#disconnects + 1] = value
		end)
		for sequence = 1, 3 do
			f.hub.serverSignal:Fire(f.players[1], {
				kind = "intent",
				protocolVersion = Network.EVENT_PROTOCOL_VERSION,
				protocolId = "tests.multiplayer.v1",
				schemaVersion = 3,
				sequence = sequence,
				clientTick = sequence,
				messageType = "move",
				payload = { delta = sequence },
			})
		end
		f:flushServer()
		h:equal(f.server:getPeerStatus(101).lastIntentSequence, 2)
		f.playerRemoving:Fire(f.players[1])
		f:flushServer()
		h:falsy(f.server:getPeerStatus(101).connected)
		h:equal(f.server:getPeerStatus(101).replayCount, 0)
		h:equal(#disconnects, 1)
		h:truthy(f.server:removePeer(f.players[2]).ok)
		f:flushServer()
		h:equal(#disconnects, 2)
		h:equal(f.server:getPeerStatus(202).generation, 1)
		local before = #violations
		f.server:dispose()
		f.server:dispose()
		local disposedSend = f.server:send(f.players[1], "state", { value = 1 }, 1)
		h:falsy(disposedSend.ok)
		h:equal(disposedSend.code, "disposed")
		f.hub.serverSignal:Fire(f.players[1], {})
		f:flushServer()
		h:equal(#violations, before)
		stop()
		stopDisconnects()
		for _, entry in ipairs(f.clients) do
			entry.channel:dispose()
			h:equal(entry.channel:send("move", { delta = 1 }, 1).code, "disposed")
			entry.driver:dispose()
			entry.host:dispose()
		end
		f.serverDriver:dispose()
		f.serverHost:dispose()
	end)
end
