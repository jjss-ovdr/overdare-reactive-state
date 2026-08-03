--!strict

-- Canonical state encoding and a stable, deliberately non-cryptographic hash.
-- This is suitable for replay drift detection, not signatures or trust checks.

local Hash = {}

Hash.CANONICAL_VERSION = 1
Hash.ALGORITHM = "djb2-sdbm-64"

local MOD_32 = 4294967296
local TWO_TO_53 = 9007199254740992
local HEX = "0123456789abcdef"

local KEY_TYPE_ORDER: { [string]: number } = {
	boolean = 1,
	number = 2,
	string = 3,
}

local function significandToHex(value: number): string
	-- frexp() produces a binary fraction whose 53-bit significand is exactly
	-- representable as a Luau number.  Fourteen hexadecimal digits retain all
	-- of those bits without depending on locale-specific decimal formatting.
	local output = {}
	local remaining = value

	for index = 14, 1, -1 do
		local digit = remaining % 16
		output[index] = string.sub(HEX, digit + 1, digit + 1)
		remaining = math.floor(remaining / 16)
	end

	return table.concat(output)
end

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

	if value == 0 then
		return "0"
	end

	local sign = if value < 0 then "-" else "+"
	local fraction, exponent = math.frexp(math.abs(value))
	local significand = fraction * TWO_TO_53
	return sign .. tostring(exponent) .. ":" .. significandToHex(significand)
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

local function encodeValue(value: any, path: string, active: { [any]: string }, chunks: { string }): (boolean, string?)
	local valueType = type(value)

	if valueType == "nil" then
		chunks[#chunks + 1] = "n"
		return true, nil
	elseif valueType == "boolean" then
		chunks[#chunks + 1] = if value then "b1" else "b0"
		return true, nil
	elseif valueType == "number" then
		local encoded = canonicalNumber(value)
		chunks[#chunks + 1] = "d" .. tostring(#encoded) .. ":" .. encoded
		return true, nil
	elseif valueType == "string" then
		chunks[#chunks + 1] = "s" .. tostring(#value) .. ":" .. value
		return true, nil
	elseif valueType ~= "table" then
		return false, string.format("%s has unsupported value type '%s'", path, valueType)
	end

	if getmetatable(value) ~= nil then
		return false, string.format("%s is not a plain table (metatables require an explicit encoder)", path)
	end

	local firstPath = active[value]
	if firstPath ~= nil then
		return false, string.format("cycle detected at %s (the table is already active at %s)", path, firstPath)
	end

	local keys = {}
	local key = next(value)
	while key ~= nil do
		local keyType = type(key)
		if KEY_TYPE_ORDER[keyType] == nil then
			return false, string.format(
				"%s has an unsupported table key of type '%s'; expected boolean, number, or string",
				path,
				keyType
			)
		end

		keys[#keys + 1] = key
		key = next(value, key)
	end
	table.sort(keys, keyLess)

	active[value] = path
	chunks[#chunks + 1] = "t" .. tostring(#keys) .. ":{"

	for _, childKey in ipairs(keys) do
		chunks[#chunks + 1] = "k"
		local keyOk, keyError = encodeValue(childKey, path .. "<key>", active, chunks)
		if not keyOk then
			active[value] = nil
			return false, keyError
		end

		chunks[#chunks + 1] = "v"
		local childPath = appendKeyPath(path, childKey)
		local childOk, childError = encodeValue(value[childKey], childPath, active, chunks)
		if not childOk then
			active[value] = nil
			return false, childError
		end

		chunks[#chunks + 1] = ";"
	end

	chunks[#chunks + 1] = "}"
	active[value] = nil
	return true, nil
end

local function tryEncode(value: any): (boolean, string?, string?)
	local chunks = { "c1:" }
	local ok, message = encodeValue(value, "$", {}, chunks)
	if not ok then
		return false, nil, message
	end

	return true, table.concat(chunks), nil
end

local function toHex32(value: number): string
	local output = {}
	local remaining = value

	for index = 8, 1, -1 do
		local digit = remaining % 16
		output[index] = string.sub(HEX, digit + 1, digit + 1)
		remaining = math.floor(remaining / 16)
	end

	return table.concat(output)
end

local function hashEncoded(encoded: string): string
	-- Both lanes stay below 2^53 before reduction, so integer operations are
	-- exact in Luau's double-precision number representation.
	local djb2 = 5381
	local sdbm = 2166136261

	for index = 1, #encoded do
		local byte = string.byte(encoded, index)
		djb2 = (djb2 * 33 + byte) % MOD_32
		sdbm = (sdbm * 65599 + byte) % MOD_32
	end

	return toHex32(djb2) .. toHex32(sdbm)
end

function Hash.tryEncode(value: any): (boolean, string?, string?)
	return tryEncode(value)
end

function Hash.encode(value: any): string
	local ok, encoded, message = tryEncode(value)
	if not ok then
		error("Hash.encode rejected the value: " .. (message :: string), 2)
	end

	return encoded :: string
end

function Hash.hashEncoded(encoded: string): string
	if type(encoded) ~= "string" then
		error("Hash.hashEncoded expected a string", 2)
	end

	return hashEncoded(encoded)
end

function Hash.tryHash(value: any): (boolean, string?, string?)
	local ok, encoded, message = tryEncode(value)
	if not ok then
		return false, nil, message
	end

	return true, hashEncoded(encoded :: string), nil
end

function Hash.hash(value: any): string
	return hashEncoded(Hash.encode(value))
end

return Hash
