--!nonstrict

-- Dedicated benchmarks for the Conal-style Future/Event/Reactive/Behavior
-- core. The older Suite.luau remains a compatibility baseline for StateRuntime.

local Suite = {}

local PROFILES = {
	smoke = {
		warmup = 0,
		samples = 2,
		futureIterations = 1000,
		frames = 100,
		burst = 100,
		depth = 8,
		dormant = 32,
	},
	standard = {
		warmup = 1,
		samples = 5,
		futureIterations = 20000,
		frames = 1000,
		burst = 1000,
		depth = 24,
		dormant = 128,
	},
}

local function expectEqual(actual, expected, label)
	if actual ~= expected then
		error(string.format("%s: expected %s, got %s", label, tostring(expected), tostring(actual)), 3)
	end
end

local function sorted(values)
	local copy = {}
	for index, value in ipairs(values) do
		copy[index] = value
	end
	table.sort(copy)
	return copy
end

local function median(values)
	local copy = sorted(values)
	return copy[math.ceil(#copy / 2)]
end

local function caseFuture(FRP, config)
	return {
		id = "future/max_sync",
		operations = config.futureIterations,
		setup = function()
			return { checksum = 0 }
		end,
		run = function(fixture)
			local checksum = 0
			for index = 1, config.futureIterations do
				local future = FRP.Future.at(index % 17, function(value)
					return value + 1
				end):ap(FRP.Future.at(index % 23, index))
				local time, value = future:force()
				checksum += time + value
			end
			fixture.checksum = checksum
		end,
		verify = function(fixture)
			if fixture.checksum <= 0 then error("future checksum was not consumed", 2) end
		end,
	}
end

local function caseStableMerge(FRP, config)
	return {
		id = "event/stable_merge_ties",
		operations = config.burst * 2,
		setup = function()
			local host = FRP.newHost()
			local left, fireLeft = host:source()
			local right, fireRight = host:source()
			local count = 0
			local checksum = 0
			left:merge(right):subscribe(function(value)
				count += 1
				checksum += value
			end)
			return { host = host, fireLeft = fireLeft, fireRight = fireRight,
				count = function() return count end, checksum = function() return checksum end }
		end,
		run = function(fixture)
			fixture.host:frame(1, function()
				for index = 1, config.burst do
					fixture.fireRight(index)
					fixture.fireLeft(index)
				end
			end)
		end,
		verify = function(fixture)
			expectEqual(fixture.count(), config.burst * 2, "stable merge occurrence count")
			expectEqual(fixture.checksum(), config.burst * (config.burst + 1), "stable merge checksum")
		end,
		cleanup = function(fixture) fixture.host:dispose() end,
	}
end

local function caseEventPipeline(FRP, config)
	return {
		id = "event/push_pull_pipeline",
		operations = config.frames * config.depth,
		setup = function()
			local host = FRP.newHost()
			local source, fire = host:source()
			local tail = source
			local evaluations = 0
			for _ = 1, config.depth do
				tail = tail:map(function(value)
					evaluations += 1
					return value + 1
				end)
			end
			local last = 0
			tail:subscribe(function(value) last = value end)
			return { host = host, fire = fire, last = function() return last end,
				evaluations = function() return evaluations end }
		end,
		run = function(fixture)
			for frame = 1, config.frames do
				fixture.fire(frame, frame)
			end
			fixture.host:advanceTo(config.frames)
		end,
		verify = function(fixture)
			expectEqual(fixture.last(), config.frames + config.depth, "pipeline final value")
			expectEqual(fixture.evaluations(), config.frames * config.depth, "pipeline evaluation count")
		end,
		cleanup = function(fixture) fixture.host:dispose() end,
	}
end

local function caseReactiveApply(FRP, config)
	return {
		id = "reactive/applicative_simultaneous",
		operations = config.frames * 2,
		setup = function()
			local host = FRP.newHost()
			local functionChanges, setFunction = host:source()
			local valueChanges, setValue = host:source()
			local functions = FRP.stepper(function(value) return value end, functionChanges)
			local values = FRP.stepper(0, valueChanges)
			local output = functions:ap(values)
			local deliveries = 0
			output:changes():subscribe(function() deliveries += 1 end)
			return { host = host, setFunction = setFunction, setValue = setValue,
				output = output, deliveries = function() return deliveries end }
		end,
		run = function(fixture)
			for frame = 1, config.frames do
				fixture.host:frame(frame, function()
					fixture.setFunction(function(value) return value + frame end)
					fixture.setValue(frame)
				end)
			end
		end,
		verify = function(fixture)
			expectEqual(fixture.output:current(), config.frames * 2, "Reactive applicative final value")
			expectEqual(fixture.deliveries(), config.frames * 2, "Reactive applicative deliveries")
		end,
		cleanup = function(fixture) fixture.host:dispose() end,
	}
end

local function caseBehaviorPull(FRP, config)
	return {
		id = "behavior/continuous_pull",
		operations = config.frames,
		setup = function()
			local host = FRP.newHost()
			local evaluations = 0
			local behavior = FRP.fromFunction(host, function(time)
				evaluations += 1
				return time * 2
			end):map(function(value) return value + 1 end)
			local last = 0
			behavior:subscribe(function(value) last = value end)
			return { host = host, behavior = behavior, last = function() return last end,
				evaluations = function() return evaluations end }
		end,
		run = function(fixture)
			for frame = 1, config.frames do
				fixture.host:advanceTo(frame)
			end
		end,
		verify = function(fixture)
			expectEqual(fixture.last(), config.frames * 2 + 1, "Behavior pull final value")
			expectEqual(fixture.evaluations(), config.frames + 1, "Behavior pull count")
		end,
		cleanup = function(fixture) fixture.host:dispose() end,
	}
end

local function caseBehaviorSwitch(FRP, config)
	return {
		id = "behavior/switcher_churn",
		operations = config.frames,
		setup = function()
			local host = FRP.newHost()
			local switches, switch = host:source()
			local behavior = FRP.constant(host, 0):switcher(switches)
			local deliveries = 0
			behavior:subscribe(function() deliveries += 1 end)
			return { host = host, switch = switch, behavior = behavior,
				deliveries = function() return deliveries end }
		end,
		run = function(fixture)
			for frame = 1, config.frames do
				fixture.host:frame(frame, function()
					fixture.switch(FRP.constant(fixture.host, frame))
				end)
			end
		end,
		verify = function(fixture)
			expectEqual(fixture.behavior:current(), config.frames, "Behavior switch final value")
			expectEqual(fixture.deliveries(), config.frames + 1, "Behavior switch renders")
		end,
		cleanup = function(fixture) fixture.host:dispose() end,
	}
end

local function caseDormant(FRP, config)
	return {
		id = "event/dormant_quiescence",
		operations = config.frames,
		setup = function()
			local host = FRP.newHost()
			local source, fire = host:source()
			local calls = 0
			for _ = 1, config.dormant do
				source:map(function(value)
					calls += 1
					return value
				end)
			end
			return { host = host, fire = fire, calls = function() return calls end }
		end,
		run = function(fixture)
			for frame = 1, config.frames do
				fixture.fire(frame, frame)
			end
			fixture.host:advanceTo(config.frames)
		end,
		verify = function(fixture)
			expectEqual(fixture.calls(), 0, "dormant mapper calls")
		end,
		cleanup = function(fixture) fixture.host:dispose() end,
	}
end

local function caseImmutableCapture(FRP, config)
	return {
		id = "event/immutable_capture",
		operations = config.frames,
		setup = function()
			local host = FRP.newHost()
			local source, fire = host:source({
				capture = FRP.Immutable.serializable(),
			})
			local shared = { frame = 0 }
			local payload = { left = shared, right = shared }
			local checksum = 0
			local last = nil
			source:subscribe(function(value)
				checksum += value.left.frame
				last = value
			end)
			return {
				host = host,
				fire = fire,
				shared = shared,
				payload = payload,
				checksum = function() return checksum end,
				last = function() return last end,
			}
		end,
		run = function(fixture)
			for frame = 1, config.frames do
				fixture.shared.frame = frame
				fixture.host:frame(frame, function()
					fixture.fire(fixture.payload)
				end)
			end
			fixture.shared.frame = -1
		end,
		verify = function(fixture)
			expectEqual(
				fixture.checksum(),
				config.frames * (config.frames + 1) / 2,
				"immutable capture checksum"
			)
			local last = fixture.last()
			expectEqual(last.left.frame, config.frames, "immutable capture detached value")
			expectEqual(last.left, last.right, "immutable capture shared alias")
			expectEqual(table.isfrozen(last), true, "immutable capture frozen root")
			expectEqual(table.isfrozen(last.left), true, "immutable capture frozen child")
		end,
		cleanup = function(fixture) fixture.host:dispose() end,
	}
end

function Suite.run(FRP, options)
	options = options or {}
	local profileName = options.profile or "standard"
	local base = PROFILES[profileName]
	if base == nil then error("unknown FRP benchmark profile '" .. tostring(profileName) .. "'", 2) end
	local config = {}
	for key, value in pairs(base) do config[key] = value end
	local now = options.now or os.clock
	local collect = options.collectGarbage
	local cases = {
		caseFuture(FRP, config),
		caseStableMerge(FRP, config),
		caseEventPipeline(FRP, config),
		caseReactiveApply(FRP, config),
		caseBehaviorPull(FRP, config),
		caseBehaviorSwitch(FRP, config),
		caseDormant(FRP, config),
		caseImmutableCapture(FRP, config),
	}

	print(string.format("Push-Pull FRP benchmark | version=%s | profile=%s | mode=%s",
		tostring(options.version or FRP.VERSION), profileName, tostring(options.mode or "unknown")))
	for _, benchmark in ipairs(cases) do
		local durations = {}
		for sample = 1, config.warmup + config.samples do
			if collect ~= nil then collect() end
			local fixture = benchmark.setup()
			local started = now()
			benchmark.run(fixture)
			local elapsed = now() - started
			benchmark.verify(fixture)
			if benchmark.cleanup ~= nil then benchmark.cleanup(fixture) end
			if sample > config.warmup then durations[#durations + 1] = elapsed end
		end
		local elapsed = median(durations)
		local rate = if elapsed > 0 then benchmark.operations / elapsed else math.huge
		print(string.format("BENCH %-36s median=%8.3fms rate=%10.2f/s ops=%d",
			benchmark.id, elapsed * 1000, rate, benchmark.operations))
	end
	print(string.format("PASS %d Push-Pull FRP benchmark workloads", #cases))
end

return Suite
