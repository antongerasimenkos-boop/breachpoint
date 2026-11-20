--!strict
--[[
	Every remote in the game is declared here, and only here.

	Client -> server events are *intents*. Each one lists the type check for every argument and a
	per-player rate limit, and the server wraps its handler in a RemoteGuard built from this table.
	The server is authoritative: these checks only prove the request is well-formed. Game rules
	(phase, role, ownership, distance, budget, cooldowns) are enforced by the owning service.

	Server -> client events carry facts for UI/VFX only. Clients never trust each other, so nothing
	here is relayed from one client to another without the server deciding it.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require("./Config")
local RemoteGuard = require(ReplicatedStorage:WaitForChild("Packages"):WaitForChild("RemoteGuard"))

local t = RemoteGuard.t
local Grid = Config.Grid

export type ClientEvent =
	"PlaceBlock"
	| "RemoveBlock"
	| "RepairBlock"
	| "Breach"
	| "Tag"
	| "UseAbility"
	| "ChooseSoloRole"
	| "BuyItem"
	| "OpenCrate"
	| "Equip"
	| "ClaimDaily"
	| "ChooseClass"

export type ServerEvent = "Notify" | "ActionResult" | "RoundResult" | "Effect" | "Profile" | "CrateResult"

export type EventSpec = {
	args: { RemoteGuard.Check },
	rateLimit: { capacity: number, refillPerSecond: number },
}

local blockId = t.integer(1, 2 ^ 31 - 1)

local crateIds = {}
for id in Config.Crates do
	table.insert(crateIds, id)
end
table.sort(crateIds)

local Protocol = {}

Protocol.FolderName = "Remotes"

Protocol.ClientToServer = {
	-- (cellX, cellY, cellZ, kind)
	PlaceBlock = {
		args = {
			t.integer(Grid.MinX, Grid.MaxX),
			t.integer(Grid.MinY, Grid.MaxY),
			t.integer(Grid.MinZ, Grid.MaxZ),
			t.literal(table.unpack(Config.BlockOrder)),
		},
		rateLimit = { capacity = 8, refillPerSecond = 6 },
	},
	-- (blockId) builder takes back one of their own blocks during the build phase
	RemoveBlock = { args = { blockId }, rateLimit = { capacity = 8, refillPerSecond = 6 } },
	-- (blockId) builder restores health during the hunt
	RepairBlock = { args = { blockId }, rateLimit = { capacity = 4, refillPerSecond = 2 } },
	-- (blockId) hunter damages a block
	Breach = { args = { blockId }, rateLimit = { capacity = 6, refillPerSecond = 5 } },
	-- (participantId) hunter tags a builder; bots have negative ids
	Tag = { args = { t.integer(-2 ^ 31, 2 ^ 53) }, rateLimit = { capacity = 4, refillPerSecond = 2 } },
	-- (ability)
	UseAbility = {
		args = { t.literal("Shockwave", "Sprint") },
		rateLimit = { capacity = 3, refillPerSecond = 1 },
	},
	-- (role) practice mode only
	ChooseSoloRole = {
		args = { t.literal("Builder", "Hunter", "Spectator") },
		rateLimit = { capacity = 3, refillPerSecond = 1 },
	},
	-- (itemId) permanent shop unlock, paid in coins
	BuyItem = { args = { t.string(40) }, rateLimit = { capacity = 4, refillPerSecond = 1 } },
	-- (crateId) coins only; the server also enforces one open at a time
	OpenCrate = {
		args = { t.literal(table.unpack(crateIds)) },
		rateLimit = { capacity = 2, refillPerSecond = 0.5 },
	},
	-- (slot, cosmeticId) "" unequips
	Equip = {
		args = { t.literal("BlockSkin", "Trail", "Title"), t.string(40) },
		rateLimit = { capacity = 6, refillPerSecond = 2 },
	},
	-- () daily login reward
	ClaimDaily = { args = {}, rateLimit = { capacity = 2, refillPerSecond = 0.2 } },
	-- (className) builder class for the next rounds
	ChooseClass = {
		args = { t.literal(table.unpack(Config.ClassOrder)) },
		rateLimit = { capacity = 3, refillPerSecond = 1 },
	},
} :: { [ClientEvent]: EventSpec }

Protocol.ServerToClient = {
	-- (kind: "info" | "warn" | "success" | "quest" | "levelup" | "feed", text)
	"Notify",
	-- (action: ClientEvent, ok: boolean, reason: string?) feedback for a rejected/accepted intent
	"ActionResult",
	-- (result: Types.RoundResult)
	"RoundResult",
	-- (kind: "BlockHit" | "BlockBroken" | "Shockwave" | "Tag" | "Place" | "Repair" | "Coins" | "Trap", position: Vector3)
	"Effect",
	-- (profile: ProfileView) coins, unlocks, cosmetics, daily status: sent on load and on change
	"Profile",
	-- (result: Crates.Result) the server-rolled prize, for the reveal animation
	"CrateResult",
} :: { ServerEvent }

return Protocol
