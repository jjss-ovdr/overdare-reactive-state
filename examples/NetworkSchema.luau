--!nonstrict

-- Build this schema separately in the server and client environment. The
-- function accepts the Atom bindings that exist on that side; it does not
-- imply shared server/client memory.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Network = require(ReplicatedStorage.ReactiveState.Network)

return function(bindings)
	return Network.defineSchema({
		{
			key = "health",
			direction = Network.SERVER_TO_CLIENT,
			source = bindings.serverHealth,
			target = bindings.clientHealth,
			validate = function(value)
				return type(value) == "number" and value >= 0 and value <= 100
			end,
		},
		{
			key = "damage",
			direction = Network.CLIENT_INTENT,
			validate = function(value)
				return type(value) == "number" and value >= 0 and value <= 20
			end,
		},
	}, {
		schemaVersion = 1,
		limits = {
			maxFields = 16,
			maxDepth = 4,
			maxElements = 128,
			maxStringLength = 256,
		},
	})
end
