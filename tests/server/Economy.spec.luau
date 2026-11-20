--!strict
local Config = require("../../src/shared/Config")
local Crates = require("../../src/server/Economy/Crates")
local Daily = require("../../src/server/Economy/Daily")
local Migrations = require("../../src/server/Data/Migrations")
local Rewards = require("../../src/server/Economy/Rewards")
local Shop = require("../../src/server/Economy/Shop")

return function(kit: any)
	local describe, it, expect = kit.describe, kit.it, kit.expect

	local function seeded(seed: number)
		local state = seed
		return function()
			state = (state * 48271) % 2147483647
			return (state - 1) / 2147483646
		end
	end

	local function rich(coins: number)
		local data = Migrations.template()
		data.coins = coins
		return data
	end

	describe("Shop", function()
		it("sells an unlock once and charges the price", function()
			local data = rich(1000)
			expect((Shop.purchase(Config, data, "Metal"))).toBe(true)
			expect(data.coins).toBe(700)
			expect(Shop.owns(data, "Metal")).toBe(true)
			expect(select(2, Shop.purchase(Config, data, "Metal"))).toBe("AlreadyOwned")
			expect(data.coins).toBe(700)
		end)

		it("refuses unknown items and insufficient coins without charging", function()
			local data = rich(100)
			expect(select(2, Shop.purchase(Config, data, "Nuke"))).toBe("UnknownItem")
			expect(select(2, Shop.purchase(Config, data, "Titanium"))).toBe("NotEnoughCoins")
			expect(data.coins).toBe(100)
		end)

		it("gates locked block kinds behind their unlock", function()
			local data = rich(0)
			expect(Shop.canUseBlock(Config, data, "Wood")).toBe(true)
			expect(Shop.canUseBlock(Config, data, "Generator")).toBe(true)
			expect(Shop.canUseBlock(Config, data, "Metal")).toBe(false)
			expect(Shop.canUseBlock(Config, nil, "Stone")).toBe(true) -- bots: free kinds only
			expect(Shop.canUseBlock(Config, nil, "Titanium")).toBe(false)
			data.owned.Titanium = true
			expect(Shop.canUseBlock(Config, data, "Titanium")).toBe(true)
			expect(Shop.canUseBlock(Config, data, "Bogus")).toBe(false)
		end)

		it("every shop item has a sane price and every unlock exists in the shop", function()
			for _, item in Config.Shop do
				expect(item.price > 0).toBe(true)
			end
			for _, cfg in Config.Blocks :: any do
				if cfg.unlock then
					expect(Shop.find(Config, cfg.unlock)).toBeTruthy()
				end
			end
		end)
	end)

	describe("Daily", function()
		it("builds a streak on consecutive days and caps it", function()
			local state = { lastDay = 0, streak = 0 }
			local rewards = {}
			for day = 100, 109 do
				local ok, reward = Daily.claim(Config, state, day)
				expect(ok).toBe(true)
				table.insert(rewards, reward)
			end
			expect(rewards[1]).toBe(Config.Rewards.DailyBase)
			expect(rewards[2]).toBe(Config.Rewards.DailyBase + Config.Rewards.DailyStep)
			expect(state.streak).toBe(Config.Rewards.DailyMaxStreak)
			expect(rewards[10]).toBe(rewards[7])
		end)

		it("refuses a second claim the same day", function()
			local state = { lastDay = 0, streak = 0 }
			Daily.claim(Config, state, 50)
			local ok, reward = Daily.claim(Config, state, 50)
			expect(ok).toBe(false)
			expect(reward).toBe(0)
			expect(Daily.status(Config, state, 50).canClaim).toBe(false)
		end)

		it("resets the streak after a missed day", function()
			local state = { lastDay = 0, streak = 0 }
			Daily.claim(Config, state, 10)
			Daily.claim(Config, state, 11)
			expect(state.streak).toBe(2)
			Daily.claim(Config, state, 13)
			expect(state.streak).toBe(1)
		end)

		it("ignores a clock that went backwards", function()
			local state = { lastDay = 30, streak = 3 }
			expect((Daily.claim(Config, state, 29))).toBe(false)
		end)
	end)

	describe("Crates", function()
		local crate = Config.Crates.Standard

		it("has a valid odds table", function()
			expect((Crates.validateOdds(Config, crate.odds))).toBe(true)
			expect((Crates.validateOdds(Config, { Common = 0.5, Rare = 0.5, Epic = 0.5, Legendary = 0 }))).toBe(
				false
			)
			expect((Crates.validateOdds(Config, { Common = 1 }))).toBe(false)
		end)

		it("matches the published odds over many rolls (pity disabled)", function()
			local random = seeded(99)
			local noPity = table.clone(crate)
			noPity.pityEpic = math.huge
			noPity.pityLegendary = math.huge
			local counts = { Common = 0, Rare = 0, Epic = 0, Legendary = 0 }
			local n = 200000
			for _ = 1, n do
				local rarity =
					Crates.rollRarity(Config, noPity, { sinceEpic = 0, sinceLegendary = 0 }, random)
				counts[rarity] += 1
			end
			for rarity, p in crate.odds do
				-- within 4 standard deviations
				local sd = math.sqrt(p * (1 - p) / n)
				expect(math.abs(counts[rarity] / n - p) < 4 * sd).toBe(true)
			end
		end)

		it("guarantees Epic or better at the epic pity threshold", function()
			local alwaysCommon = function()
				return 0 -- the lowest roll always lands on Common
			end
			local pity = { sinceEpic = crate.pityEpic - 1, sinceLegendary = 0 }
			local rarity = Crates.rollRarity(Config, crate, pity, alwaysCommon)
			expect(rarity == "Epic" or rarity == "Legendary").toBe(true)
		end)

		it("guarantees a Legendary at the legendary pity threshold", function()
			local pity = { sinceEpic = 0, sinceLegendary = crate.pityLegendary - 1 }
			expect(Crates.rollRarity(Config, crate, pity, function()
				return 0
			end)).toBe("Legendary")
		end)

		it("worst-case luck still hits pity on schedule", function()
			local data = rich(crate.price * crate.pityLegendary)
			local unlucky = function()
				return 0
			end
			local firstEpic, firstLegendary = nil, nil
			for open = 1, crate.pityLegendary do
				local result = Crates.open(Config, data, "Standard", unlucky) :: any
				if not firstEpic and (result.rarity == "Epic" or result.rarity == "Legendary") then
					firstEpic = open
				end
				if not firstLegendary and result.rarity == "Legendary" then
					firstLegendary = open
				end
			end
			expect(firstEpic).toBe(crate.pityEpic)
			expect(firstLegendary).toBe(crate.pityLegendary)
		end)

		it("updates pity counters by rarity", function()
			local pity = { sinceEpic = 4, sinceLegendary = 9 }
			Crates.updatePity(pity, "Rare")
			expect(pity).toEqual({ sinceEpic = 5, sinceLegendary = 10 })
			Crates.updatePity(pity, "Epic")
			expect(pity).toEqual({ sinceEpic = 0, sinceLegendary = 11 })
			Crates.updatePity(pity, "Legendary")
			expect(pity).toEqual({ sinceEpic = 0, sinceLegendary = 0 })
		end)

		it("charges the price, grants the prize and converts duplicates to coins", function()
			local data = rich(10000)
			local seen: { [string]: boolean } = {}
			local duplicates = 0
			local random = seeded(5)
			for _ = 1, 30 do
				local before = data.coins
				local result = Crates.open(Config, data, "Standard", random) :: any
				local prize = result.prize
				expect(data.coins).toBe(before - crate.price + prize.coins)
				if prize.kind == "cosmetic" then
					expect(data.cosmetics[prize.id]).toBe(true)
					if seen[prize.id] then
						expect(prize.duplicate).toBe(true)
						expect(prize.coins).toBe(Config.DuplicateCoins[result.rarity])
						duplicates += 1
					end
					seen[prize.id] = true
				end
			end
			expect(data.cratesOpened).toBe(30)
			expect(duplicates > 0).toBe(true)
		end)

		it("refuses without enough coins and never goes negative", function()
			local data = rich(crate.price - 1)
			local result, err = Crates.open(Config, data, "Standard", seeded(1))
			expect(result).toBeNil()
			expect(err).toBe("NotEnoughCoins")
			expect(data.coins).toBe(crate.price - 1)
			expect(select(2, Crates.open(Config, rich(9999), "Mystery", seeded(1)))).toBe("UnknownCrate")
		end)

		it("every rarity has a coin prize and only real cosmetics", function()
			for _, rarity in Config.RarityOrder do
				local pool = Crates.pool(Config, crate, rarity)
				local coinEntries = 0
				for _, prize in pool do
					if prize.kind == "coins" then
						coinEntries += 1
					end
				end
				expect(coinEntries).toBe(1)
				expect(#pool >= 2).toBe(true)
			end
		end)
	end)

	describe("Rewards", function()
		local r = Config.Rewards

		it("ranks MVPs by coins with a stable tie-break and a limit", function()
			local ranking = Rewards.ranking({ [10] = 50, [-2] = 120, [7] = 120, [3] = 5 }, 3)
			expect(#ranking).toBe(3)
			expect(ranking[1]).toEqual({ id = -2, coins = 120 })
			expect(ranking[2]).toEqual({ id = 7, coins = 120 })
			expect(ranking[3]).toEqual({ id = 10, coins = 50 })
			expect(#Rewards.ranking({}, 3)).toBe(0)
		end)

		it("pays a builder win, survivors and standing blocks", function()
			local coins = Rewards.compute(Config, {
				winner = "Builders",
				hunter = 9,
				builders = { 1, 2 },
				survivors = { 1 },
				tags = { [9] = 1 },
				standingByOwner = { [1] = 10, [2] = 1000 },
			})
			expect(coins[1]).toBe(
				r.Participation + r.BuilderTeamWin + r.SurvivorBonus + 10 * r.PerBlockStanding
			)
			expect(coins[2]).toBe(r.Participation + r.BuilderTeamWin + r.PerBlockStandingCap)
			expect(coins[9]).toBe(r.Participation + r.PerTag)
		end)

		it("pays a hunter win", function()
			local coins = Rewards.compute(Config, {
				winner = "Hunter",
				hunter = 9,
				builders = { 1 },
				survivors = {},
				tags = { [9] = 1 },
				standingByOwner = {},
			})
			expect(coins[9]).toBe(r.Participation + r.PerTag + r.HunterWin)
			expect(coins[1]).toBe(r.Participation)
		end)

		it("pays participation only for a voided round", function()
			local coins = Rewards.compute(Config, {
				winner = "None",
				hunter = 9,
				builders = { 1 },
				survivors = { 1 },
				tags = {},
				standingByOwner = { [1] = 30 },
			})
			expect(coins[1]).toBe(r.Participation)
			expect(coins[9]).toBe(r.Participation)
		end)
	end)
end
