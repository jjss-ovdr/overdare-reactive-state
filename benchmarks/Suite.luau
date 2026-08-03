--!nonstrict

-- Engine-neutral benchmark suite. The entry point injects Runtime, Network,
-- timing, and optional GC hooks so the exact same workloads can run in the
-- standalone Luau CLI and in OVERDARE Studio.

local Suite = {}

local DEFAULTS = {
	profile = "standard",
	warmup = 1,
	samples = 5,
	linearDepths = { 1, 10, 100 },
	linearIterations = 100,
	fanoutWidths = { 10, 100, 1000 },
	fanoutIterations = 30,
	diamondWidth = 100,
	diamondIterations = 40,
	dynamicBranches = 128,
	dynamicIterations = 400,
	agents = 1000,
	sparseDirtyCounts = { 10, 100 },
	sparseTicks = 40,
	denseTicks = 8,
	burstWidths = { 100, 1000 },
	burstTicks = 12,
	historyAtoms = 16,
	historyTicks = 180,
	historySteadyTicks = 180,
	historyIntervals = { 1, 6, 30 },
	historyCapacities = { 30, 180 },
	historyTableSize = 32,
	rollbackAtoms = 8,
	rollbackTicks = 180,
	rollbackDistances = { 1, 15, 60, 120, 179 },
	networkFields = 64,
	networkClientCounts = { 1, 8, 32 },
	networkTicks = 12,
	networkEndToEndTicks = 20,
}

local PROFILES = {
	smoke = {
		warmup = 0,
		samples = 2,
		linearDepths = { 1, 10, 50 },
		linearIterations = 20,
		fanoutWidths = { 10, 100 },
		fanoutIterations = 10,
		diamondWidth = 20,
		diamondIterations = 10,
		dynamicBranches = 16,
		dynamicIterations = 40,
		agents = 100,
		sparseDirtyCounts = { 10 },
		sparseTicks = 10,
		denseTicks = 3,
		burstWidths = { 10, 100 },
		burstTicks = 4,
		historyAtoms = 4,
		historyTicks = 30,
		historySteadyTicks = 30,
		historyIntervals = { 1, 6 },
		historyCapacities = { 10, 30 },
		historyTableSize = 8,
		rollbackAtoms = 4,
		rollbackTicks = 30,
		rollbackDistances = { 1, 15, 29 },
		networkFields = 16,
		networkClientCounts = { 1, 4 },
		networkTicks = 4,
		networkEndToEndTicks = 6,
	},
	standard = {},
	stress = {
		warmup = 2,
		samples = 7,
		linearIterations = 300,
		fanoutIterations = 100,
		diamondIterations = 100,
		dynamicIterations = 1200,
		sparseTicks = 120,
		denseTicks = 30,
		burstTicks = 40,
		networkTicks = 40,
		networkEndToEndTicks = 60,
	},
}

local function shallowCopy(source)
	local result = {}
	for key, value in pairs(source) do
		result[key] = value
	end
	return result
end

local function resolveConfig(options)
	local config = shallowCopy(DEFAULTS)
	local profileName = options.profile or DEFAULTS.profile
	local profile = PROFILES[profileName]
	if profile == nil then
		error("unknown benchmark profile '" .. tostring(profileName) .. "'", 3)
	end
	for key, value in pairs(profile) do
		config[key] = value
	end
	for key, value in pairs(options) do
		if config[key] ~= nil then
			config[key] = value
		end
	end
	config.profile = profileName
	return config
end

local function expect(condition, message)
	if not condition then
		error("benchmark correctness failure: " .. message, 3)
	end
end

local function expectEqual(actual, expected, message)
	if actual ~= expected then
		error(string.format(
			"benchmark correctness failure: %s (expected %s, got %s)",
			message,
			tostring(expected),
			tostring(actual)
		), 3)
	end
end

local function sortedCopy(values)
	local result = {}
	for index, value in ipairs(values) do
		result[index] = value
	end
	table.sort(result)
	return result
end

local function percentile(values, fraction)
	local sorted = sortedCopy(values)
	local index = math.ceil(#sorted * fraction)
	if index < 1 then
		index = 1
	elseif index > #sorted then
		index = #sorted
	end
	return sorted[index]
end

local function statistics(values)
	local sorted = sortedCopy(values)
	local total = 0
	for _, value in ipairs(sorted) do
		total += value
	end
	return {
		min = sorted[1],
		median = percentile(sorted, 0.5),
		p95 = percentile(sorted, 0.95),
		max = sorted[#sorted],
		mean = total / #sorted,
	}
end

local function formatMilliseconds(seconds)
	return string.format("%.3f", seconds * 1000)
end

local function formatRate(rate)
	if rate >= 1000000 then
		return string.format("%.2fM", rate / 1000000)
	elseif rate >= 1000 then
		return string.format("%.2fk", rate / 1000)
	end
	return string.format("%.2f", rate)
end

local function formatMemory(value)
	if value == nil then
		return "n/a"
	end
	return string.format("%+.1f", value)
end

local function makeLinearCase(Runtime, depth, iterations)
	return {
		id = "linear_chain/d" .. tostring(depth),
		configuration = string.format("depth=%d, commits=%d, watched pull", depth, iterations),
		unit = "commit",
		operations = iterations,
		setup = function()
			local runtime = Runtime.new()
			local source = runtime:atom(0)
			local tail = source
			local evaluations = 0
			for _ = 1, depth do
				local dependency = tail
				tail = runtime:computed(function()
					evaluations += 1
					return dependency:get() + 1
				end)
			end
			local watchCount = 0
			local checksum = 0
			runtime:watch(tail, function(value)
				watchCount += 1
				checksum += value
			end, { initial = false })
			return {
				runtime = runtime,
				source = source,
				tail = tail,
				evaluations = function() return evaluations end,
				watchCount = function() return watchCount end,
				checksum = function() return checksum end,
			}
		end,
		run = function(fixture)
			for value = 1, iterations do
				fixture.source:set(value)
			end
		end,
		verify = function(fixture)
			expectEqual(fixture.tail:get(), iterations + depth, "linear final value")
			expectEqual(fixture.evaluations(), depth * (iterations + 1), "linear evaluation count")
			expectEqual(fixture.watchCount(), iterations, "linear watcher count")
			local before = fixture.evaluations()
			for _ = 1, 20 do
				fixture.tail:get()
			end
			expectEqual(fixture.evaluations(), before, "clean linear pull must remain cached")
			expect(fixture.checksum() > 0, "linear checksum must be consumed")
		end,
		cleanup = function(fixture)
			fixture.runtime:dispose()
		end,
	}
end

local function makeFanoutCase(Runtime, width, iterations)
	return {
		id = "fan_out/w" .. tostring(width),
		configuration = string.format("computed=%d, watches=%d, commits=%d", width, width, iterations),
		unit = "delivery",
		operations = width * iterations,
		setup = function()
			local runtime = Runtime.new()
			local source = runtime:atom(0)
			local leaves = {}
			local evaluations = 0
			local watchCount = 0
			local checksum = 0
			for index = 1, width do
				local offset = index
				local leaf = runtime:computed(function()
					evaluations += 1
					return source:get() + offset
				end)
				leaves[index] = leaf
				runtime:watch(leaf, function(value)
					watchCount += 1
					checksum += value
				end, { initial = false })
			end
			return {
				runtime = runtime,
				source = source,
				leaves = leaves,
				evaluations = function() return evaluations end,
				watchCount = function() return watchCount end,
				checksum = function() return checksum end,
			}
		end,
		run = function(fixture)
			for value = 1, iterations do
				fixture.source:set(value)
			end
		end,
		verify = function(fixture)
			expectEqual(fixture.evaluations(), width * (iterations + 1), "fan-out evaluation count")
			expectEqual(fixture.watchCount(), width * iterations, "fan-out watcher count")
			expectEqual(fixture.leaves[width]:get(), iterations + width, "fan-out final leaf")
			expect(fixture.checksum() > 0, "fan-out checksum must be consumed")
		end,
		cleanup = function(fixture)
			fixture.runtime:dispose()
		end,
	}
end

local function makeDiamondCase(Runtime, width, iterations)
	return {
		id = "diamond/w" .. tostring(width),
		configuration = string.format("diamonds=%d, commits=%d, two staged writes", width, iterations),
		unit = "diamond_commit",
		operations = width * iterations,
		setup = function()
			local runtime = Runtime.new()
			local source = runtime:atom(0)
			local sinks = {}
			local evaluations = 0
			local watchCount = 0
			for index = 1, width do
				local offset = index
				local left = runtime:computed(function()
					evaluations += 1
					return source:get() + offset
				end)
				local right = runtime:computed(function()
					evaluations += 1
					return source:get() * 2 + offset
				end)
				local sink = runtime:computed(function()
					evaluations += 1
					return left:get() + right:get()
				end)
				sinks[index] = sink
				runtime:watch(sink, function()
					watchCount += 1
				end, { initial = false })
			end
			return {
				runtime = runtime,
				source = source,
				sinks = sinks,
				evaluations = function() return evaluations end,
				watchCount = function() return watchCount end,
			}
		end,
		run = function(fixture)
			for tick = 1, iterations do
				fixture.runtime:transaction(function()
					fixture.source:set(tick * 2 - 1)
					fixture.source:set(tick * 2)
				end)
			end
		end,
		verify = function(fixture)
			expectEqual(fixture.evaluations(), 3 * width * (iterations + 1), "diamond evaluation count")
			expectEqual(fixture.watchCount(), width * iterations, "diamond watcher coalescing")
			local sourceValue = iterations * 2
			expectEqual(fixture.sinks[width]:get(), 3 * sourceValue + 2 * width, "diamond final value")
		end,
		cleanup = function(fixture)
			fixture.runtime:dispose()
		end,
	}
end

local function makeDynamicCase(Runtime, branchCount, iterations)
	return {
		id = "dynamic_dependency/b" .. tostring(branchCount),
		configuration = string.format("branches=%d, switches=%d", branchCount, iterations),
		unit = "switch",
		operations = iterations,
		setup = function()
			local runtime = Runtime.new()
			local selector = runtime:atom(1)
			local branches = {}
			for index = 1, branchCount do
				branches[index] = runtime:atom(index * 1000)
			end
			local evaluations = 0
			local selected = runtime:computed(function()
				evaluations += 1
				return branches[selector:get()]:get()
			end)
			local watchCount = 0
			runtime:watch(selected, function()
				watchCount += 1
			end, { initial = false })
			return {
				runtime = runtime,
				selector = selector,
				branches = branches,
				selected = selected,
				evaluations = function() return evaluations end,
				watchCount = function() return watchCount end,
			}
		end,
		run = function(fixture)
			for iteration = 1, iterations do
				fixture.selector:set(iteration % branchCount + 1)
			end
		end,
		verify = function(fixture)
			local finalIndex = iterations % branchCount + 1
			expectEqual(fixture.selected:get(), finalIndex * 1000, "dynamic final value")
			expectEqual(fixture.evaluations(), iterations + 1, "dynamic evaluation count")
			expectEqual(fixture.watchCount(), iterations, "dynamic watcher count")
			local inactiveIndex = finalIndex % branchCount + 1
			local beforeEvaluations = fixture.evaluations()
			local beforeWatches = fixture.watchCount()
			fixture.branches[inactiveIndex]:set(-1)
			expectEqual(fixture.evaluations(), beforeEvaluations, "inactive dynamic source must be disconnected")
			expectEqual(fixture.watchCount(), beforeWatches, "inactive dynamic source must not notify")
			fixture.branches[finalIndex]:set(-2)
			expectEqual(fixture.evaluations(), beforeEvaluations + 1, "active dynamic source must evaluate once")
			expectEqual(fixture.watchCount(), beforeWatches + 1, "active dynamic source must notify once")
			for index, branch in ipairs(fixture.branches) do
				local expectedObservers = if index == finalIndex then 1 else 0
				expectEqual(branch:getDebugInfo().observers, expectedObservers, "dynamic observer cleanup")
			end
		end,
		cleanup = function(fixture)
			fixture.runtime:dispose()
		end,
	}
end

local function makeAgentCase(Runtime, id, agentCount, dirtyPerTick, ticks)
	return {
		id = id,
		configuration = string.format(
			"agents=%d, dirty/tick=%d (%.1f%%), ticks=%d",
			agentCount,
			dirtyPerTick,
			dirtyPerTick / agentCount * 100,
			ticks
		),
		unit = "agent_update",
		operations = dirtyPerTick * ticks,
		setup = function()
			local runtime = Runtime.new()
			local atoms = {}
			local computed = {}
			local evaluations = 0
			local watchCount = 0
			local checksum = 0
			for index = 1, agentCount do
				local agentIndex = index
				local atom = runtime:atom(0)
				local output = runtime:computed(function()
					evaluations += 1
					return atom:get() * 2 + agentIndex
				end)
				atoms[index] = atom
				computed[index] = output
				runtime:watch(output, function(value)
					watchCount += 1
					checksum += value
				end, { initial = false })
			end
			return {
				runtime = runtime,
				atoms = atoms,
				computed = computed,
				evaluations = function() return evaluations end,
				watchCount = function() return watchCount end,
				checksum = function() return checksum end,
			}
		end,
		run = function(fixture)
			for tick = 1, ticks do
				fixture.runtime:transaction(function()
					local base = (tick - 1) * dirtyPerTick
					for offset = 1, dirtyPerTick do
						local index = (base + offset - 1) % agentCount + 1
						fixture.atoms[index]:set(tick * 100000 + index)
					end
				end)
			end
		end,
		verify = function(fixture)
			local updates = dirtyPerTick * ticks
			expectEqual(fixture.evaluations(), agentCount + updates, id .. " evaluation count")
			expectEqual(fixture.watchCount(), updates, id .. " watcher count")
			expect(fixture.checksum() > 0, id .. " checksum must be consumed")
		end,
		cleanup = function(fixture)
			fixture.runtime:dispose()
		end,
	}
end

local function makeBurstCase(Runtime, width, ticks)
	return {
		id = "transaction_burst/w" .. tostring(width),
		configuration = string.format("atoms=%d, staged writes/atom=2, commits=%d", width, ticks),
		unit = "staged_write",
		operations = width * ticks * 2,
		setup = function()
			local runtime = Runtime.new()
			local atoms = {}
			for index = 1, width do
				atoms[index] = runtime:atom(0)
			end
			local evaluations = 0
			local sum = runtime:computed(function()
				evaluations += 1
				local total = 0
				for _, atom in ipairs(atoms) do
					total += atom:get()
				end
				return total
			end)
			local watchCount = 0
			runtime:watch(sum, function()
				watchCount += 1
			end, { initial = false })
			return {
				runtime = runtime,
				atoms = atoms,
				sum = sum,
				evaluations = function() return evaluations end,
				watchCount = function() return watchCount end,
				changedNodes = 0,
			}
		end,
		run = function(fixture)
			for tick = 1, ticks do
				local changeSet = fixture.runtime:transaction(function()
					for _, atom in ipairs(fixture.atoms) do
						atom:set(tick * 2 - 1)
						atom:set(tick * 2)
					end
				end)
				fixture.changedNodes += #changeSet.changedNodes
			end
		end,
		verify = function(fixture)
			expectEqual(fixture.sum:get(), width * ticks * 2, "transaction burst final sum")
			expectEqual(fixture.evaluations(), ticks + 1, "transaction burst aggregate evaluation count")
			expectEqual(fixture.watchCount(), ticks, "transaction burst watcher coalescing")
			expectEqual(fixture.changedNodes, width * ticks, "transaction burst unique changed nodes")
			for _, atom in ipairs(fixture.atoms) do
				expectEqual(atom:getRevision(), ticks, "transaction burst atom revision")
			end
			local revision = fixture.atoms[1]:getRevision()
			local watches = fixture.watchCount()
			local noOp = fixture.runtime:transaction(function()
				local value = fixture.atoms[1]:get()
				fixture.atoms[1]:set(value)
				fixture.atoms[1]:set(value)
			end)
			expectEqual(#noOp.changedNodes, 0, "transaction burst net no-op")
			expectEqual(fixture.atoms[1]:getRevision(), revision, "net no-op revision")
			expectEqual(fixture.watchCount(), watches, "net no-op watcher")
		end,
		cleanup = function(fixture)
			fixture.runtime:dispose()
		end,
	}
end

local function createHistoryAtoms(runtime, count, tableSize)
	local atoms = {}
	for index = 1, count do
		if tableSize == nil then
			atoms[index] = runtime:atom(0)
		else
			local value = {}
			for item = 1, tableSize do
				value[item] = index * 1000 + item
			end
			atoms[index] = runtime:atom(value)
		end
	end
	return atoms
end

local function stepHistoryFixture(fixture, tick)
	fixture.runtime:step(tick, function()
		local index = (tick - 1) % #fixture.atoms + 1
		local atom = fixture.atoms[index]
		if fixture.tableSize == nil then
			atom:set(tick)
		else
			atom:mutate(function(value)
				value[1] = tick
				value[2] = index
			end)
		end
	end)
end

local function makeHistoryOffCase(Runtime, atomCount, ticks)
	return {
		id = "history/off",
		configuration = string.format("tracked atoms=%d, ticks=%d, history=false", atomCount, ticks),
		unit = "tick",
		operations = ticks,
		setup = function()
			local runtime = Runtime.new({ deterministic = true, history = false })
			return { runtime = runtime, atoms = createHistoryAtoms(runtime, atomCount), tableSize = nil }
		end,
		run = function(fixture)
			for tick = 1, ticks do
				stepHistoryFixture(fixture, tick)
			end
		end,
		verify = function(fixture)
			expectEqual(fixture.runtime:getTick(), ticks, "history-off final tick")
			expectEqual(fixture.runtime:getDebugSnapshot().historyCount, 0, "history-off must retain no entries")
		end,
		cleanup = function(fixture) fixture.runtime:dispose() end,
	}
end

local function makeManualSnapshotCase(Runtime, atomCount, ticks, interval)
	return {
		id = "history/manual_interval_" .. tostring(interval),
		configuration = string.format("atoms=%d, ticks=%d, explicit snapshot every %d", atomCount, ticks, interval),
		unit = "tick",
		operations = ticks,
		setup = function()
			local runtime = Runtime.new({ deterministic = true, history = false })
			return {
				runtime = runtime,
				atoms = createHistoryAtoms(runtime, atomCount),
				tableSize = nil,
				snapshots = {},
			}
		end,
		run = function(fixture)
			for tick = 1, ticks do
				stepHistoryFixture(fixture, tick)
				if tick % interval == 0 then
					fixture.snapshots[#fixture.snapshots + 1] = fixture.runtime:snapshot(tick)
				end
			end
		end,
		verify = function(fixture)
			expectEqual(#fixture.snapshots, math.floor(ticks / interval), "manual snapshot count")
			expectEqual(fixture.runtime:getDebugSnapshot().historyCount, 0, "manual snapshots must not enable history")
			if ticks % interval == 0 then
				expectEqual(
					fixture.snapshots[#fixture.snapshots].stateHash,
					fixture.runtime:getStateHash(),
					"manual final snapshot hash"
				)
			end
		end,
		cleanup = function(fixture) fixture.runtime:dispose() end,
	}
end

local function makeHistoryCapacityCase(Runtime, atomCount, ticks, capacity, tableSize)
	local suffix = if tableSize == nil then "scalar" else "table" .. tostring(tableSize)
	return {
		id = string.format("history/snapshot_c%d_%s", capacity, suffix),
		configuration = string.format(
			"atoms=%d, ticks=%d, capacity=%d, payload=%s",
			atomCount,
			ticks,
			capacity,
			if tableSize == nil then "scalar" else "table[" .. tostring(tableSize) .. "]"
		),
		unit = "tick",
		operations = ticks,
		setup = function()
			local runtime = Runtime.new({
				deterministic = true,
				history = { capacity = capacity, strategy = "snapshot" },
			})
			return {
				runtime = runtime,
				atoms = createHistoryAtoms(runtime, atomCount, tableSize),
				tableSize = tableSize,
			}
		end,
		run = function(fixture)
			for tick = 1, ticks do
				stepHistoryFixture(fixture, tick)
			end
		end,
		verify = function(fixture)
			local count = math.min(capacity, ticks + 1)
			expectEqual(fixture.runtime:getDebugSnapshot().historyCount, count, "history capacity")
			local oldest = ticks - count + 1
			expectEqual(fixture.runtime:snapshot(oldest).tick, oldest, "oldest retained history tick")
			if oldest > 0 then
				local ok = pcall(fixture.runtime.snapshot, fixture.runtime, oldest - 1)
				expect(not ok, "evicted history tick must not be readable")
			end
			expectEqual(fixture.runtime:snapshot().stateHash, fixture.runtime:getStateHash(), "history final hash")
		end,
		cleanup = function(fixture) fixture.runtime:dispose() end,
	}
end

local function makeHistoryEvictionSteadyCase(Runtime, atomCount, capacity, steadyTicks)
	return {
		id = "history/eviction_steady_c" .. tostring(capacity),
		configuration = string.format(
			"atoms=%d, prefilled capacity=%d, timed eviction ticks=%d",
			atomCount,
			capacity,
			steadyTicks
		),
		unit = "evicting_tick",
		operations = steadyTicks,
		setup = function()
			local runtime = Runtime.new({
				deterministic = true,
				history = { capacity = capacity, strategy = "snapshot" },
			})
			local fixture = {
				runtime = runtime,
				atoms = createHistoryAtoms(runtime, atomCount),
				tableSize = nil,
			}
			for tick = 1, capacity - 1 do
				stepHistoryFixture(fixture, tick)
			end
			expectEqual(runtime:getDebugSnapshot().historyCount, capacity, "history steady prefill")
			return fixture
		end,
		run = function(fixture)
			for offset = 1, steadyTicks do
				stepHistoryFixture(fixture, capacity - 1 + offset)
			end
		end,
		verify = function(fixture)
			local finalTick = capacity - 1 + steadyTicks
			local oldest = finalTick - capacity + 1
			expectEqual(fixture.runtime:getDebugSnapshot().historyCount, capacity, "history steady capacity")
			expectEqual(fixture.runtime:snapshot(oldest).tick, oldest, "history steady oldest tick")
			local ok = pcall(fixture.runtime.snapshot, fixture.runtime, oldest - 1)
			expect(not ok, "history steady evicted tick must be absent")
		end,
		cleanup = function(fixture) fixture.runtime:dispose() end,
	}
end

local function makeRollbackCase(Runtime, atomCount, ticks, distance)
	return {
		id = "rollback_replay/d" .. tostring(distance),
		configuration = string.format("atoms=%d, total ticks=%d, replay distance=%d", atomCount, ticks, distance),
		unit = "replayed_tick",
		operations = distance,
		setup = function()
			local runtime = Runtime.new({
				deterministic = true,
				history = { capacity = ticks + 1, strategy = "snapshot" },
			})
			local atoms = createHistoryAtoms(runtime, atomCount)
			local inputs = {}
			for tick = 1, ticks do
				local input = {}
				for index = 1, atomCount do
					input[index] = (tick * (index * 2 + 1)) % 17 + 1
				end
				inputs[tick] = input
			end
			local function applyTick(tick)
				local input = inputs[tick]
				for index, atom in ipairs(atoms) do
					atom:set(atom:get() + input[index])
				end
			end
			local total = runtime:computed(function()
				local value = 0
				for _, atom in ipairs(atoms) do
					value += atom:get()
				end
				return value
			end)
			local watchCount = 0
			runtime:watch(total, function()
				watchCount += 1
			end, { initial = false, replay = "coalesce" })
			for tick = 1, ticks do
				runtime:step(tick, function()
					applyTick(tick)
				end)
			end
			local expectedValues = {}
			for index, atom in ipairs(atoms) do
				expectedValues[index] = atom:get()
			end
			return {
				runtime = runtime,
				atoms = atoms,
				applyTick = applyTick,
				expectedHash = runtime:getStateHash(),
				expectedValues = expectedValues,
				watchCount = function() return watchCount end,
				watchCountBefore = watchCount,
			}
		end,
		run = function(fixture)
			fixture.runtime:replay(ticks - distance, ticks, function(_, tick)
				fixture.applyTick(tick)
			end)
		end,
		verify = function(fixture)
			expectEqual(fixture.runtime:getTick(), ticks, "replay final tick")
			expectEqual(fixture.runtime:getStateHash(), fixture.expectedHash, "replay final canonical hash")
			expectEqual(fixture.watchCount(), fixture.watchCountBefore, "equal replay must coalesce watcher")
			for index, atom in ipairs(fixture.atoms) do
				expectEqual(atom:get(), fixture.expectedValues[index], "replay atom " .. tostring(index))
			end
		end,
		cleanup = function(fixture) fixture.runtime:dispose() end,
	}
end

local function makeNetworkBuildCase(Runtime, Network, fieldCount, clientCount, ticks)
	return {
		id = "network_patch/build_c" .. tostring(clientCount),
		configuration = string.format("fields=%d, clients=%d, visibility=50%%, ticks=%d", fieldCount, clientCount, ticks),
		unit = "client_patch",
		operations = clientCount * ticks,
		setup = function()
			local runtime = Runtime.new()
			local sources = {}
			local fields = {}
			local visibleByClient = {}
			for clientId = 1, clientCount do
				visibleByClient[clientId] = 0
			end
			for index = 1, fieldCount do
				local fieldIndex = index
				local source = runtime:atom(index)
				sources[index] = source
				fields[index] = {
					key = string.format("field%03d", index),
					direction = Network.SERVER_TO_CLIENT,
					source = source,
					visibility = function(clientId)
						return (fieldIndex + clientId) % 2 == 0
					end,
				}
				for clientId = 1, clientCount do
					if (fieldIndex + clientId) % 2 == 0 then
						visibleByClient[clientId] += 1
					end
				end
			end
			local schema = Network.defineSchema(fields, {
				schemaVersion = 1,
				maxFields = fieldCount,
			})
			local server = Network.createServer({ schema = schema, runtime = runtime })
			for clientId = 1, clientCount do
				local snapshot = server:createSnapshot(clientId, 0)
				expect(snapshot.ok, "network baseline snapshot")
			end
			return {
				runtime = runtime,
				sources = sources,
				server = server,
				visibleByClient = visibleByClient,
				lastPayloads = {},
				failed = nil,
				changeCount = 0,
			}
		end,
		run = function(fixture)
			for tick = 1, ticks do
				fixture.runtime:transaction(function()
					for index, source in ipairs(fixture.sources) do
						source:set(tick * 1000 + index)
					end
				end)
				for clientId = 1, clientCount do
					local result = fixture.server:createPatch(clientId, tick)
					if not result.ok then
						fixture.failed = result.message or result.code
					else
						fixture.lastPayloads[clientId] = result.payload
						fixture.changeCount += #result.payload.changes
					end
				end
			end
		end,
		verify = function(fixture)
			expect(fixture.failed == nil, "network patch build failed: " .. tostring(fixture.failed))
			local expectedChanges = 0
			for clientId = 1, clientCount do
				local visible = fixture.visibleByClient[clientId]
				expectedChanges += visible * ticks
				local payload = fixture.lastPayloads[clientId]
				expectEqual(#payload.changes, visible, "client visibility change count")
				expectEqual(payload.sequence, ticks + 1, "client patch sequence")
				expectEqual(payload.revision, ticks + 1, "client patch revision")
				for _, change in ipairs(payload.changes) do
					local index = tonumber(string.match(change.key, "(%d+)$"))
					expect((index + clientId) % 2 == 0, "patch leaked an invisible field")
				end
			end
			expectEqual(fixture.changeCount, expectedChanges, "network total visible changes")
		end,
		cleanup = function(fixture)
			fixture.server:dispose()
			fixture.runtime:dispose()
		end,
	}
end

local function makeNetworkEndToEndCase(Runtime, Network, fieldCount, ticks)
	return {
		id = "network_patch/end_to_end",
		configuration = string.format("fields=%d, one visibility edge, build+receive ticks=%d", fieldCount, ticks),
		unit = "patch_roundtrip",
		operations = ticks,
		setup = function()
			local serverRuntime = Runtime.new()
			local clientRuntime = Runtime.new()
			local sources = {}
			local targets = {}
			local fields = {}
			for index = 1, fieldCount do
				local fieldIndex = index
				local source = serverRuntime:atom(index)
				local target = clientRuntime:atom(0)
				sources[index] = source
				targets[index] = target
				fields[index] = {
					key = string.format("field%03d", index),
					direction = Network.SERVER_TO_CLIENT,
					source = source,
					target = target,
					visibility = function(_, _, context)
						return fieldIndex <= context.visibleCount
					end,
				}
			end
			local schema = Network.defineSchema(fields, {
				schemaVersion = 1,
				maxFields = fieldCount,
			})
			local server = Network.createServer({ schema = schema, runtime = serverRuntime })
			local client = Network.createClient({ schema = schema, runtime = clientRuntime })
			local snapshot = server:createSnapshot("client", 0, { visibleCount = fieldCount })
			expect(snapshot.ok, "network end-to-end snapshot build")
			expect(client:receive(snapshot.payload).ok, "network end-to-end snapshot receive")
			return {
				serverRuntime = serverRuntime,
				clientRuntime = clientRuntime,
				sources = sources,
				targets = targets,
				server = server,
				client = client,
				lastPayload = nil,
				lastResult = nil,
				failed = nil,
				changeCount = 0,
			}
		end,
		run = function(fixture)
			for tick = 1, ticks do
				local visibleCount = if tick % 2 == 1 then fieldCount - 1 else fieldCount
				local built = fixture.server:createPatch("client", tick, { visibleCount = visibleCount })
				if not built.ok then
					fixture.failed = built.message or built.code
				else
					fixture.lastPayload = built.payload
					fixture.changeCount += #built.payload.changes
					local received = fixture.client:receive(built.payload)
					fixture.lastResult = received
					if not received.ok then
						fixture.failed = received.message or received.code
					end
				end
			end
		end,
		verify = function(fixture)
			expect(fixture.failed == nil, "network end-to-end failed: " .. tostring(fixture.failed))
			expectEqual(fixture.changeCount, ticks, "visibility edge must produce one change per patch")
			expectEqual(#fixture.lastPayload.changes, 1, "last visibility patch change count")
			expectEqual(fixture.client:getStatus().revision, ticks + 1, "client final revision")
			for index = 1, fieldCount do
				expectEqual(fixture.targets[index]:get(), index, "client target " .. tostring(index))
			end
		end,
		cleanup = function(fixture)
			fixture.client:dispose()
			fixture.server:dispose()
			fixture.clientRuntime:dispose()
			fixture.serverRuntime:dispose()
		end,
	}
end

local function makeNetworkApplyCase(Runtime, Network, fieldCount, ticks)
	return {
		id = "network_patch/apply_only",
		configuration = string.format("fields=%d, prebuilt sequential visibility patches=%d", fieldCount, ticks),
		unit = "patch_apply",
		operations = ticks,
		setup = function()
			local serverRuntime = Runtime.new()
			local clientRuntime = Runtime.new()
			local fields = {}
			local targets = {}
			for index = 1, fieldCount do
				local fieldIndex = index
				local source = serverRuntime:atom(index)
				local target = clientRuntime:atom(0)
				targets[index] = target
				fields[index] = {
					key = string.format("field%03d", index),
					direction = Network.SERVER_TO_CLIENT,
					source = source,
					target = target,
					visibility = function(_, _, context)
						return fieldIndex <= context.visibleCount
					end,
				}
			end
			local schema = Network.defineSchema(fields, {
				schemaVersion = 1,
				maxFields = fieldCount,
			})
			local server = Network.createServer({ schema = schema, runtime = serverRuntime })
			local client = Network.createClient({ schema = schema, runtime = clientRuntime })
			local snapshot = server:createSnapshot("client", 0, { visibleCount = fieldCount })
			expect(snapshot.ok, "network apply snapshot build")
			expect(client:receive(snapshot.payload).ok, "network apply snapshot receive")
			local payloads = {}
			for tick = 1, ticks do
				local visibleCount = if tick % 2 == 1 then fieldCount - 1 else fieldCount
				local patch = server:createPatch("client", tick, { visibleCount = visibleCount })
				expect(patch.ok, "network apply patch build")
				payloads[tick] = patch.payload
			end
			return {
				serverRuntime = serverRuntime,
				clientRuntime = clientRuntime,
				server = server,
				client = client,
				targets = targets,
				payloads = payloads,
				failed = nil,
				changeCount = 0,
			}
		end,
		run = function(fixture)
			for _, payload in ipairs(fixture.payloads) do
				fixture.changeCount += #payload.changes
				local result = fixture.client:receive(payload)
				if not result.ok then
					fixture.failed = result.message or result.code
				end
			end
		end,
		verify = function(fixture)
			expect(fixture.failed == nil, "network apply failed: " .. tostring(fixture.failed))
			expectEqual(fixture.changeCount, ticks, "network apply one edge change per payload")
			expectEqual(fixture.client:getStatus().revision, ticks + 1, "network apply final revision")
			for index = 1, fieldCount do
				expectEqual(fixture.targets[index]:get(), index, "network apply target " .. tostring(index))
			end
		end,
		cleanup = function(fixture)
			fixture.client:dispose()
			fixture.server:dispose()
			fixture.clientRuntime:dispose()
			fixture.serverRuntime:dispose()
		end,
	}
end

local function buildCases(Runtime, Network, config)
	local cases = {}
	local function add(case)
		cases[#cases + 1] = case
	end

	for _, depth in ipairs(config.linearDepths) do
		add(makeLinearCase(Runtime, depth, config.linearIterations))
	end
	for _, width in ipairs(config.fanoutWidths) do
		add(makeFanoutCase(Runtime, width, config.fanoutIterations))
	end
	add(makeDiamondCase(Runtime, config.diamondWidth, config.diamondIterations))
	add(makeDynamicCase(Runtime, config.dynamicBranches, config.dynamicIterations))
	for _, dirty in ipairs(config.sparseDirtyCounts) do
		add(makeAgentCase(
			Runtime,
			"sparse_ai/d" .. tostring(dirty),
			config.agents,
			dirty,
			config.sparseTicks
		))
	end
	add(makeAgentCase(Runtime, "dense_ai/all", config.agents, config.agents, config.denseTicks))
	for _, width in ipairs(config.burstWidths) do
		add(makeBurstCase(Runtime, width, config.burstTicks))
	end
	add(makeHistoryOffCase(Runtime, config.historyAtoms, config.historyTicks))
	for _, interval in ipairs(config.historyIntervals) do
		add(makeManualSnapshotCase(Runtime, config.historyAtoms, config.historyTicks, interval))
	end
	for _, capacity in ipairs(config.historyCapacities) do
		add(makeHistoryCapacityCase(Runtime, config.historyAtoms, config.historyTicks, capacity, nil))
	end
	add(makeHistoryEvictionSteadyCase(
		Runtime,
		config.historyAtoms,
		config.historyCapacities[1],
		config.historySteadyTicks
	))
	add(makeHistoryCapacityCase(
		Runtime,
		config.historyAtoms,
		config.historyTicks,
		config.historyTicks,
		config.historyTableSize
	))
	for _, distance in ipairs(config.rollbackDistances) do
		add(makeRollbackCase(Runtime, config.rollbackAtoms, config.rollbackTicks, distance))
	end
	for _, clientCount in ipairs(config.networkClientCounts) do
		add(makeNetworkBuildCase(Runtime, Network, config.networkFields, clientCount, config.networkTicks))
	end
	add(makeNetworkApplyCase(Runtime, Network, config.networkFields, config.networkEndToEndTicks))
	add(makeNetworkEndToEndCase(Runtime, Network, config.networkFields, config.networkEndToEndTicks))
	return cases
end

local function collectMemory(options)
	if options.collectGarbage ~= nil then
		options.collectGarbage()
	end
	if options.memoryKB ~= nil then
		return options.memoryKB()
	end
	return nil
end

local function measureCase(case, config, options)
	for _ = 1, config.warmup do
		local fixture = case.setup()
		case.run(fixture)
		case.verify(fixture)
		case.cleanup(fixture)
	end

	local buildTimes = {}
	local runTimes = {}
	local cleanupTimes = {}
	local runHeapDeltas = {}
	local cleanupResiduals = {}
	for sample = 1, config.samples do
		local memoryBefore = collectMemory(options)
		local started = options.now()
		local fixture = case.setup()
		buildTimes[sample] = options.now() - started
		local memoryAfterBuild = collectMemory(options)

		started = options.now()
		case.run(fixture)
		runTimes[sample] = options.now() - started
		local memoryAfterRun = collectMemory(options)

		case.verify(fixture)
		started = options.now()
		case.cleanup(fixture)
		cleanupTimes[sample] = options.now() - started
		fixture = nil
		local memoryAfterCleanup = collectMemory(options)

		if memoryBefore ~= nil and memoryAfterBuild ~= nil and memoryAfterRun ~= nil and memoryAfterCleanup ~= nil then
			runHeapDeltas[sample] = memoryAfterRun - memoryAfterBuild
			cleanupResiduals[sample] = memoryAfterCleanup - memoryBefore
		end
	end

	local runStats = statistics(runTimes)
	local result = {
		id = case.id,
		configuration = case.configuration,
		unit = case.unit,
		operations = case.operations,
		buildSeconds = statistics(buildTimes),
		runSeconds = runStats,
		cleanupSeconds = statistics(cleanupTimes),
		unitsPerSecond = case.operations / runStats.median,
		correctness = "PASS",
	}
	if #runHeapDeltas > 0 then
		result.runHeapDeltaKB = statistics(runHeapDeltas)
		result.cleanupResidualKB = statistics(cleanupResiduals)
	end
	return result
end

local function runAcceptance(Runtime)
	local checks = {}
	local function check(name, callback)
		local ok, message = pcall(callback)
		checks[#checks + 1] = {
			name = name,
			status = if ok then "PASS" else "FAIL",
			message = if ok then nil else tostring(message),
		}
	end

	check("clean Computed getter stays cached", function()
		local runtime = Runtime.new()
		local source = runtime:atom(1)
		local evaluations = 0
		local value = runtime:computed(function()
			evaluations += 1
			return source:get() * 2
		end)
		expectEqual(value:get(), 2, "acceptance computed value")
		for _ = 1, 20 do
			value:get()
		end
		expectEqual(evaluations, 1, "acceptance clean computed")
		runtime:dispose()
	end)

	check("one watcher delivery per transaction", function()
		local runtime = Runtime.new()
		local source = runtime:atom(0)
		local deliveries = 0
		runtime:watch(source, function()
			deliveries += 1
		end, { initial = false })
		runtime:transaction(function()
			source:set(1)
			source:set(2)
			source:set(3)
		end)
		expectEqual(deliveries, 1, "acceptance watcher coalescing")
		runtime:dispose()
	end)

	check("history-disabled Runtime retains zero entries", function()
		local runtime = Runtime.new({ deterministic = true, history = false })
		local source = runtime:atom(0)
		for tick = 1, 10 do
			runtime:step(tick, function()
				source:set(tick)
			end)
		end
		expectEqual(runtime:getDebugSnapshot().historyCount, 0, "acceptance history off")
		runtime:dispose()
	end)

	check("dispose releases Runtime-owned graph/history/outbox", function()
		local runtime = Runtime.new({ deterministic = true, history = { capacity = 4 } })
		local source = runtime:atom(0)
		local derived = runtime:computed(function() return source:get() + 1 end)
		runtime:watch(derived, function() end, { initial = false })
		runtime:step(1, function(context)
			source:set(1)
			context:emit("benchmark", { value = 1 })
		end)
		runtime:dispose()
		local info = runtime:getDebugSnapshot()
		expectEqual(#info.nodes, 0, "disposed node retention")
		expectEqual(info.watcherCount, 0, "disposed watcher retention")
		expectEqual(info.historyCount, 0, "disposed history retention")
		expectEqual(info.outboxCount, 0, "disposed outbox retention")
	end)

	return checks
end

local function printHeader(output, dependencies, config, options)
	output("# ReactiveState benchmark")
	output("")
	output("- version: " .. tostring(dependencies.version or "unknown"))
	output("- environment: " .. tostring(options.environment or "unknown"))
	output("- execution mode: " .. tostring(options.mode or "unknown"))
	output("- profile: " .. tostring(config.profile))
	output("- warm-up runs: " .. tostring(config.warmup))
	output("- measured samples: " .. tostring(config.samples))
	output("- timing source: injected monotonic clock")
	if options.memoryKB ~= nil and options.collectGarbage ~= nil then
		output("- memory: retained KB deltas after forced GC")
	elseif options.memoryKB ~= nil then
		output("- memory: sampled KB deltas without forced GC")
	else
		output("- memory: unavailable")
	end
	output("")
end

local function printAcceptance(output, checks)
	output("## Correctness gates")
	output("")
	output("| Gate | Status |")
	output("|---|---:|")
	for _, check in ipairs(checks) do
		local status = check.status
		if check.message ~= nil then
			status ..= " — " .. string.gsub(check.message, "|", "\\|")
		end
		output("| " .. check.name .. " | " .. status .. " |")
	end
	output("")
end

local function printResultHeader(output)
	output("## Workloads")
	output("")
	output("Build/verify/cleanup are outside the steady-state timing. p50/p95/min/max are measured sample times.")
	output("")
	output("| Workload | Configuration | Unit | p50 ms | p95 ms | min ms | max ms | units/s | build p50 ms | run heap Δ KB | cleanup residual KB |")
	output("|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|")
end

local function printResult(output, result)
	local runHeap = if result.runHeapDeltaKB ~= nil then result.runHeapDeltaKB.median else nil
	local residual = if result.cleanupResidualKB ~= nil then result.cleanupResidualKB.median else nil
	output(string.format(
		"| %s | %s | %s | %s | %s | %s | %s | %s | %s | %s | %s |",
		result.id,
		result.configuration,
		result.unit,
		formatMilliseconds(result.runSeconds.median),
		formatMilliseconds(result.runSeconds.p95),
		formatMilliseconds(result.runSeconds.min),
		formatMilliseconds(result.runSeconds.max),
		formatRate(result.unitsPerSecond),
		formatMilliseconds(result.buildSeconds.median),
		formatMemory(runHeap),
		formatMemory(residual)
	))
end

function Suite.run(dependencies, options)
	options = options or {}
	if type(dependencies) ~= "table" then
		error("Suite.run dependencies must be a table", 2)
	end
	if type(dependencies.Runtime) ~= "table" or type(dependencies.Runtime.new) ~= "function" then
		error("Suite.run requires dependencies.Runtime.new", 2)
	end
	if type(dependencies.Network) ~= "table" or type(dependencies.Network.defineSchema) ~= "function" then
		error("Suite.run requires dependencies.Network", 2)
	end
	if type(options.now) ~= "function" then
		error("Suite.run requires options.now monotonic clock", 2)
	end
	local output = options.output or print
	local config = resolveConfig(options)
	local acceptance = runAcceptance(dependencies.Runtime)
	local failures = {}
	for _, check in ipairs(acceptance) do
		if check.status ~= "PASS" then
			failures[#failures + 1] = check.name .. ": " .. tostring(check.message)
		end
	end

	printHeader(output, dependencies, config, options)
	printAcceptance(output, acceptance)
	printResultHeader(output)

	local results = {}
	for _, case in ipairs(buildCases(dependencies.Runtime, dependencies.Network, config)) do
		local ok, result = pcall(measureCase, case, config, options)
		if ok then
			results[#results + 1] = result
			printResult(output, result)
		else
			failures[#failures + 1] = case.id .. ": " .. tostring(result)
			output("| " .. case.id .. " | FAILED: " .. string.gsub(tostring(result), "|", "\\|") .. " | - | - | - | - | - | - | - | - | - |")
		end
	end

	local unsupported = {
		"180-tick journal: current preview supports history.strategy='snapshot' only",
		"built-in configurable snapshot interval: current preview records every deterministic step",
		"native physics rollback: requires an engine-owned snapshot/restore boundary",
		"real RemoteEvent multi-client and target-device timing: run the Studio entry point and play-test checklist",
	}
	output("")
	output("## Unsupported / external gates")
	output("")
	for _, message in ipairs(unsupported) do
		output("- UNSUPPORTED: " .. message)
	end
	output("")
	output("Absolute pass/fail latency budgets are intentionally unset until OVERDARE target-device baselines exist.")

	if #failures > 0 then
		error("benchmark suite failed:\n- " .. table.concat(failures, "\n- "), 2)
	end

	return {
		config = config,
		acceptance = acceptance,
		results = results,
		unsupported = unsupported,
	}
end

Suite.PROFILES = PROFILES

return Suite
