--!strict
--[[
	Balance report: many seeded headless rounds per team size on the real game logic.

		lune run balance                 -- 300 rounds per team size (1..6 builders)
		lune run balance 1000            -- more rounds
		lune run balance 300 markdown    -- print a Markdown table (for docs/BALANCE.md)
		lune run balance 300 markdown v1 -- the v1 (0.1.0) numbers through the same simulation

	See sim/RoundSim.luau for what is modelled and the assumptions.
]]

local process = require("@lune/process")

local Config = require("../src/shared/Config")
local RoundSim = require("../sim/RoundSim")

local rounds = tonumber(process.args[1]) or 300
local markdown = process.args[2] == "markdown"
local v1Mode = process.args[3] == "v1"

-- The 0.1.0 tuning, replayed through today's simulation for an honest before/after comparison.
local function v1Config(): any
	local function deep(value: any): any
		if type(value) ~= "table" then
			return value
		end
		local out = {}
		for k, v in value do
			out[k] = deep(v)
		end
		return out
	end
	local c = deep(Config)
	c.Timings.Hunt = 90
	c.Blocks.Wood.health, c.Blocks.Stone.health, c.Blocks.Metal.health = 3, 6, 12
	c.Balance.FreeKinds = { "Wood", "Stone", "Metal" }
	c.Build.BudgetPerBuilder = 40
	c.Repair = { Amount = 1, Cooldown = 1.2, Reach = 16, BlockCooldown = 0 }
	c.Hunter.Breach = { Damage = 1, Range = 14, Cooldown = 0.35 }
	c.Hunter.Tag = { Range = 7, Cooldown = 0.8 }
	c.Hunter.Shockwave = { Damage = 2, Radius = 12, Cooldown = 10 }
	c.RangeLeeway = 4
	c.hunterDamageMultiplier = function()
		return 1
	end
	return c
end

local activeConfig = if v1Mode then v1Config() else Config

type Row = {
	builders: number,
	winRate: number,
	ci: number,
	avgEnd: number,
	columnHealth: number,
	blocks: number,
	breaks: number,
	repairs: number,
}

local function scenario(builders: number, overrides: { [string]: any }?): Row
	local wins, endTime, breaks, repairs, columnHealth, blocks = 0, 0, 0, 0, 0, 0
	for seed = 1, rounds do
		local options: { [string]: any } =
			{ config = activeConfig, builders = builders, seed = seed * 7919 + builders }
		for k, v in overrides or {} do
			options[k] = v
		end
		local result = RoundSim.run(options :: any)
		if result.winner == "Builders" then
			wins += 1
		else
			endTime += result.time
		end
		breaks += result.breaks
		repairs += result.repairs
		columnHealth += result.columnHealth
		blocks += result.blocks
	end
	local p = wins / rounds
	return {
		builders = builders,
		winRate = p,
		ci = 1.96 * math.sqrt(p * (1 - p) / rounds),
		avgEnd = if rounds - wins > 0 then endTime / (rounds - wins) else 0,
		columnHealth = columnHealth / rounds,
		blocks = blocks / rounds,
		breaks = breaks / rounds,
		repairs = repairs / rounds,
	}
end

local function report(title: string, overrides: { [string]: any }?)
	print("\n" .. title)
	if markdown then
		print(
			"| Builders | Builder win % (95% CI) | Hunter win time (avg s) | Wall HP / column | Blocks | Breaks | Repairs |"
		)
		print("|---|---|---|---|---|---|---|")
	else
		print(" builders  builder win %        hunter win at  col HP  blocks  breaks  repairs")
	end
	for builders = 1, 6 do
		local row = scenario(builders, overrides)
		if markdown then
			print(
				string.format(
					"| %d | %.0f%% (± %.0f) | %.0f | %.0f | %.0f | %.0f | %.0f |",
					row.builders,
					row.winRate * 100,
					row.ci * 100,
					row.avgEnd,
					row.columnHealth,
					row.blocks,
					row.breaks,
					row.repairs
				)
			)
		else
			print(
				string.format(
					" %8d  %5.1f%% (± %4.1f)     %8.1f s  %6.0f  %6.0f  %6.0f  %7.0f",
					row.builders,
					row.winRate * 100,
					row.ci * 100,
					row.avgEnd,
					row.columnHealth,
					row.blocks,
					row.breaks,
					row.repairs
				)
			)
		end
	end
end

if process.args[1] == "calibrate" then
	-- Bisection per team size on the hunter damage multiplier (win rate falls as it rises),
	-- using a fixed seed set so each probe is comparable.
	local probeRounds = tonumber(process.args[2]) or 80
	local fitted = {}
	for builders = 1, 6 do
		local lo, hi = 0.2, 4
		for _ = 1, 8 do
			local mid = (lo + hi) / 2
			local wins = 0
			for seed = 1, probeRounds do
				local result = RoundSim.run({
					config = Config,
					builders = builders,
					seed = seed * 104729 + builders,
					damageMultiplier = mid,
				})
				if result.winner == "Builders" then
					wins += 1
				end
			end
			if wins / probeRounds > 0.5 then
				lo = mid
			else
				hi = mid
			end
		end
		fitted[builders] = math.floor((lo + hi) / 2 * 100 + 0.5) / 100
		print(string.format("builders=%d  multiplier for ~50%% = %.2f", builders, fitted[builders]))
	end
	print("\nDamageByBuilders = { " .. table.concat(fitted, ", ") .. " },")
	process.exit(0)
end

print(
	string.format(
		"Breachpoint balance report: %d seeded rounds per row, Hunt = %ds",
		rounds,
		Config.Timings.Hunt
	)
)
local builderUpgrades = {
	kinds = { "Wood", "Stone", "Metal", "Titanium" },
	builderBudgetBonus = Config.Perks.DeepPocketsBudget,
	repairCooldownMultiplier = Config.Perks.QuickHandsRepairMultiplier,
}
local hunterUpgrades = {
	hunterDamageBonus = Config.Perks.HeavyHitterDamage,
	shockwaveCooldownReduction = Config.Perks.BloodhoundShockwaveReduction,
}
local both = table.clone(builderUpgrades)
for k, v in hunterUpgrades do
	both[k] = v
end

report(
	if v1Mode
		then "v1 (0.1.0) tuning: Wood/Stone/Metal free, budget 40, Hunt 90 s"
		else "Baseline: free kit (Wood + Stone), no perks or upgrades"
)
if v1Mode then
	process.exit(0)
end
if process.args[3] ~= "baseline" then
	report(
		"Builders fully upgraded (Metal, Titanium, Deep Pockets, Quick Hands) vs base hunter",
		builderUpgrades
	)
	report("Hunter fully upgraded (Heavy Hitter, Bloodhound) vs base builders", hunterUpgrades)
	report("Both sides fully upgraded", both)
	report("Builders spend 6 budget on a coin generator", { extras = { { kind = "Generator", cost = 6 } } })
end
