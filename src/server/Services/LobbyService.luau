--!strict
--[[
	LobbyService: the lobby showpieces, built from code like the rest of the map.

	  leaderboard   top 10 by total wins. Uses an OrderedDataStore when DataStores work; in an
	                unpublished Studio place it falls back to the players on this server and says so
	  podium        the last round's three MVPs (most coins earned), shown as frozen copies of their
	                characters on gold/silver/bronze pedestals
	  kiosks        shop and crate stations with ProximityPrompts; the client opens the matching
	                shop tab (the purchase itself still goes through the guarded remotes)
]]

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Log = require(Shared.Util.Log)

local Services = script.Parent
local DataService = require(Services.DataService)
local EconomyService = require(Services.EconomyService)
local MapService = require(Services.MapService)
local Participants = require(Services.Participants)

local LobbyService = {}

local BOARD_SIZE = 10
local REFRESH_INTERVAL = 60
local GOLD = Color3.fromRGB(255, 200, 70)
local SILVER = Color3.fromRGB(200, 205, 215)
local BRONZE = Color3.fromRGB(205, 130, 70)
local PANEL = Color3.fromRGB(22, 24, 36)

local model: Model
local boardRows: { TextLabel } = {}
local boardFooter: TextLabel
local pedestals: { { top: Vector3, label: TextLabel } } = {}
local podiumFigures: { Model } = {}
local store: OrderedDataStore? = nil
local memory: { [number]: number } = {} -- userId -> wins (fallback, this server only)
local names: { [number]: string } = {}

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

local function textLabel(parent: Instance, props: { [string]: any }): TextLabel
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.GothamBold
	label.TextColor3 = Color3.new(1, 1, 1)
	label.TextScaled = true
	for key, value in props do
		(label :: any)[key] = value
	end
	label.Parent = parent
	return label
end

local function surface(target: BasePart, face: Enum.NormalId): SurfaceGui
	local gui = Instance.new("SurfaceGui")
	gui.Face = face
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 30
	gui.LightInfluence = 0
	gui.Parent = target
	return gui
end

-- Leaderboard ----------------------------------------------------------------------------------

local function buildBoard(center: Vector3, half: number)
	local board = part({
		Name = "Leaderboard",
		Size = Vector3.new(1, 15, 20),
		Position = center + Vector3.new(-half + 1.5, 8.5, 0),
		Material = Enum.Material.SmoothPlastic,
		Color = PANEL,
		Parent = model,
	})
	part({
		Name = "Frame",
		Size = Vector3.new(0.8, 16, 21),
		Position = board.Position + Vector3.new(-0.3, 0, 0),
		Material = Enum.Material.Wood,
		Color = Color3.fromRGB(110, 70, 40),
		Parent = model,
	})
	local gui = surface(board, Enum.NormalId.Right)
	textLabel(gui, {
		Size = UDim2.fromScale(1, 0.13),
		Text = "TOP BREACHERS",
		Font = Enum.Font.GothamBlack,
		TextColor3 = GOLD,
	})
	for i = 1, BOARD_SIZE do
		boardRows[i] = textLabel(gui, {
			Position = UDim2.fromScale(0.05, 0.14 + (i - 1) * 0.075),
			Size = UDim2.fromScale(0.9, 0.065),
			Text = "",
			TextXAlignment = Enum.TextXAlignment.Left,
			TextColor3 = if i == 1
				then GOLD
				elseif i == 2 then SILVER
				elseif i == 3 then BRONZE
				else Color3.new(1, 1, 1),
		})
	end
	boardFooter = textLabel(gui, {
		Position = UDim2.fromScale(0.05, 0.92),
		Size = UDim2.fromScale(0.9, 0.05),
		Text = "",
		Font = Enum.Font.GothamMedium,
		TextColor3 = Color3.fromRGB(170, 175, 195),
	})
end

local function nameOf(userId: number): string
	local cached = names[userId]
	if cached then
		return cached
	end
	local player = Players:GetPlayerByUserId(userId)
	if player then
		names[userId] = player.DisplayName
		return player.DisplayName
	end
	local ok, name = pcall(Players.GetNameFromUserIdAsync, Players, userId)
	names[userId] = if ok then name else "Player " .. userId
	return names[userId]
end

local function publish(player: Player)
	local data = DataService.getStats(player)
	if not data then
		return
	end
	local wins = data.builderWins + data.hunterWins
	memory[player.UserId] = wins
	names[player.UserId] = player.DisplayName
	local ordered = store
	if ordered then
		local ok, err = pcall(function()
			ordered:SetAsync(tostring(player.UserId), wins)
		end)
		if not ok then
			Log.warn("Lobby", "leaderboard write failed: " .. tostring(err))
		end
	end
end

local function refreshBoard()
	local entries: { { id: number, wins: number } } = {}
	local fromStore = false
	local ordered = store
	if ordered then
		local ok, page = pcall(function()
			return ordered:GetSortedAsync(false, BOARD_SIZE):GetCurrentPage()
		end)
		if ok then
			fromStore = true
			for _, entry in page do
				table.insert(entries, { id = tonumber(entry.key) or 0, wins = entry.value })
			end
		end
	end
	if not fromStore then
		for id, wins in memory do
			table.insert(entries, { id = id, wins = wins })
		end
		table.sort(entries, function(a, b)
			return if a.wins ~= b.wins then a.wins > b.wins else a.id < b.id
		end)
	end
	for i = 1, BOARD_SIZE do
		local entry = entries[i]
		boardRows[i].Text = if entry
			then string.format("%d.  %s  —  %d wins", i, nameOf(entry.id), entry.wins)
			else ""
	end
	boardFooter.Text = if fromStore
		then "All servers · updates every minute"
		else "This server (DataStores unavailable)"
end

-- Podium ---------------------------------------------------------------------------------------

local function buildPodium(center: Vector3, half: number)
	local base = center + Vector3.new(half - 9, 0, 0)
	for rank, spec in
		{
			{ offset = 0, height = 4.5, color = GOLD },
			{ offset = -7, height = 3, color = SILVER },
			{ offset = 7, height = 2, color = BRONZE },
		}
	do
		local height = spec.height
		local block = part({
			Name = "Pedestal" .. rank,
			Size = Vector3.new(6, height, 6),
			Position = base + Vector3.new(0, height / 2, spec.offset),
			Material = Enum.Material.Marble,
			Color = spec.color,
			Parent = model,
		})
		local gui = surface(block, Enum.NormalId.Left)
		textLabel(gui, { Size = UDim2.fromScale(1, 1), Text = tostring(rank), Font = Enum.Font.GothamBlack })
		local sign = part({
			Name = "Nameplate" .. rank,
			Size = Vector3.new(0.4, 1.4, 6),
			Position = base + Vector3.new(-3.3, 0.9, spec.offset),
			Material = Enum.Material.SmoothPlastic,
			Color = PANEL,
			Parent = model,
		})
		local label = textLabel(surface(sign, Enum.NormalId.Left), {
			Size = UDim2.fromScale(1, 1),
			Text = "—",
			TextColor3 = spec.color,
		})
		pedestals[rank] = { top = block.Position + Vector3.new(0, height / 2, 0), label = label }
	end
	local title = part({
		Name = "PodiumTitle",
		Size = Vector3.new(0.4, 2.5, 18),
		Position = base + Vector3.new(2, 11, 0),
		Transparency = 1,
		CanCollide = false,
		Parent = model,
	})
	textLabel(surface(title, Enum.NormalId.Left), {
		Size = UDim2.fromScale(1, 1),
		Text = "LAST ROUND'S MVPs",
		Font = Enum.Font.GothamBlack,
		TextColor3 = GOLD,
		TextStrokeTransparency = 0.4,
	})
end

local function figureOf(id: number): Model?
	local character = Participants.character(id)
	if not character then
		return nil
	end
	local archivable = character.Archivable
	character.Archivable = true
	local copy = character:Clone()
	character.Archivable = archivable
	for _, item in copy:GetDescendants() do
		if item:IsA("LuaSourceContainer") or item:IsA("Highlight") then
			item:Destroy()
		elseif item:IsA("BasePart") then
			item.Anchored = true
			item.CanCollide = false
			item.CanQuery = false
		end
	end
	return copy
end

local function showMvps(mvps: { EconomyService.Mvp })
	for _, figure in podiumFigures do
		figure:Destroy()
	end
	podiumFigures = {}
	for rank, pedestal in pedestals do
		local mvp = mvps[rank]
		pedestal.label.Text = if mvp then string.format("%s  +%d", mvp.name, mvp.coins) else "—"
		local figure = if mvp then figureOf(mvp.id) else nil
		if figure then
			-- Stand on the pedestal, facing the lobby (-X).
			local _, size = figure:GetBoundingBox()
			figure:PivotTo(
				CFrame.lookAt(
					pedestal.top + Vector3.new(0, size.Y / 2, 0),
					pedestal.top + Vector3.new(-10, size.Y / 2, 0)
				)
			)
			figure.Parent = model
			table.insert(podiumFigures, figure)
		end
	end
end

-- Kiosks ---------------------------------------------------------------------------------------

local function kiosk(position: Vector3, title: string, color: Color3, tab: string)
	local counter = part({
		Name = title .. "Kiosk",
		Size = Vector3.new(8, 3.5, 3),
		Position = position + Vector3.new(0, 1.75, 0),
		Material = Enum.Material.WoodPlanks,
		Color = Color3.fromRGB(120, 80, 50),
		Parent = model,
	})
	for _, x in { -3.6, 3.6 } do
		part({
			Name = "Post",
			Size = Vector3.new(0.6, 8, 0.6),
			Position = position + Vector3.new(x, 4, -1.2),
			Material = Enum.Material.Wood,
			Color = Color3.fromRGB(90, 60, 40),
			Parent = model,
		})
	end
	local awning = part({
		Name = "Awning",
		Size = Vector3.new(9, 0.6, 4),
		Position = position + Vector3.new(0, 8.2, -0.6),
		Material = Enum.Material.Fabric,
		Color = color,
		Parent = model,
	})
	local light = Instance.new("PointLight")
	light.Color = color
	light.Range = 14
	light.Brightness = 1.5
	light.Parent = awning
	local sign = part({
		Name = "KioskSign",
		Size = Vector3.new(7, 1.8, 0.3),
		Position = position + Vector3.new(0, 6.6, -1.2),
		Material = Enum.Material.SmoothPlastic,
		Color = PANEL,
		Parent = model,
	})
	textLabel(surface(sign, Enum.NormalId.Back), {
		Size = UDim2.fromScale(1, 1),
		Text = string.upper(title),
		Font = Enum.Font.GothamBlack,
		TextColor3 = color,
	})
	local prompt = Instance.new("ProximityPrompt")
	prompt.ActionText = "Open " .. title
	prompt.ObjectText = "Breachpoint"
	prompt.MaxActivationDistance = 10
	prompt.RequiresLineOfSight = false
	prompt:SetAttribute("ShopTab", tab)
	prompt.Parent = counter
end

function LobbyService.init()
	local center = MapService.lobbyCenter()
	local half = 28
	model = Instance.new("Model")
	model.Name = "LobbyShowpieces"
	buildBoard(center, half)
	buildPodium(center, half)
	kiosk(center + Vector3.new(-10, 0, -22), "Shop", Color3.fromRGB(255, 140, 60), "Blocks")
	kiosk(center + Vector3.new(10, 0, -22), "Crates", Color3.fromRGB(180, 110, 255), "Crates")
	model.Parent = workspace:WaitForChild("Map")

	if DataService.backend == "DataStore" then
		local ok, result = pcall(DataStoreService.GetOrderedDataStore, DataStoreService, "WinsLeaderboard")
		store = if ok then result else nil
	end
end

function LobbyService.start()
	DataService.loaded:connect(function(player)
		publish(player)
		refreshBoard()
	end)
	EconomyService.roundRewarded:connect(function(_outcome, mvps)
		showMvps(mvps)
		task.defer(function()
			for _, player in Players:GetPlayers() do
				publish(player)
			end
			refreshBoard()
		end)
	end)
	refreshBoard()
	task.spawn(function()
		while true do
			task.wait(REFRESH_INTERVAL)
			refreshBoard()
		end
	end)
end

return LobbyService
