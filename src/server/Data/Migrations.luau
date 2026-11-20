--!strict
--[[
	Player data schema versions and the migrations between them.

	v1  { coins, wins }                                    -- launch schema
	v2  { coins, builderWins, hunterWins }                 -- wins split by role
	v3  v2 + { roundsPlayed, blocksPlaced, blocksBroken }  -- per-player stats
	v4  v3 + { blocksRepaired, tags, cratesOpened,         -- economy update
	           owned, cosmetics, equipped, daily, pity }
	v5  v4 + { xp, quests }                              -- progression update

	Rules:
	  * Migrations are pure functions vN -> vN+1 that run in order, so any old record reaches the
	    current version through the same audited steps.
	  * Data written by a *newer* server (version > CURRENT) is never migrated or overwritten.
	    The caller refuses the load instead of downgrading someone's progress.
	  * `reconcile` runs last and repairs missing or corrupt fields from the template, including the
	    nested tables: unknown shapes are dropped and only string-keyed `true` flags survive.
]]

export type Equipped = { BlockSkin: string, Trail: string, Title: string }

export type PlayerStats = {
	coins: number,
	builderWins: number,
	hunterWins: number,
	roundsPlayed: number,
	blocksPlaced: number,
	blocksBroken: number,
	blocksRepaired: number,
	tags: number,
	cratesOpened: number,
	owned: { [string]: boolean }, -- shop unlocks
	cosmetics: { [string]: boolean }, -- cosmetics won from crates
	equipped: Equipped, -- "" = nothing equipped
	daily: { lastDay: number, streak: number }, -- lastDay = UTC day number of the last claim
	pity: { sinceEpic: number, sinceLegendary: number },
	xp: number,
	quests: { day: number, progress: { [string]: number }, done: { [string]: boolean } },
}

local Migrations = {}

Migrations.CURRENT_VERSION = 5

-- Numeric counters, in schema order. Everything else is a nested table handled explicitly.
Migrations.COUNTERS = {
	"coins",
	"builderWins",
	"hunterWins",
	"roundsPlayed",
	"blocksPlaced",
	"blocksBroken",
	"blocksRepaired",
	"tags",
	"cratesOpened",
	"xp",
}

function Migrations.template(): PlayerStats
	return {
		coins = 0,
		builderWins = 0,
		hunterWins = 0,
		roundsPlayed = 0,
		blocksPlaced = 0,
		blocksBroken = 0,
		blocksRepaired = 0,
		tags = 0,
		cratesOpened = 0,
		owned = {},
		cosmetics = {},
		equipped = { BlockSkin = "", Trail = "", Title = "" },
		daily = { lastDay = 0, streak = 0 },
		pity = { sinceEpic = 0, sinceLegendary = 0 },
		xp = 0,
		quests = { day = 0, progress = {}, done = {} },
	}
end

local function number(value: any): number
	if type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge then
		return value
	end
	return 0
end

local function counter(value: any): number
	return math.max(0, math.floor(number(value)))
end

-- A set of string ids -> true. Anything else (numbers as keys, non-true values, huge ids) is dropped.
local function flagSet(value: any): { [string]: boolean }
	local result = {}
	if type(value) == "table" then
		for key, flag in value do
			if type(key) == "string" and #key <= 40 and flag == true then
				result[key] = true
			end
		end
	end
	return result
end

local function slotValue(value: any): string
	return if type(value) == "string" and #value <= 40 then value else ""
end

-- steps[n] upgrades a version-n table to version n+1.
local steps: { [number]: (data: { [string]: any }) -> { [string]: any } } = {
	[1] = function(v1)
		-- v1 only had builder-side wins (hunters could not win before the v2 rework).
		return {
			coins = number(v1.coins),
			builderWins = number(v1.wins),
			hunterWins = 0,
		}
	end,
	[2] = function(v2)
		local v3 = table.clone(v2)
		v3.roundsPlayed = 0
		v3.blocksPlaced = 0
		v3.blocksBroken = 0
		return v3
	end,
	[3] = function(v3)
		local v4 = table.clone(v3)
		v4.blocksRepaired = 0
		v4.tags = 0
		v4.cratesOpened = 0
		v4.owned = {}
		v4.cosmetics = {}
		v4.equipped = { BlockSkin = "", Trail = "", Title = "" }
		v4.daily = { lastDay = 0, streak = 0 }
		v4.pity = { sinceEpic = 0, sinceLegendary = 0 }
		-- Players who already earned wins before the economy update start with the Metal tier,
		-- which they could use for free before v4 (it became a shop unlock).
		if number(v3.builderWins) + number(v3.hunterWins) > 0 or number(v3.roundsPlayed) > 0 then
			v4.owned.Metal = true
		end
		return v4
	end,
	[4] = function(v4)
		local v5 = table.clone(v4)
		-- Credit past rounds so veterans don't restart at level 1. A frozen constant, not Config:
		-- a migration must give the same result whenever it runs.
		v5.xp = counter(v4.roundsPlayed) * 25
		v5.quests = { day = 0, progress = {}, done = {} }
		return v5
	end,
}

-- Quest id -> non-negative progress. Anything else is dropped.
local function progressMap(value: any): { [string]: number }
	local result = {}
	if type(value) == "table" then
		for key, amount in value do
			if type(key) == "string" and #key <= 40 then
				result[key] = counter(amount)
			end
		end
	end
	return result
end

-- Fills missing/corrupt fields from the template; counters become non-negative integers.
function Migrations.reconcile(data: { [string]: any }): PlayerStats
	local result = Migrations.template()
	local out = result :: any
	for _, key in Migrations.COUNTERS do
		out[key] = counter(data[key])
	end
	result.owned = flagSet(data.owned)
	result.cosmetics = flagSet(data.cosmetics)
	local equipped = if type(data.equipped) == "table" then data.equipped else {}
	result.equipped = {
		BlockSkin = slotValue(equipped.BlockSkin),
		Trail = slotValue(equipped.Trail),
		Title = slotValue(equipped.Title),
	}
	local daily = if type(data.daily) == "table" then data.daily else {}
	result.daily = { lastDay = counter(daily.lastDay), streak = counter(daily.streak) }
	local pity = if type(data.pity) == "table" then data.pity else {}
	result.pity = { sinceEpic = counter(pity.sinceEpic), sinceLegendary = counter(pity.sinceLegendary) }
	local quests = if type(data.quests) == "table" then data.quests else {}
	result.quests = {
		day = counter(quests.day),
		progress = progressMap(quests.progress),
		done = flagSet(quests.done),
	}
	return result
end

-- Deep copy for handing data to callers without sharing nested tables.
function Migrations.copy(data: PlayerStats): PlayerStats
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
	return deep(data)
end

-- Upgrades `data` from `fromVersion` to CURRENT_VERSION.
-- Returns nil and an error for versions this server cannot handle.
function Migrations.migrate(data: any, fromVersion: any): (PlayerStats?, string?)
	if type(fromVersion) ~= "number" or fromVersion % 1 ~= 0 or fromVersion < 1 then
		return nil, "invalid schema version " .. tostring(fromVersion)
	end
	if fromVersion > Migrations.CURRENT_VERSION then
		return nil,
			string.format("data is from a newer schema (v%d > v%d)", fromVersion, Migrations.CURRENT_VERSION)
	end
	local current: { [string]: any } = if type(data) == "table" then table.clone(data) else {}
	for version = fromVersion, Migrations.CURRENT_VERSION - 1 do
		current = steps[version](current)
	end
	return Migrations.reconcile(current)
end

return Migrations
