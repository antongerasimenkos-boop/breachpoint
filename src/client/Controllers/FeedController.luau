--!strict
--[[
	Event feed (bottom left, during rounds): short lines the server broadcasts as "feed"
	notifications, e.g. "The hunter broke a wall" or "Alex picked up SHIELD". Lines fade out.
]]

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")

local Client = script.Parent.Parent
local Create = require(Client.UI.Create)
local Net = require(Client.Net)
local State = require(Client.State)
local Theme = require(Client.UI.Theme)

local player = Players.LocalPlayer

local FeedController = {}

local MAX_LINES = 5
local LIFETIME = 7

local feed: Frame
local serial = 0

local function colorFor(text: string): Color3
	local lower = string.lower(text)
	if string.find(lower, "caught") or string.find(lower, "hunter") then
		return Theme.Colors.Hunter
	elseif string.find(lower, "picked up") then
		return Theme.Colors.Success
	elseif string.find(lower, "level") then
		return Theme.Colors.Coin
	end
	return Theme.Colors.Info
end

local function push(text: string)
	serial += 1
	local line = Create.panel({
		Name = "Line",
		LayoutOrder = serial,
		Size = UDim2.new(1, 0, 0, 26),
		BackgroundTransparency = 0.35,
		Parent = feed,
	}, {
		Create.new("Frame", {
			Position = UDim2.fromOffset(6, 5),
			Size = UDim2.fromOffset(4, 16),
			BackgroundColor3 = colorFor(text),
			BorderSizePixel = 0,
		}),
		Create.label({
			Name = "Text",
			Position = UDim2.fromOffset(16, 0),
			Size = UDim2.new(1, -22, 1, 0),
			Text = text,
			TextSize = 14,
			Font = Theme.FontBody,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd,
		}),
	})
	local lines = {}
	for _, child in feed:GetChildren() do
		if child:IsA("Frame") then
			table.insert(lines, child)
		end
	end
	table.sort(lines, function(a, b)
		return a.LayoutOrder < b.LayoutOrder
	end)
	while #lines > MAX_LINES do
		local oldest = table.remove(lines, 1)
		if oldest then
			oldest:Destroy()
		end
	end
	task.delay(LIFETIME, function()
		if line.Parent then
			local label = line:FindFirstChild("Text") :: TextLabel
			TweenService:Create(line, TweenInfo.new(0.4), { BackgroundTransparency = 1 }):Play()
			local fade = TweenService:Create(label, TweenInfo.new(0.4), { TextTransparency = 1 })
			fade:Play()
			fade.Completed:Wait()
			line:Destroy()
		end
	end)
end

function FeedController.start()
	local gui = player:WaitForChild("PlayerGui"):WaitForChild("HUD") :: ScreenGui
	feed = Create.new("Frame", {
		Name = "Feed",
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 12, 1, -44),
		Size = UDim2.fromOffset(330, MAX_LINES * 30),
		BackgroundTransparency = 1,
		Parent = gui,
	}, {
		Create.new("UIListLayout", {
			SortOrder = Enum.SortOrder.LayoutOrder,
			VerticalAlignment = Enum.VerticalAlignment.Bottom,
			Padding = UDim.new(0, 4),
		}),
	})
	local function refresh()
		local phase = State.phase()
		feed.Visible = phase == "Build" or phase == "Hunt"
	end
	refresh()
	State.changed:connect(function(name)
		if name == "Phase" then
			refresh()
		end
	end)
	Net.onNotify(function(kind, text)
		if kind == "feed" then
			push(text)
		end
	end)
end

return FeedController
