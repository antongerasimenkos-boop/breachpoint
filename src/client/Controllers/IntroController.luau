--!strict
--[[
	Title screen shown once on join: the logo over a slow camera orbit of the arena, a one-line
	pitch and a PLAY button. Purely presentational; the round flow runs underneath meanwhile.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Client = script.Parent.Parent
local Create = require(Client.UI.Create)
local Theme = require(Client.UI.Theme)
local HudController = require(script.Parent.HudController)

local player = Players.LocalPlayer

local IntroController = {}

local ORBIT_CENTER = Vector3.new(0, 4, 0)
local ORBIT_RADIUS = 95
local ORBIT_HEIGHT = 48

function IntroController.start()
	local playerGui = player:WaitForChild("PlayerGui")
	-- The HUD hides behind the title screen until PLAY.
	local hud = playerGui:FindFirstChild("HUD") :: ScreenGui?
	if hud then
		hud.Enabled = false
	end
	local gui = Create.new("ScreenGui", {
		Name = "Intro",
		IgnoreGuiInset = true,
		ResetOnSpawn = false,
		DisplayOrder = 10,
		Parent = playerGui,
	})
	local backdrop = Create.new("Frame", {
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = Color3.fromRGB(10, 8, 18),
		BackgroundTransparency = 0.25,
		BorderSizePixel = 0,
		Parent = gui,
	}, {
		Create.new("UIGradient", {
			Rotation = 90,
			Transparency = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 0.6),
				NumberSequenceKeypoint.new(0.5, 0.2),
				NumberSequenceKeypoint.new(1, 0),
			}),
		}),
	})
	local logo = Create.label({
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.36),
		Size = UDim2.fromOffset(900, 120),
		Text = "BREACHPOINT",
		Font = Theme.FontBlack,
		TextSize = 108,
		TextStrokeTransparency = 0.2,
		TextStrokeColor3 = Color3.fromRGB(60, 20, 10),
		Parent = backdrop,
	})
	Create.new("UIGradient", {
		Rotation = 90,
		Color = ColorSequence.new(Color3.fromRGB(255, 225, 130), Color3.fromRGB(255, 120, 50)),
		Parent = logo,
	})
	Create.label({
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0.36, 64),
		Size = UDim2.fromOffset(800, 34),
		Text = "Builders fortify.  One hunter breaks in.  Survive the hunt.",
		Font = Theme.Font,
		TextSize = 24,
		TextColor3 = Theme.Colors.Text,
		TextStrokeTransparency = 0.5,
		Parent = backdrop,
	})
	local chips = Create.new("Frame", {
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0.36, 112),
		Size = UDim2.fromOffset(720, 34),
		BackgroundTransparency = 1,
		Parent = backdrop,
	}, {
		Create.new("UIListLayout", {
			FillDirection = Enum.FillDirection.Horizontal,
			HorizontalAlignment = Enum.HorizontalAlignment.Center,
			Padding = UDim.new(0, 10),
		}),
	})
	for _, chip in
		{
			{ text = "BUILD", color = Theme.Colors.Builder },
			{ text = "BREACH", color = Theme.Colors.Hunter },
			{ text = "LEVEL UP", color = Theme.Colors.Info },
			{ text = "COLLECT", color = Theme.Colors.Coin },
		}
	do
		Create.panel({
			Size = UDim2.fromOffset(130, 34),
			BackgroundColor3 = Theme.Colors.PanelLight,
			Parent = chips,
		}, {
			Create.label({
				Size = UDim2.fromScale(1, 1),
				Text = chip.text,
				TextSize = 16,
				TextColor3 = chip.color,
			}),
		})
	end

	local camera = workspace.CurrentCamera
	local started = os.clock()
	local orbit = RunService.RenderStepped:Connect(function()
		local angle = (os.clock() - started) * 0.08
		local eye = ORBIT_CENTER
			+ Vector3.new(math.cos(angle) * ORBIT_RADIUS, ORBIT_HEIGHT, math.sin(angle) * ORBIT_RADIUS)
		camera.CameraType = Enum.CameraType.Scriptable
		camera.CFrame = CFrame.lookAt(eye, ORBIT_CENTER)
	end)

	local play: TextButton
	play = Create.button({
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0.36, 176),
		Size = UDim2.fromOffset(240, 60),
		Text = "PLAY",
		TextSize = 30,
		Font = Theme.FontBlack,
		Color = Theme.Colors.Accent,
		Parent = backdrop,
	}, function()
		HudController.playSound(Theme.Sounds.Click, 0.4)
		orbit:Disconnect()
		camera.CameraType = Enum.CameraType.Custom
		if hud then
			hud.Enabled = true
		end
		local fade = TweenService:Create(backdrop, TweenInfo.new(0.4), { BackgroundTransparency = 1 })
		for _, item in backdrop:GetDescendants() do
			if item:IsA("TextLabel") or item:IsA("TextButton") then
				TweenService
					:Create(item, TweenInfo.new(0.3), { TextTransparency = 1, TextStrokeTransparency = 1 })
					:Play()
			elseif item:IsA("Frame") then
				TweenService:Create(item, TweenInfo.new(0.3), { BackgroundTransparency = 1 }):Play()
			end
		end
		play.Active = false
		fade:Play()
		fade.Completed:Wait()
		gui:Destroy()
	end)
end

return IntroController
