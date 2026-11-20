--!strict
--[[
	A bag of things to tear down together: per-player or per-round connections, instances,
	threads and callbacks. One `clean()` call releases everything, which prevents leaks when a
	player leaves mid-round.

		local cleanup = Cleanup.new()
		cleanup:add(humanoid.Died:Connect(onDied))
		cleanup:add(highlight)
		cleanup:add(function() print("bye") end)
		cleanup:clean()

	Items are released in reverse order of insertion (last in, first out).
]]

export type Cleanup = {
	add: <T>(self: Cleanup, item: T) -> T,
	clean: (self: Cleanup) -> (),
	count: (self: Cleanup) -> number,
	_items: { any },
	_cleaning: boolean,
}

local Cleanup = {}
Cleanup.__index = Cleanup

function Cleanup.new(): Cleanup
	local self = setmetatable({ _items = {}, _cleaning = false }, Cleanup)
	return self :: any
end

local function release(item: any)
	local kind = typeof(item)
	if kind == "function" then
		item()
	elseif kind == "RBXScriptConnection" then
		item:Disconnect()
	elseif kind == "Instance" then
		item:Destroy()
	elseif kind == "thread" then
		if coroutine.status(item) ~= "dead" then
			pcall(task.cancel, item)
		end
	elseif kind == "table" then
		if type(item.disconnect) == "function" then
			item:disconnect()
		elseif type(item.Disconnect) == "function" then
			item:Disconnect()
		elseif type(item.destroy) == "function" then
			item:destroy()
		elseif type(item.Destroy) == "function" then
			item:Destroy()
		elseif type(item.clean) == "function" then
			item:clean()
		end
	end
end

function Cleanup.add<T>(self: Cleanup, item: T): T
	assert(not self._cleaning, "Cleanup:add called while cleaning")
	table.insert(self._items, item)
	return item
end

function Cleanup.clean(self: Cleanup)
	if self._cleaning then
		return
	end
	self._cleaning = true
	local items = self._items
	self._items = {}
	for i = #items, 1, -1 do
		local ok, err = pcall(release :: any, items[i])
		if not ok then
			warn("[Cleanup] failed to release item: " .. tostring(err))
		end
	end
	self._cleaning = false
end

function Cleanup.count(self: Cleanup): number
	return #self._items
end

return Cleanup
