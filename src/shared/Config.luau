--!strict
--[[
	Game tuning in one place. Pure data, with no Roblox types (colours are RGB arrays, materials
	are Enum names), so Lune tests can require it and assert against real values.
]]

local Types = require("./Types")

export type Timings = {
	Intermission: number,
	Build: number,
	Hunt: number,
	Results: number,
}

local Config = {}

Config.MinPlayers = 2

-- Solo practice: when exactly one player is in the server, bots fill the other role.
-- Enabled in Studio so the game can be tried alone. Off on live servers.
Config.Solo = {
	EnabledInStudio = true,
	EnabledLive = false,
	BotBuilderCount = 3,
}

Config.Timings = {
	Intermission = 12,
	Build = 50,
	Hunt = 75,
	Results = 8,
} :: Timings

-- Practice keeps the real hunt length so bot rounds match the balance numbers; only waits are shorter.
Config.SoloTimings = {
	Intermission = 6,
	Build = 40,
	Hunt = 75,
	Results = 6,
} :: Timings

-- Build grid. Cells are integer coordinates. A cell's world centre is
-- ((x + 0.5) * CellSize, GroundY + (y + 0.5) * CellSize, (z + 0.5) * CellSize).
Config.Grid = {
	CellSize = 4,
	GroundY = 0,
	MinX = -6,
	MaxX = 5,
	MinY = 0,
	MaxY = 5,
	MinZ = -6,
	MaxZ = 5,
}

-- Higher tiers trade budget efficiency for density: HP per budget point is Wood 16, Stone 20, Metal 14,
-- Titanium 12, but a Metal/Titanium block packs more HP into one cell. The innermost ring is the
-- cheapest place to add HP per column and has the fewest cells, so density is what an upgrade buys.
-- Bigger blocks also shrug off Shockwave's flat damage. See docs/BALANCE.md (iteration 3).
Config.Blocks = {
	Wood = { cost = 1, health = 16, color = { 166, 118, 72 }, material = "WoodPlanks", label = "Wood" },
	Stone = { cost = 2, health = 40, color = { 146, 146, 156 }, material = "Cobblestone", label = "Stone" },
	Metal = {
		cost = 4,
		health = 56,
		color = { 112, 128, 150 },
		material = "DiamondPlate",
		label = "Metal",
		unlock = "Metal",
	},
	Titanium = {
		cost = 7,
		health = 84,
		color = { 70, 210, 230 },
		material = "Glacier",
		label = "Titanium",
		unlock = "Titanium",
	},
	-- Builders walk through doors; the hunter has to break them.
	Door = {
		cost = 2,
		health = 40,
		color = { 120, 80, 50 },
		material = "Wood",
		label = "Door",
		unlock = "Door",
	},
	-- Pays its owner coins while it stands (see Config.Generator). Free, one per builder.
	Generator = {
		cost = 6,
		health = 60,
		color = { 255, 196, 60 },
		material = "Neon",
		label = "Generator",
		limitPerBuilder = 1,
	},
	-- A floor plate outside the grid: slows the hunter once, then breaks.
	Trap = {
		cost = 3,
		health = 1,
		color = { 60, 60, 66 },
		material = "Metal",
		label = "Spike trap",
		unlock = "Trap",
		limitPerBuilder = 3,
	},
} :: { [Types.BlockKind]: Types.BlockKindConfig }

local BLOCK_ORDER: { Types.BlockKind } = { "Wood", "Stone", "Metal", "Titanium", "Door", "Generator", "Trap" }
Config.BlockOrder = BLOCK_ORDER

Config.Build = {
	BudgetPerBuilder = 64,
	-- Max distance (studs) from a builder's root part to the centre of the cell being edited.
	Reach = 28,
	MaxBlocksTotal = 400,
}

-- Repairs slow the hunter down; they must never out-heal a working hunter (that turns rounds into
-- coin flips decided by tiny stat changes). See docs/BALANCE.md.
Config.Repair = {
	Amount = 1,
	Cooldown = 1.0,
	Reach = 16,
	-- A single block can only be repaired this often, by anyone: a crowd of builders spamming
	-- repairs on one block must not make it unbreakable.
	BlockCooldown = 1.0,
	-- A block breached in the last UnderFireLock seconds can't be repaired (Shockwave splash doesn't count): repairs patch chip damage
	-- and abandoned breaches, they never cancel the hunter's current attack (see BALANCE.md).
	UnderFireLock = 2,
}

Config.DefaultWalkSpeed = 16

Config.Hunter = {
	WalkSpeed = 18,
	-- Primary action: damage one block.
	Breach = { Damage = 1, Range = 14, Cooldown = 0.4 },
	-- Primary action on a builder: eliminate them. Needs a clear line of sight.
	Tag = { Range = 4.5, Cooldown = 0.8 },
	Shockwave = { Damage = 2, Radius = 12, Cooldown = 12 },
	Sprint = { Multiplier = 1.6, Duration = 3, Cooldown = 9 },
	-- Hunter damage multiplier by number of builders in the round. Bigger teams pool budgets
	-- into thicker walls and repair more, so the hunter hits harder. Fitted with
	-- `lune run balance calibrate` so each team size lands near a 50% builder win rate.
	DamageByBuilders = { 0.55, 0.77, 1.11, 1.42, 1.54, 1.74 },
}

-- Damage multiplier for a round with `builders` builders (beyond the table: last entry).
function Config.hunterDamageMultiplier(builders: number): number
	local table_ = Config.Hunter.DamageByBuilders
	return table_[math.clamp(builders, 1, #table_)]
end

-- Extra distance tolerated on range checks to absorb latency between client and server positions.
Config.RangeLeeway = 3

-- Balance (see docs/BALANCE.md and `lune run balance`).
Config.Balance = {
	-- Block kinds every player can use without buying anything; the baseline the numbers target.
	FreeKinds = { "Wood", "Stone" },
}

-- Coins. A typical round pays 60–250; shop items cost 250–900, so something new every few rounds.
Config.Rewards = {
	Participation = 25,
	BuilderTeamWin = 50, -- every builder on a winning team, caught or not
	SurvivorBonus = 100, -- builders still standing at the end
	PerBlockStanding = 2, -- per block you placed that survived the round...
	PerBlockStandingCap = 60, -- ...up to this many coins
	PerRepair = 2,
	HunterWin = 150,
	PerTag = 30,
	PerBlockBroken = 3,
	GeneratorBroken = 25,
	-- Daily login: base + step × (streak - 1), streak capped.
	DailyBase = 100,
	DailyStep = 50,
	DailyMaxStreak = 7,
	-- Small passive income while waiting in the lobby.
	LobbyIncome = 5,
	LobbyIncomeInterval = 60,
}

-- Builder classes, picked in the lobby. A class is a small specialisation, not a power jump:
-- the balance numbers were measured without classes (see BALANCE.md).
Config.ClassOrder = { "Engineer", "Scout", "Trapper" }
Config.DefaultClass = "Engineer"
Config.Classes = {
	Engineer = { label = "Engineer", description = "Repairs 20% faster", repairMultiplier = 0.8 },
	Scout = { label = "Scout", description = "Runs 20% faster", speedMultiplier = 1.2 },
	Trapper = {
		label = "Trapper",
		description = "Free spike traps, +2 trap limit",
		extraTraps = 2,
		unlocksTrap = true,
	},
} :: {
	[string]: {
		label: string,
		description: string,
		repairMultiplier: number?,
		speedMultiplier: number?,
		extraTraps: number?,
		unlocksTrap: boolean?,
	},
}

-- Pickups that spawn during the hunt (PowerupService). Builder pickups appear inside the fort,
-- the hunter's outside it. Not part of the balance simulation (BALANCE.md).
Config.Powerups = {
	SpawnInterval = 12,
	MaxActive = 2,
	PickupRadius = 4,
	Order = { "Shield", "Speed", "Decoy", "Reveal" },
	Kinds = {
		Shield = {
			label = "SHIELD",
			forBuilders = true,
			color = { 90, 200, 255 },
			pickupText = "Shield up: the next tag on you is blocked",
		},
		Speed = {
			label = "SPEED",
			forBuilders = true,
			color = { 120, 255, 140 },
			multiplier = 1.35,
			duration = 6,
			pickupText = "Speed boost for 6 seconds",
		},
		Decoy = {
			label = "DECOY",
			forBuilders = true,
			color = { 200, 140, 255 },
			duration = 12,
			pickupText = "Decoy placed: a copy of you stands nearby",
		},
		Reveal = {
			label = "REVEAL",
			forBuilders = false,
			color = { 255, 90, 90 },
			duration = 5,
			pickupText = "Reveal pulse: every builder is highlighted",
		},
	} :: { [string]: any },
}

-- XP and levels. Round-result coins also count as XP; level n -> n+1 costs BaseXp + StepXp*(n-1).
Config.Progression = {
	BaseXp = 150,
	StepXp = 50,
	MaxLevel = 50,
	QuestsPerDay = 3,
}

-- Daily quest pool. Three consecutive entries are active each UTC day (rotating by day number),
-- so a day always mixes builder and hunter goals. `stat` is a counter the game already records.
Config.Quests = {
	{ id = "place30", text = "Place 30 blocks", stat = "blocksPlaced", target = 30, reward = 150 },
	{ id = "break20", text = "Break 20 blocks", stat = "blocksBroken", target = 20, reward = 150 },
	{ id = "play3", text = "Play 3 rounds", stat = "roundsPlayed", target = 3, reward = 100 },
	{ id = "repair15", text = "Repair 15 blocks", stat = "blocksRepaired", target = 15, reward = 120 },
	{ id = "tag3", text = "Tag 3 builders", stat = "tags", target = 3, reward = 200 },
	{ id = "survive2", text = "Win 2 rounds as a builder", stat = "builderWins", target = 2, reward = 200 },
	{ id = "hunterwin", text = "Win a round as the hunter", stat = "hunterWins", target = 1, reward = 200 },
}

Config.Generator = {
	PayoutCoins = 4,
	Interval = 5, -- seconds, during the build and hunt phases
}

Config.Trap = {
	SlowMultiplier = 0.45,
	SlowDuration = 3,
	TriggerRadius = 2.6,
}

export type ShopItem = {
	id: string,
	name: string,
	category: "Blocks" | "Builder" | "Hunter",
	price: number,
	description: string,
}

-- Permanent unlocks. Everything is bought with in-game coins only.
Config.Shop = {
	{
		id = "Metal",
		name = "Metal blocks",
		category = "Blocks",
		price = 300,
		description = "56 HP for 4 budget: denser walls.",
	},
	{
		id = "Titanium",
		name = "Titanium blocks",
		category = "Blocks",
		price = 900,
		description = "84 HP for 7 budget: the densest walls.",
	},
	{
		id = "Door",
		name = "Door",
		category = "Blocks",
		price = 250,
		description = "Builders walk through, the hunter must break it.",
	},
	{
		id = "Trap",
		name = "Spike trap",
		category = "Blocks",
		price = 350,
		description = "Floor plate: slows the hunter for 3 s.",
	},
	{
		id = "DeepPockets",
		name = "Deep Pockets",
		category = "Builder",
		price = 600,
		description = "+2 build budget.",
	},
	{
		id = "QuickHands",
		name = "Quick Hands",
		category = "Builder",
		price = 500,
		description = "Repair cooldown -15%.",
	},
	{
		id = "HeavyHitter",
		name = "Heavy Hitter",
		category = "Hunter",
		price = 700,
		description = "+6% hunter damage.",
	},
	{
		id = "Bloodhound",
		name = "Bloodhound",
		category = "Hunter",
		price = 600,
		description = "Shockwave cooldown -1 s.",
	},
} :: { ShopItem }

Config.Perks = {
	DeepPocketsBudget = 2,
	QuickHandsRepairMultiplier = 0.85,
	HeavyHitterDamage = 0.06,
	BloodhoundShockwaveReduction = 1,
}

export type Cosmetic = {
	id: string,
	name: string,
	slot: Types.CosmeticSlot,
	rarity: Types.Rarity,
	color: { number },
	color2: { number }?, -- trails fade to this colour
}

-- Cosmetics only change looks; block HP and every stat stay the same.
Config.Cosmetics = {
	{ id = "SkinPine", name = "Pine", slot = "BlockSkin", rarity = "Common", color = { 120, 160, 90 } },
	{ id = "SkinSand", name = "Sandstone", slot = "BlockSkin", rarity = "Common", color = { 214, 190, 140 } },
	{
		id = "TrailSmoke",
		name = "Smoke trail",
		slot = "Trail",
		rarity = "Common",
		color = { 200, 200, 200 },
		color2 = { 90, 90, 90 },
	},
	{ id = "TitleRookie", name = "Rookie", slot = "Title", rarity = "Common", color = { 200, 200, 210 } },
	{ id = "SkinMarble", name = "Marble", slot = "BlockSkin", rarity = "Rare", color = { 236, 236, 242 } },
	{ id = "SkinBrick", name = "Brick", slot = "BlockSkin", rarity = "Rare", color = { 176, 74, 58 } },
	{
		id = "TrailEmber",
		name = "Ember trail",
		slot = "Trail",
		rarity = "Rare",
		color = { 255, 170, 60 },
		color2 = { 220, 40, 30 },
	},
	{ id = "TitleFortifier", name = "Fortifier", slot = "Title", rarity = "Rare", color = { 90, 170, 255 } },
	{
		id = "TitleWallbreaker",
		name = "Wallbreaker",
		slot = "Title",
		rarity = "Rare",
		color = { 255, 110, 110 },
	},
	{ id = "SkinCrystal", name = "Crystal", slot = "BlockSkin", rarity = "Epic", color = { 130, 205, 255 } },
	{
		id = "TrailLightning",
		name = "Lightning trail",
		slot = "Trail",
		rarity = "Epic",
		color = { 140, 240, 255 },
		color2 = { 255, 255, 255 },
	},
	{
		id = "TitleUnbreakable",
		name = "Unbreakable",
		slot = "Title",
		rarity = "Epic",
		color = { 190, 120, 255 },
	},
	{ id = "SkinGold", name = "Gold", slot = "BlockSkin", rarity = "Legendary", color = { 255, 200, 60 } },
	{
		id = "TrailRainbow",
		name = "Prism trail",
		slot = "Trail",
		rarity = "Legendary",
		color = { 255, 80, 200 },
		color2 = { 80, 220, 255 },
	},
	{
		id = "TitleLegend",
		name = "Breachpoint Legend",
		slot = "Title",
		rarity = "Legendary",
		color = { 255, 210, 80 },
	},
} :: { Cosmetic }

Config.RarityOrder = { "Common", "Rare", "Epic", "Legendary" } :: { Types.Rarity }

Config.RarityColors = {
	Common = { 190, 195, 205 },
	Rare = { 80, 160, 255 },
	Epic = { 185, 100, 255 },
	Legendary = { 255, 190, 50 },
}

export type CrateConfig = {
	name: string,
	price: number,
	odds: { [Types.Rarity]: number }, -- must sum to 1; shown to players before they open
	coinPrizes: { [Types.Rarity]: number }, -- each rarity also contains one coin prize
	pityEpic: number, -- this many opens without Epic or better guarantees one
	pityLegendary: number, -- this many opens without a Legendary guarantees one
}

-- Crates cost in-game coins only (never Robux), and the odds are shown before opening.
Config.Crates = {
	Standard = {
		name = "Standard Crate",
		price = 250,
		odds = { Common = 0.62, Rare = 0.27, Epic = 0.09, Legendary = 0.02 },
		coinPrizes = { Common = 60, Rare = 200, Epic = 600, Legendary = 2500 },
		pityEpic = 10,
		pityLegendary = 60,
	},
} :: { [string]: CrateConfig }

-- A cosmetic you already own converts to coins.
Config.DuplicateCoins = { Common = 40, Rare = 120, Epic = 300, Legendary = 1000 }

Config.Data = {
	StoreName = "PlayerData",
	KeyPrefix = "player_",
	AutosaveInterval = 60,
	-- A lock older than this is considered abandoned (crashed server) and may be taken over.
	-- Several autosave intervals, because every autosave refreshes the lock timestamp.
	LockExpiry = 300,
	LoadAttempts = 6,
	SaveAttempts = 4,
	RetryBaseDelay = 1,
}

Config.Net = {
	-- A player whose rejected requests exceed this "abuse budget" is kicked.
	AbuseCapacity = 60,
	AbuseRefillPerSecond = 1,
}

return Config
