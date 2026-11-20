--!strict
--[[
	In-memory stand-in for a GlobalDataStore, with the parts of the API SessionStore uses.

	Used in two places:
	  * Studio, when the place is unpublished or API access is off (real DataStores unavailable).
	  * Lune tests, where it can also inject failures to exercise the retry paths.

	Values are deep-copied on the way in and out, like real DataStores serialise them, so a
	caller can never mutate stored state through a reference it kept.
]]

export type MemoryDataStore = {
	UpdateAsync: (self: MemoryDataStore, key: string, transform: (any, any) -> ...any) -> (any, any),
	GetAsync: (self: MemoryDataStore, key: string) -> any,
	SetAsync: (self: MemoryDataStore, key: string, value: any) -> (),
	failNext: (self: MemoryDataStore, count: number, message: string?) -> (),
	writes: number,
	lastUserIds: { [string]: { number }? },
	_data: { [string]: any },
	_failures: number,
	_failureMessage: string,
}

local MemoryDataStore = {}
MemoryDataStore.__index = MemoryDataStore

local function deepCopy(value: any): any
	if type(value) ~= "table" then
		return value
	end
	local copy = {}
	for k, v in value do
		copy[deepCopy(k)] = deepCopy(v)
	end
	return copy
end

function MemoryDataStore.new(): MemoryDataStore
	local self = setmetatable({}, MemoryDataStore) :: any
	self._data = {}
	self._failures = 0
	self._failureMessage = "simulated DataStore failure"
	self.writes = 0
	self.lastUserIds = {}
	return self :: MemoryDataStore
end

local function maybeFail(self: MemoryDataStore)
	if self._failures > 0 then
		self._failures -= 1
		error(self._failureMessage, 0)
	end
end

-- Makes the next `count` requests throw, like a throttled or unavailable DataStore.
function MemoryDataStore.failNext(self: MemoryDataStore, count: number, message: string?)
	self._failures = count
	self._failureMessage = message or "simulated DataStore failure"
end

function MemoryDataStore.UpdateAsync(
	self: MemoryDataStore,
	key: string,
	transform: (any, any) -> ...any
): (any, any)
	maybeFail(self)
	local newValue, userIds = transform(deepCopy(self._data[key]), nil)
	if newValue == nil then
		-- Returning nil from the transform cancels the write, as in Roblox.
		return deepCopy(self._data[key]), nil
	end
	self._data[key] = deepCopy(newValue)
	self.lastUserIds[key] = deepCopy(userIds)
	self.writes += 1
	return deepCopy(newValue), nil
end

function MemoryDataStore.GetAsync(self: MemoryDataStore, key: string): any
	maybeFail(self)
	return deepCopy(self._data[key])
end

function MemoryDataStore.SetAsync(self: MemoryDataStore, key: string, value: any)
	maybeFail(self)
	self._data[key] = deepCopy(value)
	self.writes += 1
end

return MemoryDataStore
