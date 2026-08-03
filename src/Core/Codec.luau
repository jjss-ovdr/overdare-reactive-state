--!strict

-- The default codec intentionally supports only values that can be copied and
-- transported without engine state or executable behavior.  Domain-specific
-- value types should use an explicit custom codec instead.

local Codec = {}

export type DefaultCodec = {
	validate: (value: any) -> (boolean, string?),
	clone: (value: any) -> any,
	equals: (left: any, right: any) -> boolean,
	encode: (value: any) -> any,
	decode: (data: any) -> any,
}

local SUPPORTED_VALUE_TYPES = {
	["nil"] = true,
	boolean = true,
	number = true,
	string = true,
	table = true,
}

local SUPPORTED_KEY_TYPES = {
	boolean = true,
	number = true,
	string = true,
}

local KEY_TYPE_ORDER: { [string]: number } = {
	boolean = 1,
	number = 2,
	string = 3,
}

local function canonicalNumber(value: number): string
	if value ~= value then
		return "nan"
	end

	if value == math.huge then
		return "inf"
	end

	if value == -math.huge then
		return "-inf"
	end

	-- Treat both IEEE zero representations as the same table key.
	if value == 0 then
		return "0"
	end

	return string.format("%.17g", value)
end

local function keyLess(left: any, right: any): boolean
	local leftType = type(left)
	local rightType = type(right)
	local leftOrder = KEY_TYPE_ORDER[leftType] :: number
	local rightOrder = KEY_TYPE_ORDER[rightType] :: number

	if leftOrder ~= rightOrder then
		return leftOrder < rightOrder
	end

	if leftType == "boolean" then
		return left == false and right == true
	elseif leftType == "number" then
		if left == right then
			return false
	end

		-- NaN cannot be used as a Luau table key.  The string fallback keeps
		-- this comparator total if a host implementation nevertheless permits it.
		if left ~= left or right ~= right then
			return canonicalNumber(left) < canonicalNumber(right)
		end

		return (left :: number) < (right :: number)
	end

	return (left :: string) < (right :: string)
end

local function appendKeyPath(path: string, key: any): string
	local keyType = type(key)
	if keyType == "string" then
		if string.match(key, "^[%a_][%w_]*$") ~= nil then
			return path .. "." .. key
		end

		return path .. "[" .. string.format("%q", key) .. "]"
	elseif keyType == "number" then
		return path .. "[" .. canonicalNumber(key) .. "]"
	else
		return path .. "[" .. tostring(key) .. "]"
	end
end

local function collectKeys(value: { [any]: any }, path: string): (boolean, { any }?, string?)
	local keys = {}
	local key = next(value)

	while key ~= nil do
		local keyType = type(key)
		if not SUPPORTED_KEY_TYPES[keyType] then
			return false, nil, string.format(
				"%s has an unsupported table key of type '%s'; expected boolean, number, or string",
				path,
				keyType
			)
		end

		keys[#keys + 1] = key
		key = next(value, key)
	end

	table.sort(keys, keyLess)
	return true, keys, nil
end

local function validateInternal(value: any, path: string, active: { [any]: string }): (boolean, string?)
	local valueType = type(value)
	if not SUPPORTED_VALUE_TYPES[valueType] then
		return false, string.format("%s has unsupported value type '%s'", path, valueType)
	end

	if valueType ~= "table" then
		return true, nil
	end

	if getmetatable(value) ~= nil then
		return false, string.format("%s is not a plain table (metatables require a custom codec)", path)
	end

	local firstPath = active[value]
	if firstPath ~= nil then
		return false, string.format("cycle detected at %s (the table is already active at %s)", path, firstPath)
	end

	local keysOk, keys, keyError = collectKeys(value, path)
	if not keysOk then
		return false, keyError
	end

	active[value] = path
	for _, key in ipairs(keys :: { any }) do
		local childPath = appendKeyPath(path, key)
		local childOk, childError = validateInternal(value[key], childPath, active)
		if not childOk then
			active[value] = nil
			return false, childError
		end
	end
	active[value] = nil

	return true, nil
end

local function validate(value: any): (boolean, string?)
	return validateInternal(value, "$", {})
end

local function cloneInternal(
	value: any,
	path: string,
	active: { [any]: string },
	copies: { [any]: any }
): (boolean, any, string?)
	local valueType = type(value)
	if not SUPPORTED_VALUE_TYPES[valueType] then
		return false, nil, string.format("%s has unsupported value type '%s'", path, valueType)
	end

	if valueType ~= "table" then
		return true, value, nil
	end

	if getmetatable(value) ~= nil then
		return false, nil, string.format("%s is not a plain table (metatables require a custom codec)", path)
	end

	local firstPath = active[value]
	if firstPath ~= nil then
		return false, nil, string.format("cycle detected at %s (the table is already active at %s)", path, firstPath)
	end

	local existingCopy = copies[value]
	if existingCopy ~= nil then
		return true, existingCopy, nil
	end

	local keysOk, keys, keyError = collectKeys(value, path)
	if not keysOk then
		return false, nil, keyError
	end

	local copy = {}
	copies[value] = copy
	active[value] = path

	for _, key in ipairs(keys :: { any }) do
		local childPath = appendKeyPath(path, key)
		local childOk, childValue, childError = cloneInternal(value[key], childPath, active, copies)
		if not childOk then
			active[value] = nil
			return false, nil, childError
		end

		copy[key] = childValue
	end

	active[value] = nil
	return true, copy, nil
end

local function cloneWithContext(value: any, operation: string): any
	local ok, cloned, message = cloneInternal(value, "$", {}, {})
	if not ok then
		error(string.format("Codec.%s rejected the value: %s", operation, message :: string), 3)
	end

	return cloned
end

local function deepEqualsInternal(left: any, right: any, compared: { [any]: { [any]: boolean } }): boolean
	if left == right then
		return true
	end

	local leftType = type(left)
	if leftType ~= type(right) then
		return false
	end

	if leftType == "number" then
		-- Canonical serialization treats all NaN payloads as the same value.
		return left ~= left and right ~= right
	elseif leftType ~= "table" then
		return false
	end

	local rightTables = compared[left]
	if rightTables ~= nil and rightTables[right] then
		return true
	end

	if rightTables == nil then
		rightTables = {}
		compared[left] = rightTables
	end
	rightTables[right] = true

	local leftCount = 0
	local key = next(left)
	while key ~= nil do
		leftCount += 1
		if not deepEqualsInternal(left[key], right[key], compared) then
			return false
		end
		key = next(left, key)
	end

	local rightCount = 0
	key = next(right)
	while key ~= nil do
		rightCount += 1
		key = next(right, key)
	end

	return leftCount == rightCount
end

local Default: DefaultCodec = {} :: any

function Default.validate(value: any): (boolean, string?)
	return validate(value)
end

function Default.clone(value: any): any
	return cloneWithContext(value, "clone")
end

function Default.equals(left: any, right: any): boolean
	local leftOk, leftError = validate(left)
	if not leftOk then
		error("Codec.equals rejected the left value: " .. (leftError :: string), 2)
	end

	local rightOk, rightError = validate(right)
	if not rightOk then
		error("Codec.equals rejected the right value: " .. (rightError :: string), 2)
	end

	return deepEqualsInternal(left, right, {})
end

function Default.encode(value: any): any
	return cloneWithContext(value, "encode")
end

function Default.decode(data: any): any
	return cloneWithContext(data, "decode")
end

Codec.default = Default
Codec.validate = Default.validate
Codec.clone = Default.clone
Codec.equals = Default.equals
Codec.encode = Default.encode
Codec.decode = Default.decode

return Codec
