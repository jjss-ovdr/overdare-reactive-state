--!strict

-- This runs against the generated package, not src. Build it first with:
-- node tools/build-studio-package.mjs

local Network: any = require("../dist/ReactiveState/Network")
local State = require("../dist/ReactiveState")
local AttributePreset = require("../dist/ReactiveState/AttributePreset")
local BehaviorTree = require("../dist/ReactiveState/BehaviorTree")
local Bridge = require("../dist/ReactiveState/Bridge")
local Compat = require("../dist/ReactiveState/Compat")
local Debug = require("../dist/ReactiveState/Debug")
local Guides = require("../dist/ReactiveState/Guides")
local Overdare = require("../dist/ReactiveState/Overdare")
local Types = require("../dist/ReactiveState/Types")

assert(State.VERSION == "0.2.0-rc.1", "packaged VERSION mismatch")
assert(State.API_VERSION == 2, "packaged API_VERSION mismatch")
assert(State.SEMANTICS_VERSION == 1, "packaged FRP semantics mismatch")
assert(Network.PROTOCOL_VERSION == 1, "packaged Network.PROTOCOL_VERSION mismatch")
assert(Network.EVENT_PROTOCOL_VERSION == 1, "packaged Network.EVENT_PROTOCOL_VERSION mismatch")
assert(type(AttributePreset) == "table", "AttributePreset did not load")
assert(type(BehaviorTree) == "table", "BehaviorTree did not load")
assert(type(Bridge) == "table", "Bridge did not load")
assert(type(Compat) == "table", "Compat did not load")
assert(type(Debug) == "table", "Debug did not load")
assert(type(Guides) == "table", "Guides did not load")
assert(type(Overdare) == "table", "Overdare did not load")
assert(type(Types) == "table", "Types did not load")
assert(type(State.createCapital) == "function", "createCapital missing from package root")
assert(State.Guides.GUIDE_VERSION == 1, "root Guides export missing")
assert(State.START_HERE == Guides.START_HERE, "packaged START_HERE mismatch")
assert(
	string.find(Guides.serverAuthoritativeMultiplayer.protocol, "defineFRPProtocol", 1, true) ~= nil,
	"packaged server-authoritative guide does not name defineFRPProtocol"
)
assert(type(State.Compat) == "table", "root Compat export missing")
assert(State.Compat.KIND == Compat.KIND, "root Compat KIND mismatch")
assert(State.Compat.EVENT_KIND == Compat.EVENT_KIND, "root Compat EVENT_KIND mismatch")

local runtime = State.create()
local count = runtime:atom(1, { label = "packageSmoke.count" })
local doubled = runtime:computed(function()
	return count:get() * 2
end, { label = "packageSmoke.doubled" })

local observed = 0
local stop = runtime:watch(doubled, function(value)
	observed = value
end, { fireImmediately = true })

assert(observed == 2, "packaged Runtime initial watch failed")
count:set(5)
assert(observed == 10, "packaged Runtime update failed")

stop()
runtime:dispose()

local host = State.newHost()
local changes, fire = host:source()
local held = State.stepper(0, changes)
fire(1, 0)
assert(held:at(0) == 0, "FRP strict-before boundary failed")
assert(held:current() == 1, "FRP post-frame current failed")
host:dispose()

host = State.newHost()
local capturedChanges, captureFire = host:source({
	capture = State.Immutable.serializable(),
})
local input = { nested = { score = 7 } }
captureFire(input, 0)
input.nested.score = 99
local capturedOccurrence = capturedChanges:occurrences()[1]
assert(table.isfrozen(capturedOccurrence), "FRP occurrence envelope is mutable")
assert(table.isfrozen(capturedOccurrence.value), "FRP captured payload root is mutable")
assert(table.isfrozen(capturedOccurrence.value.nested), "FRP captured payload child is mutable")
assert(capturedOccurrence.value.nested.score == 7, "FRP captured payload retained the input alias")
host:dispose()

local protocol = Network.defineFRPProtocol({
	move = {
		direction = Network.CLIENT_INTENT,
		validate = function(value)
			return type(value) == "table" and type(value.delta) == "number"
		end,
	},
	world = {
		direction = Network.SERVER_TO_CLIENT,
		validate = function(value)
			return type(value) == "table" and type(value.revision) == "number"
		end,
	},
}, { id = "package-smoke", rateLimit = false })
local eventServer = Network.createFRPServer({ protocol = protocol, rateLimit = false })
local eventClient = Network.createFRPClient({ protocol = protocol })
local prepared = eventClient:prepareIntent("move", { delta = 1 }, 1)
assert(prepared.ok and eventClient:commitIntent(prepared.packet).ok, "packaged FRP intent encode failed")
local inbound = eventServer:reduceInbound(eventServer:initialInboundState(), {
	clientId = 7,
	packet = prepared.packet,
	receivedAt = 0,
})
assert(inbound.decision.ok and inbound.decision.sequence == 1, "packaged FRP intent reduce failed")
local authority = eventServer:encodeEvent(7, "world", { revision = 1 }, 1, 1)
assert(authority.ok, "packaged FRP authority encode failed")
local received = eventClient:reduceInbound(eventClient:initialInboundState(), {
	packet = authority.packet,
	receivedAt = 0,
})
assert(received.decision.ok and received.decision.payload.revision == 1, "packaged FRP authority reduce failed")
eventClient:dispose()
eventServer:dispose()

local capital = State.createCapital({ label = "packageSmoke.capital" })
local score = capital.Atom(0)
local seen = 0
local subscription = score:Subscribe(function(value)
	seen = value
end)
capital.Transaction(function()
	score:Set(3)
end)
assert(score:Get() == 3, "packaged Capital Atom Get/Set failed")
assert(seen == 3, "packaged Capital Subscribe failed")
local total = capital.Computed({ score }, function()
	return score:Get() * 2
end)
assert(total:Get() == 6, "packaged Capital Computed failed")
local bus = capital.Bus()
assert(bus._kind == Compat.EVENT_KIND, "Capital.Bus must remain a local bus")
subscription:Dispose()
capital:dispose()

print("PASS studio package smoke")
