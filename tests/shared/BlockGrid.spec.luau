--!strict
local BlockGrid = require("../../src/shared/Logic/BlockGrid")
local Config = require("../../src/shared/Config")
local Cooldowns = require("../../src/server/Gameplay/Cooldowns")

return function(kit: any)
	local describe, it, expect = kit.describe, kit.it, kit.expect

	local function cell(x: number, y: number, z: number)
		return { x = x, y = y, z = z }
	end

	describe("BlockGrid", function()
		it("uses the game's real grid config", function()
			local grid = BlockGrid.new(Config.Grid)
			expect(grid:inBounds(cell(Config.Grid.MinX, 0, Config.Grid.MaxZ))).toBe(true)
			expect(grid:inBounds(cell(Config.Grid.MaxX + 1, 0, 0))).toBe(false)
		end)

		it("rejects out-of-bounds and non-integer cells", function()
			local grid = BlockGrid.new(Config.Grid)
			expect(select(2, grid:canPlace(cell(100, 0, 0)))).toBe("OutOfBounds")
			expect(select(2, grid:canPlace(cell(0, -1, 0)))).toBe("OutOfBounds")
			expect(select(2, grid:canPlace(cell(0.5, 0, 0)))).toBe("OutOfBounds")
		end)

		it("places on the ground and rejects occupied cells", function()
			local grid = BlockGrid.new(Config.Grid)
			local block = grid:place(cell(0, 0, 0), "Wood", 1, 3)
			expect(block.id).toBe(1)
			expect(grid:getAt(cell(0, 0, 0))).toBe(block)
			expect(select(2, grid:canPlace(cell(0, 0, 0)))).toBe("Occupied")
		end)

		it("requires support for blocks above the ground", function()
			local grid = BlockGrid.new(Config.Grid)
			expect(select(2, grid:canPlace(cell(0, 1, 0)))).toBe("Unsupported")
			grid:place(cell(0, 0, 0), "Wood", 1, 3)
			expect((grid:canPlace(cell(0, 1, 0)))).toBe(true)
			grid:place(cell(0, 1, 0), "Wood", 1, 3)
			-- side support counts too (overhangs)
			expect((grid:canPlace(cell(1, 1, 0)))).toBe(true)
			expect(select(2, grid:canPlace(cell(2, 1, 0)))).toBe("Unsupported")
		end)

		it("insert() mirrors blocks in any order but still respects bounds and occupancy", function()
			local grid = BlockGrid.new(Config.Grid)
			expect(grid:insert(cell(0, 2, 0), "Wood", 1, 3)).toBeTruthy() -- floating is fine when mirroring
			expect(grid:insert(cell(0, 2, 0), "Wood", 1, 3)).toBeNil()
			expect(grid:insert(cell(99, 0, 0), "Wood", 1, 3)).toBeNil()
			expect((grid:canPlace(cell(0, 3, 0)))).toBe(true) -- supported by the mirrored block
		end)

		it("damages, destroys and frees the cell", function()
			local grid = BlockGrid.new(Config.Grid)
			local block = grid:place(cell(1, 0, 1), "Stone", 1, 3)
			expect(grid:damage(block.id, 1)).toBe(2)
			local health, destroyed = grid:damage(block.id, 5)
			expect(health).toBe(0)
			expect(destroyed).toBe(true)
			expect(grid:get(block.id)).toBeNil()
			expect((grid:canPlace(cell(1, 0, 1)))).toBe(true)
		end)

		it("repairs up to max health only", function()
			local grid = BlockGrid.new(Config.Grid)
			local block = grid:place(cell(0, 0, 0), "Metal", 1, 10)
			grid:damage(block.id, 4)
			expect(grid:repair(block.id, 1)).toBe(7)
			expect(grid:repair(block.id, 100)).toBe(10)
			expect(grid:repair(999, 1)).toBe(0)
		end)

		it("never reuses ids after clear()", function()
			local grid = BlockGrid.new(Config.Grid)
			local first = grid:place(cell(0, 0, 0), "Wood", 1, 3)
			grid:clear()
			expect(grid:count()).toBe(0)
			local second = grid:place(cell(0, 0, 0), "Wood", 1, 3)
			expect(second.id > first.id).toBe(true)
		end)

		it("converts between cells and world positions", function()
			local grid = BlockGrid.new(Config.Grid)
			local size = Config.Grid.CellSize
			local x, y, z = grid:cellCenter(cell(-1, 0, 2))
			expect(x).toBe(-0.5 * size)
			expect(y).toBe(Config.Grid.GroundY + 0.5 * size)
			expect(z).toBe(2.5 * size)
			expect(grid:worldToCell(x, y, z)).toEqual(cell(-1, 0, 2))
		end)

		it("finds blocks within a radius", function()
			local grid = BlockGrid.new(Config.Grid)
			grid:place(cell(0, 0, 0), "Wood", 1, 3)
			grid:place(cell(5, 0, 5), "Wood", 1, 3)
			local x, y, z = grid:cellCenter(cell(0, 0, 0))
			local near = grid:blocksWithin(x, y, z, 6)
			expect(#near).toBe(1)
			expect(near[1].cell).toEqual(cell(0, 0, 0))
		end)
	end)

	describe("Cooldowns", function()
		it("blocks reuse until the cooldown elapses", function()
			local now = 0
			local cooldowns = Cooldowns.new(function()
				return now
			end)
			expect(cooldowns:use(1, "Breach", 0.5)).toBe(true)
			expect(cooldowns:use(1, "Breach", 0.5)).toBe(false)
			expect(cooldowns:remaining(1, "Breach")).toBe(0.5)
			now = 0.5
			expect(cooldowns:use(1, "Breach", 0.5)).toBe(true)
		end)

		it("tracks abilities and participants independently", function()
			local now = 0
			local cooldowns = Cooldowns.new(function()
				return now
			end)
			cooldowns:use(1, "Breach", 1)
			expect(cooldowns:use(1, "Shockwave", 1)).toBe(true)
			expect(cooldowns:use(2, "Breach", 1)).toBe(true)
		end)

		it("clear() resets one participant or everyone", function()
			local now = 0
			local cooldowns = Cooldowns.new(function()
				return now
			end)
			cooldowns:use(1, "A", 10)
			cooldowns:use(2, "A", 10)
			cooldowns:clear(1)
			expect(cooldowns:use(1, "A", 10)).toBe(true)
			expect(cooldowns:use(2, "A", 10)).toBe(false)
			cooldowns:clear()
			expect(cooldowns:use(2, "A", 10)).toBe(true)
		end)
	end)
end
