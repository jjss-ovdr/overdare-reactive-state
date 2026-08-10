--!nonstrict

return function(h)
	h:test("createCapital exposes Atom Get/Set and Transaction", function()
		local FRP = require("../src")
		local capital = FRP.createCapital({ label = "capital.spec.basic" })

		local health = capital.Atom(100)
		h:equal(health:Get(), 100)

		local seen = {}
		local subscription = health:Subscribe(function(value)
			table.insert(seen, value)
		end)

		capital.Transaction(function()
			health:Set(90)
			health:Set(80)
		end)

		h:equal(health:Get(), 80)
		h:equal(#seen, 1)
		h:equal(seen[1], 80)

		subscription:Dispose()
		health:Set(70)
		h:equal(#seen, 1)

		capital:dispose()
	end)

	h:test("Capital.Computed accepts shim deps-array signature and auto-tracks", function()
		local FRP = require("../src")
		local capital = FRP.createCapital({ label = "capital.spec.computed" })
		local scoreA = capital.Atom(1)
		local scoreB = capital.Atom(2)

		local total = capital.Computed({ scoreA, scoreB }, function()
			return scoreA:Get() + scoreB:Get()
		end)
		h:equal(total:Get(), 3)

		local leader = capital.Computed(function()
			if scoreA:Get() >= scoreB:Get() then
				return "A"
			end
			return "B"
		end)
		h:equal(leader:Get(), "B")

		scoreA:Set(10)
		h:equal(total:Get(), 12)
		h:equal(leader:Get(), "A")

		capital:dispose()
	end)

	h:test("Capital.Event is a local bus and not FRP.Event", function()
		local FRP = require("../src")
		local capital = FRP.createCapital({ label = "capital.spec.event" })
		local bus = capital.Event()

		h:equal(bus._kind, FRP.Compat.EVENT_KIND)
		h:equal(type(FRP.Event), "table")
		h:equal(type(FRP.Event.map), "function")

		local values = {}
		local connection = bus:Connect(function(value)
			table.insert(values, value)
		end)
		bus:Fire("pickup")
		h:equal(#values, 1)
		h:equal(values[1], "pickup")
		connection:Dispose()
		bus:Fire("ignored")
		h:equal(#values, 1)

		capital:dispose()
	end)

	h:test("Compat.bind reuses an existing StateRuntime", function()
		local FRP = require("../src")
		local runtime = FRP.createStateRuntime({ label = "capital.spec.bind" })
		local capital = FRP.Compat.bind(runtime)
		local atom = capital.Atom(1)
		atom:Set(2)
		h:equal(atom:Get(), 2)
		capital:dispose()
		-- bind does not own the runtime
		h:equal(runtime._disposed == true, false)
		runtime:dispose()
	end)
end
