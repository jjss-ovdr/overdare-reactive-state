--!nonstrict

local Runtime = require("../src/Core/Runtime")
local Bridge = require("../src/Bridge")
local Network = require("../src/Network")
local Overdare = require("../src/Overdare")
local AttributePreset = require("../src/AttributePreset")

local function fakeSignal()
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
	function signal:Fire(...)
		for _, entry in ipairs(self.listeners) do
			if entry.connected then
				entry.callback(...)
			end
		end
	end
	return signal
end

return function(h)
	h:test("Bridge connects two real isolated Runtimes post-commit", function()
		local sourceRuntime = Runtime.new({ label = "source" })
		local targetRuntime = Runtime.new({ label = "target" })
		local source = sourceRuntime:atom(2)
		local target = targetRuntime:atom(0)
		local scope = Bridge.connect({
			sourceRuntime = sourceRuntime,
			targetRuntime = targetRuntime,
			source = source,
			target = target,
			direction = "one-way",
			sourceOfTruth = sourceRuntime,
			map = function(value)
				return value * 10
			end,
		})
		h:equal(target:get(), 20)
		sourceRuntime:transaction(function()
			source:set(3)
			source:set(4)
		end)
		h:equal(target:get(), 40)
		h:equal(target:getRevision(), 2)
		scope:dispose()
		source:set(5)
		h:equal(target:get(), 40)
	end)

	h:test("Network applies authoritative state and pure intent schema with real Runtimes", function()
		local serverRuntime = Runtime.new()
		local clientRuntime = Runtime.new()
		local serverHealth = serverRuntime:atom(100)
		local clientHealth = clientRuntime:atom(0)
		local schema = Network.defineSchema({
			{
				key = "health",
				direction = Network.SERVER_TO_CLIENT,
				source = serverHealth,
				target = clientHealth,
				validate = function(value)
					return type(value) == "number" and value >= 0
				end,
			},
			{
				key = "damage",
				direction = Network.CLIENT_INTENT,
				validate = function(value)
					return type(value) == "number" and value >= 0 and value <= 20
				end,
			},
		}, { schemaVersion = 1 })
		local server = Network.createServer({
			schema = schema,
			runtime = serverRuntime,
			onIntent = function(_clientId, actions)
				for _, action in ipairs(actions) do
					if action.key == "damage" then
						serverHealth:update(function(value)
							return value - action.value
						end)
					end
				end
			end,
		})
		local client = Network.createClient({ schema = schema, runtime = clientRuntime })
		h:truthy(client:receive(server:createSnapshot("player", 1).payload).ok)
		h:equal(clientHealth:get(), 100)
		local intent = client:createIntent({ damage = 7 }, 2)
		h:truthy(intent.ok)
		h:truthy(server:acceptIntent("player", intent.payload).ok)
		h:equal(serverHealth:get(), 93)
		local patch = server:createPatch("player", 2)
		h:truthy(client:receive(patch.payload).ok)
		h:equal(clientHealth:get(), 93)
		h:equal(client:getStatus().pendingCount, 0)
	end)

	h:test("Overdare fixed adapter drives real Runtime steps without a hidden loop", function()
		local runtime = Runtime.new({ deterministic = true, history = true })
		local ticks = runtime:atom(0)
		local signal = fakeSignal()
		local attachment = Overdare.attach(runtime, {
			signal = signal,
			phase = "Heartbeat",
			fixedDelta = 0.1,
			callback = function()
				ticks:update(function(value)
					return value + 1
				end)
			end,
		})
		signal:Fire(0.25)
		h:equal(runtime:getTick(), 2)
		h:equal(ticks:get(), 2)
		attachment:dispose()
	end)

	h:test("AttributePreset writes real Atoms in one Runtime transaction", function()
		local runtime = Runtime.new()
		local speed = runtime:atom(0)
		local mode = runtime:atom("none")
		local preset = AttributePreset.define({
			Speed = { type = "number", min = 0, default = 16 },
			Mode = { type = "string", enum = { "walk", "run" }, required = true },
		})
		local scope = preset:apply(nil, runtime, {
			values = { Mode = "run" },
			targets = { Speed = speed, Mode = mode },
		})
		h:equal(speed:get(), 16)
		h:equal(mode:get(), "run")
		h:equal(speed:getRevision(), 1)
		h:equal(mode:getRevision(), 1)
		scope:dispose()
	end)
end
