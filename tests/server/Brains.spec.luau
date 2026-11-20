--!strict
local BlockGrid = require("../../src/shared/Logic/BlockGrid")
local BuilderBrain = require("../../src/server/Gameplay/BuilderBrain")
local Config = require("../../src/shared/Config")
local FortPlanner = require("../../src/server/Gameplay/FortPlanner")
local HunterBrain = require("../../src/server/Gameplay/HunterBrain")

return function(kit: any)
	local describe, it, expect = kit.describe, kit.it, kit.expect

	local KINDS = {
		Wood = { cost = 1, health = 8 },
		Stone = { cost = 2, health = 20 },
		Metal = { cost = 4, health = 45 },
	}

	local function budgets(count: number, each: number)
		local list = {}
		for i = 1, count do
			list[i] = each
		end
		return list
	end

	local function build(plan): any
		local grid = BlockGrid.new(Config.Grid)
		for _, p in plan.placements do
			assert(grid:canPlace(p.cell), "plan is not buildable in order")
			grid:place(p.cell, p.kind, p.owner, KINDS[p.kind] and KINDS[p.kind].health or 10)
		end
		return grid
	end

	describe("FortPlanner", function()
		it("closes every ring completely, two layers high", function()
			local plan =
				FortPlanner.plan({ builderCount = 1, budgets = { 64 }, kinds = KINDS, bounds = Config.Grid })
			local grid = build(plan)
			local spot = plan.spots[1]
			for dx = -1, 1 do
				for dz = -1, 1 do
					if dx ~= 0 or dz ~= 0 then
						for y = 0, 1 do
							expect(grid:getAt({ x = spot.x + dx, y = y, z = spot.z + dz })).toBeTruthy()
						end
					end
				end
			end
			expect(grid:getAt(spot)).toBeNil() -- the builder's own cell stays free
		end)

		it("maximises the weakest column within the budget", function()
			-- 16 blocks per ring for a solo fort: Metal (64) gives 2 × 45 = 90 HP per column.
			local plan =
				FortPlanner.plan({ builderCount = 1, budgets = { 64 }, kinds = KINDS, bounds = Config.Grid })
			expect(plan.rings).toEqual({ "Metal" })
			expect(plan.columnHealth).toBe(90)
			expect(plan.cost <= 64).toBe(true)
		end)

		it("uses only unlocked kinds", function()
			local plan = FortPlanner.plan({
				builderCount = 1,
				budgets = { 64 },
				kinds = { Wood = KINDS.Wood },
				bounds = Config.Grid,
			})
			for _, p in plan.placements do
				expect(p.kind).toBe("Wood")
			end
		end)

		it("pools budgets for a team and never overspends any builder", function()
			local plan = FortPlanner.plan({
				builderCount = 4,
				budgets = budgets(4, 64),
				kinds = KINDS,
				bounds = Config.Grid,
			})
			expect(#plan.spots).toBe(4)
			local spent = { 0, 0, 0, 0 }
			for _, p in plan.placements do
				spent[p.owner] += KINDS[p.kind].cost
			end
			for i = 1, 4 do
				expect(spent[i] <= 64).toBe(true)
			end
			build(plan)
		end)

		it("puts extras on top of the inner ring, after the walls", function()
			local plan = FortPlanner.plan({
				builderCount = 1,
				budgets = { 64 },
				kinds = KINDS,
				bounds = Config.Grid,
				extras = { { kind = "Generator", cost = 6 } },
			})
			local last = plan.placements[#plan.placements]
			expect(last.kind).toBe("Generator")
			expect(last.cell.y).toBe(2)
			expect(plan.cost <= 64).toBe(true)
			build(plan)
		end)
	end)

	describe("HunterBrain", function()
		local tuning = HunterBrain.tuningFromConfig(Config, 1)
		local NO_ABILITIES = { shockwaveReady = false, sprintReady = false }

		local function center(c: number): number
			return (c + 0.5) * Config.Grid.CellSize
		end

		it("walks toward a builder in the open and tags in range", function()
			local grid = BlockGrid.new(Config.Grid)
			local target = { id = 7, x = center(0), z = center(0) }
			local far = HunterBrain.decide(grid, tuning, center(0), center(8), { target }, NO_ABILITIES)
			expect(far.action).toBe("move")
			local near = HunterBrain.decide(grid, tuning, center(0), center(1), { target }, NO_ABILITIES)
			expect(near.action).toBe("tag")
			expect(near.targetId).toBe(7)
		end)

		it("breaches the weakest point of a wall", function()
			local grid = BlockGrid.new(Config.Grid)
			-- Ring around (0,0): Metal everywhere except one Wood column on the east side.
			for dx = -1, 1 do
				for dz = -1, 1 do
					if dx ~= 0 or dz ~= 0 then
						local weak = dx == 1 and dz == 0
						for y = 0, 1 do
							grid:place(
								{ x = dx, y = y, z = dz },
								if weak then "Wood" else "Metal",
								1,
								if weak then 8 else 45
							)
						end
					end
				end
			end
			local target = { id = 1, x = center(0), z = center(0) }
			-- Start south-east, next to the weak column's outside.
			local decision = HunterBrain.decide(grid, tuning, center(2), center(0), { target }, NO_ABILITIES)
			expect(decision.action).toBe("breach")
			local block = grid:get(decision.blockId :: number) :: any
			expect(block.kind).toBe("Wood")
		end)

		it("respects line of sight", function()
			local grid = BlockGrid.new(Config.Grid)
			grid:place({ x = 0, y = 0, z = 1 }, "Wood", 1, 8)
			grid:place({ x = 0, y = 1, z = 1 }, "Wood", 1, 8)
			expect(HunterBrain.lineOfSight(grid, tuning, center(0), center(0), center(0), center(2))).toBe(
				false
			)
			grid:remove((grid:getAt({ x = 0, y = 1, z = 1 }) :: any).id)
			-- A gap at head height is enough.
			expect(HunterBrain.lineOfSight(grid, tuning, center(0), center(0), center(0), center(2))).toBe(
				true
			)
		end)

		it("asks for Shockwave when surrounded by blocks", function()
			local grid = BlockGrid.new(Config.Grid)
			for x = 1, 4 do
				grid:place({ x = x, y = 0, z = 0 }, "Wood", 1, 8)
			end
			local decision = HunterBrain.decide(
				grid,
				tuning,
				center(2),
				center(1),
				{ { id = 1, x = center(-5), z = center(-5) } },
				{ shockwaveReady = true, sprintReady = false }
			)
			expect(decision.shockwave).toBe(true)
		end)

		it("does nothing without targets", function()
			local grid = BlockGrid.new(Config.Grid)
			expect(HunterBrain.decide(grid, tuning, 0, 0, {}, NO_ABILITIES).action).toBe("idle")
		end)
	end)

	describe("BuilderBrain", function()
		it("repairs the most damaged block in reach", function()
			local grid = BlockGrid.new(Config.Grid)
			local a = grid:place({ x = 0, y = 0, z = 0 }, "Wood", 1, 8)
			local b = grid:place({ x = 1, y = 0, z = 0 }, "Wood", 1, 8)
			grid:damage(a.id, 2)
			grid:damage(b.id, 6)
			expect(BuilderBrain.chooseRepair(grid, 2, 3, 2, 16)).toBe(b.id)
			grid:repair(b.id, 6)
			grid:repair(a.id, 2)
			expect(BuilderBrain.chooseRepair(grid, 2, 3, 2, 16)).toBeNil()
		end)

		it("skips blocks under fire", function()
			local grid = BlockGrid.new(Config.Grid)
			local attacked = grid:place({ x = 0, y = 0, z = 0 }, "Wood", 1, 16)
			local chipped = grid:place({ x = 1, y = 0, z = 0 }, "Wood", 1, 16)
			grid:damage(attacked.id, 12)
			grid:damage(chipped.id, 2)
			local locked = function(id: number)
				return id == attacked.id
			end
			expect(BuilderBrain.chooseRepair(grid, 2, 3, 2, 16, locked)).toBe(chipped.id)
		end)
	end)
end
