--!nonstrict

local Runtime = require("../src/Core/Runtime")

local function generator(seed)
	local state = seed
	return function(limit)
		state = (state * 48271) % 2147483647
		return state % limit
	end
end

return function(h)
	h:test("randomized dynamic graph matches a direct evaluator", function()
		local nextInt = generator(20260803)
		local runtime = Runtime.new()
		local a = runtime:atom(0)
		local b = runtime:atom(0)
		local chooseA = runtime:atom(true)
		local derived = runtime:computed(function()
			return (if chooseA:get() then a:get() else b:get()) * 3
		end)
		local pureA = 0
		local pureB = 0
		local pureChooseA = true
		local expectedWatchCalls = 0
		local actualWatchCalls = 0
		runtime:watch(derived, function(value)
			actualWatchCalls += 1
			local expected = (if pureChooseA then pureA else pureB) * 3
			h:equal(value, expected)
		end, { initial = false })

		for _ = 1, 250 do
			local before = (if pureChooseA then pureA else pureB) * 3
			local operations = nextInt(5) + 1
			runtime:transaction(function()
				for _ = 1, operations do
					local kind = nextInt(3)
					if kind == 0 then
						pureA = nextInt(101) - 50
						a:set(pureA)
					elseif kind == 1 then
						pureB = nextInt(101) - 50
						b:set(pureB)
					else
						pureChooseA = nextInt(2) == 0
						chooseA:set(pureChooseA)
					end
				end
			end)
			local after = (if pureChooseA then pureA else pureB) * 3
			if after ~= before then
				expectedWatchCalls += 1
			end
			h:equal(derived:get(), after)
		end
		h:equal(actualWatchCalls, expectedWatchCalls)
	end)

	h:test("multi-tick replay hash equals straight deterministic execution", function()
		local inputs = {}
		local nextInt = generator(7)
		for tick = 1, 40 do
			inputs[tick] = nextInt(11) - 5
		end
		local runtime = Runtime.new({ deterministic = true, history = { capacity = 64 } })
		local position = runtime:atom(0, { label = "position" })
		for tick = 1, 40 do
			runtime:step(tick, function()
				position:update(function(value)
					return value + inputs[tick]
				end)
			end)
		end
		local expectedPosition = position:get()
		local expectedHash = runtime:getStateHash()
		runtime:replay(15, 40, function(_context, tick)
			position:update(function(value)
				return value + inputs[tick]
			end)
		end)
		h:equal(position:get(), expectedPosition)
		h:equal(runtime:getStateHash(), expectedHash)
	end)
end
