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

	h:test("Capital.Computed honors explicit deps and auto-tracks getter reads", function()
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

		local trigger = capital.Atom(0)
		local externalValue = 1
		local triggered = capital.Computed({ trigger }, function()
			return externalValue
		end)
		h:equal(triggered:Get(), 1)
		externalValue = 2
		trigger:Set(1)
		h:equal(triggered:Get(), 2)

		capital:dispose()
	end)

	h:test("Capital.Computed uses a membership Atom for dynamic collections", function()
		local FRP = require("../src")
		local capital = FRP.createCapital({ label = "capital.spec.membership" })
		local membership = capital.Atom(0)
		local scores = {}
		local leader = capital.Computed({ membership }, function()
			local bestName = "Waiting"
			local bestScore = -math.huge
			for name, score in pairs(scores) do
				local value = score:Get()
				if value > bestScore then
					bestName = name
					bestScore = value
				end
			end
			return bestName
		end)

		h:equal(leader:Get(), "Waiting")
		scores.A = capital.Atom(1)
		membership:Update(function(value)
			return value + 1
		end)
		h:equal(leader:Get(), "A")

		scores.B = capital.Atom(5)
		membership:Update(function(value)
			return value + 1
		end)
		h:equal(leader:Get(), "B")

		scores.B:Dispose()
		scores.B = nil
		membership:Update(function(value)
			return value + 1
		end)
		h:equal(leader:Get(), "A")

		capital:dispose()
	end)

	h:test("Capital.Bus is ordered, isolates listeners, and supports Disconnect", function()
		local FRP = require("../src")
		local errors = {}
		local capital = FRP.createCapital({
			label = "capital.spec.bus",
			onError = function(detail)
				table.insert(errors, detail)
			end,
		})
		local bus = capital.Bus()

		h:equal(bus._kind, FRP.Compat.EVENT_KIND)
		h:equal(type(FRP.Event), "table")
		h:equal(type(FRP.Event.map), "function")

		local calls = {}
		local first = bus:Connect(function(value)
			table.insert(calls, "first:" .. value)
			error("expected listener failure")
		end)
		local second = bus:Connect(function(value)
			table.insert(calls, "second:" .. value)
		end)
		bus:Fire("pickup")
		h:deepEqual(calls, { "first:pickup", "second:pickup" })
		h:equal(#errors, 1)
		h:equal(errors[1].kind, "capital_bus_listener")

		first:Disconnect()
		second:disconnect()
		bus:Fire("ignored")
		h:equal(#calls, 2)

		local legacyBus = capital.Event()
		h:equal(legacyBus._kind, FRP.Compat.EVENT_KIND)
		legacyBus:Dispose()

		capital:dispose()
		bus:Fire("disposed")
		h:equal(#calls, 2)
	end)

	h:test("createCapital dispose closes owned wrappers, subscriptions, and buses", function()
		local FRP = require("../src")
		local capital = FRP.createCapital({ label = "capital.spec.owned-dispose" })
		local atom = capital.Atom(1)
		local seen = 0
		atom:Subscribe(function()
			seen += 1
		end)
		local bus = capital.Bus()
		bus:Connect(function()
			seen += 10
		end)

		capital:dispose()
		bus:Fire()
		h:equal(seen, 0)
		h:throws(function()
			atom:Get()
		end, "after Dispose")
		h:throws(function()
			capital.Atom(2)
		end, "after dispose")
	end)

	h:test("Compat.bind reuses an existing StateRuntime", function()
		local FRP = require("../src")
		local runtime = FRP.createStateRuntime({ label = "capital.spec.bind" })
		local capital = FRP.Compat.bind(runtime)
		local atom = capital.Atom(1)
		atom:Set(2)
		h:equal(atom:Get(), 2)
		capital:dispose()
		h:throws(function()
			atom:Get()
		end, "after Dispose")
		-- bind closes its facade-owned wrappers but does not own the Runtime.
		h:equal(runtime._disposed == true, false)
		local rawAtom = runtime:atom(3)
		rawAtom:set(4)
		h:equal(rawAtom:get(), 4)
		runtime:dispose()
	end)
end
