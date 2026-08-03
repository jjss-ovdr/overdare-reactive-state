--!nonstrict

-- Diagnostic only: identifies the practical nested pull limit of a host VM.
-- It is not part of the passing performance baseline.

local Runtime = require("../src/Core/Runtime")

local requested = tonumber((...))
local depths = if requested ~= nil then { requested } else { 100, 125, 150, 175, 200, 225, 250, 300 }

for _, depth in ipairs(depths) do
	local runtime = Runtime.new({ maxEvaluationDepth = depth })
	local tail = runtime:atom(0)
	for _ = 1, depth do
		local dependency = tail
		tail = runtime:computed(function()
			return dependency:get() + 1
		end)
	end
	local ok, result = pcall(tail.get, tail)
	local classification
	if ok then
		classification = "PASS"
	elseif string.find(tostring(result), "C stack overflow", 1, true) then
		classification = "HOST_STACK_LIMIT"
	elseif string.find(tostring(result), "evaluation depth limit", 1, true) then
		classification = "RUNTIME_DEPTH_LIMIT"
	else
		classification = "FAIL"
	end
	print(depth, classification, if ok then result else "-")
	runtime:dispose()
end
