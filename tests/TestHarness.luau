--!nonstrict

local Harness = {}
Harness.__index = Harness

local function render(value)
	if type(value) == "string" then
		return string.format("%q", value)
	end
	return tostring(value)
end

local function deepEqual(a, b, seen)
	if rawequal(a, b) then
		return true
	end
	if type(a) ~= type(b) or type(a) ~= "table" then
		return false
	end
	seen = seen or {}
	if seen[a] == b then
		return true
	end
	seen[a] = b
	for key, value in pairs(a) do
		if not deepEqual(value, b[key], seen) then
			return false
		end
	end
	for key in pairs(b) do
		if a[key] == nil then
			return false
		end
	end
	return true
end

function Harness.new()
	return setmetatable({
		_tests = {},
		_passed = 0,
		_failed = 0,
	}, Harness)
end

function Harness:test(name, callback)
	assert(type(name) == "string" and name ~= "", "test name must be a non-empty string")
	assert(type(callback) == "function", "test callback must be a function")
	table.insert(self._tests, { name = name, callback = callback })
end

function Harness:equal(actual, expected, message)
	if not rawequal(actual, expected) then
		error(message or string.format("expected %s, got %s", render(expected), render(actual)), 2)
	end
end

function Harness:notEqual(actual, expected, message)
	if rawequal(actual, expected) then
		error(message or string.format("expected values to differ, both were %s", render(actual)), 2)
	end
end

function Harness:deepEqual(actual, expected, message)
	if not deepEqual(actual, expected) then
		error(message or "tables are not deeply equal", 2)
	end
end

function Harness:truthy(value, message)
	if not value then
		error(message or string.format("expected truthy value, got %s", render(value)), 2)
	end
end

function Harness:falsy(value, message)
	if value then
		error(message or string.format("expected falsy value, got %s", render(value)), 2)
	end
end

function Harness:throws(callback, pattern)
	local ok, err = pcall(callback)
	if ok then
		error("expected callback to throw", 2)
	end
	if pattern ~= nil and string.find(string.lower(tostring(err)), string.lower(pattern), 1, true) == nil then
		error(string.format("expected error containing %q, got %s", pattern, tostring(err)), 2)
	end
	return err
end

function Harness:run()
	for _, test in ipairs(self._tests) do
		local ok, err = pcall(test.callback)
		if ok then
			self._passed += 1
			print("PASS", test.name)
		else
			self._failed += 1
			print("FAIL", test.name, err)
		end
	end

	print(string.format("\n%d passed, %d failed, %d total", self._passed, self._failed, #self._tests))
	if self._failed > 0 then
		error(string.format("%d test(s) failed", self._failed), 0)
	end
	return self._passed
end

return Harness
