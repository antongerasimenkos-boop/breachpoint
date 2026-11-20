--!strict
--[[
	PowerupService: pickups that spawn during the hunt. Fully server-side: the server spawns them,
	checks distances itself (no client Touched events) and applies the effect.

	  Shield   builder  blocks the next tag (attribute "Shield", consumed by HunterService.tryTag)
	  Speed    builder  faster for a few seconds
	  Decoy    builder  a frozen copy of the builder's character, to mislead a human hunter
	  Reveal   hunter   highlights every builder through walls for a few seconds

	Builder pickups spawn inside the fort on free ground cells (builders can't leave the fort);
	the hunter's pickup spawns in the open arena. Players pick them up; practice bots don't.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Log = require(Shared.Util.Log)
local Signal = require(Shared.Util.Signal)

local Services = script.Parent
local MapService = require(Services.MapService)
local NetService = require(Services.NetService)
local Participants = require(Services.Participants)
local RoundService = require(Services.RoundService)

local PowerupService = {}

type Pickup = { kind: string, part: BasePart }

local pickups: { Pickup } = {}
local folder: Folder
local rng = Random.new()
local spawnSerial = 0

local function cfg(kind: string)
	return Config.Powerups.Kinds[kind]
end

local function clearPickups()
	for _, pickup in pickups do
		pickup.part:Destroy()
	end
	pickups = {}
end

local function blocked(position: Vector3): boolean
	local params = OverlapParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { MapService.blocksFolder() }
	return #workspace:GetPartBoundsInRadius(position, 2.5, params) > 0
end

-- A free ground cell inside the fort, or a spot in the arena outside it.
local function spawnPosition(forBuilders: boolean): Vector3?
	local grid = Config.Grid
	for _ = 1, 12 do
		local position
		if forBuilders then
			local x = rng:NextInteger(grid.MinX, grid.MaxX)
			local z = rng:NextInteger(grid.MinZ, grid.MaxZ)
			position = Vector3.new((x + 0.5) * grid.CellSize, grid.GroundY + 2.5, (z + 0.5) * grid.CellSize)
		else
			local angle = rng:NextNumber(0, math.pi * 2)
			local radius = rng:NextNumber(36, 60)
			position = Vector3.new(math.cos(angle) * radius, grid.GroundY + 2.5, math.sin(angle) * radius)
		end
		if not blocked(position) then
			return position
		end
	end
	return nil
end

local function spawnPickup(kind: string)
	local info = cfg(kind)
	local position = spawnPosition(info.forBuilders)
	if not position then
		return
	end
	spawnSerial += 1
	local color = Color3.fromRGB(table.unpack(info.color))
	local part = Instance.new("Part")
	part.Name = "Powerup_" .. kind .. "_" .. spawnSerial
	part.Shape = Enum.PartType.Ball
	part.Size = Vector3.new(2.4, 2.4, 2.4)
	part.Material = Enum.Material.Neon
	part.Color = color
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CastShadow = false
	part.Position = position
	part:SetAttribute("Powerup", kind)
	local light = Instance.new("PointLight")
	light.Color = color
	light.Range = 12
	light.Brightness = 2
	light.Parent = part
	local billboard = Instance.new("BillboardGui")
	billboard.Size = UDim2.fromOffset(140, 30)
	billboard.StudsOffset = Vector3.new(0, 2.6, 0)
	billboard.AlwaysOnTop = true
	billboard.MaxDistance = 120
	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.GothamBlack
	label.TextSize = 18
	label.TextColor3 = color
	label.TextStrokeTransparency = 0.3
	label.Text = info.label
	label.Parent = billboard
	billboard.Parent = part
	part.Parent = folder
	TweenService:Create(
		part,
		TweenInfo.new(1.2, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
		{ Position = position + Vector3.new(0, 0.8, 0) }
	):Play()
	table.insert(pickups, { kind = kind, part = part :: BasePart })
end

local function classSpeed(player: Player): number
	local class = Config.Classes[tostring(player:GetAttribute("Class"))]
	return Config.DefaultWalkSpeed * (if class and class.speedMultiplier then class.speedMultiplier else 1)
end

local function revealBuilders()
	local snapshot = RoundService.snapshot()
	local info = cfg("Reveal")
	for _, id in snapshot.builders do
		local character = Participants.character(id)
		if character and RoundService.isAlive(id) then
			local highlight = Instance.new("Highlight")
			highlight.Name = "Revealed"
			highlight.FillColor = Color3.fromRGB(240, 80, 80)
			highlight.OutlineColor = Color3.fromRGB(255, 220, 220)
			highlight.FillTransparency = 0.45
			highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
			highlight.Parent = character
			task.delay(info.duration, function()
				highlight:Destroy()
			end)
		end
	end
end

local function spawnDecoy(player: Player)
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not (character and root) then
		return
	end
	local archivable = character.Archivable
	character.Archivable = true
	local decoy = character:Clone()
	character.Archivable = archivable
	for _, item in decoy:GetDescendants() do
		if item:IsA("LuaSourceContainer") then
			item:Destroy()
		elseif item:IsA("BasePart") then
			item.Anchored = true
			item.CanCollide = false
			item.CanQuery = false
		end
	end
	decoy.Name = player.DisplayName
	decoy:PivotTo(root.CFrame * CFrame.new(rng:NextNumber(-4, 4), 0, -4))
	decoy.Parent = folder
	task.delay(cfg("Decoy").duration, function()
		decoy:Destroy()
	end)
end

local function apply(player: Player, kind: string)
	local info = cfg(kind)
	local humanoid = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
	if kind == "Shield" then
		player:SetAttribute("Shield", true)
	elseif kind == "Speed" and humanoid then
		humanoid.WalkSpeed = classSpeed(player) * info.multiplier
		task.delay(info.duration, function()
			if humanoid.Parent and RoundService.getRole(player.UserId) == "Builder" then
				humanoid.WalkSpeed = classSpeed(player)
			end
		end)
	elseif kind == "Decoy" then
		spawnDecoy(player)
	elseif kind == "Reveal" then
		revealBuilders()
	end
	NetService.notify(player, "success", info.pickupText)
	NetService.notifyAll("feed", string.format("%s picked up %s", player.DisplayName, info.label))
	local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if root then
		NetService.effect("Repair", root.Position)
	end
	PowerupService.pickedUp:fire(player, kind)
end

local function eligible(player: Player, info: any): boolean
	local id = player.UserId
	if not RoundService.isAlive(id) then
		return false
	end
	local role = RoundService.getRole(id)
	return if info.forBuilders then role == "Builder" else role == "Hunter"
end

local function checkPickups()
	for i = #pickups, 1, -1 do
		local pickup = pickups[i]
		local info = cfg(pickup.kind)
		for _, player in Players:GetPlayers() do
			local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
			if
				root
				and eligible(player, info)
				and (root.Position - pickup.part.Position).Magnitude <= Config.Powerups.PickupRadius
			then
				table.remove(pickups, i)
				pickup.part:Destroy()
				apply(player, pickup.kind)
				break
			end
		end
	end
end

-- Fires (player, kind) when a player collects a power-up (for the event feed).
PowerupService.pickedUp = Signal.new() :: Signal.Signal<Player, string>

function PowerupService.init()
	folder = Instance.new("Folder")
	folder.Name = "Powerups"
	folder.Parent = workspace
end

function PowerupService.start()
	RoundService.phaseChanged:connect(function(_from, to)
		clearPickups()
		if to ~= "Hunt" then
			for _, player in Players:GetPlayers() do
				player:SetAttribute("Shield", nil)
			end
		end
	end)
	task.spawn(function()
		local sinceSpawn = 0
		local step = 0.2
		while true do
			task.wait(step)
			if RoundService.getPhase() ~= "Hunt" then
				sinceSpawn = 0
				continue
			end
			sinceSpawn += step
			if sinceSpawn >= Config.Powerups.SpawnInterval and #pickups < Config.Powerups.MaxActive then
				sinceSpawn = 0
				local kinds = Config.Powerups.Order
				local ok, err = pcall(spawnPickup :: any, kinds[rng:NextInteger(1, #kinds)])
				if not ok then
					Log.warn("Powerups", "spawn failed: " .. tostring(err))
				end
			end
			checkPickups()
		end
	end)
end

-- Debug: spawn one now.
function PowerupService.debugSpawn(kind: string): boolean
	if not cfg(kind) then
		return false
	end
	spawnPickup(kind)
	return true
end

return PowerupService
