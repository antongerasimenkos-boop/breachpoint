--!strict
--[[
	BlockGrid: the authoritative model of placed blocks, as pure data.

	Cells are integer coordinates inside fixed bounds. Placement rules:
	  * the cell is inside the bounds and empty;
	  * the block is supported: on the ground layer (y == MinY) or touching an existing block
	    on any of its six faces (no floating blocks in mid-air).
	Breaking a block never makes others fall. Fortresses with overhangs are allowed once built.

	The client uses the same module to colour its placement preview, but only the server's
	instance is authoritative.
]]

export type Cell = { x: number, y: number, z: number }

export type GridSpec = {
	CellSize: number,
	GroundY: number,
	MinX: number,
	MaxX: number,
	MinY: number,
	MaxY: number,
	MinZ: number,
	MaxZ: number,
}

export type Block = {
	id: number,
	cell: Cell,
	kind: string,
	ownerId: number,
	health: number,
	maxHealth: number,
}

export type PlaceError = "OutOfBounds" | "Occupied" | "Unsupported"

export type BlockGrid = {
	spec: GridSpec,
	inBounds: (self: BlockGrid, cell: Cell) -> boolean,
	getAt: (self: BlockGrid, cell: Cell) -> Block?,
	get: (self: BlockGrid, id: number) -> Block?,
	canPlace: (self: BlockGrid, cell: Cell) -> (boolean, PlaceError?),
	place: (self: BlockGrid, cell: Cell, kind: string, ownerId: number, health: number) -> Block,
	insert: (self: BlockGrid, cell: Cell, kind: string, ownerId: number, health: number) -> Block?,
	remove: (self: BlockGrid, id: number) -> Block?,
	damage: (self: BlockGrid, id: number, amount: number) -> (number, boolean),
	repair: (self: BlockGrid, id: number, amount: number) -> number,
	count: (self: BlockGrid) -> number,
	all: (self: BlockGrid) -> { Block },
	clear: (self: BlockGrid) -> (),
	cellCenter: (self: BlockGrid, cell: Cell) -> (number, number, number),
	worldToCell: (self: BlockGrid, x: number, y: number, z: number) -> Cell,
	blocksWithin: (self: BlockGrid, x: number, y: number, z: number, radius: number) -> { Block },
	_byId: { [number]: Block },
	_byCell: { [number]: Block },
	_nextId: number,
}

local NEIGHBOURS = {
	{ 1, 0, 0 },
	{ -1, 0, 0 },
	{ 0, 1, 0 },
	{ 0, -1, 0 },
	{ 0, 0, 1 },
	{ 0, 0, -1 },
}

local BlockGrid = {}
BlockGrid.__index = BlockGrid

-- Packs a cell into one number. Bounds are small, so 1024 per axis is plenty.
local function cellKey(cell: Cell): number
	return ((cell.x + 512) * 1024 + (cell.y + 512)) * 1024 + (cell.z + 512)
end

function BlockGrid.new(spec: GridSpec): BlockGrid
	assert(
		spec.MinX <= spec.MaxX and spec.MinY <= spec.MaxY and spec.MinZ <= spec.MaxZ,
		"invalid grid bounds"
	)
	local self = setmetatable({
		spec = spec,
		_byId = {},
		_byCell = {},
		_nextId = 1,
	}, BlockGrid)
	return self :: any
end

function BlockGrid.inBounds(self: BlockGrid, cell: Cell): boolean
	local s = self.spec
	for _, v in { cell.x, cell.y, cell.z } do
		if type(v) ~= "number" or v % 1 ~= 0 then
			return false
		end
	end
	return cell.x >= s.MinX
		and cell.x <= s.MaxX
		and cell.y >= s.MinY
		and cell.y <= s.MaxY
		and cell.z >= s.MinZ
		and cell.z <= s.MaxZ
end

function BlockGrid.getAt(self: BlockGrid, cell: Cell): Block?
	if not self:inBounds(cell) then
		return nil
	end
	return self._byCell[cellKey(cell)]
end

function BlockGrid.get(self: BlockGrid, id: number): Block?
	return self._byId[id]
end

function BlockGrid.canPlace(self: BlockGrid, cell: Cell): (boolean, PlaceError?)
	if not self:inBounds(cell) then
		return false, "OutOfBounds"
	end
	if self._byCell[cellKey(cell)] then
		return false, "Occupied"
	end
	if cell.y == self.spec.MinY then
		return true, nil
	end
	for _, d in NEIGHBOURS do
		local neighbour = { x = cell.x + d[1], y = cell.y + d[2], z = cell.z + d[3] }
		if self:getAt(neighbour) then
			return true, nil
		end
	end
	return false, "Unsupported"
end

local function store(self: BlockGrid, cell: Cell, kind: string, ownerId: number, health: number): Block
	local block: Block = {
		id = self._nextId,
		cell = { x = cell.x, y = cell.y, z = cell.z },
		kind = kind,
		ownerId = ownerId,
		health = health,
		maxHealth = health,
	}
	self._nextId += 1
	self._byId[block.id] = block
	self._byCell[cellKey(block.cell)] = block
	return block
end

function BlockGrid.place(self: BlockGrid, cell: Cell, kind: string, ownerId: number, health: number): Block
	local ok, err = self:canPlace(cell)
	assert(ok, "BlockGrid.place: " .. tostring(err))
	return store(self, cell, kind, ownerId, health)
end

-- Adds a block without the support rule, for mirroring authoritative state that may arrive in any
-- order (the client's placement preview). Returns nil if the cell is out of bounds or taken.
function BlockGrid.insert(self: BlockGrid, cell: Cell, kind: string, ownerId: number, health: number): Block?
	if not self:inBounds(cell) or self._byCell[cellKey(cell)] then
		return nil
	end
	return store(self, cell, kind, ownerId, health)
end

function BlockGrid.remove(self: BlockGrid, id: number): Block?
	local block = self._byId[id]
	if not block then
		return nil
	end
	self._byId[id] = nil
	self._byCell[cellKey(block.cell)] = nil
	return block
end

-- Returns (remaining health, destroyed). A destroyed block is removed from the grid.
function BlockGrid.damage(self: BlockGrid, id: number, amount: number): (number, boolean)
	local block = self._byId[id]
	if not block then
		return 0, false
	end
	block.health = math.max(0, block.health - amount)
	if block.health == 0 then
		self:remove(id)
		return 0, true
	end
	return block.health, false
end

-- Returns the new health (capped at maxHealth), or 0 if the block does not exist.
function BlockGrid.repair(self: BlockGrid, id: number, amount: number): number
	local block = self._byId[id]
	if not block then
		return 0
	end
	block.health = math.min(block.maxHealth, block.health + amount)
	return block.health
end

function BlockGrid.count(self: BlockGrid): number
	local n = 0
	for _ in self._byId do
		n += 1
	end
	return n
end

function BlockGrid.all(self: BlockGrid): { Block }
	local list = {}
	for _, block in self._byId do
		table.insert(list, block)
	end
	table.sort(list, function(a, b)
		return a.id < b.id
	end)
	return list
end

function BlockGrid.clear(self: BlockGrid)
	self._byId = {}
	self._byCell = {}
	-- Ids keep increasing across rounds so a stale client click can never hit a new block.
end

function BlockGrid.cellCenter(self: BlockGrid, cell: Cell): (number, number, number)
	local size = self.spec.CellSize
	return (cell.x + 0.5) * size, self.spec.GroundY + (cell.y + 0.5) * size, (cell.z + 0.5) * size
end

function BlockGrid.worldToCell(self: BlockGrid, x: number, y: number, z: number): Cell
	local size = self.spec.CellSize
	return {
		x = math.floor(x / size),
		y = math.floor((y - self.spec.GroundY) / size),
		z = math.floor(z / size),
	}
end

function BlockGrid.blocksWithin(self: BlockGrid, x: number, y: number, z: number, radius: number): { Block }
	local result = {}
	local r2 = radius * radius
	for _, block in self:all() do
		local cx, cy, cz = self:cellCenter(block.cell)
		local dx, dy, dz = cx - x, cy - y, cz - z
		if dx * dx + dy * dy + dz * dz <= r2 then
			table.insert(result, block)
		end
	end
	return result
end

return BlockGrid
