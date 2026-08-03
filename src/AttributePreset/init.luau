--!nonstrict

-- Schema-checked Instance attributes. This module is optional and has no
-- engine references until apply() is explicitly called.

local AttributePreset = {}

local Preset = {}
Preset.__index = Preset

local function cloneDefault(value: any, seen: { [any]: boolean }?): any
	if type(value) ~= "table" then
		return value
	end
	seen = seen or {}
	assert(not seen[value], "attribute default contains a table cycle")
	seen[value] = true
	local copy = {}
	for key, child in pairs(value) do
		copy[cloneDefault(key, seen)] = cloneDefault(child, seen)
	end
	seen[value] = nil
	return copy
end

local function sortedKeys(dictionary: { [any]: any }): { any }
	local keys = {}
	for key in pairs(dictionary) do
		table.insert(keys, key)
	end
	table.sort(keys, function(a, b)
		return tostring(a) < tostring(b)
	end)
	return keys
end

local function enumContains(values: { any }, candidate: any): boolean
	for _, value in ipairs(values) do
		if value == candidate then
			return true
		end
	end
	return false
end

local function validateRule(name: string, rule: any, value: any): (boolean, string?)
	if value == nil then
		if rule.required and rule.default == nil then
			return false, string.format("attribute %q is required", name)
		end
		return true, nil
	end

	if rule.type ~= nil then
		local validType
		if type(rule.type) == "string" then
			validType = type(value) == rule.type
		elseif type(rule.type) == "function" then
			validType = rule.type(value)
		else
			return false, string.format("schema type for %q must be a string or predicate", name)
		end
		if not validType then
			return false, string.format("attribute %q has type %s; expected %s", name, type(value), tostring(rule.type))
		end
	end

	if rule.enum ~= nil and not enumContains(rule.enum, value) then
		return false, string.format("attribute %q is not an allowed enum value", name)
	end

	if type(value) == "number" then
		if rule.integer and value % 1 ~= 0 then
			return false, string.format("attribute %q must be an integer", name)
		end
		if rule.min ~= nil and value < rule.min then
			return false, string.format("attribute %q must be >= %s", name, tostring(rule.min))
		end
		if rule.max ~= nil and value > rule.max then
			return false, string.format("attribute %q must be <= %s", name, tostring(rule.max))
		end
	end

	if rule.validate ~= nil then
		local ok, message = rule.validate(value)
		if not ok then
			return false, message or string.format("attribute %q failed custom validation", name)
		end
	end

	return true, nil
end

function Preset:validate(attributes: { [string]: any }): { [string]: any }
	assert(type(attributes) == "table", "attributes must be a table")

	if not self._allowUnknown then
		for key in pairs(attributes) do
			assert(self._schema[key] ~= nil, string.format("unknown attribute %q", tostring(key)))
		end
	end

	local normalized = {}
	for _, name in ipairs(self._keys) do
		local rule = self._schema[name]
		local value = attributes[name]
		if value == nil and rule.default ~= nil then
			value = cloneDefault(rule.default)
		end

		local valid, message = validateRule(name, rule, value)
		assert(valid, message)
		if rule.transform ~= nil and value ~= nil then
			value = rule.transform(value)
		end
		normalized[name] = value
	end

	return normalized
end

function Preset:tryValidate(attributes: { [string]: any }): (boolean, any)
	local ok, result = pcall(function()
		return self:validate(attributes)
	end)
	return ok, result
end

local function readAttributes(instance: any): { [string]: any }
	assert(instance ~= nil and type(instance.GetAttributes) == "function", "instance must implement :GetAttributes()")
	return instance:GetAttributes()
end

local function applyNormalized(self: any, runtime: any, normalized: { [string]: any }, options: any)
	local targets = options.targets or {}
	runtime:transaction(function()
		for _, name in ipairs(self._keys) do
			local target = targets[name]
			local value = normalized[name]
			if target ~= nil then
				if type(target) == "function" then
					target(value, name)
				else
					assert(type(target) == "table" and type(target.set) == "function", string.format(
						"target for attribute %q must be an Atom or function",
						name
					))
					target:set(value)
				end
			end
		end

		if options.action ~= nil then
			options.action(normalized)
		end
	end, {
		cause = options.cause or "attribute",
		label = options.label or "AttributePreset.apply",
	})
end

function Preset:apply(instance: any, runtime: any, options: any?)
	assert(type(runtime) == "table" and type(runtime.transaction) == "function", "AttributePreset.apply requires a Runtime")
	options = options or {}

	local function refresh()
		local raw = if options.values ~= nil then options.values else readAttributes(instance)
		local normalized = self:validate(raw)
		applyNormalized(self, runtime, normalized, options)
		return normalized
	end

	refresh()
	local scope = runtime:scope()

	if options.observe then
		assert(instance ~= nil and type(instance.GetAttributeChangedSignal) == "function", "observed instance must implement :GetAttributeChangedSignal()")
		for _, name in ipairs(self._keys) do
			local signal = instance:GetAttributeChangedSignal(name)
			assert(signal ~= nil and type(signal.Connect) == "function", "attribute signal must implement :Connect()")
			local connection = signal:Connect(refresh)
			scope:add(function()
				if connection ~= nil and type(connection.Disconnect) == "function" then
					connection:Disconnect()
				elseif connection ~= nil and type(connection.disconnect) == "function" then
					connection:disconnect()
				end
			end)
		end
	end

	return scope
end

function AttributePreset.define(schema: { [string]: any }, options: any?)
	assert(type(schema) == "table", "AttributePreset.define expects a schema table")
	options = options or {}
	local keys = sortedKeys(schema)
	for _, name in ipairs(keys) do
		assert(type(name) == "string", "attribute schema keys must be strings")
		assert(type(schema[name]) == "table", string.format("schema entry %q must be a table", name))
	end

	return setmetatable({
		_schema = schema,
		_keys = keys,
		_allowUnknown = options.allowUnknown == true,
	}, Preset)
end

AttributePreset.apply = function(preset: any, instance: any, runtime: any, options: any?)
	assert(getmetatable(preset) == Preset, "AttributePreset.apply expects a preset returned by define()")
	return preset:apply(instance, runtime, options)
end

return AttributePreset
