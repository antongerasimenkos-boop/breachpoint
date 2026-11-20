--!strict
--[[
	RoundSim: a headless Build + Hunt round on the game's real pure modules.

	Real code used: Config (all numbers), BlockGrid (placement/support/damage/repair rules),
	Cooldowns, FortPlanner (how builders fortify), HunterBrain (pathing, breaching, tagging,
	Shockwave/Sprint), BuilderBrain (repairs). The practice bots in Studio run the same brains.

	What is modelled, and the assumptions (also listed in docs/BALANCE.md):
	  * Builders follow the FortPlanner team fort with the block kinds they have unlocked, but waste
	    0–20% of their budget (misplaced or decorative blocks). The build phase is long enough to
	    place the whole plan (budget is the real limit).
	  * Builders stand still inside the fort. Real players can also dodge inside it, so builder
	    results here are slightly pessimistic.
	  * Skill varies per round. Each builder's repair attention is drawn from [0.4, 0.95]: the share of
	    repair opportunities actually used (players also watch, panic and mis-click). Hunter skill is
	    drawn from [0.5, 1.0]: the chance to use each ready breach moment, and a reaction time of
	    0.2–0.45 s between decisions.
	  * While breaching, the hunter swings whenever the cooldown allows; each swing lands with
	    probability `skill` (a miss still costs the cooldown), so damage scales with skill. Shockwave
	    is used with the same probability when the brain asks for it.
	  * Movement is straight-line between grid columns at walk/sprint speed; no physics.
	  * Line of sight and ranges use the same formulas as HunterService (incl. Config.RangeLeeway).
	  * Blocks hit within Config.Repair.UnderFireLock can't be repaired, as in BuildService.
]]

local BlockGrid = require("../src/shared/Logic/BlockGrid")
local BuilderBrain = require("../src/server/Gameplay/BuilderBrain")
local Cooldowns = require("../src/server/Gameplay/Cooldowns")
local FortPlanner = require("../src/server/Gameplay/FortPlanner")
local HunterBrain = require("../src/server/Gameplay/HunterBrain")

export type Options = {
	config: any,
	builders: number,
	seed: number,
	kinds: { string }?, -- unlocked block kinds; defaults to Config.Balance.FreeKinds
	attention: number?,
	waste: number?, -- share of the build budget wasted; random 0-0.2 by default
	reaction: number?,
	builderBudgetBonus: number?, -- per builder (e.g. a perk)
	repairCooldownMultiplier: number?,
	hunterDamageBonus: number?, -- e.g. 0.1 = +10% damage (Heavy Hitter)
	shockwaveCooldownReduction: number?, -- seconds (Bloodhound)
	damageMultiplier: number?, -- overrides the Config table (used by calibration)
	extras: { { kind: string, cost: number } }?,
}

export type Result = {
	winner: "Builders" | "Hunter",
	time: number, -- seconds into the hunt when it ended
	tags: number,
	breaks: number,
	repairs: number,
	columnHealth: number,
	blocks: number,
	blocksLeft: number,
}

local RoundSim = {}

-- Deterministic PRNG (LCG), so a seed always replays the same round.
function RoundSim.rng(seed: number): () -> number
	local state = seed % 2147483647
	if state <= 0 then
		state += 2147483646
	end
	return function()
		state = (state * 48271) % 2147483647
		return (state - 1) / 2147483646
	end
end

function RoundSim.hunterMultiplier(config: any, builders: number): number
	return config.hunterDamageMultiplier(builders)
end

function RoundSim.run(options: Options): Result
	local config = options.config
	local random = RoundSim.rng(options.seed)
	local now = 0
	local clock = function()
		return now
	end
	local cell = config.Grid.CellSize

	local grid = BlockGrid.new(config.Grid)

	-- Build ----------------------------------------------------------------------------------
	local kinds: { [string]: FortPlanner.KindInfo } = {}
	for _, name in options.kinds or config.Balance.FreeKinds do
		kinds[name] = { cost = config.Blocks[name].cost, health = config.Blocks[name].health }
	end
	-- Real builders waste part of their budget (misplaced or decorative blocks): 0-20% per round.
	local waste = options.waste or random() * 0.2
	local budgets = {}
	for i = 1, options.builders do
		budgets[i] =
			math.floor((config.Build.BudgetPerBuilder + (options.builderBudgetBonus or 0)) * (1 - waste))
	end
	-- Small random offset so forts are not always in the exact centre.
	local n = math.ceil(math.sqrt(options.builders))
	local center = {
		x = -n // 2 + math.floor(random() * 3) - 1,
		z = -n // 2 + math.floor(random() * 3) - 1,
	}
	local plan = FortPlanner.plan({
		builderCount = options.builders,
		budgets = budgets,
		kinds = kinds,
		bounds = config.Grid,
		center = center,
		extras = options.extras,
	})
	if plan.columnHealth == 0 then
		-- The offset pushed the rings out of bounds; plan in the centre instead.
		plan = FortPlanner.plan({
			builderCount = options.builders,
			budgets = budgets,
			kinds = kinds,
			bounds = config.Grid,
			extras = options.extras,
		})
	end
	for _, placement in plan.placements do
		local info = config.Blocks[placement.kind] or { health = 10 }
		if grid:canPlace(placement.cell) then
			grid:place(placement.cell, placement.kind, placement.owner, info.health)
		end
	end
	local placed = grid:count()

	-- Hunt -----------------------------------------------------------------------------------
	local multiplier = (options.damageMultiplier or RoundSim.hunterMultiplier(config, options.builders))
		* (1 + (options.hunterDamageBonus or 0))
	local shockwaveCooldown = config.Hunter.Shockwave.Cooldown - (options.shockwaveCooldownReduction or 0)

	-- Skill varies per round: hunter breach efficiency and reaction, builder repair attention.
	local hunterSkill = 0.5 + random() * 0.5 -- share of cooldown-ready moments actually used
	local attentionOf: { number } = {}
	for i = 1, options.builders do
		attentionOf[i] = options.attention or (0.4 + random() * 0.55)
	end
	local tuning = HunterBrain.tuningFromConfig(config, multiplier)
	local hunterCfg = config.Hunter
	local cooldowns = Cooldowns.new(clock)

	local builders: { { id: number, x: number, z: number, alive: boolean } } = {}
	for i, spot in plan.spots do
		table.insert(builders, { id = i, x = (spot.x + 0.5) * cell, z = (spot.z + 0.5) * cell, alive = true })
	end

	local hx = (random() - 0.5) * 16
	local hz = (config.Grid.MaxZ + 1) * cell + 22
	local waypoint: { x: number, z: number }? = nil
	local breachTarget: number? = nil
	local sprintUntil = -1
	local nextThink = 0
	local reaction = options.reaction or (0.2 + (1 - hunterSkill) * 0.5)
	local repairCooldown = config.Repair.Cooldown * (options.repairCooldownMultiplier or 1)
	local tags, breaks, repairs = 0, 0, 0
	local dt = 0.1
	local duration = config.Timings.Hunt

	local function aliveTargets(): { HunterBrain.Target }
		local list = {}
		for _, b in builders do
			if b.alive then
				table.insert(list, { id = b.id, x = b.x, z = b.z })
			end
		end
		return list
	end

	local lastHitAt: { [number]: number } = {}
	local function underFire(blockId: number): boolean
		local at = lastHitAt[blockId]
		return at ~= nil and now - at < config.Repair.UnderFireLock
	end
	local function hit(blockId: number, damage: number, targeted: boolean)
		if targeted then
			lastHitAt[blockId] = now
		end
		local _, destroyed = grid:damage(blockId, damage)
		if destroyed then
			breaks += 1
		end
	end

	while now < duration do
		-- Hunter thinks; while breaching it keeps hammering until the block breaks (or 1.5 s pass).
		if breachTarget and not grid:get(breachTarget) then
			nextThink = now
		end
		if now >= nextThink then
			nextThink = now + reaction + random() * 0.1
			local decision = HunterBrain.decide(grid, tuning, hx, hz, aliveTargets(), {
				shockwaveReady = cooldowns:remaining(0, "Shockwave") == 0,
				sprintReady = cooldowns:remaining(0, "Sprint") == 0,
			})
			breachTarget = nil
			-- A weaker hunter also uses Shockwave less well (worse timing, wasted casts).
			if
				decision.shockwave
				and random() < hunterSkill
				and cooldowns:use(0, "Shockwave", shockwaveCooldown)
			then
				for _, block in grid:blocksWithin(hx, config.Grid.GroundY + 3, hz, hunterCfg.Shockwave.Radius) do
					hit(block.id, hunterCfg.Shockwave.Damage * multiplier, false)
				end
			end
			if decision.sprint and cooldowns:use(0, "Sprint", hunterCfg.Sprint.Cooldown) then
				sprintUntil = now + hunterCfg.Sprint.Duration
			end
			if decision.action == "tag" and decision.targetId then
				if cooldowns:use(0, "Tag", hunterCfg.Tag.Cooldown) then
					for _, b in builders do
						if b.id == decision.targetId then
							b.alive = false
							tags += 1
						end
					end
				end
				waypoint = nil
			elseif decision.action == "breach" then
				breachTarget = decision.blockId
				waypoint = nil
				nextThink = now + 1.5
			elseif decision.action == "move" and decision.x and decision.z then
				waypoint = { x = decision.x, z = decision.z }
			end
		end

		-- Breaching: one roll per swing. A missed swing (bad aim, hesitation) still costs the cooldown,
		-- so effective damage scales with skill.
		if
			breachTarget
			and grid:get(breachTarget)
			and cooldowns:use(0, "Breach", hunterCfg.Breach.Cooldown)
		then
			if random() < hunterSkill then
				hit(breachTarget, hunterCfg.Breach.Damage * multiplier, true)
			end
		end

		-- Movement, never into a blocked column.
		if waypoint then
			local speed = hunterCfg.WalkSpeed * (if now < sprintUntil then hunterCfg.Sprint.Multiplier else 1)
			local dx, dz = waypoint.x - hx, waypoint.z - hz
			local distance = math.sqrt(dx * dx + dz * dz)
			if distance < 0.05 then
				waypoint = nil
			else
				local stepLength = math.min(distance, speed * dt)
				local nx, nz = hx + dx / distance * stepLength, hz + dz / distance * stepLength
				local cx, cz = math.floor(nx / cell), math.floor(nz / cell)
				local blocked = grid:getAt({ x = cx, y = 0, z = cz }) or grid:getAt({ x = cx, y = 1, z = cz })
				if not blocked then
					hx, hz = nx, nz
				end
			end
		end

		-- Builders repair.
		-- Each repair opportunity costs the cooldown; `attention` decides whether it was used.
		for _, b in builders do
			if b.alive and cooldowns:remaining(b.id, "Repair") == 0 then
				local blockId = BuilderBrain.chooseRepair(
					grid,
					b.x,
					config.Grid.GroundY + 3,
					b.z,
					config.Repair.Reach,
					underFire
				)
				if blockId and cooldowns:remaining(100000 + blockId, "BlockRepair") == 0 then
					cooldowns:use(b.id, "Repair", repairCooldown)
					if random() < attentionOf[b.id] then
						cooldowns:use(100000 + blockId, "BlockRepair", config.Repair.BlockCooldown)
						grid:repair(blockId, config.Repair.Amount)
						repairs += 1
					end
				end
			end
		end

		-- Round over?
		local anyAlive = false
		for _, b in builders do
			anyAlive = anyAlive or b.alive
		end
		if not anyAlive then
			return {
				winner = "Hunter",
				time = now,
				tags = tags,
				breaks = breaks,
				repairs = repairs,
				columnHealth = plan.columnHealth,
				blocks = placed,
				blocksLeft = grid:count(),
			}
		end
		now += dt
	end

	return {
		winner = "Builders",
		time = duration,
		tags = tags,
		breaks = breaks,
		repairs = repairs,
		columnHealth = plan.columnHealth,
		blocks = placed,
		blocksLeft = grid:count(),
	}
end

return RoundSim
