--!nonstrict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local State = require(ReplicatedStorage:WaitForChild("ReactiveState"))

local runtime = State.createStateRuntime({ label = "PlayerDomain" })
local healthAtom = runtime:atom(100, {
	label = "player.health",
	validate = function(value)
		return type(value) == "number" and value >= 0, "health must be non-negative"
	end,
})
local maxHealthAtom = runtime:atom(100, { label = "player.maxHealth" })

local healthText = runtime:computed(function()
	return string.format("%d / %d", healthAtom:get(), maxHealthAtom:get())
end, { label = "player.healthText" })

local function damage(amount: number)
	assert(amount >= 0, "damage amount must be non-negative")
	runtime:transaction(function()
		healthAtom:update(function(health)
			return math.max(0, health - amount)
		end)
	end, { cause = "damage" })
end

return {
	runtime = runtime,
	health = healthAtom:asReadonly(),
	maxHealth = maxHealthAtom:asReadonly(),
	healthText = healthText,
	damage = damage,
}
