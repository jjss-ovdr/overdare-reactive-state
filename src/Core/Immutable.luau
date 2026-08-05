--!strict

-- Explicit capture policies for plain serializable FRP payloads. Generic FRP
-- values remain zero-copy by default so functions, Instances, and graph
-- handles are still valid payloads when the caller owns their immutability.

local DefaultCodec = require("./Codec")

local Immutable = {}

export type CloneCodec<T> = {
	clone: (value: T) -> T,
}

export type Capture<T> = (value: T) -> T

local function cloneSynchronously<T>(clone: (T) -> T, value: T): T
	local thread = coroutine.create(clone)
	local ok, result = coroutine.resume(thread, value)
	if not ok then
		error("Immutable.serializable codec.clone failed: " .. tostring(result), 3)
	end
	if coroutine.status(thread) ~= "dead" then
		error("Immutable.serializable codec.clone must finish synchronously and may not yield", 3)
	end
	return result :: T
end

local function freezeGraph(
	value: any,
	seen: { [any]: boolean },
	freezeTable: (any) -> any,
	isFrozen: (any) -> boolean
): any
	if type(value) ~= "table" then
		return value
	end
	if seen[value] then
		return value
	end
	if getmetatable(value) ~= nil then
		error(
			"Immutable.serializable codec.clone must return plain tables without metatables",
			0
		)
	end
	seen[value] = true

	-- Traverse keys as well as values. Default Codec accepts only primitive
	-- keys, while a custom codec may still return a table-keyed plain graph.
	for key, child in next, value do
		freezeGraph(key, seen, freezeTable, isFrozen)
		freezeGraph(child, seen, freezeTable, isFrozen)
	end

	if not isFrozen(value) then
		local ok, message = pcall(freezeTable, value)
		if not ok then
			error(
				"Immutable.serializable codec.clone must return freezeable plain tables: "
					.. tostring(message),
				0
			)
		end
	end
	return value
end

function Immutable.serializable<T>(codec: CloneCodec<T>?): Capture<T>
	local freezeTable = table.freeze
	local isFrozen = table.isfrozen
	if type(freezeTable) ~= "function" or type(isFrozen) ~= "function" then
		error("Immutable.serializable requires table.freeze and table.isfrozen support", 2)
	end

	local selected: any = codec or DefaultCodec
	if type(selected) ~= "table" or type(selected.clone) ~= "function" then
		error("Immutable.serializable codec must provide clone(value)", 2)
	end

	return function(value: T): T
		local cloned = cloneSynchronously(selected.clone, value)
		return freezeGraph(cloned, {}, freezeTable, isFrozen) :: T
	end
end

return Immutable
