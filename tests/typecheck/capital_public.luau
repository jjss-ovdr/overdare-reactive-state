--!strict

-- Compile-only fixture for the shim-compatible Capital surface. This keeps
-- the recommended Studio migration path from silently degrading to `any`.
local FRP = require("../../src")

local capital: FRP.CapitalFacade = FRP.createCapital({ label = "capital.typecheck" })
local score: FRP.CapitalAtom<number> = capital.Atom(0)
local membership: FRP.CapitalAtom<number> = capital.atom(0)

score:Set(1)
score:set(2)
score:Update(function(value)
	return value + 1
end)

local stop: FRP.CapitalConnection = score:Subscribe(function(value)
	local _: number = value
end)
stop:Disconnect()

local dependencies: { FRP.CapitalSource<any> } = { membership }
local label: FRP.CapitalComputed<string> = capital.Computed(dependencies, function()
	membership:Get()
	return "score=" .. tostring(score:Get())
end)
local _: string = label:Get()

local bus: FRP.CapitalBus = capital.Bus()
local busConnection: FRP.CapitalConnection = bus:Connect(function(value)
	local _: any = value
end)
bus:Fire("ready")
busConnection:Dispose()

local changeSet: FRP.ChangeSet? = capital.Transaction(function()
	score:Set(4)
end)

capital:dispose()

return changeSet
