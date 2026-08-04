--!nonstrict

-- BehaviorTree is deliberately only an execution facade. It owns no Runtime,
-- scheduler, clock, or authoritative state. Call :tick(ctx) from ordinary
-- Luau code (usually inside Runtime:step()).

local Behavior = {}

Behavior.SUCCESS = "success"
Behavior.FAILURE = "failure"
Behavior.RUNNING = "running"

local function normalizeStatus(value: any): string
	if value == nil or value == true then
		return Behavior.SUCCESS
	elseif value == false then
		return Behavior.FAILURE
	elseif value == Behavior.SUCCESS or value == Behavior.FAILURE or value == Behavior.RUNNING then
		return value
	end

	error("behavior action must return nil, boolean, or a Behavior status", 3)
end

local function assertChildren(children: any)
	assert(type(children) == "table", "behavior children must be an array")
	for index, child in ipairs(children) do
		assert(type(child) == "table" and type(child.tick) == "function", string.format(
			"behavior child #%d must implement :tick(ctx)",
			index
		))
	end
end

local function readCursor(self: any): number
	if self._cursorAtom ~= nil then
		return self._cursorAtom:get()
	end
	return self._cursor
end

local function writeCursor(self: any, cursor: number)
	if self._cursorAtom ~= nil then
		self._cursorAtom:set(cursor)
	else
		self._cursor = cursor
	end
end

local Action = {}
Action.__index = Action

function Action:tick(ctx: any): string
	return normalizeStatus(self._callback(ctx))
end

function Action:reset() end

function Behavior.action(callback: (any) -> any)
	assert(type(callback) == "function", "Behavior.action callback must be a function")
	return setmetatable({ _callback = callback }, Action)
end

local When = {}
When.__index = When

function When:tick(_ctx: any): string
	local value
	if type(self._source) == "function" then
		value = self._source()
	else
		assert(type(self._source) == "table" and type(self._source.get) == "function", "Behavior.when expects a Source or function")
		value = self._source:get()
	end

	return if value then Behavior.SUCCESS else Behavior.FAILURE
end

function When:reset() end

function Behavior.when(source: any)
	return setmetatable({ _source = source }, When)
end

local Sequence = {}
Sequence.__index = Sequence

function Sequence:tick(ctx: any): string
	local cursor = readCursor(self)
	assert(type(cursor) == "number" and cursor >= 1 and cursor % 1 == 0, "sequence cursor must be a positive integer")

	for index = cursor, #self._children do
		local status = normalizeStatus(self._children[index]:tick(ctx))
		if status == Behavior.RUNNING then
			writeCursor(self, index)
			return status
		elseif status == Behavior.FAILURE then
			writeCursor(self, 1)
			return status
		end
	end

	writeCursor(self, 1)
	return Behavior.SUCCESS
end

function Sequence:reset()
	writeCursor(self, 1)
	for _, child in ipairs(self._children) do
		if type(child.reset) == "function" then
			child:reset()
		end
	end
end

function Behavior.sequence(children: { any }, options: any?)
	assertChildren(children)
	options = options or {}
	return setmetatable({
		_children = children,
		_cursor = 1,
		_cursorAtom = options.cursor,
	}, Sequence)
end

local Selector = {}
Selector.__index = Selector

function Selector:tick(ctx: any): string
	local cursor = readCursor(self)
	assert(type(cursor) == "number" and cursor >= 1 and cursor % 1 == 0, "selector cursor must be a positive integer")

	for index = cursor, #self._children do
		local status = normalizeStatus(self._children[index]:tick(ctx))
		if status == Behavior.RUNNING then
			writeCursor(self, index)
			return status
		elseif status == Behavior.SUCCESS then
			writeCursor(self, 1)
			return status
		end
	end

	writeCursor(self, 1)
	return Behavior.FAILURE
end

function Selector:reset()
	writeCursor(self, 1)
	for _, child in ipairs(self._children) do
		if type(child.reset) == "function" then
			child:reset()
		end
	end
end

function Behavior.selector(children: { any }, options: any?)
	assertChildren(children)
	options = options or {}
	return setmetatable({
		_children = children,
		_cursor = 1,
		_cursorAtom = options.cursor,
	}, Selector)
end

local Invert = {}
Invert.__index = Invert

function Invert:tick(ctx: any): string
	local status = normalizeStatus(self._child:tick(ctx))
	if status == Behavior.SUCCESS then
		return Behavior.FAILURE
	elseif status == Behavior.FAILURE then
		return Behavior.SUCCESS
	end
	return status
end

function Invert:reset()
	if type(self._child.reset) == "function" then
		self._child:reset()
	end
end

function Behavior.invert(child: any)
	assertChildren({ child })
	return setmetatable({ _child = child }, Invert)
end

return Behavior
