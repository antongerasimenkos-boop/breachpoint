--!strict
--[[
	RoundMachine: the whole round flow as pure, deterministic logic.

	    Waiting ──(enough players)──► Intermission ──(timer)──► Build ──(timer)──► Hunt
	       ▲                             │   ▲                    │                 │
	       └──────(not enough players)───┘   │                    │ (hunter left /  │ (timer: builders survive,
	                                         │                    │  builders gone) │  all builders out: hunter
	                                         └──(timer)── Results ◄┴─────────────────┘  wins, hunter left, ...)
	                                         (or Waiting if too few)

	The machine knows nothing about Roblox. RoundService feeds it time (`update(dt)`), presence
	(`addPlayer` / `removePlayer`) and validated game events (`tag`, `eliminate`), then drains the
	events it emits (`drainEvents`) and performs the side effects: teleports, UI state, rewards.

	Solo practice: with exactly one human and `soloAllowed`, the machine fills the other role with
	bots (negative ids). The human picks a role with `setSoloRole`, which defaults to alternating.
	Choosing "Spectator" makes bots play both sides while the human watches (used to measure
	bot-vs-bot balance in Studio).
]]

local RoleAssigner = require("./RoleAssigner")
local StateMachine = require("./StateMachine")

export type Phase = "Waiting" | "Intermission" | "Build" | "Hunt" | "Results"
export type Role = "Builder" | "Hunter" | "Spectator"
export type Winner = "Builders" | "Hunter" | "None"
export type EliminationReason = "Tagged" | "Died" | "Left"

export type Timings = { Intermission: number, Build: number, Hunt: number, Results: number }

export type Options = {
	timings: Timings,
	soloTimings: Timings,
	minPlayers: number,
	soloAllowed: boolean,
	botBuilderCount: number,
	random: (() -> number)?,
}

export type Event =
	{ type: "PhaseChanged", from: Phase, to: Phase, duration: number }
	| { type: "RolesAssigned", hunter: number, builders: { number }, bots: { number }, solo: boolean }
	| { type: "Eliminated", id: number, by: number?, reason: EliminationReason }
	| {
		type: "RoundEnded",
		round: number,
		winner: Winner,
		reason: string,
		hunter: number?,
		builders: { number },
		survivors: { number },
		tags: { [number]: number }, -- tagger id -> tags this round (only the hunter can tag)
	}

export type Snapshot = {
	phase: Phase,
	timeLeft: number,
	round: number,
	solo: boolean,
	hunter: number?,
	builders: { number },
	alive: { number },
}

export type RoundMachine = {
	phase: Phase,
	timeLeft: number,
	round: number,
	solo: boolean,

	addPlayer: (self: RoundMachine, id: number) -> (),
	removePlayer: (self: RoundMachine, id: number) -> (),
	setSoloRole: (self: RoundMachine, id: number, role: Role) -> (boolean, string?),
	setPracticeBotCount: (self: RoundMachine, count: number) -> boolean,
	update: (self: RoundMachine, dt: number) -> (),
	tag: (self: RoundMachine, hunterId: number, targetId: number) -> (boolean, string?),
	eliminate: (self: RoundMachine, id: number, reason: EliminationReason) -> boolean,
	skip: (self: RoundMachine) -> (),
	getRole: (self: RoundMachine, id: number) -> Role,
	isAlive: (self: RoundMachine, id: number) -> boolean,
	isBot: (self: RoundMachine, id: number) -> boolean,
	hunterId: (self: RoundMachine) -> number?,
	snapshot: (self: RoundMachine) -> Snapshot,
	drainEvents: (self: RoundMachine) -> { Event },

	_options: Options,
	_fsm: any,
	_players: { [number]: boolean },
	_playerOrder: { number },
	_roles: { [number]: Role },
	_alive: { [number]: boolean },
	_bots: { [number]: boolean },
	_eliminations: { [number]: EliminationReason },
	_tags: { [number]: number },
	_soloPreference: Role?,
	_botBuilderCount: number,
	_lastSoloRole: Role?,
	_assigner: RoleAssigner.RoleAssigner,
	_events: { Event },
	_enter: (self: RoundMachine, phase: Phase) -> (),
	_eligible: (self: RoundMachine) -> boolean,
	_humanCount: (self: RoundMachine) -> number,
	_assignRoles: (self: RoundMachine) -> (),
	_endRound: (self: RoundMachine, winner: Winner, reason: string) -> (),
	_checkRoundOver: (self: RoundMachine) -> (),
	_timings: (self: RoundMachine) -> Timings,
}

local TRANSITIONS: { [Phase]: { Phase } } = {
	Waiting = { "Intermission" },
	Intermission = { "Waiting", "Build" },
	Build = { "Hunt", "Results" },
	Hunt = { "Results" },
	Results = { "Intermission", "Waiting" },
}

local RoundMachine = {}
RoundMachine.__index = RoundMachine

-- Typed so every event literal is checked against the Event union.
local function emit(self: RoundMachine, event: Event)
	table.insert(self._events, event)
end

function RoundMachine.new(options: Options): RoundMachine
	local self = setmetatable({}, RoundMachine) :: any
	self._options = options
	self._fsm = StateMachine.new("Waiting" :: Phase, TRANSITIONS)
	self.phase = "Waiting"
	self.timeLeft = 0
	self.round = 0
	self.solo = false
	self._players = {}
	self._playerOrder = {}
	self._roles = {}
	self._alive = {}
	self._bots = {}
	self._eliminations = {}
	self._tags = {}
	self._soloPreference = nil
	self._botBuilderCount = options.botBuilderCount
	self._lastSoloRole = nil
	self._assigner = RoleAssigner.new(options.random)
	self._events = {}
	return self :: RoundMachine
end

function RoundMachine._timings(self: RoundMachine): Timings
	return if self.solo then self._options.soloTimings else self._options.timings
end

function RoundMachine._humanCount(self: RoundMachine): number
	return #self._playerOrder
end

function RoundMachine._eligible(self: RoundMachine): boolean
	local humans = self:_humanCount()
	return humans >= self._options.minPlayers or (humans == 1 and self._options.soloAllowed)
end

function RoundMachine._enter(self: RoundMachine, phase: Phase)
	local from: Phase = self.phase
	self._fsm:transition(phase)
	self.phase = phase
	if phase == "Intermission" then
		-- Provisional (picks the countdown length); confirmed when the Build phase starts.
		self.solo = self:_humanCount() < self._options.minPlayers
	end
	local duration = if phase == "Waiting" then 0 else (self:_timings() :: any)[phase]
	self.timeLeft = duration
	emit(self, { type = "PhaseChanged", from = from, to = phase, duration = duration })
end

function RoundMachine._assignRoles(self: RoundMachine)
	self._roles = {}
	self._alive = {}
	self._bots = {}
	self._eliminations = {}
	self._tags = {}
	self.round += 1

	local humans = table.clone(self._playerOrder)
	local hunter: number
	local builders: { number } = {}
	local bots: { number } = {}

	if self.solo then
		local human = humans[1]
		local role: Role = self._soloPreference
			or (if self._lastSoloRole == "Builder" then "Hunter" else "Builder")
		self._lastSoloRole = role
		if role == "Hunter" then
			hunter = human
			for i = 1, self._botBuilderCount do
				local botId = -i
				table.insert(builders, botId)
				table.insert(bots, botId)
			end
		elseif role == "Spectator" then
			-- Bots on both sides; the human watches from the lobby.
			hunter = -1
			table.insert(bots, hunter)
			for i = 1, self._botBuilderCount do
				local botId = -(i + 1)
				table.insert(builders, botId)
				table.insert(bots, botId)
			end
		else
			hunter = -1
			table.insert(bots, hunter)
			table.insert(builders, human)
		end
	else
		hunter = self._assigner:pickHunter(humans)
		for _, id in humans do
			if id ~= hunter then
				table.insert(builders, id)
			end
		end
		self._assigner:recordRound(hunter, humans)
	end

	for _, id in bots do
		self._bots[id] = true
	end
	self._roles[hunter] = "Hunter"
	self._alive[hunter] = true
	for _, id in builders do
		self._roles[id] = "Builder"
		self._alive[id] = true
	end

	emit(self, {
		type = "RolesAssigned",
		hunter = hunter,
		builders = builders,
		bots = bots,
		solo = self.solo,
	})
end

function RoundMachine._endRound(self: RoundMachine, winner: Winner, reason: string)
	local hunter = self:hunterId()
	local builders, survivors = {}, {}
	for id, role in self._roles do
		if role == "Builder" then
			table.insert(builders, id)
			if self._alive[id] then
				table.insert(survivors, id)
			end
		end
	end
	table.sort(builders)
	table.sort(survivors)
	self:_enter("Results")
	emit(self, {
		type = "RoundEnded",
		round = self.round,
		winner = winner,
		reason = reason,
		hunter = hunter,
		builders = builders,
		survivors = survivors,
		tags = table.clone(self._tags),
	})
end

-- Ends the round early if its outcome is already decided.
function RoundMachine._checkRoundOver(self: RoundMachine)
	if self.phase ~= "Build" and self.phase ~= "Hunt" then
		return
	end
	local hunter = self:hunterId()
	if hunter == nil or not self._alive[hunter] then
		-- Voided rather than a builder win, so leaving can't be used to farm wins.
		self:_endRound("None", "HunterLeft")
		return
	end
	local anyAlive, anyCaught = false, false
	for id, role in self._roles do
		if role == "Builder" then
			if self._alive[id] then
				anyAlive = true
			elseif self._eliminations[id] == "Tagged" or self._eliminations[id] == "Died" then
				anyCaught = true
			end
		end
	end
	if not anyAlive then
		if anyCaught then
			self:_endRound("Hunter", "AllBuildersCaught")
		else
			self:_endRound("None", "BuildersLeft")
		end
	end
end

function RoundMachine.addPlayer(self: RoundMachine, id: number)
	assert(id > 0, "human ids must be positive (bots use negative ids)")
	if self._players[id] then
		return
	end
	self._players[id] = true
	table.insert(self._playerOrder, id)
	-- Late joiners spectate until the next round; Waiting reacts on the next update.
end

function RoundMachine.removePlayer(self: RoundMachine, id: number)
	if not self._players[id] then
		return
	end
	self._players[id] = nil
	table.remove(self._playerOrder, table.find(self._playerOrder, id) :: number)
	self._assigner:forget(id)
	if self._roles[id] and self._alive[id] then
		self._alive[id] = false
		self._eliminations[id] = "Left"
		emit(self, { type = "Eliminated", id = id, by = nil, reason = "Left" })
	end
	self:_checkRoundOver()
end

function RoundMachine.setSoloRole(self: RoundMachine, id: number, role: Role): (boolean, string?)
	if not self._players[id] then
		return false, "NotPlaying"
	end
	if role ~= "Builder" and role ~= "Hunter" and role ~= "Spectator" then
		return false, "InvalidRole"
	end
	if self:_humanCount() ~= 1 or not self._options.soloAllowed then
		return false, "NotSolo"
	end
	if self.phase == "Build" or self.phase == "Hunt" then
		return false, "RoundInProgress"
	end
	self._soloPreference = role
	return true, nil
end

-- How many bot builders practice rounds use (1..8).
function RoundMachine.setPracticeBotCount(self: RoundMachine, count: number): boolean
	if count % 1 ~= 0 or count < 1 or count > 8 then
		return false
	end
	self._botBuilderCount = count
	return true
end

function RoundMachine.update(self: RoundMachine, dt: number)
	if self.phase == "Waiting" then
		if self:_eligible() then
			self:_enter("Intermission")
		end
		return
	end

	if self.phase == "Intermission" and not self:_eligible() then
		self:_enter("Waiting")
		return
	end

	self.timeLeft = math.max(0, self.timeLeft - dt)
	if self.timeLeft > 0 then
		return
	end

	if self.phase == "Intermission" then
		-- Re-decide solo with the players actually present now: someone may have joined or
		-- left during the countdown.
		self.solo = self:_humanCount() < self._options.minPlayers
		self:_enter("Build")
		self:_assignRoles()
	elseif self.phase == "Build" then
		self:_enter("Hunt")
	elseif self.phase == "Hunt" then
		self:_endRound("Builders", "Survived")
	elseif self.phase == "Results" then
		self._roles = {}
		self._alive = {}
		self._bots = {}
		self:_enter(if self:_eligible() then "Intermission" else "Waiting")
	end
end

-- Game-rule half of a tag; RoundService checks distance and line of sight before calling this.
function RoundMachine.tag(self: RoundMachine, hunterId: number, targetId: number): (boolean, string?)
	if self.phase ~= "Hunt" then
		return false, "WrongPhase"
	end
	if self._roles[hunterId] ~= "Hunter" or not self._alive[hunterId] then
		return false, "NotHunter"
	end
	if self._roles[targetId] ~= "Builder" then
		return false, "NotABuilder"
	end
	if not self._alive[targetId] then
		return false, "AlreadyOut"
	end
	self._alive[targetId] = false
	self._eliminations[targetId] = "Tagged"
	self._tags[hunterId] = (self._tags[hunterId] or 0) + 1
	emit(self, { type = "Eliminated", id = targetId, by = hunterId, reason = "Tagged" })
	self:_checkRoundOver()
	return true, nil
end

-- A participant is out for a reason other than a tag (e.g. their character died).
function RoundMachine.eliminate(self: RoundMachine, id: number, reason: EliminationReason): boolean
	if (self.phase ~= "Build" and self.phase ~= "Hunt") or not self._alive[id] then
		return false
	end
	if self._roles[id] == "Hunter" then
		-- The hunter respawns instead of being eliminated; only leaving voids the round.
		return false
	end
	self._alive[id] = false
	self._eliminations[id] = reason
	emit(self, { type = "Eliminated", id = id, by = nil, reason = reason })
	self:_checkRoundOver()
	return true
end

function RoundMachine.skip(self: RoundMachine)
	self.timeLeft = 0
end

function RoundMachine.getRole(self: RoundMachine, id: number): Role
	return self._roles[id] or "Spectator"
end

function RoundMachine.isAlive(self: RoundMachine, id: number): boolean
	return self._alive[id] == true
end

function RoundMachine.isBot(self: RoundMachine, id: number): boolean
	return self._bots[id] == true
end

function RoundMachine.hunterId(self: RoundMachine): number?
	for id, role in self._roles do
		if role == "Hunter" then
			return id
		end
	end
	return nil
end

function RoundMachine.snapshot(self: RoundMachine): Snapshot
	local builders, alive = {}, {}
	for id, role in self._roles do
		if role == "Builder" then
			table.insert(builders, id)
		end
		if self._alive[id] then
			table.insert(alive, id)
		end
	end
	table.sort(builders)
	table.sort(alive)
	return {
		phase = self.phase,
		timeLeft = self.timeLeft,
		round = self.round,
		solo = self.solo,
		hunter = self:hunterId(),
		builders = builders,
		alive = alive,
	}
end

function RoundMachine.drainEvents(self: RoundMachine): { Event }
	local events = self._events
	self._events = {}
	return events
end

return RoundMachine
