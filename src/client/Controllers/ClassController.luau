--!strict
--[[
	Builder class picker, shown between rounds. The server validates the pick and stores it as the
	player's "Class" attribute; this panel only sends the intent and highlights the confirmed class.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("Shared").Config)

local Client = script.Parent.Parent
local Create = require(Client.UI.Create)
local Net = require(Client.Net)
local State = require(Client.State)
local Theme = require(Client.UI.Theme)
local HudController = require(script.Parent.HudController)

local player = Players.LocalPlayer

local ClassController = {}

local CLASS_COLORS = {
	Engineer = Color3.fromRGB(90, 210, 120),
	Scout = Color3.fromRGB(120, 200, 255),
	Trapper = Color3.fromRGB(255, 160, 60),
}

local panel: Frame
local buttons: { [string]: TextButton } = {}

local function refresh()
	local phase = State.phase()
	panel.Visible = phase ~= "Build" and phase ~= "Hunt"
	local current = player:GetAttribute("Class")
	for name, button in buttons do
		local stroke = button:FindFirstChildOfClass("UIStroke") :: UIStroke
		stroke.Transparency = if name == current then 0 else 0.8
		stroke.Thickness = if name == current then 2.5 else 1
	end
end

function ClassController.start()
	local gui = player:WaitForChild("PlayerGui"):WaitForChild("HUD") :: ScreenGui
	panel = Create.panel({
		Name = "Class",
		AnchorPoint = Vector2.new(0, 0),
		Position = UDim2.new(0, 12, 0.5, 74),
		Size = UDim2.fromOffset(250, 34 + #Config.ClassOrder * 46),
		Parent = gui,
	}, {
		Create.label({
			Position = UDim2.fromOffset(12, 6),
			Size = UDim2.new(1, -24, 0, 22),
			Text = "BUILDER CLASS",
			TextSize = 15,
			TextColor3 = Theme.Colors.Accent,
			TextXAlignment = Enum.TextXAlignment.Left,
		}),
	})
	for i, name in Config.ClassOrder do
		local class = Config.Classes[name]
		local color = CLASS_COLORS[name] or Theme.Colors.Info
		local button = Create.new("TextButton", {
			Name = name,
			Position = UDim2.fromOffset(8, 34 + (i - 1) * 46),
			Size = UDim2.new(1, -16, 0, 40),
			BackgroundColor3 = Theme.Colors.PanelLight,
			AutoButtonColor = true,
			Text = "",
			Parent = panel,
		}, {
			Create.new("UICorner", { CornerRadius = UDim.new(0, 8) }),
			Create.new("UIStroke", {
				Color = color,
				Transparency = 0.8,
				ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
			}),
			Create.new("Frame", {
				Position = UDim2.fromOffset(8, 8),
				Size = UDim2.fromOffset(24, 24),
				BackgroundColor3 = color,
				BorderSizePixel = 0,
			}, {
				Create.new("UICorner", { CornerRadius = UDim.new(0, 6) }),
				Create.label({
					Size = UDim2.fromScale(1, 1),
					Text = string.sub(class.label, 1, 1),
					TextSize = 16,
					TextColor3 = Theme.Colors.Panel,
				}),
			}),
			Create.label({
				Position = UDim2.fromOffset(42, 3),
				Size = UDim2.new(1, -50, 0, 18),
				Text = class.label,
				TextSize = 15,
				TextColor3 = color,
				TextXAlignment = Enum.TextXAlignment.Left,
			}),
			Create.label({
				Position = UDim2.fromOffset(42, 20),
				Size = UDim2.new(1, -50, 0, 16),
				Text = class.description,
				TextSize = 12,
				Font = Theme.FontBody,
				TextColor3 = Theme.Colors.TextDim,
				TextXAlignment = Enum.TextXAlignment.Left,
			}),
		})
		button.Activated:Connect(function()
			HudController.playSound(Theme.Sounds.Click, 0.3)
			Net.chooseClass(name)
		end)
		buttons[name] = button
	end
	refresh()
	State.changed:connect(function(name)
		if name == "Phase" or name == "Class" then
			refresh()
		end
	end)
end

return ClassController
