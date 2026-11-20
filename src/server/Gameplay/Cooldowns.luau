--!strict
--[[
	Per-participant ability cooldowns, server-side and authoritative.

	`use` checks and starts a cooldown in one step, so two requests arriving in the same frame
	cannot both pass. The clock is injected (os.clock in game, a fake clock in tests).
]]

export type Cooldowns = {
	use: (self: Cooldowns, id: number, ability: string, duration: number) -> boolean,
	remaining: (self: Cooldowns, id: number, ability: string) -> number,
	clear: (self: Cooldowns, id: number?) -> (),
	_readyAt: { [number]: { [string]: number } },
	_clock: () -> number,
}

local Cooldowns = {}
Cooldowns.__index = Cooldowns

function Cooldowns.new(clock: (() -> number)?): Cooldowns
	local self = setmetatable({ _readyAt = {}, _clock = clock or os.clock }, Cooldowns)
	return self :: any
end

function Cooldowns.remaining(self: Cooldowns, id: number, ability: string): number
	local byAbility = self._readyAt[id]
	local readyAt = byAbility and byAbility[ability]
	if not readyAt then
		return 0
	end
	return math.max(0, readyAt - self._clock())
end

-- Returns true and starts the cooldown if the ability is ready; false otherwise.
function Cooldowns.use(self: Cooldowns, id: number, ability: string, duration: number): boolean
	if self:remaining(id, ability) > 0 then
		return false
	end
	local byAbility = self._readyAt[id]
	if not byAbility then
		byAbility = {}
		self._readyAt[id] = byAbility
	end
	byAbility[ability] = self._clock() + duration
	return true
end

-- Clears one participant's cooldowns, or everyone's when id is nil.
function Cooldowns.clear(self: Cooldowns, id: number?)
	if id then
		self._readyAt[id] = nil
	else
		self._readyAt = {}
	end
end

return Cooldowns
