--!nonstrict

--[[
Capital-style Atom/Computed facade over createStateRuntime().

This exists so Studio game scripts and agents that expect
ReactiveState.Atom / :Get / :Set / Computed / Transaction do not invent a
3KB project-local shim. It is not Push-Pull FRP and Capital.Event is not
FRP.Event (no Host time, no occurrence stream).
]]

local Compat = {}

Compat.KIND = "CapitalStateFacade"
Compat.EVENT_KIND = "LocalSignalBus"

local function makeDisposable(disposeCallback)
	local disposed = false
	local handle = {}
	function handle:Dispose()
		if disposed then
			return
		end
		disposed = true
		disposeCallback()
	end
	handle.dispose = handle.Dispose
	handle.Destroy = handle.Dispose
	return handle
end

local function wrapSource(runtime, source, kind)
	local stops = {}
	local disposed = false
	local handle = {
		_kind = kind,
		_source = source,
		_runtime = runtime,
	}

	local function assertUsable(methodName)
		if disposed then
			error("Capital " .. kind .. ":" .. methodName .. " called after Dispose", 3)
		end
	end

	function handle:Get()
		assertUsable("Get")
		return source:get()
	end

	function handle:get()
		return self:Get()
	end

	if kind == "Atom" then
		function handle:Set(value)
			assertUsable("Set")
			source:set(value)
		end

		function handle:set(value)
			self:Set(value)
		end

		function handle:Update(updater)
			assertUsable("Update")
			source:update(updater)
		end

		function handle:update(updater)
			self:Update(updater)
		end
	end

	function handle:Subscribe(callback, options)
		assertUsable("Subscribe")
		if type(callback) ~= "function" then
			error("Capital " .. kind .. ":Subscribe callback must be a function", 2)
		end
		options = options or {}
		local watchOptions = {
			label = options.label,
			initial = if options.initial ~= nil then options.initial else false,
			equality = options.equality,
			priority = options.priority,
			replay = options.replay,
		}
		local stop = runtime:watch(source, function(value)
			callback(value)
		end, watchOptions)
		stops[#stops + 1] = stop
		return makeDisposable(function()
			stop()
		end)
	end

	function handle:subscribe(callback, options)
		return self:Subscribe(callback, options)
	end

	function handle:Dispose()
		if disposed then
			return
		end
		disposed = true
		for index = #stops, 1, -1 do
			local ok, message = pcall(stops[index])
			if not ok then
				warn("Capital " .. kind .. " subscription dispose failed: " .. tostring(message))
			end
			stops[index] = nil
		end
	end

	handle.dispose = handle.Dispose
	handle.Destroy = handle.Dispose

	return handle
end

local function createLocalSignalBus()
	local callbacks = {}
	local nextId = 0
	local disposed = false
	local event = {
		_kind = Compat.EVENT_KIND,
	}

	function event:Connect(callback)
		if type(callback) ~= "function" then
			error("Capital.Event:Connect callback must be a function", 2)
		end
		if disposed then
			return makeDisposable(function() end)
		end
		nextId += 1
		local callbackId = nextId
		callbacks[callbackId] = callback
		return makeDisposable(function()
			callbacks[callbackId] = nil
		end)
	end

	function event:connect(callback)
		return self:Connect(callback)
	end

	function event:Fire(...)
		if disposed then
			return
		end
		local snapshot = {}
		for callbackId, callback in pairs(callbacks) do
			snapshot[callbackId] = callback
		end
		for _, callback in pairs(snapshot) do
			callback(...)
		end
	end

	function event:fire(...)
		self:Fire(...)
	end

	function event:Dispose()
		disposed = true
		callbacks = {}
	end

	event.dispose = event.Dispose
	event.Destroy = event.Dispose

	return event
end

function Compat.bind(runtime, options)
	if type(runtime) ~= "table" or type(runtime.atom) ~= "function" then
		error("Compat.bind expects a StateRuntime from FRP.createStateRuntime()", 2)
	end
	options = options or {}
	if type(options) ~= "table" then
		error("Compat.bind options must be a table", 2)
	end

	local disposed = false
	local ownsRuntime = options.ownsRuntime == true
	local facade = {
		_kind = Compat.KIND,
		_runtime = runtime,
		runtime = runtime,
	}

	local function assertUsable(methodName)
		if disposed then
			error("Capital." .. methodName .. " called after dispose", 3)
		end
	end

	function facade.Atom(initialValue, atomOptions)
		assertUsable("Atom")
		return wrapSource(runtime, runtime:atom(initialValue, atomOptions), "Atom")
	end

	function facade.atom(initialValue, atomOptions)
		return facade.Atom(initialValue, atomOptions)
	end

	function facade.Computed(dependenciesOrGetter, maybeGetter, computedOptions)
		assertUsable("Computed")
		local getter
		local options = computedOptions
		if type(dependenciesOrGetter) == "function" then
			getter = dependenciesOrGetter
			if type(maybeGetter) == "table" then
				options = maybeGetter
			elseif maybeGetter ~= nil then
				error("Capital.Computed(getter, options?) got a non-table second argument", 2)
			end
		elseif type(dependenciesOrGetter) == "table" and type(maybeGetter) == "function" then
			-- Shim-compatible signature. Dependency arrays are ignored: the
			-- official Runtime tracks Sources read during getter evaluation.
			getter = maybeGetter
		else
			error("Capital.Computed expects Computed(getter) or Computed({deps}, getter)", 2)
		end
		return wrapSource(runtime, runtime:computed(getter, options), "Computed")
	end

	function facade.computed(dependenciesOrGetter, maybeGetter, computedOptions)
		return facade.Computed(dependenciesOrGetter, maybeGetter, computedOptions)
	end

	function facade.Transaction(callback, metadata)
		assertUsable("Transaction")
		if type(callback) ~= "function" then
			error("Capital.Transaction callback must be a function", 2)
		end
		return runtime:transaction(callback, metadata)
	end

	function facade.transaction(callback, metadata)
		return facade.Transaction(callback, metadata)
	end

	-- Local pub/sub bus for gameplay wiring. This is intentionally not
	-- FRP.Event: there is no Host, timestamp, or occurrence denotation.
	function facade.Event()
		assertUsable("Event")
		return createLocalSignalBus()
	end

	function facade.Bus()
		return facade.Event()
	end

	function facade:dispose()
		if disposed then
			return
		end
		disposed = true
		if ownsRuntime and type(runtime.dispose) == "function" then
			runtime:dispose()
		end
	end

	facade.Dispose = function()
		facade:dispose()
	end
	facade.Destroy = facade.Dispose

	return facade
end

function Compat.create(createRuntime, options)
	if type(createRuntime) ~= "function" then
		error("Compat.create expects FRP.createStateRuntime (or equivalent)", 2)
	end
	options = options or {}
	local runtime = createRuntime(options)
	return Compat.bind(runtime, {
		ownsRuntime = true,
	})
end

return Compat
