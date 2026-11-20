--!strict
--[[
	MapService builds the whole map from code at server start ("canyon outpost at dusk"), so the
	place needs no hand-made geometry and the layout is reviewable as data.

	    z = -110  Lobby: raised stone balcony overlooking the arena (spawn + spectators)
	    z =    0  Fort zone: 48x48 paved build grid, ringed by a barrier only builders collide with
	    z =  +90  Hunter cage: iron frame with glowing bars, opened when the hunt starts
	    r ≈ 125   Canyon rim (Terrain) closing the arena in

	The fort barrier uses collision groups: parts in "FortBarrier" collide with "Builders" only, so
	builders cannot simply run away while the hunter walks straight through. Builder doors use the
	"Door" group, which builders pass through. Barrier and invisible walls are CanQuery = false, so
	they never block mouse targeting or line-of-sight raycasts.

	Lighting uses Future technology (set in default.project.json: Technology can't be changed by
	game scripts) plus Atmosphere, Bloom, ColorCorrection and SunRays configured here.
]]

local Lighting = game:GetService("Lighting")
local PhysicsService = game:GetService("PhysicsService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("Shared").Config)

local MapService = {}

MapService.Groups = {
	Builders = "Builders",
	FortBarrier = "FortBarrier",
	Door = "Door", -- builder doors: solid for everyone except builders
}

local GRID = Config.Grid
local CELL = GRID.CellSize
local FORT_MIN_X, FORT_MAX_X = GRID.MinX * CELL, (GRID.MaxX + 1) * CELL
local FORT_MIN_Z, FORT_MAX_Z = GRID.MinZ * CELL, (GRID.MaxZ + 1) * CELL

local ARENA_SIZE = 240
local LOBBY_CENTER = Vector3.new(0, 60, -110)
local LOBBY_SIZE = 56
local CAGE_CENTER = Vector3.new(0, 0, 90)
local CAGE_SIZE = 14
local CAGE_HEIGHT = 12

local SAND = Color3.fromRGB(214, 180, 128)
local STONE = Color3.fromRGB(150, 128, 104)
local DARK_STONE = Color3.fromRGB(92, 82, 74)
local WOOD = Color3.fromRGB(110, 76, 48)
local IRON = Color3.fromRGB(58, 58, 64)
local BUILDER_BLUE = Color3.fromRGB(90, 170, 255)
local HUNTER_RED = Color3.fromRGB(255, 70, 60)

local mapFolder: Folder
local cageBars: { BasePart } = {}

local function part(props: { [string]: any }): Part
	local p = Instance.new("Part")
	p.Anchored = true
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	for key, value in props do
		(p :: any)[key] = value
	end
	return p
end

local function setupCollisionGroups()
	PhysicsService:RegisterCollisionGroup(MapService.Groups.Builders)
	PhysicsService:RegisterCollisionGroup(MapService.Groups.FortBarrier)
	PhysicsService:RegisterCollisionGroup(MapService.Groups.Door)
	PhysicsService:CollisionGroupSetCollidable(MapService.Groups.Door, MapService.Groups.Builders, false)
	PhysicsService:CollisionGroupSetCollidable(MapService.Groups.FortBarrier, "Default", false)
	PhysicsService:CollisionGroupSetCollidable(
		MapService.Groups.FortBarrier,
		MapService.Groups.Builders,
		true
	)
end

-- Lighting ---------------------------------------------------------------------------------------

local function effect(className: string, props: { [string]: any })
	local existing = Lighting:FindFirstChildOfClass(className)
	if existing then
		existing:Destroy()
	end
	local instance = Instance.new(className)
	for key, value in props do
		(instance :: any)[key] = value
	end
	instance.Parent = Lighting
end

local function setupLighting()
	-- Golden hour: long shadows read the fort's silhouette well and suit a hunt.
	Lighting.ClockTime = 17.4
	Lighting.GeographicLatitude = 35
	Lighting.Brightness = 2.6
	Lighting.Ambient = Color3.fromRGB(70, 60, 70)
	Lighting.OutdoorAmbient = Color3.fromRGB(150, 128, 120)
	Lighting.ColorShift_Top = Color3.fromRGB(255, 220, 180)
	Lighting.EnvironmentDiffuseScale = 1
	Lighting.EnvironmentSpecularScale = 1
	-- A Rojo-built place starts from engine class defaults, where shadows are off.
	Lighting.GlobalShadows = true
	Lighting.ShadowSoftness = 0.25
	effect("Atmosphere", {
		Density = 0.33,
		Offset = 0.15,
		Color = Color3.fromRGB(255, 205, 160),
		Decay = Color3.fromRGB(120, 90, 110),
		Glare = 0.5,
		Haze = 1.6,
	})
	effect("BloomEffect", { Intensity = 0.5, Size = 28, Threshold = 1.4 })
	effect("ColorCorrectionEffect", {
		Brightness = 0.02,
		Contrast = 0.12,
		Saturation = 0.12,
		TintColor = Color3.fromRGB(255, 244, 232),
	})
	effect("SunRaysEffect", { Intensity = 0.06, Spread = 0.6 })
end

-- Terrain ----------------------------------------------------------------------------------------

local function buildTerrain(rng: Random)
	local terrain = workspace.Terrain
	terrain:Clear()
	-- Arena floor: top surface exactly at GroundY.
	terrain:FillBlock(
		CFrame.new(0, GRID.GroundY - 8, 0),
		Vector3.new(ARENA_SIZE + 80, 16, ARENA_SIZE + 80),
		Enum.Material.Sand
	)
	-- Canyon rim around the arena.
	for i = 1, 32 do
		local angle = i / 32 * math.pi * 2 + rng:NextNumber(-0.05, 0.05)
		local radius = 132 + rng:NextNumber(-6, 10)
		local size = rng:NextNumber(18, 30)
		terrain:FillBall(
			Vector3.new(math.cos(angle) * radius, rng:NextNumber(0, 12), math.sin(angle) * radius),
			size,
			if i % 3 == 0 then Enum.Material.Rock else Enum.Material.Sandstone
		)
	end
	-- Low dunes inside the arena, away from the fort, the cage and the hunt-start corridor.
	local placed = 0
	while placed < 10 do
		local x = rng:NextNumber(-100, 100)
		local z = rng:NextNumber(-100, 100)
		local nearFort = math.abs(x) < 50 and math.abs(z) < 50
		local corridor = math.abs(x) < 26 and z > 0
		if nearFort or corridor then
			continue
		end
		placed += 1
		terrain:FillBall(Vector3.new(x, GRID.GroundY - 7, z), rng:NextNumber(9, 13), Enum.Material.Sand)
	end
end

-- Props ------------------------------------------------------------------------------------------

local function torch(parent: Instance, position: Vector3, color: Color3?)
	local model = Instance.new("Model")
	model.Name = "Torch"
	part({
		Name = "Post",
		Size = Vector3.new(0.8, 7, 0.8),
		Position = position + Vector3.new(0, 3.5, 0),
		Material = Enum.Material.Wood,
		Color = WOOD,
		CanQuery = false,
		Parent = model,
	})
	local head = part({
		Name = "Bowl",
		Size = Vector3.new(1.6, 0.8, 1.6),
		Position = position + Vector3.new(0, 7.2, 0),
		Material = Enum.Material.Metal,
		Color = IRON,
		CanQuery = false,
		Parent = model,
	})
	local fire = Instance.new("Fire")
	fire.Size = 4
	fire.Heat = 6
	fire.Color = color or Color3.fromRGB(255, 140, 40)
	fire.SecondaryColor = Color3.fromRGB(255, 220, 120)
	fire.Parent = head
	local light = Instance.new("PointLight")
	light.Color = color or Color3.fromRGB(255, 160, 80)
	light.Range = 18
	light.Brightness = 1.6
	light.Shadows = true
	light.Parent = head
	model.Parent = parent
end

local function pillar(parent: Instance, position: Vector3, height: number, broken: boolean)
	local radius = 3
	for i = 0, height - 1 do
		local segment = part({
			Name = "Pillar",
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(4, radius, radius),
			CFrame = CFrame.new(position + Vector3.new(0, 2 + i * 4, 0)) * CFrame.Angles(0, 0, math.rad(90)),
			Material = Enum.Material.Sandstone,
			Color = STONE:Lerp(SAND, (i % 2) * 0.3),
			Parent = parent,
		})
		segment.CanQuery = false
	end
	if broken then
		part({
			Name = "Rubble",
			Size = Vector3.new(radius + 1, 1.2, radius + 2),
			CFrame = CFrame.new(position + Vector3.new(radius, 0.6, 1)) * CFrame.Angles(0, 0.6, 0.2),
			Material = Enum.Material.Sandstone,
			Color = STONE,
			CanQuery = false,
			Parent = parent,
		})
	else
		part({
			Name = "Capital",
			Size = Vector3.new(radius + 1.6, 1, radius + 1.6),
			Position = position + Vector3.new(0, height * 4 + 0.5, 0),
			Material = Enum.Material.Sandstone,
			Color = DARK_STONE,
			CanQuery = false,
			Parent = parent,
		})
	end
end

local function crateStack(parent: Instance, position: Vector3, rng: Random)
	for i = 1, rng:NextInteger(2, 4) do
		local size = rng:NextNumber(2.6, 3.6)
		part({
			Name = "Crate",
			Size = Vector3.one * size,
			CFrame = CFrame.new(
				position
					+ Vector3.new(rng:NextNumber(-2, 2), size / 2 + (i > 2 and 3 or 0), rng:NextNumber(-2, 2))
			) * CFrame.Angles(0, rng:NextNumber(0, math.pi), 0),
			Material = Enum.Material.WoodPlanks,
			Color = WOOD:Lerp(SAND, rng:NextNumber(0, 0.3)),
			CanQuery = false,
			Parent = parent,
		})
	end
end

local function deadTree(parent: Instance, position: Vector3, rng: Random)
	local height = rng:NextNumber(10, 15)
	part({
		Name = "Trunk",
		Size = Vector3.new(1.6, height, 1.6),
		CFrame = CFrame.new(position + Vector3.new(0, height / 2, 0))
			* CFrame.Angles(0, 0, rng:NextNumber(-0.08, 0.08)),
		Material = Enum.Material.Wood,
		Color = Color3.fromRGB(80, 62, 50),
		CanQuery = false,
		Parent = parent,
	})
	for _ = 1, 3 do
		local length = rng:NextNumber(4, 7)
		local yaw = rng:NextNumber(0, math.pi * 2)
		local branch = CFrame.new(position + Vector3.new(0, height * rng:NextNumber(0.55, 0.9), 0))
			* CFrame.Angles(0, yaw, 0)
			* CFrame.Angles(0, 0, math.rad(rng:NextNumber(35, 60)))
		part({
			Name = "Branch",
			Size = Vector3.new(length, 0.7, 0.7),
			CFrame = branch * CFrame.new(length / 2, 0, 0),
			Material = Enum.Material.Wood,
			Color = Color3.fromRGB(80, 62, 50),
			CanQuery = false,
			Parent = parent,
		})
	end
end

local function banner(parent: Instance, position: Vector3, color: Color3)
	part({
		Name = "Pole",
		Size = Vector3.new(0.6, 14, 0.6),
		Position = position + Vector3.new(0, 7, 0),
		Material = Enum.Material.Metal,
		Color = IRON,
		CanQuery = false,
		Parent = parent,
	})
	part({
		Name = "Cloth",
		Size = Vector3.new(0.2, 6, 3.4),
		Position = position + Vector3.new(0, 10, 1.8),
		Material = Enum.Material.Fabric,
		Color = color,
		CanQuery = false,
		Parent = parent,
	})
end

-- Arena ------------------------------------------------------------------------------------------

local function buildFort(parent: Instance)
	-- Paved floor, checkered by build cell so the grid is readable.
	local floor = Instance.new("Folder")
	floor.Name = "FortFloor"
	for x = GRID.MinX, GRID.MaxX do
		for z = GRID.MinZ, GRID.MaxZ do
			local even = (x + z) % 2 == 0
			part({
				Name = "Tile",
				Size = Vector3.new(CELL - 0.15, 0.3, CELL - 0.15),
				Position = Vector3.new((x + 0.5) * CELL, GRID.GroundY - 0.1, (z + 0.5) * CELL),
				Material = Enum.Material.Pavement,
				Color = if even then Color3.fromRGB(176, 160, 138) else Color3.fromRGB(160, 144, 124),
				CanQuery = false,
				Parent = floor,
			})
		end
	end
	floor.Parent = parent

	local cx, cz = (FORT_MIN_X + FORT_MAX_X) / 2, (FORT_MIN_Z + FORT_MAX_Z) / 2
	local w, d = FORT_MAX_X - FORT_MIN_X, FORT_MAX_Z - FORT_MIN_Z
	local height = (GRID.MaxY + 1) * CELL + 16
	local walls = {
		{ Vector3.new(cx, height / 2, FORT_MIN_Z - 0.5), Vector3.new(w + 2, height, 1) },
		{ Vector3.new(cx, height / 2, FORT_MAX_Z + 0.5), Vector3.new(w + 2, height, 1) },
		{ Vector3.new(FORT_MIN_X - 0.5, height / 2, cz), Vector3.new(1, height, d + 2) },
		{ Vector3.new(FORT_MAX_X + 0.5, height / 2, cz), Vector3.new(1, height, d + 2) },
	}
	for i, spec in walls do
		part({
			Name = "FortBarrier" .. i,
			Position = spec[1],
			Size = spec[2],
			Material = Enum.Material.ForceField,
			Color = BUILDER_BLUE,
			Transparency = 0.82,
			CanQuery = false,
			CanTouch = false,
			CastShadow = false,
			CollisionGroup = MapService.Groups.FortBarrier,
			Parent = parent,
		})
		part({
			Name = "FortEdge" .. i,
			Position = Vector3.new(spec[1].X, GRID.GroundY + 0.12, spec[1].Z),
			Size = Vector3.new(spec[2].X, 0.25, spec[2].Z),
			Material = Enum.Material.Neon,
			Color = BUILDER_BLUE,
			CanCollide = false,
			CanQuery = false,
			Parent = parent,
		})
	end
	-- Corner pylons with blue light mark the zone from far away.
	for _, corner in { { -1, -1 }, { -1, 1 }, { 1, -1 }, { 1, 1 } } do
		local x = if corner[1] < 0 then FORT_MIN_X - 1.5 else FORT_MAX_X + 1.5
		local z = if corner[2] < 0 then FORT_MIN_Z - 1.5 else FORT_MAX_Z + 1.5
		part({
			Name = "Pylon",
			Size = Vector3.new(2.4, 10, 2.4),
			Position = Vector3.new(x, 5, z),
			Material = Enum.Material.Slate,
			Color = DARK_STONE,
			CanQuery = false,
			Parent = parent,
		})
		local cap = part({
			Name = "PylonLight",
			Size = Vector3.new(1.6, 1.6, 1.6),
			Position = Vector3.new(x, 10.8, z),
			Material = Enum.Material.Neon,
			Color = BUILDER_BLUE,
			CanQuery = false,
			Parent = parent,
		})
		local light = Instance.new("PointLight")
		light.Color = BUILDER_BLUE
		light.Range = 20
		light.Brightness = 1.2
		light.Parent = cap
	end
end

local function buildArenaBounds(parent: Instance)
	-- Invisible walls keep everyone inside; the canyon rim makes them read as natural.
	local half = ARENA_SIZE / 2
	for i, spec in { { 0, half }, { 0, -half }, { half, 0 }, { -half, 0 } } do
		local alongX = spec[2] ~= 0
		part({
			Name = "ArenaWall" .. i,
			Size = if alongX then Vector3.new(ARENA_SIZE, 60, 2) else Vector3.new(2, 60, ARENA_SIZE),
			Position = Vector3.new(spec[1], 30, spec[2]),
			Transparency = 1,
			CanQuery = false,
			Parent = parent,
		})
	end
end

local function buildCage(parent: Instance)
	local model = Instance.new("Model")
	model.Name = "HunterCage"
	local half = CAGE_SIZE / 2
	part({
		Name = "Pad",
		Size = Vector3.new(CAGE_SIZE + 4, 0.6, CAGE_SIZE + 4),
		Position = CAGE_CENTER + Vector3.new(0, 0.3, 0),
		Material = Enum.Material.DiamondPlate,
		Color = IRON,
		Parent = model,
	})
	part({
		Name = "PadGlow",
		Size = Vector3.new(CAGE_SIZE + 4.4, 0.2, CAGE_SIZE + 4.4),
		Position = CAGE_CENTER + Vector3.new(0, 0.1, 0),
		Material = Enum.Material.Neon,
		Color = HUNTER_RED,
		CanCollide = false,
		Parent = model,
	})
	-- Frame: corner posts and a roof ring.
	for _, corner in { { -1, -1 }, { -1, 1 }, { 1, -1 }, { 1, 1 } } do
		part({
			Name = "Post",
			Size = Vector3.new(1.2, CAGE_HEIGHT, 1.2),
			Position = CAGE_CENTER + Vector3.new(corner[1] * half, CAGE_HEIGHT / 2, corner[2] * half),
			Material = Enum.Material.Metal,
			Color = IRON,
			Parent = model,
		})
	end
	part({
		Name = "Roof",
		Size = Vector3.new(CAGE_SIZE + 1, 1, CAGE_SIZE + 1),
		Position = CAGE_CENTER + Vector3.new(0, CAGE_HEIGHT + 0.5, 0),
		Material = Enum.Material.DiamondPlate,
		Color = IRON,
		Parent = model,
	})
	-- Glowing bars on every side; these are what opens.
	for side = 1, 4 do
		for i = -3, 3 do
			local offset = i * (CAGE_SIZE / 7)
			local position = if side == 1
				then Vector3.new(offset, CAGE_HEIGHT / 2, half)
				elseif side == 2 then Vector3.new(offset, CAGE_HEIGHT / 2, -half)
				elseif side == 3 then Vector3.new(half, CAGE_HEIGHT / 2, offset)
				else Vector3.new(-half, CAGE_HEIGHT / 2, offset)
			local bar = part({
				Name = "Bar",
				Size = Vector3.new(0.4, CAGE_HEIGHT, 0.4),
				Position = CAGE_CENTER + position,
				Material = Enum.Material.Neon,
				Color = HUNTER_RED,
				CanQuery = false,
				Parent = model,
			})
			table.insert(cageBars, bar)
		end
		-- An invisible pane between the bars so nothing slips through the gaps.
		local paneSize = if side <= 2
			then Vector3.new(CAGE_SIZE, CAGE_HEIGHT, 0.4)
			else Vector3.new(0.4, CAGE_HEIGHT, CAGE_SIZE)
		local panePosition = if side == 1
			then Vector3.new(0, CAGE_HEIGHT / 2, half)
			elseif side == 2 then Vector3.new(0, CAGE_HEIGHT / 2, -half)
			elseif side == 3 then Vector3.new(half, CAGE_HEIGHT / 2, 0)
			else Vector3.new(-half, CAGE_HEIGHT / 2, 0)
		local pane = part({
			Name = "Pane",
			Size = paneSize,
			Position = CAGE_CENTER + panePosition,
			Transparency = 1,
			CanQuery = false,
			Parent = model,
		})
		table.insert(cageBars, pane)
	end
	local light = Instance.new("PointLight")
	light.Color = HUNTER_RED
	light.Range = 22
	light.Brightness = 2
	light.Parent = model:FindFirstChild("Roof")
	banner(model, CAGE_CENTER + Vector3.new(-half - 4, 0, -half), HUNTER_RED)
	banner(model, CAGE_CENTER + Vector3.new(half + 4, 0, -half), HUNTER_RED)
	model.Parent = parent
end

local function buildLobby(parent: Instance)
	local model = Instance.new("Model")
	model.Name = "Lobby"
	part({
		Name = "Floor",
		Size = Vector3.new(LOBBY_SIZE, 2, LOBBY_SIZE),
		Position = LOBBY_CENTER - Vector3.new(0, 1, 0),
		Material = Enum.Material.Slate,
		Color = DARK_STONE,
		Parent = model,
	})
	part({
		Name = "Inlay",
		Size = Vector3.new(LOBBY_SIZE - 12, 0.2, LOBBY_SIZE - 12),
		Position = LOBBY_CENTER + Vector3.new(0, 0.05, 0),
		Material = Enum.Material.Marble,
		Color = Color3.fromRGB(226, 214, 196),
		Parent = model,
	})
	part({
		Name = "Underside",
		Size = Vector3.new(LOBBY_SIZE - 6, 10, LOBBY_SIZE - 6),
		Position = LOBBY_CENTER - Vector3.new(0, 7, 0),
		Material = Enum.Material.Sandstone,
		Color = STONE,
		CanQuery = false,
		Parent = model,
	})
	local half = LOBBY_SIZE / 2
	for i, spec in { { 0, half }, { 0, -half }, { half, 0 }, { -half, 0 } } do
		local alongX = spec[2] ~= 0
		part({
			Name = "Rail" .. i,
			Size = if alongX then Vector3.new(LOBBY_SIZE, 1, 1) else Vector3.new(1, 1, LOBBY_SIZE),
			Position = LOBBY_CENTER + Vector3.new(spec[1], 2.5, spec[2]),
			Material = Enum.Material.Wood,
			Color = WOOD,
			Parent = model,
		})
		part({
			Name = "Wall" .. i,
			Size = if alongX then Vector3.new(LOBBY_SIZE, 20, 1) else Vector3.new(1, 20, LOBBY_SIZE),
			Position = LOBBY_CENTER + Vector3.new(spec[1], 10, spec[2]),
			Transparency = 1,
			CanQuery = false,
			Parent = model,
		})
	end
	for _, corner in { { -1, -1 }, { -1, 1 }, { 1, -1 }, { 1, 1 } } do
		torch(model, LOBBY_CENTER + Vector3.new(corner[1] * (half - 2), 0, corner[2] * (half - 2)))
	end

	-- Title sign facing the arena.
	local sign = part({
		Name = "Sign",
		Size = Vector3.new(30, 7, 0.6),
		Position = LOBBY_CENTER + Vector3.new(0, 7, half - 1),
		Material = Enum.Material.Wood,
		Color = WOOD,
		Parent = model,
	})
	local gui = Instance.new("SurfaceGui")
	gui.Face = Enum.NormalId.Back
	gui.PixelsPerStud = 40
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.GothamBlack
	label.TextScaled = true
	label.Text = "BREACHPOINT"
	label.TextColor3 = Color3.fromRGB(255, 210, 120)
	label.TextStrokeTransparency = 0.3
	label.Parent = gui
	gui.Parent = sign
	local front = gui:Clone()
	front.Face = Enum.NormalId.Front
	front.Parent = sign

	local spawn = Instance.new("SpawnLocation")
	spawn.Name = "LobbySpawn"
	spawn.Anchored = true
	spawn.Neutral = true
	spawn.Duration = 0
	spawn.Size = Vector3.new(10, 1, 10)
	-- Rotated so players spawn facing the arena (+Z).
	spawn.CFrame = CFrame.new(LOBBY_CENTER + Vector3.new(0, 0.5, -12)) * CFrame.Angles(0, math.pi, 0)
	spawn.Material = Enum.Material.Neon
	spawn.Color = Color3.fromRGB(255, 190, 110)
	spawn.Parent = model
	model.Parent = parent
end

local function buildProps(parent: Instance, rng: Random)
	local folder = Instance.new("Folder")
	folder.Name = "Props"
	-- Torches ring the fort (outside the barrier).
	for _, offset in { { -1, -1 }, { -1, 1 }, { 1, -1 }, { 1, 1 }, { 0, -1 }, { 0, 1 }, { -1, 0 }, { 1, 0 } } do
		local x = offset[1] * (FORT_MAX_X + 7)
		local z = offset[2] * (FORT_MAX_Z + 7)
		if not (offset[1] == 0 and offset[2] == 1) then -- keep the hunter's approach lane clear
			torch(folder, Vector3.new(x, GRID.GroundY, z))
		end
	end
	banner(folder, Vector3.new(FORT_MIN_X - 6, GRID.GroundY, FORT_MIN_Z - 6), BUILDER_BLUE)
	banner(folder, Vector3.new(FORT_MAX_X + 6, GRID.GroundY, FORT_MIN_Z - 6), BUILDER_BLUE)

	-- Ruins, crates and dead trees scattered with a fixed seed: same scenery on every server.
	local placed = 0
	while placed < 30 do
		local x = rng:NextNumber(-ARENA_SIZE / 2 + 12, ARENA_SIZE / 2 - 12)
		local z = rng:NextNumber(-ARENA_SIZE / 2 + 12, ARENA_SIZE / 2 - 12)
		local nearFort = math.abs(x) < 46 and math.abs(z) < 46
		local nearCage = math.abs(x) < 22 and math.abs(z - CAGE_CENTER.Z) < 22
		local corridor = math.abs(x) < 18 and z > 0 and z < CAGE_CENTER.Z
		if nearFort or nearCage or corridor then
			continue
		end
		placed += 1
		local position = Vector3.new(x, GRID.GroundY, z)
		local roll = rng:NextNumber()
		if roll < 0.3 then
			pillar(folder, position, rng:NextInteger(2, 5), rng:NextNumber() < 0.5)
		elseif roll < 0.55 then
			crateStack(folder, position, rng)
		elseif roll < 0.8 then
			deadTree(folder, position, rng)
		else
			torch(folder, position)
		end
	end
	folder.Parent = parent
end

function MapService.init()
	setupCollisionGroups()
	setupLighting()

	local existing = workspace:FindFirstChild("Map")
	if existing then
		existing:Destroy()
	end
	local rng = Random.new(1337) -- fixed seed: same scenery every server
	buildTerrain(rng)

	mapFolder = Instance.new("Folder")
	mapFolder.Name = "Map"
	buildArenaBounds(mapFolder)
	buildFort(mapFolder)
	buildCage(mapFolder)
	buildLobby(mapFolder)
	buildProps(mapFolder, rng)
	for _, name in { "Blocks", "Bots" } do
		local folder = Instance.new("Folder")
		folder.Name = name
		folder.Parent = mapFolder
	end
	mapFolder.Parent = workspace
end

function MapService.start() end

function MapService.blocksFolder(): Folder
	return mapFolder:FindFirstChild("Blocks") :: Folder
end

function MapService.botsFolder(): Folder
	return mapFolder:FindFirstChild("Bots") :: Folder
end

function MapService.lobbyCenter(): Vector3
	return LOBBY_CENTER
end

function MapService.lobbySpawn(index: number): CFrame
	local angle = index * 2.4
	local radius = 6 + (index % 4) * 3
	local position = LOBBY_CENTER + Vector3.new(math.cos(angle) * radius, 3, math.sin(angle) * radius)
	return CFrame.lookAt(position, Vector3.new(0, position.Y, 0)) -- face the arena
end

function MapService.builderSpawn(index: number): CFrame
	local spots = {
		Vector3.new(-8, 3, -8),
		Vector3.new(8, 3, 8),
		Vector3.new(-8, 3, 8),
		Vector3.new(8, 3, -8),
		Vector3.new(0, 3, 0),
		Vector3.new(0, 3, -14),
		Vector3.new(0, 3, 14),
		Vector3.new(-14, 3, 0),
		Vector3.new(14, 3, 0),
	}
	local spot = spots[((index - 1) % #spots) + 1]
	return CFrame.lookAt(spot, Vector3.new(0, 3, 0))
end

function MapService.cageSpawn(): CFrame
	return CFrame.lookAt(CAGE_CENTER + Vector3.new(0, 3, 0), Vector3.new(0, 3, 0))
end

function MapService.huntStart(): CFrame
	return CFrame.lookAt(Vector3.new(0, 3, FORT_MAX_Z + 22), Vector3.new(0, 3, 0))
end

function MapService.setCageOpen(open: boolean)
	for _, bar in cageBars do
		bar.CanCollide = not open
		if bar.Name == "Bar" then
			bar.Transparency = if open then 1 else 0
		end
	end
end

-- True if a world position is inside the fort zone (with an optional margin in studs).
function MapService.isInFort(position: Vector3, margin: number?): boolean
	local m = margin or 0
	return position.X >= FORT_MIN_X - m
		and position.X <= FORT_MAX_X + m
		and position.Z >= FORT_MIN_Z - m
		and position.Z <= FORT_MAX_Z + m
end

function MapService.teleport(character: Model?, target: CFrame)
	if character and character.PrimaryPart then
		character:PivotTo(target)
	end
end

return MapService
