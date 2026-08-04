--!nonstrict

local FRP = require("../src")

local host = FRP.newHost()
local impulses, emitImpulse = host:source({ label = "velocity.impulse" })

local velocity = FRP.accumReactive(0, impulses:map(function(delta)
	return function(previous)
		return previous + delta
	end
end))

local position = FRP.lift2(function(time, currentVelocity)
	return time * currentVelocity
end, FRP.time(host), FRP.stepperBehavior(0, velocity:changes()))

host:frame(1, function()
	emitImpulse(2)
	emitImpulse(3)
end)

assert(velocity:at(1) == 0)
assert(velocity:current() == 5)

host:advanceTo(2)
assert(velocity:at(2) == 5)
assert(position:at(2) == 10)

host:dispose()
