--!strict
--[[
	FortPlanner: how bots (and the balance simulation) fortify. Pure: no Roblox APIs, no requires.

	The plan is a team fort, which is what sensible builders do. All builders stand in an n×n
	interior (n = ceil(sqrt(builders))). It is walled by up to three concentric rings, each two blocks
	high (8 studs, above the ~7-stud jump height, so a single-height wall would just be hopped).

	The hunter attacks the weakest column, so what matters is the HP of one column through every
	ring: Σ rings 2 × health(kind). The planner brute-forces a block kind per ring from the unlocked
	kinds to maximise that within the pooled budget. A ring is only planned if it can be closed
	completely, because one gap makes every ring behind it pointless.
]]

export type Cell = { x: number, y: number, z: number }

export type KindInfo = { cost: number, health: number }

export type Options = {
	builderCount: number,
	budgets: { number }, -- one budget per builder, index-aligned with builderCount
	kinds: { [string]: KindInfo }, -- unlocked kinds the builders may use
	bounds: { MinX: number, MaxX: number, MinZ: number, MaxZ: number },
	center: { x: number, z: number }?, -- interior's minimum corner; defaults to the middle of the bounds
	maxRings: number?,
	extras: { { kind: string, cost: number } }?, -- placed inside the fort first (e.g. a coin generator)
}

export type Placement = { cell: Cell, kind: string, owner: number }

export type Plan = {
	spots: { Cell }, -- where each builder stands (index = builder index)
	placements: { Placement }, -- in a buildable order (ground layer before the one above it)
	rings: { string }, -- kind chosen per ring, innermost first
	columnHealth: number, -- HP of the weakest column through all rings
	cost: number,
}

local FortPlanner = {}

local function ringCells(x0: number, z0: number, n: number, r: number): { { x: number, z: number } }
	-- Border of the square [x0 - r, x0 + n - 1 + r] × [z0 - r, z0 + n - 1 + r].
	local minX, maxX = x0 - r, x0 + n - 1 + r
	local minZ, maxZ = z0 - r, z0 + n - 1 + r
	local cells = {}
	for x = minX, maxX do
		table.insert(cells, { x = x, z = minZ })
		table.insert(cells, { x = x, z = maxZ })
	end
	for z = minZ + 1, maxZ - 1 do
		table.insert(cells, { x = minX, z = z })
		table.insert(cells, { x = maxX, z = z })
	end
	return cells
end

local function ringFits(x0: number, z0: number, n: number, r: number, bounds: any): boolean
	return x0 - r >= bounds.MinX
		and x0 + n - 1 + r <= bounds.MaxX
		and z0 - r >= bounds.MinZ
		and z0 + n - 1 + r <= bounds.MaxZ
end

function FortPlanner.plan(options: Options): Plan
	local count = math.max(1, options.builderCount)
	local n = math.ceil(math.sqrt(count))
	local bounds = options.bounds
	local x0 = if options.center
		then options.center.x
		else math.floor((bounds.MinX + bounds.MaxX + 1) / 2) - n // 2
	local z0 = if options.center
		then options.center.z
		else math.floor((bounds.MinZ + bounds.MaxZ + 1) / 2) - n // 2

	local spots: { Cell } = {}
	for i = 1, count do
		local index = i - 1
		table.insert(spots, { x = x0 + index % n, y = 0, z = z0 + index // n })
	end

	local totalBudget = 0
	for i = 1, count do
		totalBudget += options.budgets[i] or 0
	end

	local extrasCost = 0
	for _, extra in (options.extras or {}) :: { { kind: string, cost: number } } do
		extrasCost += extra.cost
	end
	local wallBudget = totalBudget - extrasCost

	-- Rings that fit inside the bounds, with their cell lists.
	local maxRings = options.maxRings or 3
	local ringList: { { { x: number, z: number } } } = {}
	for r = 1, maxRings do
		if not ringFits(x0, z0, n, r, bounds) then
			break
		end
		table.insert(ringList, ringCells(x0, z0, n, r))
	end

	local kindNames: { string } = {}
	for name in options.kinds do
		table.insert(kindNames, name)
	end
	table.sort(kindNames)

	-- Brute force: for each number of rings, every assignment of kinds (≤ 4^3 combinations).
	local best: { kinds: { string }, health: number, cost: number }? = nil
	local function search(ring: number, chosen: { string }, health: number, cost: number)
		if cost > wallBudget then
			return
		end
		if #chosen > 0 then
			local better = best == nil or health > best.health or (health == best.health and cost < best.cost)
			if better then
				best = { kinds = table.clone(chosen), health = health, cost = cost }
			end
		end
		if ring > #ringList then
			return
		end
		local blocks = #ringList[ring] * 2
		for _, name in kindNames do
			local info = options.kinds[name]
			table.insert(chosen, name)
			search(ring + 1, chosen, health + 2 * info.health, cost + blocks * info.cost)
			table.remove(chosen)
		end
	end
	search(1, {}, 0, 0)

	-- Owners: each placement is paid by the builder with the most budget left.
	local remaining = table.clone(options.budgets)
	local function payer(cost: number): number
		local who, most = 1, -math.huge
		for i = 1, count do
			local left = remaining[i] or 0
			if left >= cost and left > most then
				who, most = i, left
			end
		end
		remaining[who] = (remaining[who] or 0) - cost
		return who
	end

	-- Extras are paid first (their budget was reserved) and placed last, on top of the inner ring,
	-- where the hunter can reach them: that exposure is the risk of e.g. a coin generator.
	local extraOwners: { number } = {}
	for _, extra in (options.extras or {}) :: { { kind: string, cost: number } } do
		table.insert(extraOwners, payer(extra.cost))
	end

	local placements: { Placement } = {}
	local chosenKinds: { string } = {}
	local plan = best
	if plan then
		chosenKinds = plan.kinds
		for ringIndex, kind in plan.kinds do
			local info = options.kinds[kind]
			for y = 0, 1 do
				for _, c in ringList[ringIndex] do
					table.insert(
						placements,
						{ cell = { x = c.x, y = y, z = c.z }, kind = kind, owner = payer(info.cost) }
					)
				end
			end
		end
	end

	for i, extra in (options.extras or {}) :: { { kind: string, cost: number } } do
		local top = if #ringList > 0 and plan then ringList[1][((i - 1) % #ringList[1]) + 1] else nil
		local cell = if top then { x = top.x, y = 2, z = top.z } else { x = x0 + n + i, y = 0, z = z0 }
		table.insert(placements, { cell = cell, kind = extra.kind, owner = extraOwners[i] })
	end

	return {
		spots = spots,
		placements = placements,
		rings = chosenKinds,
		columnHealth = if plan then plan.health else 0,
		cost = (if plan then plan.cost else 0) + extrasCost,
	}
end

return FortPlanner
