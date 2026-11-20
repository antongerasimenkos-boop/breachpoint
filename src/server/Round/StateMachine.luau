--!strict
--[[
	A small explicit finite-state machine. Every legal transition is declared up front, and an
	undeclared transition is an error rather than a silent state change.

		local fsm = StateMachine.new("Waiting", {
			Waiting = { "Intermission" },
			Intermission = { "Waiting", "Build" },
			...
		})
		fsm:onTransition(function(from, to) ... end)
		fsm:transition("Intermission")
]]

export type StateMachine<S> = {
	state: S,
	can: (self: StateMachine<S>, to: S) -> boolean,
	transition: (self: StateMachine<S>, to: S) -> (),
	onTransition: (self: StateMachine<S>, listener: (from: S, to: S) -> ()) -> (),
	_edges: { [S]: { [S]: boolean } },
	_listeners: { (from: S, to: S) -> () },
	_transitioning: boolean,
}

local StateMachine = {}
StateMachine.__index = StateMachine

function StateMachine.new<S>(initial: S, transitions: { [S]: { S } }): StateMachine<S>
	local edges = {}
	for from, targets in transitions do
		edges[from] = {}
		for _, to in targets do
			edges[from][to] = true
		end
	end
	assert(edges[initial], "initial state has no transition entry: " .. tostring(initial))
	for _, targets in transitions do
		for _, to in targets do
			assert(edges[to], "transition target is not a declared state: " .. tostring(to))
		end
	end

	local self = setmetatable({
		state = initial,
		_edges = edges,
		_listeners = {},
		_transitioning = false,
	}, StateMachine)
	return self :: any
end

function StateMachine.can<S>(self: StateMachine<S>, to: S): boolean
	return self._edges[self.state][to] == true
end

function StateMachine.transition<S>(self: StateMachine<S>, to: S)
	assert(not self._transitioning, "re-entrant transition to " .. tostring(to))
	if not self:can(to) then
		error(string.format("illegal transition %s -> %s", tostring(self.state), tostring(to)), 2)
	end
	local from = self.state
	self.state = to
	self._transitioning = true
	for _, listener in self._listeners do
		local ok, err = pcall(listener :: any, from, to)
		if not ok then
			self._transitioning = false
			error(err, 0)
		end
	end
	self._transitioning = false
end

function StateMachine.onTransition<S>(self: StateMachine<S>, listener: (from: S, to: S) -> ())
	table.insert(self._listeners, listener)
end

return StateMachine
