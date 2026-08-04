--!strict

-- This runs against the generated package, not src. Build it first with:
-- node tools/build-studio-package.mjs

local Network = require("../dist/ReactiveState/Network")
local State = require("../dist/ReactiveState")
local AttributePreset = require("../dist/ReactiveState/AttributePreset")
local BehaviorTree = require("../dist/ReactiveState/BehaviorTree")
local Bridge = require("../dist/ReactiveState/Bridge")
local Debug = require("../dist/ReactiveState/Debug")
local Overdare = require("../dist/ReactiveState/Overdare")
local Types = require("../dist/ReactiveState/Types")

assert(State.VERSION == "0.2.0-dev.1", "packaged VERSION mismatch")
assert(State.API_VERSION == 2, "packaged API_VERSION mismatch")
assert(State.SEMANTICS_VERSION == 1, "packaged FRP semantics mismatch")
assert(Network.PROTOCOL_VERSION == 1, "packaged Network.PROTOCOL_VERSION mismatch")
assert(type(AttributePreset) == "table", "AttributePreset did not load")
assert(type(BehaviorTree) == "table", "BehaviorTree did not load")
assert(type(Bridge) == "table", "Bridge did not load")
assert(type(Debug) == "table", "Debug did not load")
assert(type(Overdare) == "table", "Overdare did not load")
assert(type(Types) == "table", "Types did not load")

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

print("PASS studio package smoke")
