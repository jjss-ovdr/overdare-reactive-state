--!nonstrict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local State = require(ReplicatedStorage:WaitForChild("ReactiveState"))
local Overdare = require(ReplicatedStorage.ReactiveState.Overdare)

local runtime = State.create({
	label = "Simulation",
	deterministic = true,
	history = { strategy = "snapshot", capacity = 180 },
	effects = "confirmed",
	commandNamespace = "simulation",
})

local position = runtime:atom(0, { label = "player.position" })
local velocity = runtime:atom(4, { label = "player.velocity" })

local attachment = Overdare.attach(runtime, {
	phase = "Heartbeat",
	fixedDelta = 1 / 60,
	maxSubsteps = 8,
	overflow = "drop",
	callback = function(ctx, delta)
		position:update(function(value)
			return value + velocity:get() * delta
		end)
		if position:get() >= 10 then
			ctx:emit("ReachedTarget", { tick = ctx.tick }, { policy = "confirmed" })
		end
	end,
})

return {
	runtime = runtime,
	position = position:asReadonly(),
	attachment = attachment,
}
