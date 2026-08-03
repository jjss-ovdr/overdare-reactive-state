--!nonstrict

local State = require("../src")

return function(h)
	h:test("runtime owns isolated atoms and stable read-only sources", function()
		local runtime = State.create({ label = "basic" })
		h:truthy(State.isRuntime(runtime))
		local atom = runtime:atom(nil, { label = "optional" })
		local source = atom:asReadonly()
		h:equal(source, atom:asReadonly())
		h:equal(source:get(), nil)
		h:equal(source.set, nil)
		atom:set(4)
		h:equal(source:get(), 4)
		h:equal(source:getRevision(), 1)
	end)

	h:test("computed values are lazy, cached, and replace dynamic dependencies", function()
		local runtime = State.create()
		local chooseLeft = runtime:atom(true)
		local left = runtime:atom(10)
		local right = runtime:atom(20)
		local evaluations = 0
		local selected = runtime:computed(function()
			evaluations += 1
			return if chooseLeft:get() then left:get() else right:get()
		end)
		h:equal(evaluations, 0)
		h:equal(selected:get(), 10)
		h:equal(selected:get(), 10)
		h:equal(evaluations, 1)
		chooseLeft:set(false)
		h:equal(selected:get(), 20)
		h:equal(evaluations, 2)
		left:set(99)
		h:equal(selected:get(), 20)
		h:equal(evaluations, 2)
		right:set(21)
		h:equal(selected:get(), 21)
		h:equal(evaluations, 3)
	end)

	h:test("pending verification suppresses unchanged computed output downstream", function()
		local runtime = State.create()
		local value = runtime:atom(1)
		local parityRuns = 0
		local downstreamRuns = 0
		local parity = runtime:computed(function()
			parityRuns += 1
			return value:get() % 2
		end)
		local downstream = runtime:computed(function()
			downstreamRuns += 1
			return parity:get() == 1 and "odd" or "even"
		end)
		h:equal(downstream:get(), "odd")
		value:set(3)
		h:equal(downstream:get(), "odd")
		h:equal(parityRuns, 2)
		h:equal(downstreamRuns, 1)
	end)

	h:test("diamond graph and watch observe one stable transaction result", function()
		local runtime = State.create()
		local source = runtime:atom(1)
		local left = runtime:computed(function()
			return source:get() + 1
		end)
		local right = runtime:computed(function()
			return source:get() * 2
		end)
		local diamondRuns = 0
		local diamond = runtime:computed(function()
			diamondRuns += 1
			return left:get() + right:get()
		end)
		local seen = {}
		runtime:watch(diamond, function(value, previous)
			seen[#seen + 1] = { value, previous }
		end)
		runtime:transaction(function()
			source:set(2)
			source:set(4)
		end)
		h:equal(#seen, 2)
		h:deepEqual(seen[1], { 4 })
		h:deepEqual(seen[2], { 13, 4 })
		h:equal(diamondRuns, 2)
	end)

	h:test("watched dynamic computed commits its new dependency edges", function()
		local runtime = State.create()
		local chooseLeft = runtime:atom(true)
		local left = runtime:atom(1)
		local right = runtime:atom(10)
		local selected = runtime:computed(function()
			return if chooseLeft:get() then left:get() else right:get()
		end)
		local seen = {}
		runtime:watch(selected, function(value)
			seen[#seen + 1] = value
		end)
		chooseLeft:set(false)
		right:set(11)
		left:set(2)
		h:deepEqual(seen, { 1, 10, 11 })
	end)

	h:test("transactions expose staged reads and roll back nested failures", function()
		local runtime = State.create()
		local value = runtime:atom(1)
		local doubled = runtime:computed(function()
			return value:get() * 2
		end)
		local changeSet = runtime:transaction(function()
			value:set(3)
			h:equal(value:get(), 3)
			h:equal(doubled:get(), 6)
		end)
		h:equal(value:get(), 3)
		h:equal(#changeSet.changedNodes, 1)

		h:throws(function()
			runtime:transaction(function()
				value:set(7)
				pcall(function()
					runtime:transaction(function()
						value:set(9)
						error("inner failure")
					end)
				end)
				value:set(11)
			end)
		end, "aborted")
		h:equal(value:get(), 3)
	end)

	h:test("net no-op transactions do not change revisions or notify", function()
		local runtime = State.create()
		local value = runtime:atom("a")
		local calls = 0
		runtime:watch(value, function()
			calls += 1
		end, { initial = false })
		local revision = value:getRevision()
		local changeSet = runtime:transaction(function()
			value:set("b")
			value:set("a")
		end)
		h:equal(value:getRevision(), revision)
		h:equal(#changeSet.changedNodes, 0)
		h:equal(calls, 0)
	end)

	h:test("validator and updater failures leave committed state untouched", function()
		local runtime = State.create()
		local value = runtime:atom(2, {
			validate = function(nextValue)
				return nextValue >= 0, "must be non-negative"
			end,
		})
		h:throws(function()
			value:set(-1)
		end, "non-negative")
		h:equal(value:get(), 2)
		h:equal(value:getRevision(), 0)
		h:throws(function()
			value:update(function()
				error("bad updater")
			end)
		end, "bad updater")
		h:equal(value:get(), 2)
	end)

	h:test("prepare callbacks cannot stage new writes", function()
		local runtime = State.create()
		local side = runtime:atom(0)
		local guarded = runtime:atom(0, {
			validate = function(value)
				if value > 0 then
					side:set(1)
				end
				return true
			end,
		})
		h:throws(function()
			guarded:set(1)
		end, "mutation phase")
		h:equal(guarded:get(), 0)
		h:equal(side:get(), 0)
	end)

	h:test("watched computed failure and transaction yield both abort publication", function()
		local runtime = State.create()
		local value = runtime:atom(1)
		local checked = runtime:computed(function()
			local current = value:get()
			if current == 2 then
				error("cannot derive two")
			end
			return current
		end)
		runtime:watch(checked, function() end, { initial = false })
		h:throws(function()
			value:set(2)
		end, "cannot derive two")
		h:equal(value:get(), 1)
		h:throws(function()
			runtime:transaction(function()
				value:set(3)
				coroutine.yield()
			end)
		end, "yielded")
		h:equal(value:get(), 1)
	end)

	h:test("computed cycles, cross-runtime reads, and writes are diagnosed", function()
		local first = State.create({ label = "first" })
		local second = State.create({ label = "second" })
		local foreign = second:atom(1, { label = "foreign" })
		local cross = first:computed(function()
			return foreign:get()
		end, { label = "cross" })
		h:throws(function()
			cross:get()
		end, "cross-runtime")

		local writable = first:atom(0, { label = "writable" })
		local badWrite = first:computed(function()
			writable:set(1)
			return 1
		end, { label = "badWrite" })
		h:throws(function()
			badWrite:get()
		end, "writes")
		h:equal(writable:get(), 0)

		local cyclic
		cyclic = first:computed(function()
			return cyclic:get()
		end, { label = "cycle" })
		h:throws(function()
			cyclic:get()
		end, "cycle")
	end)

	h:test("computed depth limit fails before the host stack overflows", function()
		local runtime = State.create({ maxEvaluationDepth = 4 })
		local tail = runtime:atom(0)
		for _ = 1, 5 do
			local dependency = tail
			tail = runtime:computed(function()
				return dependency:get() + 1
			end)
		end
		h:throws(function()
			tail:get()
		end, "evaluation depth limit 4")
	end)

	h:test("watch ordering is stable and reentrant writes are queued", function()
		local runtime = State.create()
		local value = runtime:atom(0)
		local order = {}
		runtime:watch(value, function(nextValue)
			order[#order + 1] = "late:" .. tostring(nextValue)
		end, { initial = false, priority = 10 })
		runtime:watch(value, function(nextValue)
			order[#order + 1] = "early:" .. tostring(nextValue)
			if nextValue == 1 then
				value:set(2)
			end
		end, { initial = false, priority = -1 })
		value:set(1)
		h:deepEqual(order, { "early:1", "late:1", "early:2", "late:2" })
		h:equal(value:get(), 2)
	end)

	h:test("a failing watcher does not block later watchers or roll back state", function()
		local errors = 0
		local runtime = State.create({ onError = function(detail)
			if detail.kind == "watch" then
				errors += 1
			end
		end })
		local value = runtime:atom(0)
		local completed = false
		runtime:watch(value, function()
			error("watch failed")
		end, { initial = false, priority = 0 })
		runtime:watch(value, function()
			completed = true
		end, { initial = false, priority = 1 })
		local changeSet = value:set(1)
		h:equal(value:get(), 1)
		h:truthy(completed)
		h:equal(errors, 1)
		h:equal(#changeSet.watchErrors, 1)
	end)

	h:test("scope disposal is reverse-order and idempotent", function()
		local runtime = State.create()
		local order = {}
		local scope = runtime:scope()
		scope:add(function()
			order[#order + 1] = 1
		end)
		scope:add(function()
			order[#order + 1] = 2
		end)
		scope:dispose()
		scope:dispose()
		h:deepEqual(order, { 2, 1 })
		h:truthy(scope:isDisposed())
	end)

	h:test("store reducer and selector share the Runtime commit", function()
		local runtime = State.create()
		local store = runtime:store({
			initialState = { score = 0 },
			reducer = function(state, action)
				return { score = state.score + action.amount }
			end,
		})
		local score = store:select(function(state)
			return state.score
		end)
		local changeSet = store:dispatch({ amount = 5 })
		h:equal(store:getState().score, 5)
		h:equal(score:get(), 5)
		h:equal(#changeSet.actions, 1)
	end)

	h:test("timeline rollback keeps revisions monotonic and replay converges", function()
		local runtime = State.create({ deterministic = true, history = { capacity = 8 } })
		local value = runtime:atom(0, { label = "value" })
		runtime:step(1, function()
			value:set(1)
		end)
		runtime:step(2, function()
			value:set(2)
		end)
		local straightHash = runtime:getStateHash()
		local revision = value:getRevision()
		local replayWatchCalls = 0
		runtime:watch(value, function()
			replayWatchCalls += 1
		end, { initial = false, replay = "coalesce" })
		runtime:replay(1, 2, function(_context, tick)
			value:set(tick)
		end)
		h:equal(value:get(), 2)
		h:equal(runtime:getTick(), 2)
		h:equal(runtime:getStateHash(), straightHash)
		h:truthy(value:getRevision() > revision)
		h:equal(replayWatchCalls, 0)
	end)

	h:test("failed replay restores ring history and the stable checkpoint", function()
		local runtime = State.create({ deterministic = true, history = { capacity = 5 } })
		local value = runtime:atom(0)
		for tick = 1, 4 do
			runtime:step(tick, function()
				value:set(tick)
			end)
		end
		local checkpointHash = runtime:getStateHash()
		h:throws(function()
			runtime:replay(2, 4, function(_, tick)
				if tick == 3 then
					error("replay probe failure")
				end
				value:set(tick)
			end)
		end, "replay failed")
		h:equal(runtime:getTick(), 4)
		h:equal(value:get(), 4)
		h:equal(runtime:getStateHash(), checkpointHash)
		h:equal(runtime:getDebugSnapshot().historyCount, 5)
		runtime:rollback(2)
		h:equal(value:get(), 2)
	end)

	h:test("history retains the pre-first-step state as tick zero", function()
		local runtime = State.create({ deterministic = true, history = true })
		local value = runtime:atom("initial")
		runtime:step(1, function()
			value:set("advanced")
		end)
		runtime:rollback(0)
		h:equal(runtime:getTick(), 0)
		h:equal(value:get(), "initial")
	end)

	h:test("failed step preserves tick, state, and outbox", function()
		local runtime = State.create({ deterministic = true, history = true })
		local value = runtime:atom(0)
		h:throws(function()
			runtime:step(1, function(context)
				value:set(1)
				context:emit("Invalid", { callback = function() end })
			end)
		end, "function")
		h:equal(runtime:getTick(), nil)
		h:equal(value:get(), 0)
		h:equal(value:getRevision(), 0)
		h:equal(#runtime:getPendingCommands(), 0)
	end)

	h:test("history capacity evicts the oldest rollback tick", function()
		local runtime = State.create({ deterministic = true, history = { capacity = 3 } })
		local value = runtime:atom(0)
		for tick = 1, 3 do
			runtime:step(tick, function()
				value:set(tick)
			end)
		end
		h:throws(function()
			runtime:rollback(0)
		end, "no retained")
		runtime:rollback(1)
		h:equal(value:get(), 1)
	end)

	h:test("history ring wraps and replays in chronological tick order", function()
		local runtime = State.create({ deterministic = true, history = { capacity = 4 } })
		local value = runtime:atom(0)
		for tick = 1, 8 do
			runtime:step(tick, function()
				value:set(tick)
			end)
		end
		local expectedHash = runtime:getStateHash()
		h:equal(runtime:getDebugSnapshot().historyCount, 4)
		h:throws(function()
			runtime:snapshot(4)
		end, "no retained")
		h:equal(runtime:snapshot(5).tick, 5)
		runtime:replay(5, 8, function(_, tick)
			value:set(tick)
		end)
		h:equal(value:get(), 8)
		h:equal(runtime:getStateHash(), expectedHash)
	end)

	h:test("step commands remain data and confirmed effects are monotonic", function()
		local runtime = State.create({ deterministic = true, history = true, commandNamespace = "match" })
		local commandId
		runtime:step(1, function(context)
			commandId = context:emit("PlaySound", { sound = "hit" }, { policy = "confirmed" })
		end)
		h:equal(commandId, "match:1:1")
		h:equal(#runtime:getPendingCommands(), 1)
		local confirmed = runtime:confirm(1)
		h:equal(#confirmed, 1)
		h:equal(confirmed[1].type, "PlaySound")
		h:equal(#runtime:confirm(1), 0)
		h:throws(function()
			runtime:rollback(0)
		end, "confirmed")
	end)

	h:test("enabled trace preserves scalar internal event fields", function()
		local events = {}
		local runtime = State.create({
			label = "trace-test",
			trace = function(event)
				events[#events + 1] = event
			end,
		})
		local value = runtime:atom(1, { label = "score" })
		value:set(2)
		runtime:dispose()
		local atomSet = nil
		local disposed = false
		for _, event in ipairs(events) do
			if event.event == "atom:set" then
				atomSet = event
			elseif event.event == "runtime:dispose" then
				disposed = true
			end
		end
		h:truthy(atomSet)
		h:equal(atomSet.label, "score")
		h:equal(atomSet.revision, 1)
		h:equal(atomSet.runtimeLabel, "trace-test")
		h:truthy(disposed)
	end)

	h:test("runtime disposal releases owned graph history and outbox idempotently", function()
		local runtime = State.create({ deterministic = true, history = { capacity = 4 } })
		local value = runtime:atom(1)
		local derived = runtime:computed(function()
			return value:get() + 1
		end)
		runtime:watch(derived, function() end, { initial = false })
		runtime:step(1, function(context)
			value:set(2)
			context:emit("DisposeProbe", { value = 2 })
		end)
		runtime:dispose()
		runtime:dispose()
		local debug = runtime:getDebugSnapshot()
		h:equal(#debug.nodes, 0)
		h:equal(debug.watcherCount, 0)
		h:equal(debug.historyCount, 0)
		h:equal(debug.outboxCount, 0)
		h:throws(function()
			value:get()
		end, "disposed")
	end)
end
