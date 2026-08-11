--!strict

-- Compile-only public API fixture. This file deliberately exercises inference
-- through the package root rather than importing internal Core types.
local FRP = require("../../src")

local startHere: string = FRP.START_HERE
local guides: FRP.GuidesNamespace = FRP.Guides
local multiplayerGuide: FRP.ServerAuthoritativeMultiplayerGuide = guides.serverAuthoritativeMultiplayer
local guideRoute: FRP.GuideRoute = guides.routes.serverAuthoritativeMultiplayer
local _: string = multiplayerGuide.protocol
local _: string = guideRoute.entryPoint

local host: FRP.Host = FRP.newHost({ startTime = 0 })

local numbers, emitNumber = host:source({
	label = "numbers",
	capture = function(value: number): number
		return value
	end,
})

local _: FRP.Event<number> = numbers
local _: FRP.Emit<number> = emitNumber
local eventHost: FRP.Host = numbers:getHost()
local _: FRP.Event<number>, _: FRP.Emit<number> = eventHost:source({
	capture = function(value: number): number
		return value
	end,
})

local strings: FRP.Event<string> = numbers:map(function(value)
	return tostring(value)
end)

local timed: FRP.Event<string> = strings:mapWithTime(function(value, time)
	return value .. "@" .. tostring(time)
end)

local totals: FRP.Event<number> = numbers:scan(0, function(total, value)
	return total + value
end, {
	capture = function(value: number): number
		return value
	end,
})

local rebound: FRP.Event<string> = numbers:bind(function(value)
	return FRP.eventPure(host, tostring(value))
end)

local nestedEvents: FRP.Event<FRP.Event<string>> = numbers:map(function(value)
	return FRP.eventPure(host, tostring(value))
end)
local joinedEvents: FRP.Event<string> = nestedEvents:join()

local eventFunctions: FRP.Event<(number) -> string> = numbers:map(function(prefix)
	return function(value: number): string
		return tostring(prefix) .. ":" .. tostring(value)
	end
end)
local appliedEvents: FRP.Event<string> = eventFunctions:ap(numbers)

local reactiveNumber: FRP.Reactive<number> = FRP.stepper(0, numbers)
local _: FRP.Host = reactiveNumber:getHost()
local reactiveString: FRP.Reactive<string> = reactiveNumber:map(tostring)
local reactiveFunctions: FRP.Reactive<(number) -> string> = reactiveNumber:map(function(prefix)
	return function(value: number): string
		return tostring(prefix) .. ":" .. tostring(value)
	end
end)
local appliedReactive: FRP.Reactive<string> = reactiveFunctions:ap(reactiveNumber)
local reboundReactive: FRP.Reactive<string> = reactiveNumber:bind(function(value)
	return FRP.reactivePure(host, tostring(value))
end)
local nestedReactive: FRP.Reactive<FRP.Reactive<string>> = reactiveNumber:map(function(value)
	return FRP.reactivePure(host, tostring(value))
end)
local joinedReactive: FRP.Reactive<string> = nestedReactive:join()

local behaviorNumber: FRP.Behavior<number> = FRP.stepperBehavior(0, numbers)
local _: FRP.Host = behaviorNumber:getHost()
local behaviorString: FRP.Behavior<string> = behaviorNumber:map(tostring)
local behaviorFunctions: FRP.Behavior<(number) -> string> = behaviorNumber:map(function(prefix)
	return function(value: number): string
		return tostring(prefix) .. ":" .. tostring(value)
	end
end)
local appliedBehavior: FRP.Behavior<string> = behaviorFunctions:ap(behaviorNumber)
local behaviorSum: FRP.Behavior<number> = FRP.lift2(function(left, right)
	return left + right
end, behaviorNumber, FRP.time(host))
local phases: FRP.Reactive<FRP.TimeFunction<string>> = behaviorString:phases()

local snapshotPair: FRP.Event<FRP.Snapshot<number, string>> = numbers:snapshot(behaviorString)
local snapshotText: FRP.Event<string> = numbers:snapshot(behaviorString, function(eventValue, behaviorValue, time)
	return tostring(eventValue) .. behaviorValue .. tostring(time)
end)

local futureNumber: FRP.Future<number> = FRP.Future.pure(1)
local futureString: FRP.Future<string> = futureNumber:map(tostring)
local nestedFuture: FRP.Future<FRP.Future<string>> = futureNumber:map(function(value)
	return FRP.Future.pure(tostring(value))
end)
local joinedFuture: FRP.Future<string> = nestedFuture:join()
local futureEvent: FRP.Event<string> = host:eventFromFuture(futureString)

local timeFunction: FRP.TimeFunction<number> = FRP.TimeFunction.dynamic(function(time: number): number
	return time * 2
end)
local mappedTimeFunction: FRP.TimeFunction<string> = timeFunction:map(tostring)
local nestedTimeFunction: FRP.TimeFunction<FRP.TimeFunction<string>> = timeFunction:map(function(value)
	return FRP.TimeFunction.constant(tostring(value))
end)
local joinedTimeFunction: FRP.TimeFunction<string> = nestedTimeFunction:join()

local immutableNumber: FRP.Capture<number> = FRP.Immutable.serializable({
	clone = function(value: number): number
		return value
	end,
})

local occurrence: FRP.Occurrence<number>? = nil
numbers:subscribe(function(value, time, item)
	local _: number = value
	local _: number = time
	occurrence = item
end)

behaviorString:subscribe(function(value, time, metadata)
	local _: string = value
	local _: number = time
	local _: FRP.BehaviorSinkMetadata<string>? = metadata
end)

host:frame(1, function(frame)
	local _: number = frame.id
	emitNumber(2)
end)

local _: number = host:sample(behaviorNumber)
local typedOccurrences: { { time: number, value: number } } = {
	{ time = 2, value = immutableNumber(3) },
}
-- The pinned analyzer cannot infer T through the mixed named/tuple input union;
-- the public result and capture callback still pin this call to number.
local _: FRP.Event<number> = FRP.Event.fromOccurrences(host, typedOccurrences :: any, {
	capture = function(value: number): number
		return value
	end,
})

return {
	startHere = startHere,
	multiplayerGuide = multiplayerGuide,
	timed = timed,
	totals = totals,
	rebound = rebound,
	joinedEvents = joinedEvents,
	appliedEvents = appliedEvents,
	reactiveString = reactiveString,
	appliedReactive = appliedReactive,
	reboundReactive = reboundReactive,
	joinedReactive = joinedReactive,
	behaviorSum = behaviorSum,
	appliedBehavior = appliedBehavior,
	phases = phases,
	snapshotPair = snapshotPair,
	snapshotText = snapshotText,
	futureEvent = futureEvent,
	joinedFuture = joinedFuture,
	mappedTimeFunction = mappedTimeFunction,
	joinedTimeFunction = joinedTimeFunction,
	occurrence = occurrence,
}
