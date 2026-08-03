--!nonstrict

-- Mount/copy the benchmarks folder into a Studio test place, keep the package
-- at ReplicatedStorage.ReactiveState, then run this as a server Script.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local packageRoot = ReplicatedStorage:WaitForChild("ReactiveState")

local State = require(packageRoot)
local Runtime = require(packageRoot.Core.Runtime)
local Network = require(packageRoot.Network)
local Suite = require(script.Parent.Suite)

Suite.run({
	version = State.VERSION,
	Runtime = Runtime,
	Network = Network,
}, {
	profile = "standard",
	mode = "OVERDARE Studio server VM",
	environment = "OVERDARE Studio",
	now = os.clock,
	memoryKB = gcinfo,
	output = print,
})
