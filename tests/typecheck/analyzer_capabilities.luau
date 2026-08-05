--!strict

-- This is a toolchain capability probe, not an application fixture. The public
-- FRP surface depends on read-only properties and recursive generic methods.

type ReadonlyBox<T> = {
	read value: T,
}

type Handle<T> = {
	read _type: (T) -> T,
}

type Methods = {
	map: <T, U>(self: Handle<T> & Methods, mapper: (T) -> U) -> (Handle<U> & Methods),
}

export type GenericHandle<T> = Handle<T> & Methods

local box: ReadonlyBox<number> = { value = 1 }
local value: number = box.value

return value
