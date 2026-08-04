--!nonstrict

local FRP = require("../src")

local function pairsOf(occurrences)
	local output = {}
	for _, item in ipairs(occurrences) do
		output[#output + 1] = { item.time, item.value }
	end
	return output
end

local function capture(event)
	local output = {}
	event:subscribe(function(value, time)
		output[#output + 1] = { time, value }
	end)
	return output
end

return function(h)
	h:test("frp root exposes the paper types and keeps State runtime explicit", function()
		h:equal(FRP.API_VERSION, 2)
		h:equal(FRP.SEMANTICS_VERSION, 1)
		h:truthy(type(FRP.Future.pure) == "function")
		h:truthy(type(FRP.Event.merge) == "function")
		h:truthy(type(FRP.Reactive.bind) == "function")
		h:truthy(type(FRP.Behavior.ap) == "function")
		h:equal(FRP.Behavior.bind, nil)
		h:truthy(type(FRP.createStateRuntime) == "function")
	end)

	h:test("frp Future pure is minus infinity and at rejects infinity", function()
		local time, value = FRP.Future.pure("unit"):force()
		h:equal(time, -math.huge)
		h:equal(value, "unit")
		h:throws(function()
			FRP.Future.at(math.huge, "not-an-occurrence")
		end, "finite")
	end)

	h:test("frp Future satisfies finite Functor and Monad laws", function()
		local source = FRP.Future.at(3, 4)
		local identity = source:map(function(value) return value end)
		local ti, vi = identity:force()
		h:equal(ti, 3)
		h:equal(vi, 4)

		local function k(value) return FRP.Future.at(5, value + 1) end
		local function q(value) return FRP.Future.at(2, value * 3) end
		local left = FRP.Future.pure(4):bind(k)
		local right = k(4)
		local tl, vl = left:force()
		local tr, vr = right:force()
		h:equal(tl, tr)
		h:equal(vl, vr)

		local a = source:bind(k):bind(q)
		local b = source:bind(function(value) return k(value):bind(q) end)
		local ta, va = a:force()
		local tb, vb = b:force()
		h:equal(ta, tb)
		h:equal(va, vb)
	end)

	h:test("frp TimeFunction preserves constants and implements pointwise bind", function()
		local constant = FRP.TimeFunction.constant(function(value)
			return value + 1
		end):ap(FRP.TimeFunction.constant(2))
		h:truthy(constant:isConstant())
		h:equal(constant:apply(10), 3)

		local dynamic = FRP.TimeFunction.dynamic(function(time)
			return time
		end):bind(function(value)
			return FRP.TimeFunction.dynamic(function(time)
				return value + time
			end)
		end)
		h:equal(dynamic:apply(3), 6)
	end)

	h:test("frp Event merge matches the paper stable chronological example", function()
		local host = FRP.newHost()
		local left = FRP.Event.fromOccurrences(host, {
			{ 1, "A1" }, { 2, "A2a" }, { 2, "A2b" }, { 4, "A4" },
		})
		local right = FRP.Event.fromOccurrences(host, {
			{ 2, "B2a" }, { 2, "B2b" }, { 3, "B3" },
		})
		host:advanceTo(4)
		h:deepEqual(pairsOf(left:merge(right):occurrences()), {
			{ 1, "A1" },
			{ 2, "A2a" }, { 2, "A2b" },
			{ 2, "B2a" }, { 2, "B2b" },
			{ 3, "B3" }, { 4, "A4" },
		})
		host:dispose()
	end)

	h:test("frp Event bind delays inner prefixes with max and merges outer order", function()
		local host = FRP.newHost()
		local innerA = FRP.Event.fromOccurrences(host, { { 3, "a0" }, { 8, "a1" } })
		local innerB = FRP.Event.fromOccurrences(host, { { 6, "b0" }, { 8, "b1" } })
		local outer = FRP.Event.fromOccurrences(host, { { 5, "A" }, { 7, "B" } })
		local bound = outer:bind(function(value)
			return if value == "A" then innerA else innerB
		end)
		local observed = capture(bound)
		host:advanceTo(8)
		h:deepEqual(observed, {
			{ 5, "a0" }, { 7, "b0" }, { 8, "a1" }, { 8, "b1" },
		})
		host:dispose()
	end)

	h:test("frp Event applicative produces the Cartesian occurrence product", function()
		local host = FRP.newHost()
		local functions = FRP.Event.fromOccurrences(host, {
			{ 1, function(value) return "f1:" .. value end },
			{ 3, function(value) return "f2:" .. value end },
		})
		local values = FRP.Event.fromOccurrences(host, { { 2, "x1" }, { 4, "x2" } })
		local observed = capture(functions:ap(values))
		host:advanceTo(4)
		h:deepEqual(observed, {
			{ 2, "f1:x1" }, { 3, "f2:x1" }, { 4, "f1:x2" }, { 4, "f2:x2" },
		})
		host:dispose()
	end)

	h:test("frp Event pure participates at minus infinity without finite duplication", function()
		local host = FRP.newHost()
		local event = FRP.Event.pure(host, 2):bind(function(value)
			return FRP.Event.pure(host, value * 3)
		end)
		local occurrences = event:occurrences()
		h:equal(#occurrences, 1)
		h:equal(occurrences[1].time, -math.huge)
		h:equal(occurrences[1].value, 6)
		host:dispose()
	end)

	h:test("frp Event merge identity and associativity preserve ordered occurrences", function()
		local host = FRP.newHost()
		local a = FRP.fromOccurrences(host, { { 1, "a1" }, { 2, "a2" } })
		local b = FRP.fromOccurrences(host, { { 2, "b2" } })
		local c = FRP.fromOccurrences(host, { { 2, "c2" }, { 3, "c3" } })
		host:advanceTo(3)
		h:deepEqual(pairsOf(FRP.Event.never(host):merge(a):occurrences()), pairsOf(a:occurrences()))
		h:deepEqual(
			pairsOf(a:merge(b):merge(c):occurrences()),
			pairsOf(a:merge(b:merge(c)):occurrences())
		)
		host:dispose()
	end)

	h:test("frp Event Monad left and right identity match denotation", function()
		local host = FRP.newHost()
		local source = FRP.fromOccurrences(host, { { 1, 2 }, { 3, 4 } })
		local doubled = FRP.fromOccurrences(host, { { 2, 8 } })
		local left = FRP.Event.pure(host, "select"):bind(function() return doubled end)
		local right = source:bind(function(value) return FRP.Event.pure(host, value) end)
		host:advanceTo(3)
		h:deepEqual(pairsOf(left:occurrences()), pairsOf(doubled:occurrences()))
		h:deepEqual(pairsOf(right:occurrences()), pairsOf(source:occurrences()))
		host:dispose()
	end)

	h:test("frp Event Monad associativity is independent of occurrence time", function()
		local host = FRP.newHost()
		local source = FRP.fromOccurrences(host, { { 5, 1 } })
		local mapperSawTime = false
		local mapSawTime = false
		local function k(value, hiddenTime)
			mapperSawTime = mapperSawTime or hiddenTime ~= nil
			return FRP.fromOccurrences(host, { { 3, value + 1 } })
		end
		local function q(value, hiddenTime)
			mapperSawTime = mapperSawTime or hiddenTime ~= nil
			return FRP.fromOccurrences(host, {
				{ hiddenTime or 4, if hiddenTime ~= nil then hiddenTime else value * 2 },
			})
		end
		local mapped = source:map(function(value, hiddenTime)
			mapSawTime = hiddenTime ~= nil
			return value
		end)
		local left = source:bind(k):bind(q)
		local right = source:bind(function(value)
			return k(value):bind(q)
		end)
		host:advanceTo(5)
		h:deepEqual(pairsOf(left:occurrences()), { { 5, 4 } })
		h:deepEqual(pairsOf(right:occurrences()), pairsOf(left:occurrences()))
		h:deepEqual(pairsOf(mapped:occurrences()), { { 5, 1 } })
		h:falsy(mapperSawTime)
		h:falsy(mapSawTime)
		host:dispose()
	end)

	h:test("frp Reactive can be constructed and mapped after its source prefix", function()
		local host = FRP.newHost()
		local changes, fire = host:source()
		fire(10, 1)
		fire(20, 2)
		host:advanceTo(2)
		local reactive = FRP.Reactive.stepper(0, changes)
		local mapped = reactive:map(function(value) return value + 1 end)
		h:equal(reactive:at(1), 0)
		h:equal(reactive:at(2), 10)
		h:equal(reactive:current(), 20)
		h:equal(mapped:at(1), 1)
		h:equal(mapped:at(2), 11)
		h:equal(mapped:current(), 21)
		host:dispose()
	end)

	h:test("frp Reactive apply reconstructs simultaneous history after composition", function()
		local host = FRP.newHost()
		local functionChanges, setFunction = host:source()
		local valueChanges, setValue = host:source()
		local functions = FRP.stepper(function(value) return value end, functionChanges)
		local values = FRP.stepper(1, valueChanges)
		host:frame(2, function()
			setFunction(function(value) return value * 10 end)
			setValue(2)
		end)
		local applied = functions:ap(values)
		h:deepEqual(pairsOf(applied:changes():occurrences()), { { 2, 10 }, { 2, 20 } })
		h:equal(applied:at(2), 1)
		host:advanceTo(3)
		h:equal(applied:at(3), 20)
		host:dispose()
	end)

	h:test("frp Reactive Monad right identity preserves boundary samples", function()
		local host = FRP.newHost()
		local changes = FRP.fromOccurrences(host, { { 1, 10 }, { 1, 11 }, { 3, 30 } })
		host:advanceTo(4)
		local reactive = FRP.stepper(0, changes)
		local identity = reactive:bind(function(value)
			return FRP.reactivePure(host, value)
		end)
		for _, time in ipairs({ 0, 1, 2, 3, 4 }) do
			h:equal(identity:at(time), reactive:at(time))
		end
		host:dispose()
	end)

	h:test("frp Reactive Monad associativity uses value-only mappers", function()
		local host = FRP.newHost()
		local mapperSawTime = false
		local source = FRP.stepper(0, FRP.fromOccurrences(host, { { 5, 1 } }))
		local function k(value, hiddenTime)
			mapperSawTime = mapperSawTime or hiddenTime ~= nil
			return FRP.reactivePure(host, value + 1)
		end
		local function q(value, hiddenTime)
			mapperSawTime = mapperSawTime or hiddenTime ~= nil
			return FRP.reactivePure(host, value * 2)
		end
		local left = source:bind(k):bind(q)
		local right = source:bind(function(value)
			return k(value):bind(q)
		end)
		host:advanceTo(6)
		for _, time in ipairs({ 0, 5, 6 }) do
			h:equal(left:at(time), right:at(time))
		end
		h:deepEqual(pairsOf(left:changes():occurrences()), pairsOf(right:changes():occurrences()))
		h:falsy(mapperSawTime)
		host:dispose()
	end)

	h:test("frp switcher same-time right merge wins only after the boundary", function()
		local host = FRP.newHost()
		local leftSwitch, fireLeft = host:source()
		local rightSwitch, fireRight = host:source()
		local switched = FRP.reactivePure(host, "old"):switcher(leftSwitch:merge(rightSwitch))
		host:frame(10, function()
			fireRight(FRP.reactivePure(host, "right"))
			fireLeft(FRP.reactivePure(host, "left"))
		end)
		h:equal(switched:at(10), "old")
		h:equal(switched:current(), "right")
		host:advanceTo(11)
		h:equal(switched:at(11), "right")
		host:dispose()
	end)

	h:test("frp Reactive join reconstructs past switches and drops old futures", function()
		local host = FRP.newHost()
		local oldChanges, setOld = host:source()
		local newChanges, setNew = host:source()
		local outerChanges, switch = host:source()
		local old = FRP.stepper("A", oldChanges)
		local new = FRP.stepper("B", newChanges)
		local outer = FRP.stepper(old, outerChanges)
		host:frame(2, function()
			setOld("A2")
			switch(new)
		end)
		setNew("B3", 3)
		setOld("A4", 4)
		host:advanceTo(4)
		local joined = outer:join()
		h:deepEqual(pairsOf(joined:changes():occurrences()), {
			{ 2, "A2" }, { 2, "B" }, { 3, "B3" },
		})
		h:equal(joined:at(2), "A")
		h:equal(joined:at(4), "B3")
		host:dispose()
	end)

	h:test("frp snapshot pulls Behavior at the strict occurrence boundary", function()
		local host = FRP.newHost()
		local changes, set = host:source()
		local triggers, trigger = host:source()
		local behavior = FRP.stepperBehavior(0, changes)
		local observed = capture(triggers:snapshot(behavior, function(eventValue, sampled)
			return { eventValue, sampled }
		end))
		host:frame(1, function()
			set(10)
			trigger("at-one")
		end)
		host:frame(2, function()
			trigger("at-two")
		end)
		h:deepEqual(observed, {
			{ 1, { "at-one", 0 } },
			{ 2, { "at-two", 10 } },
		})
		host:dispose()
	end)

	h:test("frp dynamic Behavior renders every host advance even for equal values", function()
		local host = FRP.newHost()
		local renders = 0
		FRP.fromFunction(host, function() return 7 end):subscribe(function()
			renders += 1
		end)
		host:advanceTo(1)
		host:advanceTo(2)
		host:advanceTo(3)
		h:equal(renders, 4)
		host:dispose()
	end)

	h:test("frp Behavior Applicative identity is pointwise", function()
		local host = FRP.newHost()
		local behavior = FRP.fromFunction(host, function(time) return time * time end)
		local identity = FRP.constant(host, function(value) return value end):ap(behavior)
		for _, time in ipairs({ 0, 0.25, 1.5, 4 }) do
			host:advanceTo(time)
			h:equal(identity:at(time), behavior:at(time))
		end
		host:dispose()
	end)

	h:test("frp randomized stable merge agrees with an array denotation", function()
		local seed = 73129
		local function random(limit)
			seed = (seed * 48271) % 2147483647
			return seed % limit
		end
		for case = 1, 100 do
			local host = FRP.newHost()
			local leftEntries = {}
			local rightEntries = {}
			for index = 1, random(7) do
				leftEntries[#leftEntries + 1] = { random(5), "L" .. case .. ":" .. index }
			end
			for index = 1, random(7) do
				rightEntries[#rightEntries + 1] = { random(5), "R" .. case .. ":" .. index }
			end
			table.sort(leftEntries, function(a, b) return a[1] < b[1] end)
			table.sort(rightEntries, function(a, b) return a[1] < b[1] end)
			local left = FRP.fromOccurrences(host, leftEntries)
			local right = FRP.fromOccurrences(host, rightEntries)
			host:advanceTo(4)
			local expected = {}
			local li, ri = 1, 1
			while li <= #leftEntries or ri <= #rightEntries do
				local l, r = leftEntries[li], rightEntries[ri]
				if r == nil or (l ~= nil and l[1] <= r[1]) then
					expected[#expected + 1] = l
					li += 1
				else
					expected[#expected + 1] = r
					ri += 1
				end
			end
			h:deepEqual(pairsOf(left:merge(right):occurrences()), expected)
			host:dispose()
		end
	end)

	h:test("frp occurrence constructor rejects descending time", function()
		local host = FRP.newHost()
		h:throws(function()
			FRP.fromOccurrences(host, { { 2, "late" }, { 1, "early" } })
		end, "nondecreasing")
		host:dispose()
	end)
end
