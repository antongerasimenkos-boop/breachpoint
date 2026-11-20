--!strict
--[[
	ShopController: the Shop / Crates / Cosmetics window and the crate reveal.

	The client never decides anything here. Buttons send intents (BuyItem, OpenCrate, Equip), the
	server validates and replies with a fresh Profile snapshot. A crate reveal animates toward the
	prize the server already rolled (CrateResult); the filler cards on the reel are decoration.
	Odds and pity progress are shown before every open.
]]

local Players = game:GetService("Players")
local ProximityPromptService = game:GetService("ProximityPromptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)

local Client = script.Parent.Parent
local Create = require(Client.UI.Create)
local HudController = require(script.Parent.HudController)
local Net = require(Client.Net)
local Profile = require(Client.Profile)
local Theme = require(Client.UI.Theme)

local player = Players.LocalPlayer

local ShopController = {}

type Tab = "Blocks" | "Builder" | "Hunter" | "Crates" | "Cosmetics"
local TABS: { Tab } = { "Blocks", "Builder", "Hunter", "Crates", "Cosmetics" }

local window: Frame
local content: ScrollingFrame
local tabButtons: { [string]: TextButton } = {}
local currentTab: Tab = "Blocks"
local revealing = false
local overlay: Frame

local function rarityColor(rarity: string): Color3
	return Theme.rgb((Config.RarityColors :: any)[rarity])
end

local function clear()
	for _, child in content:GetChildren() do
		if not child:IsA("UIGridLayout") and not child:IsA("UIListLayout") and not child:IsA("UIPadding") then
			child:Destroy()
		end
	end
end

local function priceTag(parent: Instance, price: number, position: UDim2)
	local holder = Create.new("Frame", {
		Position = position,
		Size = UDim2.fromOffset(110, 20),
		BackgroundTransparency = 1,
		Parent = parent,
	})
	local icon = Create.coinIcon(16)
	icon.Position = UDim2.fromOffset(0, 2)
	icon.Parent = holder
	Create.label({
		Position = UDim2.fromOffset(22, 0),
		Size = UDim2.new(1, -22, 1, 0),
		Text = tostring(price),
		TextSize = 16,
		TextColor3 = Theme.Colors.Coin,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = holder,
	})
end

local function card(name: string, description: string, accent: Color3): Frame
	local frame = Create.panel({
		Size = UDim2.fromOffset(196, 132),
		BackgroundColor3 = Theme.Colors.PanelLight,
		Parent = content,
	}, {
		Create.new("Frame", {
			Size = UDim2.new(1, 0, 0, 4),
			BackgroundColor3 = accent,
			BorderSizePixel = 0,
		}),
		Create.label({
			Position = UDim2.fromOffset(12, 12),
			Size = UDim2.new(1, -24, 0, 20),
			Text = name,
			TextSize = 17,
			TextXAlignment = Enum.TextXAlignment.Left,
		}),
		Create.label({
			Position = UDim2.fromOffset(12, 34),
			Size = UDim2.new(1, -24, 0, 40),
			Text = description,
			TextSize = 13,
			Font = Theme.FontBody,
			TextColor3 = Theme.Colors.TextDim,
			TextWrapped = true,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextYAlignment = Enum.TextYAlignment.Top,
		}),
	})
	return frame
end

local function renderShop(category: string)
	for _, item in Config.Shop do
		if item.category ~= category then
			continue
		end
		local accent = if category == "Hunter"
			then Theme.Colors.Hunter
			elseif category == "Builder" then Theme.Colors.Builder
			else Theme.Colors.Accent
		local frame = card(item.name, item.description, accent)
		local owned = Profile.owns(item.id)
		if owned then
			Create.label({
				Position = UDim2.new(0, 12, 1, -36),
				Size = UDim2.new(1, -24, 0, 26),
				Text = "OWNED",
				TextSize = 15,
				TextColor3 = Theme.Colors.Success,
				Parent = frame,
			})
		else
			priceTag(frame, item.price, UDim2.new(0, 12, 1, -32))
			local affordable = Profile.coins() >= item.price
			local buy = Create.button({
				AnchorPoint = Vector2.new(1, 1),
				Position = UDim2.new(1, -10, 1, -10),
				Size = UDim2.fromOffset(72, 30),
				Text = "Buy",
				Color = if affordable then Theme.Colors.Success else Theme.Colors.PanelRaised,
				TextTransparency = if affordable then 0 else 0.4,
				Parent = frame,
			}, function()
				HudController.playSound(Theme.Sounds.Click, 0.3)
				Net.buyItem(item.id)
			end)
			buy.Name = "Buy"
		end
	end
end

local function renderCrates()
	local view = Profile.current
	for crateId, crate in Config.Crates do
		local frame = Create.panel({
			Size = UDim2.fromOffset(600, 230),
			BackgroundColor3 = Theme.Colors.PanelLight,
			Parent = content,
		})
		Create.label({
			Position = UDim2.fromOffset(16, 12),
			Size = UDim2.fromOffset(300, 26),
			Text = crate.name,
			TextSize = 22,
			TextXAlignment = Enum.TextXAlignment.Left,
			Parent = frame,
		})
		Create.label({
			Position = UDim2.fromOffset(16, 40),
			Size = UDim2.fromOffset(300, 18),
			Text = "Odds per open (coins only, no Robux):",
			TextSize = 13,
			Font = Theme.FontBody,
			TextColor3 = Theme.Colors.TextDim,
			TextXAlignment = Enum.TextXAlignment.Left,
			Parent = frame,
		})
		for i, rarity in Config.RarityOrder do
			local odds = (crate.odds :: any)[rarity]
			local y = 62 + (i - 1) * 30
			Create.label({
				Position = UDim2.fromOffset(16, y),
				Size = UDim2.fromOffset(90, 22),
				Text = rarity,
				TextSize = 15,
				TextColor3 = rarityColor(rarity),
				TextXAlignment = Enum.TextXAlignment.Left,
				Parent = frame,
			})
			local track = Create.new("Frame", {
				Position = UDim2.fromOffset(110, y + 6),
				Size = UDim2.fromOffset(150, 10),
				BackgroundColor3 = Theme.Colors.Panel,
				BorderSizePixel = 0,
				Parent = frame,
			}, { Create.new("UICorner", { CornerRadius = UDim.new(1, 0) }) })
			Create.new("Frame", {
				Size = UDim2.fromScale(math.max(0.02, odds), 1),
				BackgroundColor3 = rarityColor(rarity),
				BorderSizePixel = 0,
				Parent = track,
			}, { Create.new("UICorner", { CornerRadius = UDim.new(1, 0) }) })
			Create.label({
				Position = UDim2.fromOffset(270, y),
				Size = UDim2.fromOffset(60, 22),
				Text = string.format("%g%%", odds * 100),
				TextSize = 15,
				TextXAlignment = Enum.TextXAlignment.Left,
				Parent = frame,
			})
		end
		local sinceEpic = if view then view.pity.sinceEpic else 0
		local sinceLegendary = if view then view.pity.sinceLegendary else 0
		Create.label({
			Position = UDim2.fromOffset(340, 62),
			Size = UDim2.fromOffset(244, 80),
			Text = string.format(
				"Pity: Epic or better guaranteed within %d opens.\nLegendary guaranteed within %d opens.\nDuplicates turn into coins.",
				crate.pityEpic - sinceEpic,
				crate.pityLegendary - sinceLegendary
			),
			TextSize = 13,
			Font = Theme.FontBody,
			TextColor3 = Theme.Colors.TextDim,
			TextWrapped = true,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextYAlignment = Enum.TextYAlignment.Top,
			Parent = frame,
		})
		priceTag(frame, crate.price, UDim2.fromOffset(340, 156))
		local open = Create.button({
			AnchorPoint = Vector2.new(1, 1),
			Position = UDim2.new(1, -16, 1, -16),
			Size = UDim2.fromOffset(150, 44),
			Text = "Open crate",
			TextSize = 18,
			Color = if Profile.coins() >= crate.price then Theme.Colors.Accent else Theme.Colors.PanelRaised,
			Parent = frame,
		}, function()
			if revealing then
				return
			end
			if Profile.coins() < crate.price then
				HudController.toast("warn", "Not enough coins")
				return
			end
			HudController.playSound(Theme.Sounds.Click, 0.3)
			Net.openCrate(crateId)
		end)
		open.Name = "OpenCrate"
	end
end

local function renderCosmetics()
	local any = false
	for _, slot in { "Title", "BlockSkin", "Trail" } do
		for _, cosmetic in Config.Cosmetics do
			if cosmetic.slot ~= slot or not Profile.hasCosmetic(cosmetic.id) then
				continue
			end
			any = true
			local slotName = if slot == "BlockSkin"
				then "Block skin"
				elseif slot == "Trail" then "Hunter trail"
				else "Title"
			local frame =
				card(cosmetic.name, cosmetic.rarity .. " " .. slotName, rarityColor(cosmetic.rarity))
			Create.new("Frame", {
				Position = UDim2.new(1, -40, 0, 14),
				Size = UDim2.fromOffset(26, 26),
				BackgroundColor3 = Theme.rgb(cosmetic.color),
				Parent = frame,
			}, { Create.new("UICorner", { CornerRadius = UDim.new(0, 6) }) })
			local equipped = Profile.current ~= nil and (Profile.current.equipped :: any)[slot] == cosmetic.id
			Create.button({
				AnchorPoint = Vector2.new(1, 1),
				Position = UDim2.new(1, -10, 1, -10),
				Size = UDim2.fromOffset(96, 30),
				Text = if equipped then "Unequip" else "Equip",
				Color = if equipped then Theme.Colors.PanelRaised else Theme.Colors.Builder,
				Parent = frame,
			}, function()
				Net.equip(slot :: any, if equipped then "" else cosmetic.id)
			end)
		end
	end
	if not any then
		Create.label({
			Size = UDim2.fromOffset(600, 60),
			Text = "No cosmetics yet. Open crates to win block skins, hunter trails and titles.",
			TextSize = 15,
			Font = Theme.FontBody,
			TextColor3 = Theme.Colors.TextDim,
			TextWrapped = true,
			Parent = content,
		})
	end
end

local function render()
	if not window.Visible then
		return
	end
	clear()
	-- Crate panels and empty states are full-width; item cards use a 3-column grid.
	local grid = content:FindFirstChildOfClass("UIGridLayout") :: UIGridLayout
	local wide = currentTab == "Crates"
		or (currentTab == "Cosmetics" and (not Profile.current or #Profile.current.cosmetics == 0))
	grid.CellSize = if wide then UDim2.fromOffset(600, 230) else UDim2.fromOffset(196, 132)
	for tab, button in tabButtons do
		button.BackgroundColor3 = if tab == currentTab then Theme.Colors.Accent else Theme.Colors.PanelRaised
	end
	if currentTab == "Crates" then
		renderCrates()
	elseif currentTab == "Cosmetics" then
		renderCosmetics()
	else
		renderShop(currentTab)
	end
end

function ShopController.open(tab: Tab?)
	currentTab = tab or currentTab
	window.Visible = true
	window.Size = UDim2.fromOffset(640, 420)
	local scale = window:FindFirstChildOfClass("UIScale") :: UIScale
	scale.Scale = 0.9
	TweenService:Create(scale, TweenInfo.new(0.18, Enum.EasingStyle.Back), { Scale = 1 }):Play()
	render()
end

function ShopController.close()
	window.Visible = false
end

function ShopController.toggle(tab: Tab)
	if window.Visible and currentTab == tab then
		ShopController.close()
	else
		ShopController.open(tab)
	end
end

-- Crate reveal ---------------------------------------------------------------------------------

local CARD_W = 120

local function reelCard(parent: Instance, index: number, name: string, rarity: string): Frame
	return Create.panel({
		Position = UDim2.fromOffset((index - 1) * CARD_W + 4, 8),
		Size = UDim2.fromOffset(CARD_W - 8, 124),
		BackgroundColor3 = Theme.Colors.PanelLight,
		Parent = parent,
	}, {
		Create.new("Frame", {
			Size = UDim2.new(1, 0, 0, 6),
			BackgroundColor3 = rarityColor(rarity),
			BorderSizePixel = 0,
		}),
		Create.label({
			Position = UDim2.fromOffset(6, 40),
			Size = UDim2.new(1, -12, 0, 44),
			Text = name,
			TextSize = 15,
			TextWrapped = true,
		}),
		Create.label({
			Position = UDim2.new(0, 0, 1, -28),
			Size = UDim2.new(1, 0, 0, 20),
			Text = rarity,
			TextSize = 12,
			TextColor3 = rarityColor(rarity),
		}),
	})
end

local function randomFiller(crate: any): (string, string)
	local roll = math.random()
	local rarity = "Common"
	for _, r in Config.RarityOrder do
		roll -= crate.odds[r]
		if roll < 0 then
			rarity = r
			break
		end
	end
	local names = { tostring(crate.coinPrizes[rarity]) .. " coins" }
	for _, cosmetic in Config.Cosmetics do
		if cosmetic.rarity == rarity then
			table.insert(names, cosmetic.name)
		end
	end
	return names[math.random(1, #names)], rarity
end

local function showReveal(result: any)
	revealing = true
	HudController.freezeCoins(true)
	local crate = Config.Crates[result.crateId]
	overlay.Visible = true
	overlay.BackgroundTransparency = 1
	TweenService:Create(overlay, TweenInfo.new(0.2), { BackgroundTransparency = 0.35 }):Play()
	local reel = overlay:FindFirstChild("Reel") :: Frame
	local strip = reel:FindFirstChild("Strip") :: Frame
	local caption = overlay:FindFirstChild("Caption") :: TextLabel
	local done = overlay:FindFirstChild("Done") :: TextButton
	caption.Text = "Opening " .. crate.name .. "..."
	caption.TextColor3 = Theme.Colors.Text
	done.Visible = false
	for _, child in strip:GetChildren() do
		child:Destroy()
	end

	local WIN_INDEX = 34
	for i = 1, WIN_INDEX + 4 do
		if i == WIN_INDEX then
			reelCard(strip, i, result.prize.name, result.rarity)
		else
			local name, rarity = randomFiller(crate)
			reelCard(strip, i, name, rarity)
		end
	end
	strip.Size = UDim2.fromOffset((WIN_INDEX + 4) * CARD_W, 140)
	strip.Position = UDim2.fromOffset(0, 0)
	local center = reel.AbsoluteSize.X / 2
	local target = -((WIN_INDEX - 1) * CARD_W + CARD_W / 2 - center) + math.random(-30, 30)
	local tween = TweenService:Create(
		strip,
		TweenInfo.new(3.2, Enum.EasingStyle.Quint, Enum.EasingDirection.Out),
		{ Position = UDim2.fromOffset(target, 0) }
	)
	-- Ticks while the reel moves.
	task.spawn(function()
		local last = 0
		while tween.PlaybackState ~= Enum.PlaybackState.Completed do
			local x = -strip.Position.X.Offset
			if x - last >= CARD_W then
				last = x
				HudController.playSound(Theme.Sounds.Reel, 0.15)
			end
			task.wait()
		end
	end)
	tween:Play()
	tween.Completed:Wait()

	local prize = result.prize
	local headline = string.upper(result.rarity) .. ": " .. prize.name
	if prize.duplicate then
		headline ..= string.format("  (duplicate → +%d coins)", prize.coins)
	end
	caption.Text = headline
	caption.TextColor3 = rarityColor(result.rarity)
	HudController.playSound(
		Theme.Sounds.Reveal,
		if result.rarity == "Legendary" or result.rarity == "Epic" then 0.8 else 0.4
	)
	done.Visible = true
	revealing = false
	HudController.freezeCoins(false)
end

-- Build ----------------------------------------------------------------------------------------

local function buildWindow(gui: ScreenGui)
	window = Create.panel({
		Name = "Shop",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.52),
		Size = UDim2.fromOffset(640, 420),
		Visible = false,
		ZIndex = 5,
		Parent = gui,
	}, { Create.new("UIScale", { Scale = 1 }) })
	Create.label({
		Position = UDim2.fromOffset(18, 12),
		Size = UDim2.fromOffset(200, 30),
		Text = "SHOP",
		TextSize = 24,
		Font = Theme.FontBlack,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = window,
	})
	Create.button({
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -12, 0, 10),
		Size = UDim2.fromOffset(36, 36),
		Text = "X",
		Color = Theme.Colors.Hunter,
		Parent = window,
	}, ShopController.close)

	for i, tab in TABS do
		tabButtons[tab] = Create.button({
			Position = UDim2.fromOffset(18 + (i - 1) * 118, 52),
			Size = UDim2.fromOffset(110, 32),
			Text = tab,
			TextSize = 15,
			Parent = window,
		}, function()
			local chosen: Tab = tab :: any
			currentTab = chosen
			render()
		end)
	end

	content = Create.new("ScrollingFrame", {
		Position = UDim2.fromOffset(16, 96),
		Size = UDim2.new(1, -32, 1, -110),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = 6,
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		CanvasSize = UDim2.new(),
		Parent = window,
	}, {
		Create.new("UIGridLayout", {
			CellSize = UDim2.fromOffset(196, 132),
			CellPadding = UDim2.fromOffset(8, 8),
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
	})

	overlay = Create.new("Frame", {
		Name = "CrateReveal",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = Color3.new(0, 0, 0),
		BackgroundTransparency = 0.35,
		Visible = false,
		ZIndex = 10,
		Parent = gui,
	})
	local reel = Create.panel({
		Name = "Reel",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.45),
		Size = UDim2.fromOffset(620, 140),
		ClipsDescendants = true,
		Parent = overlay,
	}, {
		Create.new("Frame", { Name = "Strip", BackgroundTransparency = 1, Size = UDim2.fromOffset(0, 140) }),
	})
	Create.new("Frame", {
		Name = "Marker",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.fromScale(0.5, 0),
		Size = UDim2.new(0, 4, 1, 0),
		BackgroundColor3 = Theme.Colors.Coin,
		BorderSizePixel = 0,
		ZIndex = 3,
		Parent = reel,
	})
	Create.label({
		Name = "Caption",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0.45, 86),
		Size = UDim2.fromOffset(700, 36),
		TextSize = 26,
		TextStrokeTransparency = 0.4,
		Parent = overlay,
	})
	local done = Create.button({
		Name = "Done",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0.45, 132),
		Size = UDim2.fromOffset(140, 42),
		Text = "Nice!",
		Color = Theme.Colors.Success,
		Visible = false,
		Parent = overlay,
	}, function()
		overlay.Visible = false
		render()
	end)
	done.Name = "Done"
end

local dailyButton: TextButton

local function buildMenu(gui: ScreenGui)
	local menu = Create.new("Frame", {
		Name = "Menu",
		Position = UDim2.fromOffset(12, 52),
		Size = UDim2.fromOffset(150, 4 * 44),
		BackgroundTransparency = 1,
		Parent = gui,
	}, {
		Create.new("UIListLayout", { Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder }),
	})
	type Entry = { name: string, color: Color3, action: () -> () }
	local entries: { Entry } = {
		{
			name = "Shop",
			color = Theme.Colors.Accent,
			action = function()
				ShopController.toggle("Blocks")
			end,
		},
		{
			name = "Crates",
			color = Color3.fromRGB(185, 100, 255),
			action = function()
				ShopController.toggle("Crates")
			end,
		},
		{
			name = "Cosmetics",
			color = Theme.Colors.Builder,
			action = function()
				ShopController.toggle("Cosmetics")
			end,
		},
		{
			name = "Daily",
			color = Theme.Colors.Success,
			action = function()
				local view = Profile.current
				if view and view.daily.canClaim then
					Net.claimDaily()
				else
					HudController.toast("info", "Daily reward already claimed. Come back tomorrow!")
				end
			end,
		},
	}
	for i, entry in entries do
		local b = Create.button({
			Name = entry.name,
			LayoutOrder = i,
			Size = UDim2.fromOffset(150, 38),
			Text = entry.name,
			Color = entry.color,
			Parent = menu,
		}, function()
			HudController.playSound(Theme.Sounds.Click, 0.3)
			entry.action()
		end)
		if entry.name == "Daily" then
			dailyButton = b
		end
	end
end

local function refreshDaily()
	local view = Profile.current
	if not view or not dailyButton then
		return
	end
	if view.daily.canClaim then
		dailyButton.Text = string.format("Daily +%d", view.daily.reward)
		dailyButton.BackgroundColor3 = Theme.Colors.Success
	else
		dailyButton.Text = string.format("Daily (day %d)", view.daily.streak)
		dailyButton.BackgroundColor3 = Theme.Colors.PanelRaised
	end
end

function ShopController.start()
	local gui = player:WaitForChild("PlayerGui"):WaitForChild("HUD") :: ScreenGui
	buildWindow(gui)
	buildMenu(gui)
	Profile.changed:connect(function()
		refreshDaily()
		if not revealing then
			render()
		end
	end)
	refreshDaily()
	Net.onCrateResult(function(result)
		task.spawn(showReveal, result)
	end)
	-- Lobby kiosks (LobbyService) open the matching tab.
	ProximityPromptService.PromptTriggered:Connect(function(prompt)
		local tab = prompt:GetAttribute("ShopTab")
		if type(tab) == "string" then
			ShopController.open(tab :: any)
		end
	end)
end

return ShopController
