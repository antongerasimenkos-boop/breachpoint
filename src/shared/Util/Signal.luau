--!strict
--[[
	Minimal synchronous signal for module-to-module events (pure Luau, no BindableEvents).

	Handlers run in connection order on the firing thread. A handler that errors does not stop
	the others; the error is reported through `Signal.onError` (defaults to `warn`).
	Disconnecting during a fire is safe.
]]

export type Connection = {
	connected: boolean,
	disconnect: (self: Connection) -> (),
}

export type Signal<T...> = {
	connect: (self: Signal<T...>, handler: (T...) -> ()) -> Connection,
	once: (self: Signal<T...>, handler: (T...) -> ()) -> Connection,
	fire: (self: Signal<T...>, T...) -> (),
	destroy: (self: Signal<T...>) -> (),
	connectionCount: (self: Signal<T...>) -> number,
}

type Slot = { handler: (...any) -> (), connection: Connection }

local Signal = {}
Signal.__index = Signal

Signal.onError = function(err: string)
	warn(err)
end

function Signal.new<T...>(): Signal<T...>
	local self = setmetatable({ _slots = {} :: { Slot } }, Signal)
	return self :: any
end

function Signal.connect(self: any, handler: (...any) -> ()): Connection
	local slots: { Slot } = self._slots
	local connection = { connected = true } :: any
	local slot: Slot = { handler = handler, connection = connection }
	function connection.disconnect(conn: Connection)
		if not conn.connected then
			return
		end
		conn.connected = false
		local index = table.find(self._slots, slot)
		if index then
			-- Copy-on-write so an in-progress fire keeps iterating its own snapshot.
			local copy = table.clone(self._slots)
			table.remove(copy, index)
			self._slots = copy
		end
	end
	local copy = table.clone(slots)
	table.insert(copy, slot)
	self._slots = copy
	return connection
end

function Signal.once(self: any, handler: (...any) -> ()): Connection
	local connection: Connection
	connection = Signal.connect(self, function(...)
		connection:disconnect()
		handler(...)
	end)
	return connection
end

function Signal.fire(self: any, ...: any)
	for _, slot in self._slots :: { Slot } do
		if slot.connection.connected then
			local ok, err = xpcall(slot.handler :: any, debug.traceback, ...)
			if not ok then
				Signal.onError(tostring(err))
			end
		end
	end
end

function Signal.destroy(self: any)
	for _, slot in self._slots :: { Slot } do
		slot.connection.connected = false
	end
	self._slots = {}
end

function Signal.connectionCount(self: any): number
	return #self._slots
end

return Signal
