--!nonstrict

local ReactiveState = require("../src")
local Guides = require("../src/Guides")

return function(h)
	h:test("installed guide is discoverable from the package root", function()
		h:equal(ReactiveState.START_HERE, Guides.START_HERE)
		h:equal(ReactiveState.Guides.GUIDE_VERSION, 1)
		h:equal(
			ReactiveState.Guides.routes.serverAuthoritativeMultiplayer.entryPoint,
			"require(packageRoot.Network).defineFRPProtocol + require(packageRoot.Overdare).attachFRP*Remote"
		)
	end)

	h:test("server-authoritative guide names the canonical public boundary", function()
		local guide = Guides.serverAuthoritativeMultiplayer
		h:truthy(string.find(guide.protocol, "defineFRPProtocol", 1, true))
		h:truthy(string.find(guide.serverTransport, "attachFRPServerRemote", 1, true))
		h:truthy(string.find(guide.clientTransport, "attachFRPClientRemote", 1, true))
		h:truthy(string.find(guide.serverInput, "intents", 1, true))
		h:truthy(string.find(guide.clientInput, "authority", 1, true))
		h:truthy(string.find(guide.initialSync, "initialResync", 1, true))
	end)

	h:test("guide descriptors are immutable and side-effect-free data", function()
		h:truthy(table.isfrozen(Guides))
		h:truthy(table.isfrozen(Guides.routes))
		h:truthy(table.isfrozen(Guides.serverAuthoritativeMultiplayer))
		h:truthy(table.isfrozen(Guides.serverAuthoritativeMultiplayer.steps))
		h:truthy(table.isfrozen(Guides.serverAuthoritativeMultiplayer.invariants))
		h:throws(function()
			Guides.START_HERE = "replace"
		end)
	end)
end
