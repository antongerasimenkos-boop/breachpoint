--!strict
--[[
	BuildService: block placement, removal, repair and damage, plus the utility pieces (doors,
	coin generators, spike traps). The server's BlockGrid is the truth; Parts in
	workspace.Map.Blocks only display it.

	Every placement passes, in order:
	  phase == Build → alive Builder → kind known → kind unlocked (shop) → per-builder limit
	  → budget covers cost → server block cap → placement rules (grid: bounds, empty, supported;
	  trap: empty ground cell) → within reach of the builder → no character overlapping the cell
	Humans (via NetService handlers) and bots (via BotService) use the same `tryPlace`.

	Doors are grid blocks in the "Door" collision group, which builders pass through.
	Traps are floor plates outside the grid; standing on one fires `trapTriggered(hunterId)`.
	Generators are grid blocks that pay their owner coins on an interval while they stand.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local BlockGrid = require(Shared.Logic.BlockGrid)
local Config = require(Shared.Config)
local Signal = require(Shared.Util.Signal)
local Types = require(Shared.Types)

local Services = script.Parent
local Cooldowns = require(script.Parent.Parent.Gameplay.Cooldowns)
local DataService = require(Services.DataService)
local MapService = require(Services.MapService)
local NetService = require(Services.NetService)
local Participants = require(Services.Participants)
local RoundService = require(Services.RoundService)
local Shop = require(script.Parent.Parent.Economy.Shop)

local BuildService = {}

-- (hunterId) fired when the hunter steps on a spike trap.
BuildService.trapTriggered = Signal.new() :: Signal.Signal<number>

type Trap = { id: number, cell: Types.Cell, ownerId: number, part: Model }

type BuilderLoadout = {
	skin: Color3?,
	repairMultiplier: number,
	extraTraps: number,
}

local grid = BlockGrid.new(Config.Grid)
local parts: { [number]: BasePart } = {}
local budgets: { [number]: number } = {}
local loadouts: { [number]: BuilderLoadout } = {}
local placedCount: { [number]: { [string]: number } } = {} -- owner -> kind -> count this round
local traps: { [number]: Trap } = {}
local lastBreachFeed = 0
local nextTrapId = 1
local repairCooldowns = Cooldowns.new() -- per builder
local blockRepairCooldowns = Cooldowns.new() -- per block, shared by all builders
local lastHitAt: { [number]: number } = {} -- block id -> os.clock() of the last hunter hit

local CELL = Config.Grid.CellSize
local HALF_DIAGONAL = CELL * math.sqrt(3) / 2
local SKINNABLE = { Wood = true, Stone = true, Metal = true, Titanium = true }

local function playerOf(id: number): Player?
	return if id > 0 then Players:GetPlayerByUserId(id) else nil
end

local function setBudget(id: number, value: number)
	budgets[id] = value
	local player = playerOf(id)
	if player then
		player:SetAttribute("Budget", value)
	end
end

local function rgb(values: { number }): Color3
	return Color3.fromRGB(values[1], values[2], values[3])
end

local function blockColor(block: BlockGrid.Block): Color3
	local base = rgb(Config.Blocks[block.kind :: Types.BlockKind].color)
	local loadout = loadouts[block.ownerId]
	if loadout and loadout.skin and SKINNABLE[block.kind] then
		-- Skins tint the block but keep the tier's material, so strength stays readable.
		base = base:Lerp(loadout.skin, 0.65)
	end
	-- Darken as the block takes damage, so the hunter can read weak points.
	local damage = 1 - block.health / block.maxHealth
	return base:Lerp(Color3.new(0.1, 0.05, 0.05), damage * 0.65)
end

local function centerOf(cell: Types.Cell): Vector3
	local x, y, z = grid:cellCenter(cell)
	return Vector3.new(x, y, z)
end

local function createPart(block: BlockGrid.Block): BasePart
	local cfg = Config.Blocks[block.kind :: Types.BlockKind]
	local p = Instance.new("Part")
	p.Name = "Block_" .. block.id
	p.Anchored = true
	p.Size = Vector3.one * CELL
	p.Position = centerOf(block.cell)
	p.Material = (Enum.Material :: any)[cfg.material]
	p.Color = blockColor(block)
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	if block.kind == "Door" then
		p.CollisionGroup = MapService.Groups.Door
		p.Transparency = 0.25
	elseif block.kind == "Generator" then
		p.Size = Vector3.one * (CELL - 0.6)
		local light = Instance.new("PointLight")
		light.Color = p.Color
		light.Range = 10
		light.Brightness = 1.5
		light.Parent = p
	end
	p:SetAttribute("BlockId", block.id)
	p:SetAttribute("Kind", block.kind)
	p:SetAttribute("OwnerId", block.ownerId)
	p:SetAttribute("Health", block.health)
	p:SetAttribute("MaxHealth", block.maxHealth)
	p.Parent = MapService.blocksFolder()
	return p
end

local function createTrap(trap: Trap): Model
	local model = Instance.new("Model")
	model.Name = "Trap_" .. trap.id
	local base = centerOf(trap.cell) - Vector3.new(0, CELL / 2, 0)
	local plate = Instance.new("Part")
	plate.Name = "Plate"
	plate.Anchored = true
	plate.CanCollide = false
	plate.Size = Vector3.new(CELL - 0.4, 0.3, CELL - 0.4)
	plate.Position = base + Vector3.new(0, 0.15, 0)
	plate.Material = Enum.Material.Metal
	plate.Color = rgb(Config.Blocks["Trap" :: Types.BlockKind].color)
	plate.Parent = model
	for i = 0, 3 do
		local spike = Instance.new("Part")
		spike.Name = "Spike"
		spike.Anchored = true
		spike.CanCollide = false
		spike.CanQuery = false
		spike.Shape = Enum.PartType.Cylinder
		spike.Size = Vector3.new(1, 0.5, 0.5)
		spike.CFrame = CFrame.new(base + Vector3.new((i % 2 - 0.5) * 1.6, 0.6, (i // 2 - 0.5) * 1.6))
			* CFrame.Angles(0, 0, math.rad(90))
		spike.Material = Enum.Material.Metal
		spike.Color = Color3.fromRGB(170, 170, 180)
		spike.Parent = model
	end
	model:SetAttribute("TrapId", trap.id)
	model:SetAttribute("OwnerId", trap.ownerId)
	model.Parent = MapService.blocksFolder()
	return model
end

local function refreshPart(block: BlockGrid.Block)
	local p = parts[block.id]
	if p then
		p.Color = blockColor(block)
		p:SetAttribute("Health", block.health)
	end
end

local function destroyPart(id: number)
	local p = parts[id]
	parts[id] = nil
	if p then
		p:Destroy()
	end
end

local function clearAll()
	for id in parts do
		destroyPart(id)
	end
	for _, trap in traps do
		trap.part:Destroy()
	end
	traps = {}
	grid:clear()
	repairCooldowns:clear()
	blockRepairCooldowns:clear()
	lastHitAt = {}
	placedCount = {}
end

local function cellOccupiedByCharacter(center: Vector3): boolean
	local params = OverlapParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = Participants.allCharacters()
	local hits = workspace:GetPartBoundsInBox(CFrame.new(center), Vector3.one * (CELL - 0.3), params)
	return #hits > 0
end

local function trapAt(cell: Types.Cell): Trap?
	for _, trap in traps do
		if trap.cell.x == cell.x and trap.cell.y == cell.y and trap.cell.z == cell.z then
			return trap
		end
	end
	return nil
end

local function withinReach(id: number, position: Vector3, reach: number): boolean
	local root = Participants.root(id)
	if not root then
		return false
	end
	return (root.Position - position).Magnitude <= reach + HALF_DIAGONAL + Config.RangeLeeway
end

local function isActiveBuilder(id: number): boolean
	return RoundService.getRole(id) == "Builder" and RoundService.isAlive(id)
end

-- The builder class a player picked in the lobby (attribute "Class"), or the default.
local function classOf(player: Player)
	local name = player:GetAttribute("Class")
	return Config.Classes[if type(name) == "string" then name else Config.DefaultClass]
		or Config.Classes[Config.DefaultClass]
end

local function canUseKind(id: number, kind: string): boolean
	local player = playerOf(id)
	if kind == "Trap" and player and classOf(player).unlocksTrap then
		return true
	end
	local data = if player then DataService.getStats(player) else nil
	return Shop.canUseBlock(Config, data, kind)
end

-- Core rules ---------------------------------------------------------------------------------

function BuildService.tryPlace(ownerId: number, cell: Types.Cell, kind: Types.BlockKind): (boolean, string?)
	if RoundService.getPhase() ~= "Build" then
		return false, "Building is only allowed in the build phase"
	end
	if not isActiveBuilder(ownerId) then
		return false, "Only builders can build"
	end
	local cfg = Config.Blocks[kind]
	if not cfg then
		return false, "Unknown block"
	end
	if not canUseKind(ownerId, kind) then
		return false, cfg.label .. " is locked. Unlock it in the shop"
	end
	local counts = placedCount[ownerId] or {}
	local limit = if cfg.limitPerBuilder
			and kind == "Trap"
			and loadouts[ownerId]
		then cfg.limitPerBuilder + loadouts[ownerId].extraTraps
		else cfg.limitPerBuilder
	if limit and (counts[kind] or 0) >= limit then
		return false, string.format("You can place %d %s per round", limit, cfg.label)
	end
	if (budgets[ownerId] or 0) < cfg.cost then
		return false, "Not enough budget"
	end
	local trapCount = 0
	for _ in traps do
		trapCount += 1
	end
	if grid:count() + trapCount >= Config.Build.MaxBlocksTotal then
		return false, "Block limit reached"
	end

	if kind == "Trap" then
		if not grid:inBounds(cell) then
			return false, "OutOfBounds"
		end
		if cell.y ~= Config.Grid.MinY or grid:getAt(cell) or trapAt(cell) then
			return false, "Traps go on an empty floor cell"
		end
	else
		if trapAt(cell) then
			return false, "There is a trap there"
		end
		local ok, err = grid:canPlace(cell)
		if not ok then
			return false, if err == "Unsupported" then "Blocks need support below or beside them" else err
		end
	end

	local center = centerOf(cell)
	if not withinReach(ownerId, center, Config.Build.Reach) then
		return false, "Too far away"
	end
	if kind ~= "Trap" and cellOccupiedByCharacter(center) then
		return false, "Someone is standing there"
	end

	if kind == "Trap" then
		local trap: Trap = { id = nextTrapId, cell = table.clone(cell), ownerId = ownerId, part = nil :: any }
		nextTrapId += 1
		trap.part = createTrap(trap)
		traps[trap.id] = trap
	else
		local block = grid:place(cell, kind, ownerId, cfg.health)
		parts[block.id] = createPart(block)
	end
	counts[kind] = (counts[kind] or 0) + 1
	placedCount[ownerId] = counts
	setBudget(ownerId, budgets[ownerId] - cfg.cost)
	local player = playerOf(ownerId)
	if player then
		DataService.increment(player, "blocksPlaced", 1)
	end
	NetService.effect("Place", center)
	return true, nil
end

function BuildService.tryRemove(ownerId: number, blockId: number): (boolean, string?)
	if RoundService.getPhase() ~= "Build" then
		return false, "You can only take blocks back while building"
	end
	if not isActiveBuilder(ownerId) then
		return false, "Only builders can do that"
	end
	local block = grid:get(blockId)
	if not block then
		return false, "That block is gone"
	end
	if block.ownerId ~= ownerId then
		return false, "That is not your block"
	end
	if not withinReach(ownerId, centerOf(block.cell), Config.Build.Reach) then
		return false, "Too far away"
	end
	grid:remove(blockId)
	destroyPart(blockId)
	local counts = placedCount[ownerId]
	if counts and counts[block.kind] then
		counts[block.kind] -= 1
	end
	setBudget(ownerId, (budgets[ownerId] or 0) + Config.Blocks[block.kind :: Types.BlockKind].cost)
	return true, nil
end

function BuildService.tryRepair(builderId: number, blockId: number): (boolean, string?)
	if RoundService.getPhase() ~= "Hunt" then
		return false, "Repairs happen during the hunt"
	end
	if not isActiveBuilder(builderId) then
		return false, "Only builders can repair"
	end
	local block = grid:get(blockId)
	if not block then
		return false, "That block is gone"
	end
	if block.health >= block.maxHealth then
		return false, "Already at full health"
	end
	if not withinReach(builderId, centerOf(block.cell), Config.Repair.Reach) then
		return false, "Too far away"
	end
	if BuildService.isUnderFire(blockId) then
		return false, "That block is under attack"
	end
	if blockRepairCooldowns:remaining(blockId, "Repair") > 0 then
		return false, "That block was just repaired"
	end
	local loadout = loadouts[builderId]
	local cooldown = Config.Repair.Cooldown * (if loadout then loadout.repairMultiplier else 1)
	if not repairCooldowns:use(builderId, "Repair", cooldown) then
		return false, "Repair is cooling down"
	end
	blockRepairCooldowns:use(blockId, "Repair", Config.Repair.BlockCooldown)
	grid:repair(blockId, Config.Repair.Amount)
	refreshPart(block)
	NetService.effect("Repair", centerOf(block.cell))
	local player = playerOf(builderId)
	if player then
		DataService.increment(player, "blocksRepaired", 1)
		DataService.increment(player, "coins", Config.Rewards.PerRepair)
	end
	return true, nil
end

-- Used by HunterService. Returns (existed, destroyed, kind, ownerId).
-- `targeted` (a Breach, not Shockwave splash) puts the block under fire: no repairs for a moment.
function BuildService.damageBlock(
	blockId: number,
	amount: number,
	targeted: boolean?
): (boolean, boolean, string?, number?)
	local block = grid:get(blockId)
	if not block then
		return false, false, nil, nil
	end
	local position = centerOf(block.cell)
	if targeted then
		lastHitAt[blockId] = os.clock()
	end
	local _, destroyed = grid:damage(blockId, amount)
	if destroyed then
		destroyPart(blockId)
		NetService.effect("BlockBroken", position)
		-- At most one feed line every few seconds, so a Shockwave doesn't flood it.
		if os.clock() - lastBreachFeed > 4 then
			lastBreachFeed = os.clock()
			local kindConfig = (Config.Blocks :: any)[block.kind]
			local label = if kindConfig then kindConfig.label else "wall"
			NetService.notifyAll(
				"feed",
				string.format("The hunter broke through a %s block", string.lower(label))
			)
		end
	else
		refreshPart(block)
		NetService.effect("BlockHit", position)
	end
	return true, destroyed, block.kind, block.ownerId
end

-- True while a block was hit within Config.Repair.UnderFireLock seconds (repairs refused).
function BuildService.isUnderFire(blockId: number): boolean
	local hit = lastHitAt[blockId]
	return hit ~= nil and os.clock() - hit < Config.Repair.UnderFireLock
end

function BuildService.blockCenter(blockId: number): Vector3?
	local block = grid:get(blockId)
	return block and centerOf(block.cell)
end

function BuildService.blocksWithin(position: Vector3, radius: number): { number }
	local ids = {}
	for _, block in grid:blocksWithin(position.X, position.Y, position.Z, radius) do
		table.insert(ids, block.id)
	end
	return ids
end

-- Blocks still standing per owner (end-of-round rewards).
function BuildService.standingByOwner(): { [number]: number }
	local counts = {}
	for _, block in grid:all() do
		counts[block.ownerId] = (counts[block.ownerId] or 0) + 1
	end
	return counts
end

-- Read-only view of the authoritative grid, for the practice bots' brains.
function BuildService.gridView(): BlockGrid.BlockGrid
	return grid
end

function BuildService.blockCount(): number
	return grid:count()
end

function BuildService.budgetOf(id: number): number
	return budgets[id] or 0
end

-- Network handlers ---------------------------------------------------------------------------

local function respond(player: Player, action: any, ok: boolean, reason: string?)
	NetService.actionResult(player, action, ok, reason)
end

function BuildService.onPlaceBlock(player: Player, x: number, y: number, z: number, kind: Types.BlockKind)
	local ok, reason = BuildService.tryPlace(player.UserId, { x = x, y = y, z = z }, kind)
	if not ok then
		respond(player, "PlaceBlock", false, reason)
	end
end

function BuildService.onRemoveBlock(player: Player, blockId: number)
	local ok, reason = BuildService.tryRemove(player.UserId, blockId)
	respond(player, "RemoveBlock", ok, reason)
end

function BuildService.onRepairBlock(player: Player, blockId: number)
	local ok, reason = BuildService.tryRepair(player.UserId, blockId)
	respond(player, "RepairBlock", ok, reason)
end

-- Lifecycle ----------------------------------------------------------------------------------

local function resetRound()
	clearAll()
	budgets = {}
	loadouts = {}
	for _, player in Players:GetPlayers() do
		player:SetAttribute("Budget", nil)
		-- Undo a Scout's speed between rounds (the hunter's speed is HunterService's job).
		local humanoid = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
		if humanoid and player:GetAttribute("Role") ~= "Hunter" then
			humanoid.WalkSpeed = Config.DefaultWalkSpeed
		end
	end
end

local function loadoutFor(id: number): (BuilderLoadout, number)
	local player = playerOf(id)
	local data = if player then DataService.getStats(player) else nil
	local skin: Color3? = nil
	local budget = Config.Build.BudgetPerBuilder
	local repairMultiplier = 1
	if data then
		for _, cosmetic in Config.Cosmetics do
			if cosmetic.id == data.equipped.BlockSkin and data.cosmetics[cosmetic.id] then
				skin = rgb(cosmetic.color)
			end
		end
		if data.owned.DeepPockets then
			budget += Config.Perks.DeepPocketsBudget
		end
		if data.owned.QuickHands then
			repairMultiplier = Config.Perks.QuickHandsRepairMultiplier
		end
	end
	local extraTraps = 0
	if player then
		local class = classOf(player)
		repairMultiplier *= class.repairMultiplier or 1
		extraTraps = class.extraTraps or 0
		local humanoid = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
		if humanoid then
			humanoid.WalkSpeed = Config.DefaultWalkSpeed * (class.speedMultiplier or 1)
		end
	end
	return { skin = skin, repairMultiplier = repairMultiplier, extraTraps = extraTraps }, budget
end

function BuildService.onChooseClass(player: Player, className: string)
	local class = Config.Classes[className]
	if not class then
		respond(player, "ChooseClass", false, "Unknown class")
		return
	end
	player:SetAttribute("Class", className)
	respond(player, "ChooseClass", true, nil)
	local phase = RoundService.getPhase()
	local timing = if phase == "Build" or phase == "Hunt" then " from the next round" else ""
	NetService.notify(player, "success", string.format("You play as %s%s", class.label, timing))
end

-- Generators pay their owners while they stand; traps fire when the hunter steps on them.
local function startLoops()
	task.spawn(function()
		while true do
			task.wait(Config.Generator.Interval)
			local phase = RoundService.getPhase()
			if phase ~= "Build" and phase ~= "Hunt" then
				continue
			end
			for _, block in grid:all() do
				local player = if block.kind == "Generator" then playerOf(block.ownerId) else nil
				if player and DataService.increment(player, "coins", Config.Generator.PayoutCoins) then
					NetService.effect("Coins", centerOf(block.cell))
				end
			end
		end
	end)

	local accumulator = 0
	RunService.Heartbeat:Connect(function(dt)
		accumulator += dt
		if accumulator < 0.15 or next(traps) == nil or RoundService.getPhase() ~= "Hunt" then
			return
		end
		accumulator = 0
		local hunterId = RoundService.hunterId()
		local root = hunterId and Participants.root(hunterId)
		if not hunterId or not root then
			return
		end
		for id, trap in traps do
			local center = centerOf(trap.cell)
			local flat = Vector3.new(root.Position.X - center.X, 0, root.Position.Z - center.Z)
			if flat.Magnitude <= Config.Trap.TriggerRadius and root.Position.Y < center.Y + CELL then
				traps[id] = nil
				trap.part:Destroy()
				NetService.effect("Trap", center)
				BuildService.trapTriggered:fire(hunterId)
			end
		end
	end)
end

function BuildService.init() end

function BuildService.start()
	RoundService.rolesAssigned:connect(function(_hunter, builders)
		resetRound()
		for _, id in builders do
			local loadout, budget = loadoutFor(id)
			loadouts[id] = loadout
			setBudget(id, budget)
		end
	end)
	RoundService.phaseChanged:connect(function(_from, to)
		if to == "Intermission" or to == "Waiting" then
			resetRound()
		end
	end)
	local function initClass(player: Player)
		if player:GetAttribute("Class") == nil then
			player:SetAttribute("Class", Config.DefaultClass)
		end
	end
	Players.PlayerAdded:Connect(initClass)
	for _, player in Players:GetPlayers() do
		initClass(player)
	end
	Players.PlayerRemoving:Connect(function(player)
		budgets[player.UserId] = nil
		loadouts[player.UserId] = nil
		repairCooldowns:clear(player.UserId)
	end)
	startLoops()
end

return BuildService
