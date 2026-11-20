--!strict
--[[
	HunterBrain: the hunter's decision-making, pure and shared by the practice bot and the
	headless balance simulation. Because both use it, a balance number measured in the simulation
	is the same AI the Studio bots run.

	Model: the hunter moves over ground columns (x, z). A column is blocked when it holds a block at
	layer 0 or 1 (characters are ~5 studs tall; two layers = 8 studs, above jump height).
	Dijkstra over columns, where entering a column costs
		travel time (cell / speed, ×√2 diagonally) + time to break its blocks (HP / breach DPS),
	so the hunter picks the cheapest builder and attacks the weakest point of the wall, as a good
	human hunter would.

	Each `decide` call returns one primary action plus whether to fire Shockwave / Sprint.
]]

export type Cell = { x: number, y: number, z: number }

export type Block = { id: number, cell: Cell, health: number, maxHealth: number }

-- The subset of BlockGrid the brain needs (injected, so this module has no requires).
export type GridView = {
	getAt: (self: any, cell: Cell) -> Block?,
	blocksWithin: (self: any, x: number, y: number, z: number, radius: number) -> { Block },
}

export type Tuning = {
	cellSize: number,
	groundY: number,
	bounds: { MinX: number, MaxX: number, MinZ: number, MaxZ: number },
	margin: number, -- extra columns around the grid the hunter may walk through
	speed: number, -- studs / s
	breachDps: number, -- damage per second against one block
	breachRange: number, -- studs from hunter root to block centre, leeway included
	tagRange: number, -- studs, leeway included
	shockwaveRadius: number,
	shockwaveMinBlocks: number,
	sprintMinDistance: number,
}

export type Target = { id: number, x: number, z: number }

export type Decision = {
	action: "tag" | "breach" | "move" | "idle",
	targetId: number?,
	blockId: number?,
	x: number?,
	z: number?,
	shockwave: boolean,
	sprint: boolean,
}

local HunterBrain = {}

local ROOT_HEIGHT = 3 -- root part height above the ground
local HEAD_OFFSET = 1.5

local function columnBlocks(grid: GridView, x: number, z: number): (Block?, Block?)
	return grid:getAt({ x = x, y = 0, z = z }), grid:getAt({ x = x, y = 1, z = z })
end

local function toColumn(t: Tuning, px: number, pz: number): (number, number)
	return math.floor(px / t.cellSize), math.floor(pz / t.cellSize)
end

local function columnCenter(t: Tuning, cx: number, cz: number): (number, number)
	return (cx + 0.5) * t.cellSize, (cz + 0.5) * t.cellSize
end

-- Line of sight at body height or head height (mirrors HunterService's two raycasts).
function HunterBrain.lineOfSight(
	grid: GridView,
	t: Tuning,
	ax: number,
	az: number,
	bx: number,
	bz: number
): boolean
	local dx, dz = bx - ax, bz - az
	local length = math.sqrt(dx * dx + dz * dz)
	local steps = math.max(1, math.ceil(length / 0.5))
	for _, height in { ROOT_HEIGHT, ROOT_HEIGHT + HEAD_OFFSET } do
		local layer = math.floor((height - t.groundY) / t.cellSize)
		local clear = true
		for i = 1, steps - 1 do
			local f = i / steps
			local cx, cz = toColumn(t, ax + dx * f, az + dz * f)
			if grid:getAt({ x = cx, y = layer, z = cz }) then
				clear = false
				break
			end
		end
		if clear then
			return true
		end
	end
	return false
end

-- Minimal binary heap keyed by cost.
local function push(heap: { { number } }, cost: number, node: number)
	table.insert(heap, { cost, node })
	local i = #heap
	while i > 1 do
		local parent = i // 2
		if heap[parent][1] <= heap[i][1] then
			break
		end
		heap[parent], heap[i] = heap[i], heap[parent]
		i = parent
	end
end

local function pop(heap: { { number } }): (number, number)
	local top = heap[1]
	local last = table.remove(heap) :: { number }
	if #heap > 0 then
		heap[1] = last
		local i = 1
		while true do
			local l, r, smallest = i * 2, i * 2 + 1, i
			if l <= #heap and heap[l][1] < heap[smallest][1] then
				smallest = l
			end
			if r <= #heap and heap[r][1] < heap[smallest][1] then
				smallest = r
			end
			if smallest == i then
				break
			end
			heap[i], heap[smallest] = heap[smallest], heap[i]
			i = smallest
		end
	end
	return top[1], top[2]
end

local NEIGHBOURS = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 }, { 1, 1 }, { 1, -1 }, { -1, 1 }, { -1, -1 } }

function HunterBrain.decide(
	grid: GridView,
	t: Tuning,
	hx: number,
	hz: number,
	targets: { Target },
	abilities: {
		shockwaveReady: boolean,
		sprintReady: boolean,
	}
): Decision
	local decision: Decision = { action = "idle", shockwave = false, sprint = false }
	if #targets == 0 then
		return decision
	end

	local minX, maxX = t.bounds.MinX - t.margin, t.bounds.MaxX + t.margin
	local minZ, maxZ = t.bounds.MinZ - t.margin, t.bounds.MaxZ + t.margin
	local width = maxX - minX + 1
	local function id(cx: number, cz: number): number
		return (cz - minZ) * width + (cx - minX) + 1
	end
	local function coords(node: number): (number, number)
		local index = node - 1
		return index % width + minX, index // width + minZ
	end

	local startX, startZ = toColumn(t, hx, hz)
	startX = math.clamp(startX, minX, maxX)
	startZ = math.clamp(startZ, minZ, maxZ)

	-- Break time of each column, computed lazily.
	local breakCache: { [number]: number } = {}
	local function breakTime(cx: number, cz: number): number
		local node = id(cx, cz)
		local cached = breakCache[node]
		if cached then
			return cached
		end
		local a, b = columnBlocks(grid, cx, cz)
		local hp = (if a then a.health else 0) + (if b then b.health else 0)
		local time = hp / t.breachDps
		breakCache[node] = time
		return time
	end

	local step = t.cellSize / t.speed
	local dist: { [number]: number } = { [id(startX, startZ)] = 0 }
	local previous: { [number]: number } = {}
	local heap = {}
	push(heap, 0, id(startX, startZ))
	local done: { [number]: boolean } = {}
	while #heap > 0 do
		local cost, node = pop(heap)
		if not done[node] then
			done[node] = true
			local cx, cz = coords(node)
			for _, d in NEIGHBOURS do
				local nx, nz = cx + d[1], cz + d[2]
				if nx >= minX and nx <= maxX and nz >= minZ and nz <= maxZ then
					local diagonal = d[1] ~= 0 and d[2] ~= 0
					-- No cutting corners past a blocked column.
					if not diagonal or (breakTime(cx + d[1], cz) == 0 and breakTime(cx, cz + d[2]) == 0) then
						local nextCost = cost + (if diagonal then step * 1.4142 else step) + breakTime(nx, nz)
						local neighbour = id(nx, nz)
						if nextCost < (dist[neighbour] or math.huge) then
							dist[neighbour] = nextCost
							previous[neighbour] = node
							push(heap, nextCost, neighbour)
						end
					end
				end
			end
		end
	end

	-- Cheapest target to reach.
	local best: Target? = nil
	local bestCost = math.huge
	for _, target in targets do
		local tx, tz = toColumn(t, target.x, target.z)
		local cost = dist[id(math.clamp(tx, minX, maxX), math.clamp(tz, minZ, maxZ))] or math.huge
		if cost < bestCost then
			best, bestCost = target, cost
		end
	end
	if not best then
		return decision
	end
	local target = best :: Target

	-- Shockwave whenever enough blocks are packed around us.
	if abilities.shockwaveReady then
		local around = grid:blocksWithin(hx, t.groundY + ROOT_HEIGHT, hz, t.shockwaveRadius)
		decision.shockwave = #around >= t.shockwaveMinBlocks
	end

	-- Tag if possible.
	local dx, dz = target.x - hx, target.z - hz
	if
		math.sqrt(dx * dx + dz * dz) <= t.tagRange
		and HunterBrain.lineOfSight(grid, t, hx, hz, target.x, target.z)
	then
		decision.action = "tag"
		decision.targetId = target.id
		return decision
	end

	-- Walk the path back from the target to find the next steps.
	local path: { number } = {}
	local tx, tz = toColumn(t, target.x, target.z)
	local node: number? = id(math.clamp(tx, minX, maxX), math.clamp(tz, minZ, maxZ))
	while node and node ~= id(startX, startZ) do
		table.insert(path, 1, node)
		node = previous[node]
	end

	if #path == 0 then
		-- Same column as the target but no line of sight: step toward them.
		decision.action = "move"
		decision.x, decision.z = target.x, target.z
		return decision
	end

	local nx, nz = coords(path[1])
	if breakTime(nx, nz) > 0 then
		local a, b = columnBlocks(grid, nx, nz)
		local block = if a and b then (if a.health <= b.health then a else b) else (a or b)
		if block then
			local bx, bz = columnCenter(t, nx, nz)
			local by = t.groundY + (block.cell.y + 0.5) * t.cellSize
			local ex, ey, ez = bx - hx, by - (t.groundY + ROOT_HEIGHT), bz - hz
			if math.sqrt(ex * ex + ey * ey + ez * ez) <= t.breachRange then
				decision.action = "breach"
				decision.blockId = block.id
				return decision
			end
		end
	end

	-- Move to the farthest of the next few columns that are already open.
	local waypoint = path[1]
	local openRun = 0
	for i = 1, math.min(#path, 3) do
		local px, pz = coords(path[i])
		if breakTime(px, pz) > 0 then
			break
		end
		waypoint = path[i]
		openRun = i
	end
	local wx, wz = coords(waypoint)
	decision.action = "move"
	decision.x, decision.z = columnCenter(t, wx, wz)
	if abilities.sprintReady then
		local remaining = bestCost * t.speed
		decision.sprint = openRun >= 2 and remaining >= t.sprintMinDistance
	end
	return decision
end

-- Derives the brain's tuning from game Config, so the bot and the simulation can't drift apart.
-- `damageMultiplier` applies hunter scaling (see Config.Hunter.DamagePerExtraBuilder).
function HunterBrain.tuningFromConfig(config: any, damageMultiplier: number?): Tuning
	local cell = config.Grid.CellSize
	local hunter = config.Hunter
	return {
		cellSize = cell,
		groundY = config.Grid.GroundY,
		bounds = {
			MinX = config.Grid.MinX,
			MaxX = config.Grid.MaxX,
			MinZ = config.Grid.MinZ,
			MaxZ = config.Grid.MaxZ,
		},
		margin = 7,
		speed = hunter.WalkSpeed,
		breachDps = hunter.Breach.Damage * (damageMultiplier or 1) / hunter.Breach.Cooldown,
		breachRange = hunter.Breach.Range + cell * math.sqrt(3) / 2,
		tagRange = hunter.Tag.Range + config.RangeLeeway,
		shockwaveRadius = hunter.Shockwave.Radius,
		shockwaveMinBlocks = 4,
		sprintMinDistance = 24,
	}
end

return HunterBrain
