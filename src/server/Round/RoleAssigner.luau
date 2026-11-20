--!strict
--[[
	Fair hunter selection.

	Every player holds "tickets" equal to the number of rounds they have played since they were
	last the hunter (new players start with 1). The hunter is drawn at random, weighted by tickets,
	so the longer you have waited the likelier you are to be picked. One hard rule applies on top:
	the previous hunter is never picked twice in a row when anyone else is available.

	Pure: randomness is injected so tests are deterministic.
]]

export type RoleAssigner = {
	pickHunter: (self: RoleAssigner, candidates: { number }) -> number,
	recordRound: (self: RoleAssigner, hunterId: number, participants: { number }) -> (),
	forget: (self: RoleAssigner, id: number) -> (),
	tickets: (self: RoleAssigner, id: number) -> number,
	_tickets: { [number]: number },
	_lastHunter: number?,
	_random: () -> number,
}

local RoleAssigner = {}
RoleAssigner.__index = RoleAssigner

function RoleAssigner.new(random: (() -> number)?): RoleAssigner
	local self = setmetatable({
		_tickets = {},
		_lastHunter = nil,
		_random = random or math.random,
	}, RoleAssigner)
	return self :: any
end

function RoleAssigner.tickets(self: RoleAssigner, id: number): number
	return self._tickets[id] or 1
end

function RoleAssigner.pickHunter(self: RoleAssigner, candidates: { number }): number
	assert(#candidates > 0, "pickHunter needs at least one candidate")
	local pool = candidates
	if #candidates > 1 and self._lastHunter ~= nil and table.find(candidates, self._lastHunter) then
		pool = table.clone(candidates)
		table.remove(pool, table.find(pool, self._lastHunter) :: number)
	end

	-- Iterate in a stable order so the same random stream always gives the same answer.
	pool = table.clone(pool)
	table.sort(pool)

	local total = 0
	for _, id in pool do
		total += self:tickets(id)
	end
	local roll = self._random() * total
	for _, id in pool do
		roll -= self:tickets(id)
		if roll < 0 then
			return id
		end
	end
	return pool[#pool]
end

-- Call once per round that actually started, with everyone who took part.
function RoleAssigner.recordRound(self: RoleAssigner, hunterId: number, participants: { number })
	for _, id in participants do
		if id == hunterId then
			self._tickets[id] = 1
		else
			self._tickets[id] = self:tickets(id) + 1
		end
	end
	self._lastHunter = hunterId
end

function RoleAssigner.forget(self: RoleAssigner, id: number)
	self._tickets[id] = nil
	if self._lastHunter == id then
		self._lastHunter = nil
	end
end

return RoleAssigner
