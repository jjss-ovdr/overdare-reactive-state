--!nonstrict

local Network = require("../src/Network")

local function fakeRuntime()
	local runtime = { transactions = 0, lastMetadata = nil }
	function runtime:transaction(callback, metadata)
		self.transactions += 1
		self.lastMetadata = metadata
		return callback()
	end
	function runtime:getTick()
		return nil
	end
	return runtime
end

local function fakeAtom(initial)
	local atom = { value = initial }
	function atom:get()
		return self.value
	end
	function atom:set(value)
		self.value = value
	end
	return atom
end

local function fixture()
	local serverRuntime = fakeRuntime()
	local clientRuntime = fakeRuntime()
	local serverHealth = fakeAtom(100)
	local clientHealth = fakeAtom(0)
	local input = fakeAtom(0)
	local predicted = fakeAtom(0)
	local accepted = {}
	local schema = Network.defineSchema({
		{
			key = "move",
			direction = Network.CLIENT_INTENT,
			source = input,
			target = predicted,
			predict = true,
			validate = function(value)
				return type(value) == "number", "move must be a number"
			end,
		},
		{
			key = "health",
			direction = Network.SERVER_TO_CLIENT,
			source = serverHealth,
			target = clientHealth,
			validate = function(value)
				return type(value) == "number", "health must be a number"
			end,
		},
	}, { schemaVersion = 7 })
	local server = Network.createServer({
		schema = schema,
		runtime = serverRuntime,
		onIntent = function(_clientId, actions)
			for _, action in ipairs(actions) do
				table.insert(accepted, action)
			end
		end,
	})
	local client = Network.createClient({ schema = schema, runtime = clientRuntime })
	return {
		server = server,
		client = client,
		serverRuntime = serverRuntime,
		clientRuntime = clientRuntime,
		serverHealth = serverHealth,
		clientHealth = clientHealth,
		predicted = predicted,
		accepted = accepted,
	}
end

return function(h)
	h:test("network snapshot and patch use canonical metadata and one client transaction", function()
		local f = fixture()
		local snapshot = f.server:createSnapshot("a", 10)
		h:truthy(snapshot.ok)
		h:equal(snapshot.payload.protocolVersion, Network.PROTOCOL_VERSION)
		h:equal(snapshot.payload.schemaVersion, 7)
		h:equal(snapshot.payload.baseRevision, 0)
		h:equal(snapshot.payload.revision, 1)
		h:equal(snapshot.payload.tick, 10)
		h:equal(snapshot.payload.changes[1].key, "health")

		local received = f.client:receive(snapshot.payload)
		h:truthy(received.ok)
		h:equal(f.clientHealth:get(), 100)
		h:equal(f.clientRuntime.transactions, 1)

		f.serverHealth:set(75)
		local patch = f.server:createPatch("a", 11)
		h:truthy(patch.ok)
		h:equal(patch.payload.baseRevision, 1)
		h:equal(patch.payload.revision, 2)
		h:equal(#patch.payload.changes, 1)
		h:truthy(f.client:receive(patch.payload).ok)
		h:equal(f.clientHealth:get(), 75)
		h:equal(f.clientRuntime.transactions, 2)
	end)

	h:test("network rejects patch gaps without mutating targets and recovers with the expected patch", function()
		local f = fixture()
		local snapshot = f.server:createSnapshot("a", 1).payload
		h:truthy(f.client:receive(snapshot).ok)
		f.serverHealth:set(90)
		local patch = f.server:createPatch("a", 2).payload
		local gap = {}
		for key, value in pairs(patch) do
			gap[key] = value
		end
		gap.sequence = patch.sequence + 1
		local rejected = f.client:receive(gap)
		h:falsy(rejected.ok)
		h:truthy(rejected.requestResync)
		h:equal(rejected.code, "sequence_gap")
		h:equal(f.clientHealth:get(), 100)
		h:truthy(f.client:receive(patch).ok)
		h:equal(f.clientHealth:get(), 90)
	end)

	h:test("network rejects a tampered state hash without advancing the baseline", function()
		local f = fixture()
		h:truthy(f.client:receive(f.server:createSnapshot("a", 1).payload).ok)
		f.serverHealth:set(50)
		local patch = f.server:createPatch("a", 2).payload
		local tampered = {}
		for key, value in pairs(patch) do
			tampered[key] = value
		end
		tampered.stateHash = "0000000000000000"
		local rejected = f.client:receive(tampered)
		h:falsy(rejected.ok)
		h:equal(rejected.code, "state_hash_mismatch")
		h:truthy(rejected.requestResync)
		h:equal(f.clientHealth:get(), 100)
		h:truthy(f.client:receive(patch).ok)
		h:equal(f.clientHealth:get(), 50)
	end)

	h:test("client values remain intents, are validated, predicted, acknowledged, and replay-safe", function()
		local f = fixture()
		h:truthy(f.client:receive(f.server:createSnapshot("a", 1).payload).ok)
		local intent = f.client:createIntent({ move = 3 }, 2)
		h:truthy(intent.ok)
		h:equal(f.predicted:get(), 3)
		h:equal(f.client:getStatus().pendingCount, 1)

		local accepted = f.server:acceptIntent("a", intent.payload)
		h:truthy(accepted.ok)
		h:equal(#f.accepted, 1)
		h:equal(f.accepted[1].key, "move")
		h:equal(f.accepted[1].value, 3)

		local ack = f.server:createPatch("a", 2).payload
		h:equal(ack.ackSequence, intent.sequence)
		h:truthy(f.client:receive(ack).ok)
		h:equal(f.client:getStatus().pendingCount, 0)

		local duplicate = f.server:acceptIntent("a", intent.payload)
		h:falsy(duplicate.ok)
		h:equal(duplicate.code, "duplicate_intent")
		local wrongDirection = {
			kind = "intent",
			protocolVersion = Network.PROTOCOL_VERSION,
			schemaVersion = 7,
			sequence = 2,
			clientTick = 3,
			changes = { { key = "health", op = "set", value = 1 } },
		}
		local rejected = f.server:acceptIntent("a", wrongDirection)
		h:falsy(rejected.ok)
		h:equal(rejected.code, "intent_rejected")
		h:equal(f.serverHealth:get(), 100)
	end)
end
