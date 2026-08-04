--!nonstrict

local State = require("../src")
local Network = require("../src/Network")
local Suite = require("./MultiplayerSuite")

local profile, mode = ...
local environment = getfenv()
local collectGarbage = environment.collectgarbage

Suite.run(Network, {
	version = State.VERSION,
	profile = profile or "standard",
	mode = mode or "Luau CLI (mode not supplied)",
	now = os.clock,
	collectGarbage = if type(collectGarbage) == "function" then function()
		collectGarbage("collect")
	end else nil,
})
