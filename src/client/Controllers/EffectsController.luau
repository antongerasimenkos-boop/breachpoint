--!strict
--[[
	EffectsController: cheap, client-only feedback for server-confirmed events.

	  particles     ParticleEmitter bursts (built-in textures) for hits, breaks, repairs, tags
	  debris        a few physics chips for hits and breaks
	  rings         expanding neon spheres for Shockwave / Tag / Trap
	  screen shake  CameraOffset jitter, scaled by distance to the event
	  coin popups   "+N" billboards over coin generators

	Everything here is cosmetic and local, so none of it touches the server.
]]

local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)

local Client = script.Parent.Parent
local HudController = require(script.Parent.HudController)
local Net = require(Client.Net)
local Theme = require(Client.UI.Theme)

local player = Players.LocalPlayer

local EffectsController = {}

local random = Random.new()
local SPARKLE = "rbxasset://textures/particles/sparkles_main.dds"
local SMOKE = "rbxasset://textures/particles/smoke_main.dds"

local shakeIntensity = 0

local function shake(position: Vector3, strength: number)
	local character = player.Character
	local root = character and character.PrimaryPart
	if not root then
		return
	end
	local distance = (root.Position - position).Magnitude
	local falloff = math.clamp(1 - distance / 40, 0, 1)
	shakeIntensity = math.max(shakeIntensity, strength * falloff)
end

local function burst(position: Vector3, texture: string, color: Color3, count: number, speed: number)
	local anchor = Instance.new("Part")
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CanTouch = false
	anchor.Transparency = 1
	anchor.Size = Vector3.one * 0.2
	anchor.Position = position
	local emitter = Instance.new("ParticleEmitter")
	emitter.Texture = texture
	emitter.Color = ColorSequence.new(color)
	emitter.LightEmission = 0.4
	emitter.Size =
		NumberSequence.new({ NumberSequenceKeypoint.new(0, 1.2), NumberSequenceKeypoint.new(1, 0) })
	emitter.Transparency = NumberSequence.new(0.1, 1)
	emitter.Lifetime = NumberRange.new(0.4, 0.8)
	emitter.Speed = NumberRange.new(speed * 0.5, speed)
	emitter.SpreadAngle = Vector2.new(180, 180)
	emitter.Rate = 0
	emitter.Parent = anchor
	anchor.Parent = workspace.CurrentCamera
	emitter:Emit(count)
	Debris:AddItem(anchor, 1.2)
end

local function debris(position: Vector3, count: number, color: Color3)
	for _ = 1, count do
		local chip = Instance.new("Part")
		chip.Size = Vector3.one * random:NextNumber(0.4, 0.9)
		chip.Color = color
		chip.Material = Enum.Material.SmoothPlastic
		chip.CanCollide = false
		chip.CanQuery = false
		chip.CanTouch = false
		chip.CastShadow = false
		chip.CFrame = CFrame.new(position + random:NextUnitVector() * 1.5)
		chip.AssemblyLinearVelocity = random:NextUnitVector() * random:NextNumber(12, 24)
			+ Vector3.new(0, 18, 0)
		chip.Parent = workspace.CurrentCamera
		Debris:AddItem(chip, 0.9)
	end
end

local function ring(position: Vector3, radius: number, color: Color3, duration: number)
	local sphere = Instance.new("Part")
	sphere.Shape = Enum.PartType.Ball
	sphere.Anchored = true
	sphere.CanCollide = false
	sphere.CanQuery = false
	sphere.CanTouch = false
	sphere.CastShadow = false
	sphere.Material = Enum.Material.Neon
	sphere.Color = color
	sphere.Transparency = 0.3
	sphere.Size = Vector3.one * 2
	sphere.Position = position
	sphere.Parent = workspace.CurrentCamera
	TweenService:Create(
		sphere,
		TweenInfo.new(duration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Size = Vector3.one * radius * 2, Transparency = 1 }
	):Play()
	Debris:AddItem(sphere, duration + 0.1)
end

local function coinPopup(position: Vector3, amount: number)
	local anchor = Instance.new("Part")
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.Transparency = 1
	anchor.Size = Vector3.one * 0.2
	anchor.Position = position + Vector3.new(0, 2.5, 0)
	local gui = Instance.new("BillboardGui")
	gui.Size = UDim2.fromOffset(90, 30)
	gui.AlwaysOnTop = true
	gui.MaxDistance = 70
	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Font = Theme.FontBlack
	label.TextSize = 22
	label.Text = "+" .. tostring(amount)
	label.TextColor3 = Theme.Colors.Coin
	label.TextStrokeTransparency = 0.3
	label.Parent = gui
	gui.Parent = anchor
	anchor.Parent = workspace.CurrentCamera
	TweenService:Create(anchor, TweenInfo.new(1), { Position = anchor.Position + Vector3.new(0, 3, 0) })
		:Play()
	TweenService:Create(label, TweenInfo.new(1), { TextTransparency = 1, TextStrokeTransparency = 1 }):Play()
	Debris:AddItem(anchor, 1.1)
end

function EffectsController.start()
	Net.onEffect(function(kind, position)
		if typeof(position) ~= "Vector3" then
			return
		end
		if kind == "Place" then
			HudController.playSound(Theme.Sounds.Place, 0.25)
			burst(position, SMOKE, Color3.fromRGB(230, 220, 200), 4, 4)
		elseif kind == "BlockHit" then
			debris(position, 3, Color3.fromRGB(150, 130, 110))
			burst(position, SMOKE, Color3.fromRGB(200, 190, 175), 6, 8)
			HudController.playSound(Theme.Sounds.Hit, 0.3)
			shake(position, 0.15)
		elseif kind == "BlockBroken" then
			debris(position, 9, Color3.fromRGB(120, 100, 85))
			burst(position, SMOKE, Color3.fromRGB(180, 170, 160), 16, 14)
			HudController.playSound(Theme.Sounds.Break, 0.45)
			shake(position, 0.45)
		elseif kind == "Shockwave" then
			ring(position, Config.Hunter.Shockwave.Radius, Theme.Colors.Hunter, 0.45)
			burst(position, SPARKLE, Theme.Colors.Hunter, 30, 30)
			HudController.playSound(Theme.Sounds.Shockwave, 0.7)
			shake(position, 0.9)
		elseif kind == "Tag" then
			ring(position, 4, Theme.Colors.Warn, 0.35)
			burst(position, SPARKLE, Theme.Colors.Warn, 24, 16)
			HudController.playSound(Theme.Sounds.Tag, 0.6)
			shake(position, 0.3)
		elseif kind == "Repair" then
			ring(position, 2.5, Theme.Colors.Success, 0.3)
			burst(position, SPARKLE, Theme.Colors.Success, 10, 6)
		elseif kind == "Coins" then
			coinPopup(position, Config.Generator.PayoutCoins)
			burst(position, SPARKLE, Theme.Colors.Coin, 8, 5)
		elseif kind == "Trap" then
			ring(position, 3.5, Color3.fromRGB(200, 200, 210), 0.3)
			burst(position, SPARKLE, Color3.fromRGB(220, 220, 230), 18, 12)
			HudController.playSound(Theme.Sounds.Trap, 0.6)
			shake(position, 0.5)
		end
	end)

	-- Screen shake decays every frame; applied through the humanoid's camera offset.
	RunService.RenderStepped:Connect(function(dt: number)
		local character = player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if not humanoid then
			return
		end
		if shakeIntensity > 0.01 then
			humanoid.CameraOffset = random:NextUnitVector() * shakeIntensity
			shakeIntensity = math.max(0, shakeIntensity - dt * 2.5)
		elseif humanoid.CameraOffset ~= Vector3.zero then
			humanoid.CameraOffset = Vector3.zero
		end
	end)
end

return EffectsController
