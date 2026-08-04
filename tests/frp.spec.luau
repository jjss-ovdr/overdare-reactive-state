--!nonstrict

local FRP = require("../src/Core/FRP")

local function capture(event)
	local values = {}
	local disconnect = event:subscribe(function(value, time)
		values[#values + 1] = { time, value }
	end)
	return values, disconnect
end

return function(harness)
	harness:test("frp Future uses max for apply and bind", function()
		local applied = FRP.Future.at(3, function(value)
			return value * 2
		end):ap(FRP.Future.at(5, 7))
		local time, value = applied:force()
		harness:equal(time, 5)
		harness:equal(value, 14)

		local bound = FRP.Future.at(7, "outer"):bind(function()
			return FRP.Future.at(3, "inner")
		end)
		time, value = bound:force()
		harness:equal(time, 7)
		harness:equal(value, "inner")
	end)

	harness:test("frp Future earliest uses min and keeps left ties", function()
		local left = FRP.Future.at(1, "left")
		local right = FRP.Future.at(1, "right")
		harness:equal(left:earlier(right), left)
		harness:equal(FRP.Future.never():earlier(right), right)
	end)

	harness:test("frp rejects NaN time", function()
		harness:throws(function()
			FRP.Future.at(0 / 0, "bad")
		end, "non-NaN")
	end)

	harness:test("frp Event merge preserves structural left order in a frame", function()
		local host = FRP.newHost()
		local left, fireLeft = host:source()
		local right, fireRight = host:source()
		local values = capture(left:merge(right))

		host:frame(1, function()
			fireRight("R1")
			fireLeft("L1")
			fireRight("R2")
			fireLeft("L2")
		end)

		harness:deepEqual(values, {
			{ 1, "L1" },
			{ 1, "L2" },
			{ 1, "R1" },
			{ 1, "R2" },
		})
	end)

	harness:test("frp Event preserves duplicate occurrences", function()
		local host = FRP.newHost()
		local event, fire = host:source()
		local values = capture(event)
		host:frame(1, function()
			fire("same")
			fire("same")
		end)
		harness:deepEqual(values, { { 1, "same" }, { 1, "same" } })
	end)

	harness:test("frp Event map is demand driven", function()
		local host = FRP.newHost()
		local event, fire = host:source()
		local calls = 0
		local mapped = event:map(function(value)
			calls += 1
			return value * 2
		end)
		fire(2, 0)
		harness:equal(calls, 0)
		local values = capture(mapped)
		fire(3, 1)
		host:advanceTo(1)
		harness:equal(calls, 1)
		harness:deepEqual(values, { { 1, 6 } })
	end)

	harness:test("frp stepper uses strict-before sampling", function()
		local host = FRP.newHost()
		local changes, fire = host:source()
		local reactive = FRP.stepper(0, changes)
		host:frame(1, function()
			fire(10)
			fire(11)
		end)
		harness:equal(reactive:at(1), 0)
		harness:equal(reactive:current(), 11)
		host:advanceTo(2)
		harness:equal(reactive:at(2), 11)
	end)

	harness:test("frp Reactive apply emits function change before value change", function()
		local host = FRP.newHost()
		local functionChanges, setFunction = host:source()
		local valueChanges, setValue = host:source()
		local functions = FRP.stepper(function(value)
			return value
		end, functionChanges)
		local values = FRP.stepper(1, valueChanges)
		local output = capture(functions:ap(values):changes())
		host:frame(2, function()
			setValue(2)
			setFunction(function(value)
				return value * 10
			end)
		end)
		harness:deepEqual(output, { { 2, 10 }, { 2, 20 } })
	end)

	harness:test("frp Reactive switch keeps old inner change before same-time switch", function()
		local host = FRP.newHost()
		local oldChanges, setOld = host:source()
		local newChanges, setNew = host:source()
		local switches, switch = host:source()
		local old = FRP.stepper("A", oldChanges)
		local new = FRP.stepper("B", newChanges)
		local joined = old:switcher(switches)
		local output = capture(joined:changes())
		host:frame(2, function()
			setOld("A2")
			switch(new)
		end)
		setNew("B3", 3)
		setOld("A4", 4)
		host:advanceTo(4)
		harness:deepEqual(output, { { 2, "A2" }, { 2, "B" }, { 3, "B3" } })
	end)

	harness:test("frp constant and time Behaviors sample pointwise", function()
		local host = FRP.newHost()
		local behavior = FRP.lift2(function(left, right)
			return left + right
		end, FRP.constant(host, 4), FRP.time(host))
		host:advanceTo(3.25)
		harness:equal(behavior:at(3.25), 7.25)
	end)

	harness:test("frp Behavior apply samples both sides at the same time", function()
		local host = FRP.newHost()
		local functions = FRP.fromFunction(host, function(time)
			return function(value)
				return time + value
			end
		end)
		local values = FRP.fromFunction(host, function(time)
			return 2 * time
		end)
		host:advanceTo(3)
		harness:equal(functions:ap(values):at(3), 9)
	end)

	harness:test("frp Behavior switch uses global time and strict boundary", function()
		local host = FRP.newHost()
		local switches, switch = host:source()
		local behavior = FRP.constant(host, "old"):switcher(switches)
		host:frame(10, function()
			switch(FRP.time(host))
		end)
		harness:equal(behavior:at(10), "old")
		host:advanceTo(11)
		harness:equal(behavior:at(11), 11)
	end)

	harness:test("frp constant Behavior sink renders once while dynamic renders per advance", function()
		local host = FRP.newHost()
		local constantCalls = 0
		local dynamicCalls = 0
		FRP.constant(host, 1):subscribe(function()
			constantCalls += 1
		end)
		FRP.time(host):subscribe(function()
			dynamicCalls += 1
		end)
		host:advanceTo(1)
		host:advanceTo(2)
		host:advanceTo(3)
		harness:equal(constantCalls, 1)
		harness:equal(dynamicCalls, 4)
	end)

	harness:test("frp Event bind clamps a selected inner past occurrence", function()
		local host = FRP.newHost()
		local outer, fireOuter = host:source()
		local inner, fireInner = host:source()
		local bound = outer:bind(function()
			return inner
		end)
		local output = capture(bound)
		fireInner("past", 3)
		fireOuter(true, 5)
		host:advanceTo(5)
		harness:deepEqual(output, { { 5, "past" } })
	end)

	harness:test("frp frame prepare failure is atomic", function()
		local host = FRP.newHost()
		local source, fire = host:source()
		local reactive = FRP.stepper(0, source:map(function(value)
			if value == 2 then
				error("boom")
			end
			return value
		end))
		fire(1, 1)
		host:advanceTo(1)
		harness:throws(function()
			fire(2, 2)
			host:advanceTo(2)
		end, "aborted")
		harness:equal(host:now(), 1)
		harness:equal(reactive:current(), 1)
	end)

	harness:test("frp failed initial and past pulls do not poison Event cycle guards", function()
		local host = FRP.newHost()
		local fail = true
		local initial = FRP.eventPure(host, 1):map(function(value)
			if fail then error("initial failure") end
			return value + 1
		end)
		harness:throws(function()
			initial:occurrences()
		end, "initial failure")
		fail = false
		harness:equal(initial:occurrences()[1].value, 2)

		local source, fire = host:source()
		fire(3, 1)
		host:advanceTo(1)
		local failPast = true
		local mapped = source:map(function(value)
			if failPast then error("past failure") end
			return value * 2
		end)
		harness:throws(function()
			mapped:occurrences()
		end, "past failure")
		failPast = false
		harness:equal(mapped:occurrences()[1].value, 6)
		host:dispose()
	end)

	harness:test("frp source and sampling reject cross-host values", function()
		local first = FRP.newHost()
		local second = FRP.newHost()
		local event = first:source()
		harness:throws(function()
			FRP.stepper(0, event):ap(FRP.reactivePure(second, 1))
		end, "same Host")
		harness:throws(function()
			first:sample(FRP.constant(second, 1))
		end, "same Host")
	end)

	harness:test("frp reentrant sink emission preserves an explicit future time", function()
		local host = FRP.newHost()
		local first, fireFirst = host:source()
		local second, fireSecond = host:source()
		local observed = {}
		first:subscribe(function(value, time)
			fireSecond(value + 1, time + 1)
		end)
		second:subscribe(function(value, time)
			observed[#observed + 1] = { time, value }
		end)
		fireFirst(1, 0)
		harness:equal(#observed, 0)
		host:advanceTo(1)
		harness:deepEqual(observed, { { 1, 2 } })
		host:dispose()
	end)

	harness:test("frp Host rejects backwards time", function()
		local host = FRP.newHost({ startTime = 2 })
		harness:throws(function()
			host:advanceTo(1)
		end, "monotonic")
	end)

	harness:test("frp Event scan keeps live state when the same inner is selected again", function()
		local host = FRP.newHost()
		local updates, update = host:source()
		local selections, selectInner = host:source()
		local inner = updates:scan(0, function(total, amount)
			return total + amount
		end)
		local bound = selections:bind(function()
			return inner
		end)
		local observed = capture(bound)

		host:frame(0, function()
			selectInner(true)
		end)
		host:frame(1, function()
			update(1)
			selectInner(true)
		end)
		host:frame(2, function()
			update(1)
		end)

		harness:deepEqual(observed, {
			{ 1, 1 }, { 1, 1 },
			{ 2, 2 }, { 2, 2 },
		})
		host:dispose()
	end)

	harness:test("frp Event scan commits nil reducer state", function()
		local host = FRP.newHost()
		local source, fire = host:source()
		local sawNilState = false
		local count = 0
		local scanned = source:scan("seed", function(previous, command)
			if command == "clear" then
				return nil
			end
			sawNilState = previous == nil
			return "restored"
		end)
		scanned:subscribe(function()
			count += 1
		end)
		host:frame(1, function() fire("clear") end)
		host:frame(2, function() fire("restore") end)
		harness:equal(count, 2)
		harness:truthy(sawNilState)
		host:dispose()
	end)

	harness:test("frp Behavior sink preserves every same-frame phase", function()
		local host = FRP.newHost()
		local changes, fire = host:source()
		local observed = {}
		FRP.stepperBehavior(0, changes):subscribe(function(value)
			observed[#observed + 1] = value
		end)
		host:frame(1, function()
			fire(1)
			fire(2)
		end)
		harness:deepEqual(observed, { 0, 1, 2 })
		host:dispose()
	end)

	harness:test("frp Behavior sink preserves duplicate same-object switches", function()
		local host = FRP.newHost()
		local switches, switch = host:source()
		local constant = FRP.constant(host, 7)
		local observed = {}
		constant:switcher(switches):subscribe(function(value)
			observed[#observed + 1] = value
		end)
		host:frame(1, function()
			switch(constant)
			switch(constant)
		end)
		harness:deepEqual(observed, { 7, 7, 7 })
		host:dispose()
	end)

	harness:test("frp Behavior initial false does not pull the TimeFunction", function()
		local host = FRP.newHost()
		local pulls = 0
		local observed = {}
		FRP.fromFunction(host, function(time)
			pulls += 1
			return time
		end):subscribe(function(value)
			observed[#observed + 1] = value
		end, { initial = false })
		harness:equal(pulls, 0)
		host:advanceTo(1)
		harness:equal(pulls, 1)
		harness:deepEqual(observed, { 1 })
		host:dispose()
	end)

	harness:test("frp Reactive subscribes before its initial callback", function()
		local host = FRP.newHost()
		local changes, fire = host:source()
		local observed = {}
		FRP.stepper(0, changes):subscribe(function(value)
			observed[#observed + 1] = value
			if value == 0 then
				fire(1, 0)
			end
		end)
		harness:deepEqual(observed, { 0, 1 })
		host:dispose()
	end)

	harness:test("frp commits a Reactive constructed during prepare", function()
		local host = FRP.newHost()
		local baseChanges, setBase = host:source()
		local outerChanges, setOuter = host:source()
		local created = nil
		local outer = FRP.stepper(false, outerChanges)
		local joined = outer:bind(function(enabled)
			if enabled then
				created = FRP.stepper(0, baseChanges)
				return created
			end
			return FRP.reactivePure(host, -1)
		end)
		joined:subscribe(function() end, { initial = false })
		host:frame(1, function()
			setBase(10)
			setOuter(true)
		end)
		harness:equal(created:current(), 10)
		host:advanceTo(2)
		harness:equal(created:at(2), 10)
		host:dispose()
	end)

	harness:test("frp diagnostic past pulls never rewind live scan state", function()
		local host = FRP.newHost()
		local source, fire = host:source()
		local scanned = source:scan(0, function(total, amount)
			return total + amount
		end)
		local observed = capture(scanned)
		host:frame(1, function() fire(1) end)
		host:frame(2, function() fire(1) end)
		scanned:occurrences(1)
		host:frame(3, function() fire(1) end)
		harness:deepEqual(observed, { { 1, 1 }, { 2, 2 }, { 3, 3 } })
		host:dispose()
	end)

	harness:test("frp closes each logical time once and coalesces scheduled roots", function()
		local host = FRP.newHost()
		local left, fireLeft = host:source()
		local right, fireRight = host:source()
		local observed = capture(left:merge(right))
		fireRight("R0", 0)
		harness:throws(function()
			fireLeft("late-L0", 0)
		end, "closed logical time")
		harness:deepEqual(observed, { { 0, "R0" } })

		fireRight("R1", 1)
		fireLeft("L1", 1)
		host:advanceTo(1)
		harness:deepEqual(observed, {
			{ 0, "R0" }, { 1, "L1" }, { 1, "R1" },
		})
		host:dispose()
	end)

	harness:test("frp Event bind supports dynamically constructed past same and future occurrences", function()
		local host = FRP.newHost()
		local outer = FRP.fromOccurrences(host, { { 5, { selectedAt = 5 } } })
		local bound = outer:bind(function(selection)
			local time = selection.selectedAt
			return FRP.fromOccurrences(host, {
				{ time - 2, "past" },
				{ time, "same" },
				{ time + 2, "future" },
			})
		end)
		local observed = capture(bound)
		host:advanceTo(7)
		harness:deepEqual(observed, {
			{ 5, "past" }, { 5, "same" }, { 7, "future" },
		})
		host:dispose()
	end)

	harness:test("frp Host disposal severs graph edges and clears retained prefixes", function()
		local host = FRP.newHost()
		local source, fire = host:source()
		local mapped = source:map(function(value) return value end)
		local stopEvent = mapped:subscribe(function() end)
		local stopBehavior = FRP.constant(host, { retained = true }):subscribe(function() end)
		host:frame(1, function() fire({ payload = "retained" }) end)
		harness:truthy(next(source._dependents) ~= nil)
		harness:equal(#source._sourceHistory, 1)
		host:dispose()
		harness:equal(next(source._dependents), nil)
		harness:equal(next(mapped._dependents), nil)
		harness:equal(#source._sourceHistory, 0)
		harness:equal(mapped._compute, nil)
		stopEvent()
		stopBehavior()
		stopEvent()
		stopBehavior()
	end)

	harness:test("frp discarded downstream graphs are not retained by their parents", function()
		local collectGarbage = getfenv().collectgarbage
		if type(collectGarbage) ~= "function" then
			return
		end
		local host = FRP.newHost()
		local source = host:source()
		local discarded = source:map(function(value) return value end)
		harness:truthy(discarded ~= nil)
		harness:equal(source:getDebugInfo().dependents, 1)
		discarded = nil
		collectGarbage("collect")
		collectGarbage("collect")
		harness:equal(source:getDebugInfo().dependents, 0)
		host:dispose()
	end)
end
