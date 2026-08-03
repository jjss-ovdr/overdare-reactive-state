--!nonstrict

local State = require("../src")
local Runtime = require("../src/Core/Runtime")
local Network = require("../src/Network")
local Suite = require("./Suite")

local profile, mode = ...
local environment = getfenv()
local collectGarbage = environment.collectgarbage

Suite.run({
	version = State.VERSION,
	Runtime = Runtime,
	Network = Network,
}, {
	profile = profile or "standard",
	mode = mode or "Luau CLI (mode not supplied)",
	environment = "independent Luau CLI",
	now = os.clock,
	memoryKB = gcinfo,
	collectGarbage = if type(collectGarbage) == "function" then function()
		collectGarbage("collect")
	end else nil,
})
