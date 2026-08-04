--!nonstrict

-- Engine-neutral multiplayer protocol benchmarks. Setup and cleanup are kept
-- outside the timed region; every sample still runs correctness assertions.

local Suite = {}

local PROFILES = {
	smoke = {
		warmup = 0,
		samples = 2,
		peerOperations = 640,
		replayCapacity = 16,
		replayRounds = 4,
		rejectedOperations = 640,
		payloadBytes = 32,
	},
	standard = {
		warmup = 1,
		samples = 5,
		peerOperations = 12000,
		replayCapacity = 64,
		replayRounds = 100,
		rejectedOperations = 12000,
		payloadBytes = 96,
	},
}

local function expect(condition, label)
	if not condition then
		error(label, 3)
	end
end

local function expectOk(result, label)
	if not result.ok then
		error(string.format("%s: %s (%s)", label, tostring(result.message), tostring(result.code)), 3)
	end
	return result
end

local function sorted(values)
	local copy = {}
	for index, value in ipairs(values) do
		copy[index] = value
	end
	table.sort(copy)
	return copy
end

local function percentile(values, fraction)
	local copy = sorted(values)
	return copy[math.max(1, math.ceil(#copy * fraction))]
end

local function makeProtocol(Network, config, suffix)
	return Network.defineFRPProtocol({
		move = {
			direction = Network.CLIENT_INTENT,
			validate = function(value)
				return type(value) == "table"
					and type(value.delta) == "number"
					and type(value.padding) == "string"
			end,
		},
		state = {
			direction = Network.SERVER_TO_CLIENT,
			validate = function(value)
				return type(value) == "table"
					and type(value.value) == "number"
					and type(value.padding) == "string"
			end,
		},
	}, {
		id = "bench.multiplayer." .. suffix,
		schemaVersion = 1,
		rateLimit = false,
		replayCapacity = config.replayCapacity,
		pendingCapacity = 128,
	})
end

local function expectedPeerChecksum(peers, rounds)
	return peers * rounds * (rounds + 1) / 2
		+ rounds * peers * (peers + 1) / 2
end

local function caseIntentIngress(Network, config, peers)
	local rounds = math.max(1, math.floor(config.peerOperations / peers))
	local operations = rounds * peers
	return {
		id = string.format("intent/validated_ingress_%02dp", peers),
		operations = operations,
		setup = function()
			local protocol = makeProtocol(Network, config, "intent." .. tostring(peers))
			local server = Network.createFRPServer({ protocol = protocol, rateLimit = false })
			local clients = {}
			for peer = 1, peers do
				clients[peer] = Network.createFRPClient({ protocol = protocol })
			end
			return {
				server = server,
				clients = clients,
				state = server:initialInboundState(),
				padding = string.rep("p", config.payloadBytes),
				accepted = 0,
				checksum = 0,
			}
		end,
		run = function(fixture)
			local state = fixture.state
			for round = 1, rounds do
				for peer = 1, peers do
					local client = fixture.clients[peer]
					local prepared = expectOk(client:prepareIntent("move", {
						delta = round + peer,
						padding = fixture.padding,
					}, round), "prepare intent")
					expectOk(client:commitIntent(prepared.packet), "commit intent")
					state = fixture.server:reduceInbound(state, {
						clientId = peer,
						packet = prepared.packet,
						receivedAt = round,
					})
					expect(state.decision.ok and state.decision.kind == "intent", "intent was not accepted")
					expectOk(client:acknowledge(state.decision.sequence), "acknowledge intent")
					fixture.accepted += 1
					fixture.checksum += state.decision.payload.delta
				end
			end
			fixture.state = state
		end,
		verify = function(fixture)
			expect(fixture.accepted == operations, "accepted intent count mismatch")
			expect(fixture.checksum == expectedPeerChecksum(peers, rounds), "intent checksum mismatch")
			for peer = 1, peers do
				local status = fixture.clients[peer]:getStatus()
				expect(status.intentSequence == rounds and status.ackSequence == rounds, "client intent status mismatch")
				expect(status.pendingCount == 0, "acknowledged client retained pending intents")
				expect(fixture.server:getInboundStatus(fixture.state, peer).lastIntentSequence == rounds,
					"server intent sequence mismatch")
			end
		end,
		cleanup = function(fixture)
			for _, client in ipairs(fixture.clients) do client:dispose() end
			fixture.server:dispose()
		end,
	}
end

local function caseAuthorityFanout(Network, config, peers)
	local rounds = math.max(1, math.floor(config.peerOperations / peers))
	local operations = rounds * peers
	return {
		id = string.format("authority/per_peer_stream_%02dp", peers),
		operations = operations,
		setup = function()
			local protocol = makeProtocol(Network, config, "authority." .. tostring(peers))
			local server = Network.createFRPServer({ protocol = protocol, rateLimit = false })
			local clients = {}
			local states = {}
			for peer = 1, peers do
				clients[peer] = Network.createFRPClient({ protocol = protocol })
				states[peer] = clients[peer]:initialInboundState()
			end
			return {
				server = server,
				clients = clients,
				states = states,
				padding = string.rep("a", config.payloadBytes),
				accepted = 0,
				checksum = 0,
			}
		end,
		run = function(fixture)
			for round = 1, rounds do
				for peer = 1, peers do
					local encoded = expectOk(fixture.server:encodeEvent(peer, "state", {
						value = round + peer,
						padding = fixture.padding,
					}, round, 0), "encode authority")
					local state = fixture.clients[peer]:reduceInbound(fixture.states[peer], {
						packet = encoded.packet,
						receivedAt = round,
					})
					expect(state.decision.ok and state.decision.kind == "event", "authority event was not accepted")
					fixture.states[peer] = state
					fixture.accepted += 1
					fixture.checksum += state.decision.payload.value
				end
			end
		end,
		verify = function(fixture)
			expect(fixture.accepted == operations, "accepted authority count mismatch")
			expect(fixture.checksum == expectedPeerChecksum(peers, rounds), "authority checksum mismatch")
			for peer = 1, peers do
				expect(fixture.states[peer].sequence == rounds, "client authority sequence mismatch")
				local status = fixture.server:getOutboundStatus(peer)
				expect(status.sequence == rounds, "server authority sequence mismatch")
				expect(status.replayCount == math.min(rounds, config.replayCapacity), "replay capacity mismatch")
			end
		end,
		cleanup = function(fixture)
			for _, client in ipairs(fixture.clients) do client:dispose() end
			fixture.server:dispose()
		end,
	}
end

local function caseReplay(Network, config)
	local operations = config.replayRounds * config.replayCapacity * 2
	return {
		id = string.format("recovery/replay_%03d", config.replayCapacity),
		operations = operations,
		setup = function()
			local protocol = makeProtocol(Network, config, "replay")
			return {
				server = Network.createFRPServer({ protocol = protocol, rateLimit = false }),
				client = Network.createFRPClient({ protocol = protocol }),
				padding = string.rep("r", config.payloadBytes),
				recovered = 0,
				finalSequence = 0,
			}
		end,
		run = function(fixture)
			for _ = 1, config.replayRounds do
				for _ = 1, config.replayCapacity do
					local tick = fixture.server:getOutboundStatus(1).sequence + 1
					expectOk(fixture.server:encodeEvent(1, "state", {
						value = tick,
						padding = fixture.padding,
					}, tick, 0), "encode replay source")
				end
				local status = fixture.server:getOutboundStatus(1)
				local expectedSequence = status.sequence - config.replayCapacity + 1
				local recovered = expectOk(fixture.server:recover(1, {
					epoch = status.epoch,
					expectedSequence = expectedSequence,
				}), "recover replay range")
				expect(recovered.mode == "replay" and #recovered.packets == config.replayCapacity,
					"replay did not return the retained contiguous range")
				local inbound = {
					epoch = status.epoch,
					sequence = expectedSequence - 1,
					ackSequence = 0,
					serverTick = expectedSequence - 1,
					decision = nil,
				}
				for _, packet in ipairs(recovered.packets) do
					inbound = fixture.client:reduceInbound(inbound, { packet = packet, receivedAt = packet.serverTick })
					expect(inbound.decision.ok, "client rejected a replayed authority packet")
					fixture.recovered += 1
				end
				fixture.finalSequence = inbound.sequence
			end
		end,
		verify = function(fixture)
			expect(fixture.recovered == config.replayRounds * config.replayCapacity, "replayed packet count mismatch")
			expect(fixture.finalSequence == config.replayRounds * config.replayCapacity, "replay final sequence mismatch")
		end,
		cleanup = function(fixture)
			fixture.client:dispose()
			fixture.server:dispose()
		end,
	}
end

local function caseRejectUntrusted(Network, config)
	return {
		id = "security/reject_untrusted",
		operations = config.rejectedOperations,
		setup = function()
			local protocol = makeProtocol(Network, config, "reject")
			local server = Network.createFRPServer({ protocol = protocol, rateLimit = false })
			return {
				server = server,
				state = server:initialInboundState(),
				packet = {
					kind = "intent",
					protocolVersion = Network.EVENT_PROTOCOL_VERSION,
					protocolId = protocol.id,
					schemaVersion = protocol.schemaVersion,
					sequence = 1,
					clientTick = 1,
					messageType = "move",
					payload = { delta = 1, padding = function() end },
				},
				rejected = 0,
			}
		end,
		run = function(fixture)
			local state = fixture.state
			for index = 1, config.rejectedOperations do
				state = fixture.server:reduceInbound(state, {
					clientId = 1,
					packet = fixture.packet,
					receivedAt = index,
				})
				expect(not state.decision.ok and state.decision.code == "malformed_packet",
					"unsafe packet was not rejected at the wire boundary")
				fixture.rejected += 1
			end
			fixture.state = state
		end,
		verify = function(fixture)
			expect(fixture.rejected == config.rejectedOperations, "untrusted reject count mismatch")
			expect(fixture.server:getInboundStatus(fixture.state, 1).lastIntentSequence == 0,
				"rejected packet advanced intent authority")
		end,
		cleanup = function(fixture) fixture.server:dispose() end,
	}
end

function Suite.run(Network, options)
	options = options or {}
	local profileName = options.profile or "standard"
	local base = PROFILES[profileName]
	if base == nil then error("unknown multiplayer benchmark profile '" .. tostring(profileName) .. "'", 2) end
	local config = {}
	for key, value in pairs(base) do config[key] = value end
	local now = options.now or os.clock
	local collect = options.collectGarbage
	local cases = {}
	for _, peers in ipairs({ 2, 8, 32 }) do
		cases[#cases + 1] = caseIntentIngress(Network, config, peers)
	end
	for _, peers in ipairs({ 2, 8, 32 }) do
		cases[#cases + 1] = caseAuthorityFanout(Network, config, peers)
	end
	cases[#cases + 1] = caseReplay(Network, config)
	cases[#cases + 1] = caseRejectUntrusted(Network, config)

	print(string.format(
		"Multiplayer FRP protocol benchmark | version=%s | profile=%s | mode=%s | payload=%dB",
		tostring(options.version or "unknown"), profileName, tostring(options.mode or "unknown"), config.payloadBytes
	))
	for _, benchmark in ipairs(cases) do
		local durations = {}
		for sample = 1, config.warmup + config.samples do
			if collect ~= nil then collect() end
			local fixture = benchmark.setup()
			local started = now()
			benchmark.run(fixture)
			local elapsed = now() - started
			benchmark.verify(fixture)
			if benchmark.cleanup ~= nil then benchmark.cleanup(fixture) end
			if sample > config.warmup then durations[#durations + 1] = elapsed end
		end
		local p50 = percentile(durations, 0.50)
		local p95 = percentile(durations, 0.95)
		local rate = if p50 > 0 then benchmark.operations / p50 else math.huge
		print(string.format("BENCH %-38s p50=%8.3fms p95=%8.3fms rate=%10.2f/s ops=%d",
			benchmark.id, p50 * 1000, p95 * 1000, rate, benchmark.operations))
	end
	print(string.format("PASS %d multiplayer FRP protocol benchmark workloads", #cases))
end

return Suite
