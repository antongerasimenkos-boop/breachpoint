--!strict
--[[
	Crates: cosmetic loot rolled on the server (pure; Config and randomness are passed in).

	  * Paid with in-game coins only. There is no Robux path anywhere in the game.
	  * The odds table in Config is exactly what the UI shows before opening.
	  * Each rarity's pool holds that rarity's cosmetics plus one coin prize, drawn uniformly.
	  * Pity: after `pityEpic - 1` opens without Epic or better, the next open is Epic or better
	    (rolled between Epic and Legendary by their relative odds). After `pityLegendary - 1` opens
	    without a Legendary, the next one is Legendary.
	  * A cosmetic you already own converts to coins (Config.DuplicateCoins).

	The server passes a `Random.new()` stream; the client never sees seeds or rolls, only results.
]]

export type Data = {
	coins: number,
	cosmetics: { [string]: boolean },
	pity: { sinceEpic: number, sinceLegendary: number },
	cratesOpened: number,
}

export type Prize = {
	kind: "cosmetic" | "coins",
	id: string?, -- cosmetic id
	name: string,
	coins: number, -- coins granted (prize amount or duplicate refund)
	duplicate: boolean,
}

export type Result = {
	crateId: string,
	rarity: string,
	prize: Prize,
	pity: { sinceEpic: number, sinceLegendary: number },
	coinsAfter: number,
}

export type OpenError = "UnknownCrate" | "NotEnoughCoins"

local Crates = {}

local RANK = { Common = 1, Rare = 2, Epic = 3, Legendary = 4 }

-- Validates an odds table: every rarity present, non-negative, summing to 1.
function Crates.validateOdds(config: any, odds: { [string]: number }): (boolean, string?)
	local sum = 0
	for _, rarity in config.RarityOrder do
		local p = odds[rarity]
		if type(p) ~= "number" or p < 0 then
			return false, "missing or negative odds for " .. rarity
		end
		sum += p
	end
	if math.abs(sum - 1) > 1e-9 then
		return false, string.format("odds sum to %.6f, not 1", sum)
	end
	return true, nil
end

-- Rolls a rarity, applying pity. Pure apart from `random`.
function Crates.rollRarity(
	config: any,
	crate: any,
	pity: { sinceEpic: number, sinceLegendary: number },
	random: () -> number
): string
	if pity.sinceLegendary + 1 >= crate.pityLegendary then
		return "Legendary"
	end
	local allowed = config.RarityOrder
	if pity.sinceEpic + 1 >= crate.pityEpic then
		allowed = { "Epic", "Legendary" }
	end
	local total = 0
	for _, rarity in allowed do
		total += crate.odds[rarity]
	end
	local roll = random() * total
	for _, rarity in allowed do
		roll -= crate.odds[rarity]
		if roll < 0 then
			return rarity
		end
	end
	return allowed[#allowed]
end

-- Everything that can drop at a rarity: its cosmetics plus one coin prize.
function Crates.pool(config: any, crate: any, rarity: string): { Prize }
	local pool: { Prize } = {}
	for _, cosmetic in config.Cosmetics do
		if cosmetic.rarity == rarity then
			table.insert(
				pool,
				{ kind = "cosmetic", id = cosmetic.id, name = cosmetic.name, coins = 0, duplicate = false }
			)
		end
	end
	local amount = crate.coinPrizes[rarity]
	table.insert(
		pool,
		{ kind = "coins", id = nil, name = tostring(amount) .. " coins", coins = amount, duplicate = false }
	)
	return pool
end

function Crates.updatePity(pity: { sinceEpic: number, sinceLegendary: number }, rarity: string)
	local rank = RANK[rarity] or 1
	pity.sinceLegendary = if rank >= 4 then 0 else pity.sinceLegendary + 1
	pity.sinceEpic = if rank >= 3 then 0 else pity.sinceEpic + 1
end

-- Charges the crate, rolls, grants the prize and updates pity. Mutates `data` on success.
function Crates.open(config: any, data: Data, crateId: string, random: () -> number): (Result?, OpenError?)
	local crate = config.Crates[crateId]
	if not crate then
		return nil, "UnknownCrate"
	end
	if data.coins < crate.price then
		return nil, "NotEnoughCoins"
	end
	data.coins -= crate.price

	local rarity = Crates.rollRarity(config, crate, data.pity, random)
	Crates.updatePity(data.pity, rarity)

	local pool = Crates.pool(config, crate, rarity)
	local pick = pool[math.clamp(math.floor(random() * #pool) + 1, 1, #pool)]
	local prize: Prize = table.clone(pick)
	if prize.kind == "cosmetic" and prize.id then
		if data.cosmetics[prize.id] then
			prize.duplicate = true
			prize.coins = config.DuplicateCoins[rarity]
		else
			data.cosmetics[prize.id] = true
		end
	end
	data.coins += prize.coins
	data.cratesOpened += 1

	return {
		crateId = crateId,
		rarity = rarity,
		prize = prize,
		pity = table.clone(data.pity),
		coinsAfter = data.coins,
	},
		nil
end

return Crates
