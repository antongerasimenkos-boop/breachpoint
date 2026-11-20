--!strict
--[[
	HunterController: the hunter's tools during the hunt.

	  click / hold  breach the block under the cursor, or tag the builder under it
	  Q             Shockwave (damages every block around you)
	  E             Sprint

	The client only sends intents and draws cooldowns. It starts a cooldown overlay when the
	server confirms an action (ActionResult ok), so the UI never shows an ability as used when
	the server refused it.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)

local Client = script.Parent.Parent
local Create = require(Client.UI.Create)
local Net = require(Client.Net)
local Pointer = require(Client.Pointer)
local State = require(Client.State)
local Theme = require(Client.UI.Theme)

local player = Players.LocalPlayer

local HunterController = {}

type Slot = { frame: Frame, overlay: Frame, timer: TextLabel, duration: number, readyAt: number }

local slots: { [string]: Slot } = {}
local bar: Frame
local highlight: Highlight
local holding = false
local nextPrimaryAt = 0

local ABILITIES = {
	{ id = "Breach", key = "Click", label = "Breach", duration = Config.Hunter.Breach.Cooldown },
	{ id = "Shockwave", key = "Q", label = "Shockwave", duration = Config.Hunter.Shockwave.Cooldown },
	{ id = "Sprint", key = "E", label = "Sprint", duration = Config.Hunter.Sprint.Cooldown },
}

local function active(): boolean
	return State.isActiveHunter() and State.phase() == "Hunt"
end

local function buildGui()
	local gui = player:WaitForChild("PlayerGui"):WaitForChild("HUD")
	bar = Create.new("Frame", {
		Name = "Abilities",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -16),
		Size = UDim2.fromOffset(#ABILITIES * 104 - 8, 84),
		BackgroundTransparency = 1,
		Visible = false,
		Parent = gui,
	})
	for i, ability in ABILITIES do
		local frame = Create.panel({
			Name = ability.id,
			Position = UDim2.fromOffset((i - 1) * 104, 0),
			Size = UDim2.fromOffset(96, 84),
			ClipsDescendants = true,
			Parent = bar,
		}, {
			Create.label({
				Position = UDim2.fromOffset(0, 14),
				Size = UDim2.new(1, 0, 0, 22),
				Text = ability.label,
				TextSize = 16,
				TextColor3 = Theme.Colors.Hunter,
			}),
			Create.label({
				Position = UDim2.fromOffset(0, 40),
				Size = UDim2.new(1, 0, 0, 18),
				Text = "[" .. ability.key .. "]",
				TextSize = 13,
				Font = Theme.FontBody,
				TextColor3 = Theme.Colors.TextDim,
			}),
		})
		local overlay = Create.new("Frame", {
			Name = "Cooldown",
			AnchorPoint = Vector2.new(0, 1),
			Position = UDim2.fromScale(0, 1),
			Size = UDim2.fromScale(1, 0),
			BackgroundColor3 = Color3.new(0, 0, 0),
			BackgroundTransparency = 0.35,
			BorderSizePixel = 0,
			ZIndex = 2,
			Parent = frame,
		})
		local timer = Create.label({
			Position = UDim2.fromOffset(0, 58),
			Size = UDim2.new(1, 0, 0, 18),
			Text = "",
			TextSize = 14,
			ZIndex = 3,
			Parent = frame,
		})
		slots[ability.id] = {
			frame = frame,
			overlay = overlay,
			timer = timer,
			duration = ability.duration,
			readyAt = 0,
		}
		local button = Create.new("TextButton", {
			Size = UDim2.fromScale(1, 1),
			BackgroundTransparency = 1,
			Text = "",
			ZIndex = 4,
			Parent = frame,
		})
		if ability.id ~= "Breach" then
			button.Activated:Connect(function()
				if active() then
					Net.useAbility(ability.id :: any)
				end
			end)
		end
	end

	highlight = Create.new("Highlight", {
		FillTransparency = 1,
		OutlineColor = Theme.Colors.Hunter,
		OutlineTransparency = 0,
		DepthMode = Enum.HighlightDepthMode.Occluded,
		Enabled = false,
		Parent = gui,
	})
end

local function startCooldown(id: string)
	local slot = slots[id]
	if slot then
		slot.readyAt = os.clock() + slot.duration
	end
end

-- What the cursor is on: a builder to tag, a block to breach, or nothing.
local function currentTarget(): (string?, number?, Instance?)
	local result = Pointer.raycast()
	if not result then
		return nil, nil, nil
	end
	local character = Pointer.characterOf(result.Instance)
	if character then
		local id = Pointer.participantId(character)
		if id and id ~= player.UserId then
			return "Tag", id, character
		end
	end
	local blockId = result.Instance:GetAttribute("BlockId")
	if type(blockId) == "number" then
		return "Breach", blockId, result.Instance
	end
	return nil, nil, nil
end

local function primary()
	if not active() or os.clock() < nextPrimaryAt then
		return
	end
	local action, id = currentTarget()
	if action == "Tag" and id then
		nextPrimaryAt = os.clock() + Config.Hunter.Tag.Cooldown + 0.05
		Net.tag(id)
	elseif action == "Breach" and id then
		nextPrimaryAt = os.clock() + Config.Hunter.Breach.Cooldown + 0.03
		Net.breach(id)
	end
end

function HunterController.start()
	buildGui()

	State.changed:connect(function()
		bar.Visible = active()
		if not active() then
			highlight.Enabled = false
		end
	end)

	Net.onActionResult(function(action, ok, detail)
		if not ok then
			return
		end
		if action == "Breach" then
			startCooldown("Breach")
		elseif action == "UseAbility" and detail then
			startCooldown(detail)
		end
	end)

	UserInputService.InputBegan:Connect(function(input, processed)
		if processed or not active() then
			return
		end
		if
			input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch
		then
			holding = true
			primary()
		elseif input.KeyCode == Enum.KeyCode.Q then
			Net.useAbility("Shockwave")
		elseif input.KeyCode == Enum.KeyCode.E then
			Net.useAbility("Sprint")
		end
	end)
	UserInputService.InputEnded:Connect(function(input)
		if
			input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch
		then
			holding = false
		end
	end)

	RunService.RenderStepped:Connect(function()
		if not active() then
			return
		end
		local action, _, instance = currentTarget()
		highlight.Adornee = instance
		highlight.Enabled = instance ~= nil
		highlight.OutlineColor = if action == "Tag" then Theme.Colors.Warn else Theme.Colors.Hunter
		if holding then
			primary()
		end

		local now = os.clock()
		for _, slot in slots do
			local remaining = math.max(0, slot.readyAt - now)
			slot.overlay.Size = UDim2.fromScale(1, if slot.duration > 0 then remaining / slot.duration else 0)
			slot.timer.Text = if remaining > 0.05 then string.format("%.1f", remaining) else ""
		end
	end)
end

return HunterController
