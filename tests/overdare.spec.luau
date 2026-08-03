--!nonstrict

local Overdare = require("../src/Overdare")

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
