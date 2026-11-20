--!strict
local Config = require("../../src/shared/Config")
local Migrations = require("../../src/server/Data/Migrations")
local Progression = require("../../src/server/Economy/Progression")

return function(kit: any)
	local describe, it, expect = kit.describe, kit.it, kit.expect

	describe("Levels", function()
		it("starts at level 1 and needs more XP for each level", function()
			expect(Progression.levelInfo(Config, 0)).toEqual({ level = 1, into = 0, need = 150 })
			expect(Progression.levelInfo(Config, 149).level).toBe(1)
			expect(Progression.levelInfo(Config, 150)).toEqual({ level = 2, into = 0, need = 200 })
			expect(Progression.levelInfo(Config, 360)).toEqual({ level = 3, into = 10, need = 250 })
		end)

		it("stops at the max level", function()
			local info = Progression.levelInfo(Config, 10 ^ 9)
			expect(info.level).toBe(Config.Progression.MaxLevel)
			expect(info.need).toBe(0)
		end)

		it("addXp reports a level-up and ignores negative or fractional XP", function()
			local data = { xp = 140 }
			local before, after = Progression.addXp(Config, data, 20.9)
			expect(before).toBe(1)
			expect(after).toBe(2)
			expect(data.xp).toBe(160)
			Progression.addXp(Config, data, -50)
			expect(data.xp).toBe(160)
		end)
	end)

	describe("Daily quests", function()
		it("picks three distinct quests per day and rotates them", function()
			local today = Progression.questsForDay(Config, 20000)
			expect(#today).toBe(3)
			expect(today[1].id ~= today[2].id and today[2].id ~= today[3].id and today[1].id ~= today[3].id).toBe(
				true
			)
			local tomorrow = Progression.questsForDay(Config, 20001)
			expect(tomorrow[1].id == today[1].id).toBe(false)
		end)

		it("counts matching stats, pays once on completion, and caps progress", function()
			local day = 20000
			local data = Migrations.template()
			local quest = Progression.questsForDay(Config, day)[1]
			expect(#Progression.record(Config, data, day, quest.stat, quest.target - 1)).toBe(0)
			expect(data.coins).toBe(0)
			local done = Progression.record(Config, data, day, quest.stat, 5)
			expect(#done).toBe(1)
			expect(data.coins).toBe(quest.reward)
			expect(data.quests.progress[quest.id]).toBe(quest.target)
			expect(#Progression.record(Config, data, day, quest.stat, 5)).toBe(0)
			expect(data.coins).toBe(quest.reward)
		end)

		it("ignores stats that no active quest tracks", function()
			local day = 20000
			local data = Migrations.template()
			local active = {}
			for _, quest in Progression.questsForDay(Config, day) do
				active[quest.stat] = true
			end
			for _, quest in Config.Quests do
				if not active[quest.stat] then
					Progression.record(Config, data, day, quest.stat, 1000)
				end
			end
			expect(data.coins).toBe(0)
			expect(data.quests.progress).toEqual({})
		end)

		it("resets progress on a new day", function()
			local data = Migrations.template()
			local quest = Progression.questsForDay(Config, 20000)[1]
			Progression.record(Config, data, 20000, quest.stat, 1)
			Progression.record(Config, data, 20001, "coins", 1)
			expect(data.quests.day).toBe(20001)
			expect(data.quests.progress).toEqual({})
			local view = Progression.view(Config, data.quests, 20002)
			expect(#view).toBe(3)
			expect(view[1].progress).toBe(0)
		end)
	end)
end
