--!strict
--[[
	CosmeticsService: shows equipped cosmetics. Purely visual, no gameplay effect.
	  Title       a name tag above the head, always
	  Trail       on the hunter during the hunt
	  Block skin  applied by BuildService when the block is created

	Data changes fire often (every coin), so each player's applied state is cached and only real
	changes touch the character.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)

local Services = script.Parent
local DataService = require(Services.DataService)
local RoundService = require(Services.RoundService)

local CosmeticsService = {}

type Applied = { character: Model?, title: string, trail: string }

local applied: { [Player]: Applied } = {}
local connections: { [Player]: RBXScriptConnection } = {}

local function cosmetic(id: string): any?
	for _, c in Config.Cosmetics do
		if c.id == id then
			return c
		end
	end
	return nil
end

local function rgb(values: { number }): Color3
	return Color3.fromRGB(values[1], values[2], values[3])
end

local function setTitle(character: Model, id: string)
	local head = character:FindFirstChild("Head")
	if not head then
		return
	end
	local existing = head:FindFirstChild("Title")
	if existing then
		existing:Destroy()
	end
	local title = cosmetic(id)
	if not title then
		return
	end
	local gui = Instance.new("BillboardGui")
	gui.Name = "Title"
	gui.Size = UDim2.fromOffset(200, 26)
	gui.StudsOffset = Vector3.new(0, 2.6, 0)
	gui.MaxDistance = 80
	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.GothamBold
	label.TextSize = 18
	label.Text = title.name
	label.TextColor3 = rgb(title.color)
	label.TextStrokeTransparency = 0.4
	label.Parent = gui
	gui.Parent = head
end

local function setTrail(character: Model, id: string)
	local root = character:FindFirstChild("HumanoidRootPart")
	if not root then
		return
	end
	for _, name in { "CosmeticTrail", "TrailTop", "TrailBottom" } do
		local existing = root:FindFirstChild(name)
		if existing then
			existing:Destroy()
		end
	end
	local trail = cosmetic(id)
	if not trail then
		return
	end
	local top = Instance.new("Attachment")
	top.Name = "TrailTop"
	top.Position = Vector3.new(0, 1, 0)
	top.Parent = root
	local bottom = Instance.new("Attachment")
	bottom.Name = "TrailBottom"
	bottom.Position = Vector3.new(0, -1, 0)
	bottom.Parent = root
	local effect = Instance.new("Trail")
	effect.Name = "CosmeticTrail"
	effect.Attachment0 = top
	effect.Attachment1 = bottom
	effect.Lifetime = 0.6
	effect.LightEmission = 0.6
	effect.Color = ColorSequence.new(rgb(trail.color), rgb(trail.color2 or trail.color))
	effect.Transparency = NumberSequence.new(0.1, 1)
	effect.Parent = root
end

local function refresh(player: Player)
	local data = DataService.getStats(player)
	local character = player.Character
	if not data or not character then
		return
	end
	local title = if data.cosmetics[data.equipped.Title] then data.equipped.Title else ""
	local hunting = RoundService.getPhase() == "Hunt" and RoundService.getRole(player.UserId) == "Hunter"
	local trail = if hunting and data.cosmetics[data.equipped.Trail] then data.equipped.Trail else ""

	local previous = applied[player]
	local state: Applied = if previous and previous.character == character
		then previous
		else { character = character, title = "", trail = "" }
	applied[player] = state
	if state.title ~= title then
		setTitle(character, title)
		state.title = title
	end
	if state.trail ~= trail then
		setTrail(character, trail)
		state.trail = trail
	end
end

function CosmeticsService.init() end

function CosmeticsService.start()
	local function watch(player: Player)
		connections[player] = player.CharacterAdded:Connect(function(character)
			character:WaitForChild("Head", 5)
			refresh(player)
		end)
	end
	Players.PlayerAdded:Connect(watch)
	for _, player in Players:GetPlayers() do
		watch(player)
	end
	Players.PlayerRemoving:Connect(function(player)
		local connection = connections[player]
		if connection then
			connection:Disconnect()
		end
		connections[player] = nil
		applied[player] = nil
	end)
	DataService.loaded:connect(function(player)
		refresh(player)
	end)
	DataService.changed:connect(refresh)
	RoundService.phaseChanged:connect(function()
		for _, player in Players:GetPlayers() do
			refresh(player)
		end
	end)
end

return CosmeticsService
