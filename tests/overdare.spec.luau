--!nonstrict

local Overdare = require("../src/Overdare")
local FRP = require("../src/Core/FRP")

local function fakeSignal()
	local signal = { listeners = {} }
	function signal:Connect(callback)
		local entry = { callback = callback, connected = true }
		table.insert(self.listeners, entry)
		local connection = {}
		function connection:Disconnect()
			entry.connected = false
		end
		return connection
	end
	function signal:Fire(...)
		for _, entry in ipairs(self.listeners) do
			if entry.connected then
				entry.callback(...)
			end
		end
	end
	return signal
end
local function fakeRuntime()
	local runtime = { transactions = 0, steps = {}, watches = {} }
	function runtime:transaction(callback, metadata)
		self.transactions += 1
		self.lastMetadata = metadata
		return callback()
	end
	function runtime:step(tick, callback, metadata)
		table.insert(self.steps, tick)
		self.lastMetadata = metadata
		return callback({ tick = tick })
	end
	function runtime:getTick()
		return nil
	end
	function runtime:watch(source, callback, options)
		local watch = { source = source, callback = callback, active = true }
		table.insert(self.watches, watch)
		if options.initial then
			callback(source:get(), nil, nil)
		end
		return function()
			watch.active = false
		end
	end
	function runtime:flush(source, changeSet)
		for _, watch in ipairs(self.watches) do
			if watch.active and watch.source == source then
				watch.callback(source:get(), nil, changeSet)
			end
		end
	end
	return runtime
end

local function fakeAtom(runtime, initial)
	local atom = { _runtime = runtime, value = initial }
	function atom:get()
		return self.value
	end
	function atom:set(value)
		self.value = value
	end
	return atom
end

return function(h)
	h:test("Overdare FRP driver batches signals and preserves structural tie order", function()
		local host = FRP.newHost()
		local phase = fakeSignal()
		local leftSignal = fakeSignal()
		local rightSignal = fakeSignal()
		local driver = Overdare.attachFRP(host, { signal = phase, phase = "Heartbeat" })
		local left = driver:eventFromSignal(leftSignal)
		local right = driver:eventFromSignal(rightSignal)
		local observed = {}
		left:merge(right):subscribe(function(value, time)
			observed[#observed + 1] = { time, value }
		end)

		rightSignal:Fire("right")
		leftSignal:Fire("left")
		h:equal(#observed, 0)
		phase:Fire(1)
		h:deepEqual(observed, { { 1, "left" }, { 1, "right" } })
		driver:dispose()
		host:dispose()
	end)

	h:test("Overdare FRP driver preserves duplicates and strict-before state", function()
		local host = FRP.newHost()
		local phase = fakeSignal()
		local input = fakeSignal()
		local driver = Overdare.attachFRP(host, { signal = phase })
		local event = driver:eventFromSignal(input)
		local state = FRP.stepper(0, event)
		local occurrences = {}
		event:subscribe(function(value)
			occurrences[#occurrences + 1] = value
		end)
		input:Fire(1)
		input:Fire(1)
		phase:Fire(2)
		h:deepEqual(occurrences, { 1, 1 })
		h:equal(state:at(2), 0)
		h:equal(state:current(), 1)
		phase:Fire(0.5)
		h:equal(state:at(2.5), 1)
		driver:dispose()
		host:dispose()
	end)

	h:test("Overdare FRP binding disposal cancels pending input and driver leaves Host alive", function()
		local host = FRP.newHost()
		local phase = fakeSignal()
		local input = fakeSignal()
		local driver = Overdare.attachFRP(host, { signal = phase })
		local event, binding = driver:eventFromSignal(input)
		local observed = {}
		event:subscribe(function(value)
			observed[#observed + 1] = value
		end)
		input:Fire("pending")
		binding:dispose()
		phase:Fire(1)
		h:equal(#observed, 0)
		driver:dispose()

		local source, fire = host:source()
		local live = {}
		source:subscribe(function(value)
			live[#live + 1] = value
		end)
		fire("still-alive", 2)
		host:advanceTo(2)
		h:deepEqual(live, { "still-alive" })
		host:dispose()
	end)

	h:test("Overdare FRP driver isolates mapper errors under continue policy", function()
		local host = FRP.newHost()
		local phase = fakeSignal()
		local badSignal = fakeSignal()
		local goodSignal = fakeSignal()
		local errors = {}
		local driver = Overdare.attachFRP(host, {
			signal = phase,
			errorPolicy = "continue",
			onError = function(detail)
				errors[#errors + 1] = detail
			end,
		})
		driver:eventFromSignal(badSignal, { map = function()
			error("bad projection")
		end })
		local good = driver:eventFromSignal(goodSignal)
		local observed = {}
		good:subscribe(function(value)
			observed[#observed + 1] = value
		end)
		badSignal:Fire("bad")
		goodSignal:Fire("good")
		phase:Fire(1)
		h:equal(#errors, 1)
		h:equal(errors[1].stage, "signal-map")
		h:deepEqual(observed, { "good" })
		driver:dispose()
		host:dispose()
	end)

	h:test("Overdare allows only one active FRP driver per Host", function()
		local host = FRP.newHost()
		local first = Overdare.attachFRP(host, { signal = fakeSignal() })
		h:throws(function()
			Overdare.attachFRP(host, { signal = fakeSignal() })
		end, "only one")
		first:dispose()
		local second = Overdare.attachFRP(host, { signal = fakeSignal() })
		second:dispose()
		host:dispose()
	end)

	h:test("Overdare fixed attach uses stable callback priority and disposes", function()
		local runtime = fakeRuntime()
		local signal = fakeSignal()
		local calls = {}
		local attached = Overdare.attach(runtime, {
			signal = signal,
			phase = "Heartbeat",
			fixedDelta = 0.1,
			maxSubsteps = 4,
			callbacks = {
				{ priority = 10, callback = function(_ctx, _delta, tick)
					table.insert(calls, "late:" .. tostring(tick))
				end },
				{ priority = -1, callback = function(_ctx, _delta, tick)
					table.insert(calls, "early:" .. tostring(tick))
				end },
			},
		})
		signal:Fire(0.25)
		h:deepEqual(runtime.steps, { 1, 2 })
		h:deepEqual(calls, { "early:1", "late:1", "early:2", "late:2" })
		h:truthy(math.abs(attached:getAccumulator() - 0.05) < 1e-9)
		attached:dispose()
		attached:dispose()
		signal:Fire(0.1)
		h:equal(#runtime.steps, 2)
	end)

	h:test("Overdare bind projects Source changes one way", function()
		local runtime = fakeRuntime()
		local source = fakeAtom(runtime, "idle")
		local instance = { State = "" }
		local stop = Overdare.bind(instance, "State", source, {
			runtime = runtime,
			sourceOfTruth = "source",
		})
		h:equal(instance.State, "idle")
		source:set("running")
		runtime:flush(source, { transactionId = 1 })
		h:equal(instance.State, "running")
		stop()
		source:set("stopped")
		runtime:flush(source, { transactionId = 2 })
		h:equal(instance.State, "running")
	end)

	h:test("Overdare sample polls a property through the chosen phase", function()
		local runtime = fakeRuntime()
		local atom = fakeAtom(runtime, nil)
		local instance = { Position = 3 }
		local signal = fakeSignal()
		local sampling = Overdare.sample(instance, "Position", atom, {
			runtime = runtime,
			signal = signal,
			phase = "Heartbeat",
			sourceOfTruth = "instance",
		})
		h:equal(atom:get(), 3)
		instance.Position = 8
		signal:Fire(1 / 60)
		h:equal(atom:get(), 8)
		h:truthy(runtime.transactions >= 2)
		sampling:dispose()
	end)
end
