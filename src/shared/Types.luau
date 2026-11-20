--!strict
-- Shared type vocabulary. Types only, no runtime values, so any module (pure or Roblox-bound) can use it.

export type Phase = "Waiting" | "Intermission" | "Build" | "Hunt" | "Results"

export type Role = "Builder" | "Hunter" | "Spectator"

-- Grid blocks. "Trap" is placed through the same intent but lives outside the grid (a floor plate).
export type BlockKind = "Wood" | "Stone" | "Metal" | "Titanium" | "Door" | "Generator" | "Trap"

export type HunterAbility = "Shockwave" | "Sprint"

export type Winner = "Builders" | "Hunter" | "None"

-- A participant id is a Player.UserId for humans and a negative number for practice bots.
export type ParticipantId = number

export type Cell = { x: number, y: number, z: number }

export type BlockKindConfig = {
	cost: number,
	health: number,
	color: { number },
	material: string,
	label: string,
	unlock: string?, -- shop item id required to use it (nil = free)
	limitPerBuilder: number?,
}

export type CosmeticSlot = "BlockSkin" | "Trail" | "Title"
export type Rarity = "Common" | "Rare" | "Epic" | "Legendary"

export type RoundResult = {
	round: number,
	winner: Winner,
	reason: string,
	hunterId: ParticipantId?,
	survivors: { ParticipantId },
	rewards: { [string]: number }, -- tostring(UserId) -> coins, string keys so it survives remote serialisation
	mvps: { { id: ParticipantId, name: string, role: string, coins: number } }, -- best first, up to 3
	stats: { blocksStanding: number, tags: number, builders: number },
}

return {}
