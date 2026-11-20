--!strict
local Migrations = require("../../src/server/Data/Migrations")
local Retry = require("../../src/server/Data/Retry")

return function(kit: any)
	local describe, it, expect = kit.describe, kit.it, kit.expect

	describe("Migrations", function()
		it("upgrades v1 -> current through every step", function()
			local data = Migrations.migrate({ coins = 12, wins = 3 }, 1)
			local expected = Migrations.template()
			expected.coins = 12
			expected.builderWins = 3
			expected.owned = { Metal = true } -- v3 -> v4 grandfathers Metal for existing players
			expect(data).toEqual(expected)
		end)

		it("upgrades v2 -> current keeping role wins", function()
			local data = Migrations.migrate({ coins = 1, builderWins = 2, hunterWins = 4 }, 2) :: any
			expect(data.hunterWins).toBe(4)
			expect(data.roundsPlayed).toBe(0)
		end)

		it("leaves current-version data intact", function()
			local current = Migrations.template()
			current.coins = 5
			current.tags = 3
			current.owned = { Metal = true, Door = true }
			current.cosmetics = { SkinGold = true }
			current.equipped = { BlockSkin = "SkinGold", Trail = "", Title = "" }
			current.daily = { lastDay = 20000, streak = 4 }
			current.pity = { sinceEpic = 3, sinceLegendary = 17 }
			current.xp = 420
			current.quests = { day = 20410, progress = { place30 = 12 }, done = { play3 = true } }
			expect(Migrations.migrate(current, Migrations.CURRENT_VERSION)).toEqual(current)
		end)

		it("v3 -> v4 adds the economy fields with safe defaults", function()
			local fresh =
				Migrations.migrate({ coins = 7, builderWins = 0, hunterWins = 0, roundsPlayed = 0 }, 3) :: any
			expect(fresh.coins).toBe(7)
			expect(fresh.owned).toEqual({})
			expect(fresh.equipped).toEqual({ BlockSkin = "", Trail = "", Title = "" })
			expect(fresh.daily).toEqual({ lastDay = 0, streak = 0 })
			expect(fresh.pity).toEqual({ sinceEpic = 0, sinceLegendary = 0 })
			local veteran = Migrations.migrate({ coins = 7, hunterWins = 2, roundsPlayed = 9 }, 3) :: any
			expect(veteran.owned).toEqual({ Metal = true })
		end)

		it("sanitises corrupt nested tables", function()
			local data = Migrations.migrate({
				owned = { Metal = true, [5] = true, Door = "yes", [string.rep("x", 50)] = true },
				cosmetics = "not a table",
				equipped = { BlockSkin = 12, Trail = "TrailEmber" },
				daily = { lastDay = -3, streak = 0 / 0 },
				pity = nil,
			}, 4) :: any
			expect(data.owned).toEqual({ Metal = true })
			expect(data.cosmetics).toEqual({})
			expect(data.equipped).toEqual({ BlockSkin = "", Trail = "TrailEmber", Title = "" })
			expect(data.daily).toEqual({ lastDay = 0, streak = 0 })
			expect(data.pity).toEqual({ sinceEpic = 0, sinceLegendary = 0 })
		end)

		it("v4 -> v5 credits XP for past rounds and starts empty quests", function()
			local data =
				Migrations.migrate({ coins = 3, roundsPlayed = 8, owned = { Metal = true } }, 4) :: any
			expect(data.xp).toBe(200)
			expect(data.quests).toEqual({ day = 0, progress = {}, done = {} })
			expect(data.owned).toEqual({ Metal = true })
			local fresh = Migrations.migrate({ coins = 3 }, 4) :: any
			expect(fresh.xp).toBe(0)
		end)

		it("sanitises corrupt quest state", function()
			local data = Migrations.migrate({
				xp = -40,
				quests = {
					day = "today",
					progress = { place30 = 12.7, [3] = 5, break20 = -2 },
					done = { play3 = 1 },
				},
			}, 5) :: any
			expect(data.xp).toBe(0)
			expect(data.quests).toEqual({ day = 0, progress = { place30 = 12, break20 = 0 }, done = {} })
		end)

		it("copy() shares no nested tables", function()
			local data = Migrations.template()
			local clone = Migrations.copy(data)
			clone.owned.Metal = true
			expect(data.owned.Metal).toBeNil()
		end)

		it("refuses data from a newer schema", function()
			local data, err = Migrations.migrate({ coins = 1 }, Migrations.CURRENT_VERSION + 1)
			expect(data).toBeNil()
			expect(err).toContain("newer schema")
		end)

		it("refuses nonsense versions", function()
			expect((Migrations.migrate({}, 0))).toBeNil()
			expect((Migrations.migrate({}, 1.5))).toBeNil()
			expect((Migrations.migrate({}, "2"))).toBeNil()
		end)

		it("repairs corrupt or missing fields", function()
			local data = Migrations.migrate(
				{ coins = "lots", builderWins = -4, hunterWins = 0 / 0, roundsPlayed = 2.7 },
				3
			) :: any
			expect(data.coins).toBe(0)
			expect(data.builderWins).toBe(0)
			expect(data.hunterWins).toBe(0)
			expect(data.roundsPlayed).toBe(2)
			expect(data.blocksBroken).toBe(0)
		end)

		it("handles a nil data table", function()
			expect(Migrations.migrate(nil, 1)).toEqual(Migrations.template())
		end)

		it("does not mutate its input", function()
			local input = { coins = 1, wins = 1 }
			Migrations.migrate(input, 1)
			expect(input).toEqual({ coins = 1, wins = 1 })
		end)
	end)

	describe("Retry", function()
		local function options(waits: { number })
			return {
				attempts = 4,
				baseDelay = 1,
				jitter = 0,
				wait = function(s: number)
					table.insert(waits, s)
				end,
			}
		end

		it("returns the first success", function()
			local waits = {}
			local calls = 0
			local ok, result, attempts = Retry.run(function()
				calls += 1
				if calls < 3 then
					error("flaky")
				end
				return "done"
			end, options(waits))
			expect(ok).toBe(true)
			expect(result).toBe("done")
			expect(attempts).toBe(3)
			expect(waits).toEqual({ 1, 2 })
		end)

		it("gives up after the last attempt without waiting again", function()
			local waits = {}
			local ok, err, attempts = Retry.run(function()
				error("down", 0)
			end, options(waits))
			expect(ok).toBe(false)
			expect(err).toBe("down")
			expect(attempts).toBe(4)
			expect(waits).toEqual({ 1, 2, 4 })
		end)

		it("caps the delay and adds bounded jitter", function()
			local delay = Retry.delayFor(10, {
				attempts = 10,
				baseDelay = 1,
				maxDelay = 8,
				jitter = 0.5,
				wait = function() end,
				random = function()
					return 1
				end,
			})
			expect(delay).toBe(12) -- 8 capped + 8 * 0.5 jitter
		end)
	end)
end
