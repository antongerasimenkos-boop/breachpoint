--!strict
local RoleAssigner = require("../../src/server/Round/RoleAssigner")
local RoundMachine = require("../../src/server/Round/RoundMachine")
local StateMachine = require("../../src/server/Round/StateMachine")

return function(kit: any)
	local describe, it, expect = kit.describe, kit.it, kit.expect

	-- Deterministic [0, 1) stream (LCG) so role picks are reproducible.
	local function seeded(seed: number)
		local state = seed
		return function()
			state = (state * 1103515245 + 12345) % 2147483648
			return state / 2147483648
		end
	end

	local TIMINGS = { Intermission = 10, Build = 20, Hunt = 30, Results = 5 }
	local SOLO = { Intermission = 3, Build = 6, Hunt = 9, Results = 2 }

	local function newMachine(overrides: { [string]: any }?)
		local options: { [string]: any } = {
			timings = TIMINGS,
			soloTimings = SOLO,
			minPlayers = 2,
			soloAllowed = false,
			botBuilderCount = 3,
			random = seeded(7),
		}
		for k, v in overrides or {} do
			options[k] = v
		end
		return RoundMachine.new(options :: any)
	end

	local function phases(events)
		local out = {}
		for _, e in events do
			if e.type == "PhaseChanged" then
				table.insert(out, e.to)
			end
		end
		return out
	end

	local function find(events, kind: string)
		for _, e in events do
			if e.type == kind then
				return e
			end
		end
		return nil
	end

	-- Advances to the start of the Build phase and returns the RolesAssigned event.
	local function startRound(m)
		m:update(0)
		m:update(TIMINGS.Intermission)
		return find(m:drainEvents(), "RolesAssigned")
	end

	describe("StateMachine", function()
		it("allows declared transitions and notifies listeners", function()
			local fsm = StateMachine.new("A", { A = { "B" }, B = { "A" } })
			local seen = {}
			fsm:onTransition(function(from, to)
				table.insert(seen, from .. ">" .. to)
			end)
			fsm:transition("B")
			fsm:transition("A")
			expect(seen).toEqual({ "A>B", "B>A" })
		end)

		it("rejects undeclared transitions", function()
			local fsm = StateMachine.new("A", { A = { "B" }, B = {} })
			fsm:transition("B")
			expect(function()
				fsm:transition("A")
			end).toThrow("illegal transition B -> A")
		end)

		it("rejects re-entrant transitions from listeners", function()
			local fsm = StateMachine.new("A", { A = { "B" }, B = { "A" } })
			fsm:onTransition(function()
				fsm:transition("A")
			end)
			expect(function()
				fsm:transition("B")
			end).toThrow("re-entrant")
		end)

		it("validates the transition table", function()
			expect(function()
				StateMachine.new("A", { A = { "Missing" } })
			end).toThrow("not a declared state")
		end)
	end)

	describe("RoleAssigner", function()
		it("never picks the same hunter twice in a row", function()
			local assigner = RoleAssigner.new(seeded(1))
			local players = { 1, 2, 3 }
			local last = nil
			for _ = 1, 200 do
				local hunter = assigner:pickHunter(players)
				expect(hunter ~= last).toBe(true)
				assigner:recordRound(hunter, players)
				last = hunter
			end
		end)

		it("spreads the hunter role fairly over many rounds", function()
			local assigner = RoleAssigner.new(seeded(42))
			local players = { 10, 20, 30, 40 }
			local counts = { [10] = 0, [20] = 0, [30] = 0, [40] = 0 }
			for _ = 1, 400 do
				local hunter = assigner:pickHunter(players)
				counts[hunter] += 1
				assigner:recordRound(hunter, players)
			end
			for _, n in counts do
				expect(n).toBeGreaterThan(75) -- expected 100 each
				expect(n).toBeLessThan(125)
			end
		end)

		it("favours whoever has waited longest", function()
			local assigner = RoleAssigner.new(seeded(3))
			-- Player 1 hunted last round, 2 hunted two rounds ago, 3 has never hunted.
			assigner:recordRound(2, { 1, 2, 3 })
			assigner:recordRound(1, { 1, 2, 3 })
			expect(assigner:tickets(3)).toBe(3)
			expect(assigner:tickets(2)).toBe(2)
			local picks = { [2] = 0, [3] = 0 }
			for seed = 1, 300 do
				local probe = RoleAssigner.new(seeded(seed))
				probe:recordRound(2, { 1, 2, 3 })
				probe:recordRound(1, { 1, 2, 3 })
				local pick = probe:pickHunter({ 1, 2, 3 })
				picks[pick] += 1
			end
			expect(picks[3]).toBeGreaterThan(picks[2])
		end)

		it("works with a single candidate", function()
			local assigner = RoleAssigner.new(seeded(1))
			assigner:recordRound(5, { 5 })
			expect(assigner:pickHunter({ 5 })).toBe(5)
		end)
	end)

	describe("RoundMachine", function()
		it("waits for the minimum number of players", function()
			local m = newMachine()
			m:addPlayer(1)
			m:update(1)
			expect(m.phase).toBe("Waiting")
			m:addPlayer(2)
			m:update(0)
			expect(m.phase).toBe("Intermission")
			expect(m.timeLeft).toBe(TIMINGS.Intermission)
		end)

		it("falls back to Waiting if players leave during intermission", function()
			local m = newMachine()
			m:addPlayer(1)
			m:addPlayer(2)
			m:update(0)
			m:removePlayer(2)
			m:update(1)
			expect(m.phase).toBe("Waiting")
		end)

		it("runs the full cycle with timers and assigns exactly one hunter", function()
			local m = newMachine()
			for id = 1, 4 do
				m:addPlayer(id)
			end
			local roles = startRound(m)
			expect(m.phase).toBe("Build")
			expect(roles).toBeTruthy()
			expect(#roles.builders).toBe(3)
			expect(table.find(roles.builders, roles.hunter)).toBeNil()
			expect(m:getRole(roles.hunter)).toBe("Hunter")

			m:update(TIMINGS.Build)
			expect(m.phase).toBe("Hunt")
			m:update(TIMINGS.Hunt)
			expect(m.phase).toBe("Results")
			local ended = find(m:drainEvents(), "RoundEnded")
			expect(ended.winner).toBe("Builders")
			expect(ended.reason).toBe("Survived")
			expect(#ended.survivors).toBe(3)

			m:update(TIMINGS.Results)
			expect(m.phase).toBe("Intermission")
			expect(m:getRole(roles.hunter)).toBe("Spectator")
		end)

		it("emits phase changes in order", function()
			local m = newMachine()
			m:addPlayer(1)
			m:addPlayer(2)
			m:update(0)
			m:update(TIMINGS.Intermission)
			m:update(TIMINGS.Build)
			m:update(TIMINGS.Hunt)
			m:update(TIMINGS.Results)
			expect(phases(m:drainEvents())).toEqual({
				"Intermission",
				"Build",
				"Hunt",
				"Results",
				"Intermission",
			})
		end)

		it("ends early with a hunter win when every builder is tagged", function()
			local m = newMachine()
			for id = 1, 3 do
				m:addPlayer(id)
			end
			local roles = startRound(m)
			m:update(TIMINGS.Build)
			for _, builder in roles.builders do
				expect((m:tag(roles.hunter, builder))).toBe(true)
			end
			expect(m.phase).toBe("Results")
			local ended = find(m:drainEvents(), "RoundEnded")
			expect(ended.winner).toBe("Hunter")
			expect(ended.tags[roles.hunter]).toBe(2)
		end)

		it("rejects invalid tags", function()
			local m = newMachine()
			for id = 1, 3 do
				m:addPlayer(id)
			end
			local roles = startRound(m)
			local b1, b2 = roles.builders[1], roles.builders[2]
			expect(select(2, m:tag(roles.hunter, b1))).toBe("WrongPhase") -- still building
			m:update(TIMINGS.Build)
			expect(select(2, m:tag(b1, b2))).toBe("NotHunter")
			expect(select(2, m:tag(roles.hunter, roles.hunter))).toBe("NotABuilder")
			expect(select(2, m:tag(roles.hunter, 999))).toBe("NotABuilder")
			m:tag(roles.hunter, b1)
			expect(select(2, m:tag(roles.hunter, b1))).toBe("AlreadyOut")
		end)

		it("voids the round when the hunter leaves", function()
			local m = newMachine()
			for id = 1, 3 do
				m:addPlayer(id)
			end
			local roles = startRound(m)
			m:update(TIMINGS.Build)
			m:removePlayer(roles.hunter)
			expect(m.phase).toBe("Results")
			local ended = find(m:drainEvents(), "RoundEnded")
			expect(ended.winner).toBe("None")
			expect(ended.reason).toBe("HunterLeft")
		end)

		it("voids the round when every builder leaves untagged", function()
			local m = newMachine()
			for id = 1, 3 do
				m:addPlayer(id)
			end
			local roles = startRound(m)
			for _, builder in roles.builders do
				m:removePlayer(builder)
			end
			local ended = find(m:drainEvents(), "RoundEnded")
			expect(ended.winner).toBe("None")
			expect(ended.reason).toBe("BuildersLeft")
		end)

		it("gives the hunter the win if the last builder leaves after others were tagged", function()
			local m = newMachine()
			for id = 1, 3 do
				m:addPlayer(id)
			end
			local roles = startRound(m)
			m:update(TIMINGS.Build)
			m:tag(roles.hunter, roles.builders[1])
			m:removePlayer(roles.builders[2])
			local ended = find(m:drainEvents(), "RoundEnded")
			expect(ended.winner).toBe("Hunter")
		end)

		it("treats a builder's death as elimination, but the hunter respawns", function()
			local m = newMachine()
			for id = 1, 3 do
				m:addPlayer(id)
			end
			local roles = startRound(m)
			m:update(TIMINGS.Build)
			expect(m:eliminate(roles.builders[1], "Died")).toBe(true)
			expect(m:isAlive(roles.builders[1])).toBe(false)
			expect(m:eliminate(roles.hunter, "Died")).toBe(false)
			expect(m:isAlive(roles.hunter)).toBe(true)
		end)

		it("lets late joiners spectate until the next round", function()
			local m = newMachine()
			m:addPlayer(1)
			m:addPlayer(2)
			startRound(m)
			m:addPlayer(3)
			expect(m:getRole(3)).toBe("Spectator")
			m:update(TIMINGS.Build)
			m:update(TIMINGS.Hunt)
			m:update(TIMINGS.Results)
			m:update(TIMINGS.Intermission)
			expect(m:getRole(3) ~= "Spectator").toBe(true)
		end)

		it("goes back to Waiting after results if too few players remain", function()
			local m = newMachine()
			m:addPlayer(1)
			m:addPlayer(2)
			local roles = startRound(m)
			m:update(TIMINGS.Build)
			m:removePlayer(roles.builders[1])
			m:update(TIMINGS.Results)
			expect(m.phase).toBe("Waiting")
		end)

		it("skip() advances the current phase on the next update", function()
			local m = newMachine()
			m:addPlayer(1)
			m:addPlayer(2)
			m:update(0)
			m:skip()
			m:update(0)
			expect(m.phase).toBe("Build")
		end)
	end)

	describe("RoundMachine solo practice", function()
		it("does not start alone unless solo is allowed", function()
			local m = newMachine()
			m:addPlayer(1)
			m:update(100)
			expect(m.phase).toBe("Waiting")
		end)

		it("starts alone with bots and solo timings", function()
			local m = newMachine({ soloAllowed = true })
			m:addPlayer(1)
			m:update(0)
			expect(m.phase).toBe("Intermission")
			expect(m.timeLeft).toBe(SOLO.Intermission)
			m:update(SOLO.Intermission)
			local roles = find(m:drainEvents(), "RolesAssigned")
			expect(roles.solo).toBe(true)
			-- First solo round defaults to Builder against one bot hunter.
			expect(roles.builders).toEqual({ 1 })
			expect(roles.hunter < 0).toBe(true)
			expect(m:isBot(roles.hunter)).toBe(true)
			expect(m.timeLeft).toBe(SOLO.Build)
		end)

		it("alternates roles by default and honours an explicit choice", function()
			local m = newMachine({ soloAllowed = true })
			m:addPlayer(1)
			m:update(0)
			m:update(SOLO.Intermission)
			m:update(SOLO.Build)
			m:update(SOLO.Hunt)
			m:update(SOLO.Results)
			m:drainEvents()
			m:update(SOLO.Intermission)
			local second = find(m:drainEvents(), "RolesAssigned")
			expect(second.hunter).toBe(1)
			expect(#second.builders).toBe(3)

			m:update(SOLO.Build)
			expect(select(2, m:setSoloRole(1, "Builder"))).toBe("RoundInProgress")
			m:update(SOLO.Hunt)
			expect((m:setSoloRole(1, "Hunter"))).toBe(true)
			m:update(SOLO.Results)
			m:update(SOLO.Intermission)
			local third = find(m:drainEvents(), "RolesAssigned")
			expect(third.hunter).toBe(1)
		end)

		it("lets the player watch bots play both sides", function()
			local m = newMachine({ soloAllowed = true })
			m:addPlayer(1)
			expect((m:setSoloRole(1, "Spectator"))).toBe(true)
			expect(m:setPracticeBotCount(5)).toBe(true)
			expect(m:setPracticeBotCount(0)).toBe(false)
			m:update(0)
			m:update(SOLO.Intermission)
			local roles = find(m:drainEvents(), "RolesAssigned")
			expect(roles.hunter).toBe(-1)
			expect(#roles.builders).toBe(5)
			expect(table.find(roles.builders, 1)).toBeNil()
			expect(#roles.bots).toBe(6)
			expect(m:getRole(1)).toBe("Spectator")
			-- The bots' round plays out normally: tag everyone and the hunter wins.
			m:update(SOLO.Build)
			for _, id in roles.builders do
				m:tag(-1, id)
			end
			expect(find(m:drainEvents(), "RoundEnded").winner).toBe("Hunter")
		end)

		it("rejects setSoloRole with two or more players", function()
			local m = newMachine({ soloAllowed = true })
			m:addPlayer(1)
			m:addPlayer(2)
			expect(select(2, m:setSoloRole(1, "Hunter"))).toBe("NotSolo")
		end)

		it("switches to a normal round if a second player joins during the countdown", function()
			local m = newMachine({ soloAllowed = true })
			m:addPlayer(1)
			m:update(0)
			m:addPlayer(2)
			m:update(SOLO.Intermission)
			local roles = find(m:drainEvents(), "RolesAssigned")
			expect(roles.solo).toBe(false)
			expect(#roles.bots).toBe(0)
		end)

		it("switches to solo if a player leaves during a normal countdown", function()
			local m = newMachine({ soloAllowed = true })
			m:addPlayer(1)
			m:addPlayer(2)
			m:update(0)
			m:removePlayer(2)
			m:update(TIMINGS.Intermission)
			local roles = find(m:drainEvents(), "RolesAssigned")
			expect(roles.solo).toBe(true)
			expect(m.phase).toBe("Build")
		end)
	end)
end
