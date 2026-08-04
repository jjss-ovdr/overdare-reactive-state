--!nonstrict

local FRP = require("../src")
local Suite = require("./FRPSuite")

local profile, mode = ...
local environment = getfenv()
local collectGarbage = environment.collectgarbage

Suite.run(FRP, {
	version = FRP.VERSION,
	profile = profile or "standard",
	mode = mode or "Luau CLI (mode not supplied)",
	now = os.clock,
	collectGarbage = if type(collectGarbage) == "function" then function()
		collectGarbage("collect")
	end else nil,
})
