--!nonstrict

--[[
Capital-style Atom/Computed facade over createStateRuntime().

This exists so Studio game scripts and agents that expect
ReactiveState.Atom / :Get / :Set / Computed / Transaction do not invent a
3KB project-local shim. It is not Push-Pull FRP and Capital.Bus (legacy alias:
Capital.Event) is not FRP.Event (no Host time, no occurrence stream).
]]

local Compat = {}

Compat.KIND = "CapitalStateFacade"
Compat.EVENT_KIND = "LocalSignalBus"

local function reportWarning(message)
	local warning = _G.warn
	if type(warning) == "function" then
		warning(message)
	else
		print(message)
	end
end

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
	handle.Disconnect = handle.Dispose
	handle.disconnect = handle.Dispose
	handle.Destroy = handle.Dispose
	return handle
end

local function wrapSource(runtime, source, kind, onDispose)
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
		stops[stop] = true
		return makeDisposable(function()
			if stops[stop] ~= nil then
				stops[stop] = nil
				stop()
			end
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
		for stop in pairs(stops) do
			stops[stop] = nil
			local ok, message = pcall(stop)
			if not ok then
				reportWarning("Capital " .. kind .. " subscription dispose failed: " .. tostring(message))
			end
		end
		if onDispose ~= nil then
			onDispose()
		end
	end

	handle.dispose = handle.Dispose
	handle.Destroy = handle.Dispose

	return handle
end

local function createLocalSignalBus(reportError, onDispose)
	local callbacks = {}
	local nextId = 0
	local disposed = false
	local bus = {
		_kind = Compat.EVENT_KIND,
	}

	function bus:Connect(callback)
		if type(callback) ~= "function" then
			error("Capital.Bus:Connect callback must be a function", 2)
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

	function bus:connect(callback)
		return self:Connect(callback)
	end

	function bus:Fire(...)
		if disposed then
			return
		end
		local snapshot = {}
		for callbackId = 1, nextId do
			local callback = callbacks[callbackId]
			if callback ~= nil then
				snapshot[#snapshot + 1] = callback
			end
		end
		for _, callback in ipairs(snapshot) do
			local ok, message = pcall(callback, ...)
			if not ok then
				reportError(message)
			end
		end
	end

	function bus:fire(...)
		self:Fire(...)
	end

	function bus:Dispose()
		if disposed then
			return
		end
		disposed = true
		callbacks = {}
		if onDispose ~= nil then
			onDispose()
		end
	end

	bus.dispose = bus.Dispose
	bus.Destroy = bus.Dispose

	return bus
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
	local onError = options.onError
	if onError ~= nil and type(onError) ~= "function" then
		error("Compat.bind onError must be a function", 2)
	end
	local facade = {
		_kind = Compat.KIND,
		_runtime = runtime,
		runtime = runtime,
	}
	local children = {}
	local childIndices = {}

	local function unregisterChild(child)
		local index = childIndices[child]
		if index == nil then
			return
		end
		local lastIndex = #children
		local last = children[lastIndex]
		children[index] = last
		children[lastIndex] = nil
		childIndices[child] = nil
		if last ~= child then
			childIndices[last] = index
		end
	end

	local function registerChild(child)
		children[#children + 1] = child
		childIndices[child] = #children
		return child
	end

	local function reportBusError(message)
		local detail = {
			kind = "capital_bus_listener",
			message = tostring(message),
		}
		if onError ~= nil then
			local ok, handlerError = pcall(onError, detail)
			if not ok then
				reportWarning("Capital.Bus onError failed: " .. tostring(handlerError))
			end
		else
			reportWarning("Capital.Bus listener failed: " .. detail.message)
		end
	end

	local function assertUsable(methodName)
		if disposed then
			error("Capital." .. methodName .. " called after dispose", 3)
		end
	end

	function facade.Atom(initialValue, atomOptions)
		assertUsable("Atom")
		local handle
		handle = wrapSource(runtime, runtime:atom(initialValue, atomOptions), "Atom", function()
			unregisterChild(handle)
		end)
		return registerChild(handle)
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
			-- Shim-compatible signature. Explicit dependencies are read before
			-- the getter so they act as invalidation triggers. The dependency
			-- array itself is a fixed snapshot; changing plain-table membership
			-- still requires a tracked membership/version Atom.
			local dependencies = {}
			for index, dependency in ipairs(dependenciesOrGetter) do
				if type(dependency) ~= "table" or type(dependency.Get) ~= "function" then
					error("Capital.Computed dependency " .. tostring(index) .. " must be a Capital Source", 2)
				end
				dependencies[index] = dependency
			end
			local compute = maybeGetter
			getter = function()
				for _, dependency in ipairs(dependencies) do
					dependency:Get()
				end
				return compute()
			end
		else
			error("Capital.Computed expects Computed(getter) or Computed({deps}, getter)", 2)
		end
		local handle
		handle = wrapSource(runtime, runtime:computed(getter, options), "Computed", function()
			unregisterChild(handle)
		end)
		return registerChild(handle)
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
	function facade.Bus()
		assertUsable("Bus")
		local bus
		bus = createLocalSignalBus(reportBusError, function()
			unregisterChild(bus)
		end)
		return registerChild(bus)
	end

	-- Deprecated shim alias. New code should say Bus so it cannot be confused
	-- with the package's timestamped Push-Pull FRP.Event namespace.
	function facade.Event()
		assertUsable("Event")
		return facade.Bus()
	end

	function facade:dispose()
		if disposed then
			return
		end
		disposed = true
		while #children > 0 do
			local child = children[#children]
			local ok, message = pcall(function()
				child:Dispose()
			end)
			if not ok then
				unregisterChild(child)
				reportWarning("Capital child dispose failed: " .. tostring(message))
			end
		end
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
	if type(options) ~= "table" then
		error("Compat.create options must be a table", 2)
	end
	local runtime = createRuntime(options)
	return Compat.bind(runtime, {
		ownsRuntime = true,
		onError = options.onError,
	})
end

return Compat
