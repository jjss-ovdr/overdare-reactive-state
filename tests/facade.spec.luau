--!nonstrict

local AttributePreset = require("../src/AttributePreset")
local Behavior = require("../src/Behavior")
local Bridge = require("../src/Bridge")
local Debug = require("../src/Debug")

local function fakeRuntime()
	local runtime = { _watches = {} }
	function runtime:transaction(callback)
		return callback()
	end
	function runtime:scope()
		local scope = { cleanups = {}, disposed = false }
		function scope:add(cleanup)
			table.insert(self.cleanups, cleanup)
			return cleanup
		end
		function scope:dispose()
			if self.disposed then
				return
			end
			self.disposed = true
			for index = #self.cleanups, 1, -1 do
				self.cleanups[index]()
			end
		end
		return scope
	end
	function runtime:watch(source, callback, options)
		local entry = { source = source, callback = callback, active = true }
		table.insert(self._watches, entry)
		if options == nil or options.initial ~= false then
			callback(source:get(), nil, nil)
		end
		return function()
			entry.active = false
		end
	end
	function runtime:flush(source, changeSet)
		for _, entry in ipairs(self._watches) do
			if entry.active and entry.source == source then
				entry.callback(source:get(), nil, changeSet)
			end
		end
	end
	return runtime
end

local function fakeAtom(initial)
	local atom = { value = initial }
	function atom:get()
		return self.value
	end
	function atom:set(value)
		self.value = value
	end
	return atom
end

return function(h)
	h:test("behavior sequence resumes from a Runtime-owned cursor", function()
		local cursor = fakeAtom(1)
		local firstRuns = 0
		local secondRuns = 0
		local first = Behavior.action(function()
			firstRuns += 1
			return Behavior.SUCCESS
		end)
		local second = Behavior.action(function()
			secondRuns += 1
			return if secondRuns == 1 then Behavior.RUNNING else Behavior.SUCCESS
		end)
		local tree = Behavior.sequence({ first, second }, { cursor = cursor })

		h:equal(tree:tick({}), Behavior.RUNNING)
		h:equal(cursor:get(), 2)
		h:equal(tree:tick({}), Behavior.SUCCESS)
		h:equal(firstRuns, 1)
		h:equal(secondRuns, 2)
		h:equal(cursor:get(), 1)
	end)

	h:test("behavior selector and invert have explicit status semantics", function()
		local tree = Behavior.selector({
			Behavior.when(function()
				return false
			end),
			Behavior.invert(Behavior.when(function()
				return false
			end)),
		})
		h:equal(tree:tick({}), Behavior.SUCCESS)
	end)

	h:test("attribute preset validates defaults, ranges, and unknown keys", function()
		local preset = AttributePreset.define({
			Damage = { type = "number", min = 0, max = 100, default = 10 },
			Mode = { type = "string", enum = { "safe", "fast" }, required = true },
		})
		local result = preset:validate({ Mode = "safe" })
		h:equal(result.Damage, 10)
		h:equal(result.Mode, "safe")
		h:throws(function()
			preset:validate({ Mode = "safe", Surprise = true })
		end, "unknown")
		h:throws(function()
			preset:validate({ Mode = "safe", Damage = 101 })
		end, "<=")
	end)

	h:test("attribute preset applies all targets in one caller-owned transaction", function()
		local runtime = fakeRuntime()
		local speed = fakeAtom(0)
		local preset = AttributePreset.define({
			Speed = { type = "number", default = 16 },
		})
		local scope = preset:apply(nil, runtime, {
			values = {},
			targets = { Speed = speed },
		})
		h:equal(speed:get(), 16)
		scope:dispose()
		scope:dispose()
	end)

	h:test("bridge transfers committed values one way and disposes cleanly", function()
		local sourceRuntime = fakeRuntime()
		local targetRuntime = fakeRuntime()
		local source = fakeAtom(4)
		local target = fakeAtom(0)
		local scope = Bridge.connect({
			sourceRuntime = sourceRuntime,
			source = source,
			targetRuntime = targetRuntime,
			target = target,
			direction = "one-way",
			sourceOfTruth = sourceRuntime,
			map = function(value)
				return value * 2
			end,
		})
		h:equal(target:get(), 8)
		source:set(7)
		sourceRuntime:flush(source, { transactionId = 1, tick = 3 })
		h:equal(target:get(), 14)
		scope:dispose()
		source:set(9)
		sourceRuntime:flush(source, { transactionId = 2, tick = 4 })
		h:equal(target:get(), 14)
	end)

	h:test("bridge rejects a Runtime cycle", function()
		local a = fakeRuntime()
		local b = fakeRuntime()
		local sourceA = fakeAtom(1)
		local sourceB = fakeAtom(2)
		local targetA = fakeAtom(0)
		local targetB = fakeAtom(0)
		local first = Bridge.connect({
			sourceRuntime = a,
			source = sourceA,
			targetRuntime = b,
			target = targetB,
			direction = "one-way",
			sourceOfTruth = a,
		})
		h:throws(function()
			Bridge.connect({
				sourceRuntime = b,
				source = sourceB,
				targetRuntime = a,
				target = targetA,
				direction = "one-way",
				sourceOfTruth = b,
			})
		end, "cycle")
		first:dispose()
	end)

	h:test("debug trace buffer is bounded and chronological", function()
		local buffer = Debug.traceBuffer(2)
		buffer.handler({ event = "one" })
		buffer.handler({ event = "two" })
		buffer.handler({ event = "three" })
		local events = buffer.get()
		h:equal(#events, 2)
		h:equal(events[1].event, "two")
		h:equal(events[2].event, "three")
		buffer.clear()
		h:equal(buffer.size(), 0)
	end)
end
