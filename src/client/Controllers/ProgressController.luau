--!strict
--[[
	Level badge with an XP bar (top right, next to the wallet), the daily quest card (shown between
	rounds) and the level-up banner. Everything is read from the server's profile snapshot.
]]

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")

local Client = script.Parent.Parent
local Create = require(Client.UI.Create)
local Net = require(Client.Net)
local Profile = require(Client.Profile)
local State = require(Client.State)
local Theme = require(Client.UI.Theme)
local HudController = require(script.Parent.HudController)

local player = Players.LocalPlayer

local ProgressController = {}

local levelLabel: TextLabel
local xpFill: Frame
local xpLabel: TextLabel
local questCard: Frame
local questRows: { Frame } = {}
local banner: TextLabel
local bannerSub: TextLabel

local function questRow(index: number, parent: Instance): Frame
	return Create.panel({
		Name = "Quest" .. index,
		Size = UDim2.new(1, -16, 0, 40),
		Position = UDim2.fromOffset(8, 34 + (index - 1) * 46),
		BackgroundColor3 = Theme.Colors.PanelLight,
		Parent = parent,
	}, {
		Create.label({
			Name = "Text",
			Position = UDim2.fromOffset(10, 3),
			Size = UDim2.new(1, -80, 0, 18),
			TextSize = 14,
			TextXAlignment = Enum.TextXAlignment.Left,
		}),
		Create.label({
			Name = "Reward",
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.new(1, -10, 0, 3),
			Size = UDim2.fromOffset(70, 18),
			TextSize = 14,
			TextColor3 = Theme.Colors.Coin,
			TextXAlignment = Enum.TextXAlignment.Right,
		}),
		Create.new("Frame", {
			Name = "Bar",
			Position = UDim2.new(0, 10, 1, -13),
			Size = UDim2.new(1, -20, 0, 6),
			BackgroundColor3 = Theme.Colors.Panel,
			BorderSizePixel = 0,
		}, {
			Create.new("UICorner", { CornerRadius = UDim.new(1, 0) }),
			Create.new("Frame", {
				Name = "Fill",
				Size = UDim2.fromScale(0, 1),
				BackgroundColor3 = Theme.Colors.Success,
				BorderSizePixel = 0,
			}, { Create.new("UICorner", { CornerRadius = UDim.new(1, 0) }) }),
		}),
	})
end

local function build(gui: ScreenGui)
	local badge = Create.panel({
		Name = "Level",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -170, 0, 8),
		Size = UDim2.fromOffset(150, 40),
		Parent = gui,
	})
	levelLabel = Create.label({
		Position = UDim2.fromOffset(10, 2),
		Size = UDim2.fromOffset(60, 22),
		Text = "LV 1",
		TextSize = 18,
		TextColor3 = Theme.Colors.Info,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = badge,
	})
	xpLabel = Create.label({
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -10, 0, 4),
		Size = UDim2.fromOffset(80, 18),
		Text = "0 / 150",
		TextSize = 12,
		Font = Theme.FontBody,
		TextColor3 = Theme.Colors.TextDim,
		TextXAlignment = Enum.TextXAlignment.Right,
		Parent = badge,
	})
	local bar = Create.new("Frame", {
		Position = UDim2.new(0, 10, 1, -12),
		Size = UDim2.new(1, -20, 0, 6),
		BackgroundColor3 = Theme.Colors.PanelLight,
		BorderSizePixel = 0,
		Parent = badge,
	}, { Create.new("UICorner", { CornerRadius = UDim.new(1, 0) }) })
	xpFill = Create.new("Frame", {
		Size = UDim2.fromScale(0, 1),
		BackgroundColor3 = Theme.Colors.Info,
		BorderSizePixel = 0,
		Parent = bar,
	}, { Create.new("UICorner", { CornerRadius = UDim.new(1, 0) }) })

	questCard = Create.panel({
		Name = "Quests",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -12, 0, 56),
		Size = UDim2.fromOffset(308, 34 + 3 * 46 + 4),
		Parent = gui,
	}, {
		Create.label({
			Position = UDim2.fromOffset(12, 6),
			Size = UDim2.new(1, -24, 0, 22),
			Text = "DAILY QUESTS",
			TextSize = 15,
			TextColor3 = Theme.Colors.Accent,
			TextXAlignment = Enum.TextXAlignment.Left,
		}),
	})
	for i = 1, 3 do
		questRows[i] = questRow(i, questCard)
	end

	banner = Create.label({
		Name = "LevelUp",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.3),
		Size = UDim2.fromOffset(600, 70),
		Text = "LEVEL UP!",
		TextSize = 60,
		Font = Theme.FontBlack,
		TextColor3 = Theme.Colors.Coin,
		TextStrokeTransparency = 0.4,
		Visible = false,
		ZIndex = 30,
		Parent = gui,
	})
	bannerSub = Create.label({
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0.3, 40),
		Size = UDim2.fromOffset(600, 30),
		TextSize = 24,
		TextStrokeTransparency = 0.5,
		Visible = false,
		ZIndex = 30,
		Parent = gui,
	})
end

local function refresh()
	local view = Profile.current :: any
	if not view or not view.progress then
		return
	end
	local progress = view.progress
	levelLabel.Text = "LV " .. progress.level
	if progress.need > 0 then
		xpLabel.Text = string.format("%d / %d XP", progress.into, progress.need)
		TweenService
			:Create(xpFill, TweenInfo.new(0.4), { Size = UDim2.fromScale(progress.into / progress.need, 1) })
			:Play()
	else
		xpLabel.Text = "MAX"
		xpFill.Size = UDim2.fromScale(1, 1)
	end
	for i, quest in view.quests or {} do
		local row = questRows[i]
		if not row then
			continue
		end
		local text = row:FindFirstChild("Text") :: TextLabel
		local reward = row:FindFirstChild("Reward") :: TextLabel
		local fill = (row:FindFirstChild("Bar") :: Frame):FindFirstChild("Fill") :: Frame
		text.Text = if quest.done
			then "✓ " .. quest.text
			else string.format("%s  (%d/%d)", quest.text, quest.progress, quest.target)
		text.TextColor3 = if quest.done then Theme.Colors.Success else Theme.Colors.Text
		reward.Text = if quest.done then "done" else "+" .. quest.reward
		fill.Size = UDim2.fromScale(math.clamp(quest.progress / quest.target, 0, 1), 1)
	end
end

local function refreshVisibility()
	local phase = State.phase()
	questCard.Visible = phase ~= "Build" and phase ~= "Hunt"
end

local function celebrate(text: string)
	local level = string.match(text, "level (%d+)")
	bannerSub.Text = if level then "You reached level " .. level else text
	banner.Visible = true
	bannerSub.Visible = true
	banner.TextTransparency = 0
	bannerSub.TextTransparency = 0
	local scale = banner:FindFirstChildOfClass("UIScale") or Create.new("UIScale", { Parent = banner })
	scale.Scale = 0.4
	TweenService
		:Create(scale, TweenInfo.new(0.45, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 })
		:Play()
	HudController.playSound(Theme.Sounds.Victory, 0.5)
	task.delay(2.6, function()
		local info = TweenInfo.new(0.5)
		TweenService:Create(banner, info, { TextTransparency = 1 }):Play()
		local fade = TweenService:Create(bannerSub, info, { TextTransparency = 1 })
		fade:Play()
		fade.Completed:Wait()
		banner.Visible = false
		bannerSub.Visible = false
	end)
end

function ProgressController.start()
	local gui = player:WaitForChild("PlayerGui"):WaitForChild("HUD") :: ScreenGui
	build(gui)
	refresh()
	refreshVisibility()
	Profile.changed:connect(refresh)
	State.changed:connect(function(name)
		if name == "Phase" then
			refreshVisibility()
		end
	end)
	Net.onNotify(function(kind, text)
		if kind == "levelup" then
			celebrate(text)
		elseif kind == "quest" then
			HudController.playSound(Theme.Sounds.Coins, 0.4)
		end
	end)
end

return ProgressController
