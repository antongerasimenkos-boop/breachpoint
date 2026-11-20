--!strict
--[[
	BuilderBrain: repair choice for practice bots and the balance simulation (pure).
	A sensible builder repairs whatever is closest to breaking: the lowest health fraction in reach.
]]

export type Block = { id: number, health: number, maxHealth: number }

export type GridView = {
	blocksWithin: (self: any, x: number, y: number, z: number, radius: number) -> { Block },
}

local BuilderBrain = {}

-- `locked(id)` excludes blocks that can't be repaired right now (under fire).
function BuilderBrain.chooseRepair(
	grid: GridView,
	x: number,
	y: number,
	z: number,
	reach: number,
	locked: ((id: number) -> boolean)?
): number?
	local bestId: number? = nil
	local bestRatio = 1
	for _, block in grid:blocksWithin(x, y, z, reach) do
		if locked and locked(block.id) then
			continue
		end
		local ratio = block.health / block.maxHealth
		if ratio < bestRatio then
			bestId, bestRatio = block.id, ratio
		end
	end
	return bestId
end

return BuilderBrain
