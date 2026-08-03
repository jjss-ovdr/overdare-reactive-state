--!nonstrict

local Clock = require("../src/Core/Clock")
local Codec = require("../src/Core/Codec")
local Hash = require("../src/Core/Hash")

return function(h)
	h:test("codec clones serializable state without aliasing the input", function()
		local shared = { score = 7 }
		local input = { a = shared, b = shared }
		local clone = Codec.clone(input)
		h:notEqual(clone, input)
		h:notEqual(clone.a, shared)
		h:equal(clone.a, clone.b)
		clone.a.score = 9
		h:equal(input.a.score, 7)
	end)

	h:test("codec validates and rejects cycles and executable values", function()
		local valid, message = Codec.validate({ value = function() end })
		h:falsy(valid)
		h:truthy(string.find(message, "function", 1, true))

		local cyclic = {}
		cyclic.self = cyclic
		h:throws(function()
			Codec.clone(cyclic)
		end, "cycle")
	end)

	h:test("codec round-trip preserves values", function()
		local value = { [false] = "no", [3] = { true, "x" }, z = 4 }
		local decoded = Codec.decode(Codec.encode(value))
		h:truthy(Codec.equals(value, decoded))
	end)

	h:test("canonical hash ignores table insertion order", function()
		local first = { a = 1, b = 2, nested = { x = true, y = false } }
		local second = {}
		second.nested = { y = false, x = true }
		second.b = 2
		second.a = 1
		h:equal(Hash.encode(first), Hash.encode(second))
		h:equal(Hash.hash(first), Hash.hash(second))
		h:equal(#Hash.hash(first), 16)
	end)

	h:test("manual clock rolls back a failed callback", function()
		local clock = Clock.manual()
		h:throws(function()
			clock:advance(0.25, function()
				error("reject step")
			end)
		end, "reject step")
		h:equal(clock:getTick(), 0)
		h:equal(clock:getTime(), 0)
	end)

	h:test("fixed clock caps work and reports dropped time", function()
		local ticks = {}
		local overflows = {}
		local clock = Clock.fixed(0.1, {
			maxSubsteps = 2,
			overflow = "drop",
			onOverflow = function(event)
				table.insert(overflows, event)
			end,
		})
		local result = clock:advance(0.55, function(delta, tick)
			table.insert(ticks, { delta, tick })
		end)
		h:equal(result.steps, 2)
		h:truthy(result.overflowed)
		h:equal(#overflows, 1)
		h:equal(#ticks, 2)
		h:equal(clock:getTick(), 2)
		h:truthy(result.accumulator >= 0 and result.accumulator < 0.1)
	end)

	h:test("fixed error overflow mutates no clock state", function()
		local clock = Clock.fixed(1, { maxSubsteps = 1, overflow = "error" })
		h:throws(function()
			clock:advance(2, function() end)
		end, "overflow")
		h:equal(clock:getTick(), 0)
		h:equal(clock:getAccumulator(), 0)
	end)
end
