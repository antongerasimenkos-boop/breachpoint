--!strict
--[[
	HudController: the code-built HUD shared by every role.

	  top bar       phase name, countdown, builders alive / players needed
	  role badge    current role, colour-coded
	  role reveal   large animated "You are the HUNTER" when roles are assigned
	  toasts        server notifications and rejected actions
	  results       winner, reason and your reward at the end of a round
	  practice      role picker shown when you are alone in Studio
	  hint          controls for your current role and phase
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")

local Config = require(ReplicatedStorage:WaitForChild("Shared").Config)

local Client = script.Parent.Parent
local Create = require(Client.UI.Create)
local Net = require(Client.Net)
local Profile = require(Client.Profile)
local State = require(Client.State)
local Theme = require(Client.UI.Theme)

local player = Players.LocalPlayer

local HudController = {}

local gui: ScreenGui
local phaseLabel: TextLabel
local timerLabel: TextLabel
local subLabel: TextLabel
local roleBadge: Frame
local roleLabel: TextLabel
local toastList: Frame
local revealLabel: TextLabel
local revealSub: TextLabel
local resultsPanel: Frame
local soloPanel: Frame
local soloButtons: { [string]: TextButton } = {}
local pendingSoloRole: string? = nil
local hintLabel: TextLabel
local coinLabel: TextLabel
local shownCoins = 0
local coinsFrozen = false

local lastToast: { text: string, at: number } = { text = "", at = 0 }

local PHASE_TITLES = {
	Waiting = "Waiting for players",
	Intermission = "Next round in",
	Build = "Build phase",
	Hunt = "Hunt!",
	Results = "Round over",
}

local REASONS = {
	Survived = "At least one builder survived the hunt.",
	AllBuildersCaught = "Every builder was caught.",
	HunterLeft = "The hunter left, so the round does not count.",
	BuildersLeft = "All builders left, so the round does not count.",
}

function HudController.playSound(soundId: string, volume: number?)
	local sound = Instance.new("Sound")
	sound.SoundId = soundId
	sound.Volume = volume or 0.5
	SoundService:PlayLocalSound(sound)
	sound.Ended:Once(function()
		sound:Destroy()
	end)
	task.delay(6, function()
		if sound.Parent then
			sound:Destroy()
		end
	end)
end

function HudController.toast(kind: string, text: string)
	-- Collapse identical messages fired in quick succession (e.g. holding the mouse on a bad cell).
	local now = os.clock()
	if text == lastToast.text and now - lastToast.at < 1.2 then
		return
	end
	lastToast = { text = text, at = now }

	local color = if kind == "warn"
		then Theme.Colors.Warn
		elseif kind == "success" then Theme.Colors.Success
		elseif kind == "quest" or kind == "levelup" then Theme.Colors.Coin
		else Theme.Colors.Info
	local toast = Create.panel({
		Size = UDim2.fromOffset(340, 34),
		LayoutOrder = math.floor(now * 100),
		Parent = toastList,
	}, {
		Create.new("Frame", {
			Size = UDim2.new(0, 4, 1, -12),
			Position = UDim2.fromOffset(8, 6),
			BackgroundColor3 = color,
			BorderSizePixel = 0,
		}),
		Create.label({
			Size = UDim2.new(1, -26, 1, 0),
			Position = UDim2.fromOffset(20, 0),
			Text = text,
			TextSize = 15,
			Font = Theme.FontBody,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd,
		}),
	})
	local children = toastList:GetChildren()
	local count = 0
	for _, child in children do
		if child:IsA("Frame") then
			count += 1
		end
	end
	if count > 4 then
		-- Drop the oldest toast.
		local oldest: Frame? = nil
		for _, child in children do
			if child:IsA("Frame") and (not oldest or child.LayoutOrder < oldest.LayoutOrder) then
				oldest = child
			end
		end
		if oldest then
			oldest:Destroy()
		end
	end
	task.delay(2.6, function()
		if toast.Parent then
			local tween = TweenService:Create(toast, TweenInfo.new(0.3), { BackgroundTransparency = 1 })
			tween:Play()
			tween.Completed:Wait()
			toast:Destroy()
		end
	end)
end

local function formatTime(seconds: number): string
	local s = math.ceil(seconds)
	return string.format("%d:%02d", s // 60, s % 60)
end

local function buildGui()
	gui = Create.new("ScreenGui", {
		Name = "HUD",
		ResetOnSpawn = false,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		Parent = player:WaitForChild("PlayerGui"),
	})

	-- Scale the whole HUD down on narrow (phone) screens so nothing overlaps.
	local uiScale = Create.new("UIScale", { Parent = gui })
	local function rescale()
		local camera = workspace.CurrentCamera
		local width = if camera then camera.ViewportSize.X else 1280
		uiScale.Scale = math.clamp(width / 1100, 0.6, 1)
	end
	rescale()
	if workspace.CurrentCamera then
		workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(rescale)
	end

	-- Coins, top right.
	local wallet = Create.panel({
		Name = "Wallet",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -12, 0, 8),
		Size = UDim2.fromOffset(150, 40),
		Parent = gui,
	})
	local icon = Create.coinIcon(22)
	icon.Position = UDim2.fromOffset(12, 9)
	icon.Parent = wallet
	coinLabel = Create.label({
		Name = "Coins",
		Position = UDim2.fromOffset(42, 0),
		Size = UDim2.new(1, -52, 1, 0),
		Text = "0",
		TextSize = 22,
		TextColor3 = Theme.Colors.Coin,
		TextXAlignment = Enum.TextXAlignment.Right,
		Parent = wallet,
	})

	-- Top bar
	local top = Create.panel({
		Name = "TopBar",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 6),
		Size = UDim2.fromOffset(380, 66),
		Parent = gui,
	})
	phaseLabel = Create.label({
		Name = "Phase",
		Position = UDim2.fromOffset(16, 8),
		Size = UDim2.new(1, -120, 0, 26),
		TextSize = 22,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = top,
	})
	subLabel = Create.label({
		Name = "Sub",
		Position = UDim2.fromOffset(16, 36),
		Size = UDim2.new(1, -120, 0, 20),
		TextSize = 14,
		Font = Theme.FontBody,
		TextColor3 = Theme.Colors.TextDim,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = top,
	})
	timerLabel = Create.label({
		Name = "Timer",
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -16, 0.5, 0),
		Size = UDim2.fromOffset(100, 40),
		TextSize = 32,
		TextXAlignment = Enum.TextXAlignment.Right,
		Parent = top,
	})

	-- Role badge
	roleBadge = Create.panel({
		Name = "RoleBadge",
		Position = UDim2.fromOffset(12, 8),
		Size = UDim2.fromOffset(230, 36),
		Parent = gui,
	})
	roleLabel = Create.label({
		Size = UDim2.fromScale(1, 1),
		TextSize = 17,
		Parent = roleBadge,
	})

	-- Toasts
	toastList = Create.new("Frame", {
		Name = "Toasts",
		ZIndex = 20, -- above the shop window
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -150),
		Size = UDim2.fromOffset(340, 200),
		BackgroundTransparency = 1,
		Parent = gui,
	}, {
		Create.new("UIListLayout", {
			SortOrder = Enum.SortOrder.LayoutOrder,
			VerticalAlignment = Enum.VerticalAlignment.Bottom,
			HorizontalAlignment = Enum.HorizontalAlignment.Center,
			Padding = UDim.new(0, 6),
		}),
	})

	-- Role reveal
	revealLabel = Create.label({
		Name = "Reveal",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.36),
		Size = UDim2.fromOffset(700, 70),
		TextSize = 54,
		TextStrokeTransparency = 0.4,
		TextTransparency = 1,
		TextStrokeColor3 = Color3.new(0, 0, 0),
		Parent = gui,
	})
	revealSub = Create.label({
		Name = "RevealSub",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.36),
		Size = UDim2.fromOffset(700, 30),
		TextSize = 22,
		Font = Theme.FontBody,
		TextStrokeTransparency = 0.5,
		TextTransparency = 1,
		Parent = gui,
	})
	revealSub.Position = UDim2.new(0.5, 0, 0.36, 50)

	-- Results
	resultsPanel = Create.panel({
		Name = "Results",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.42),
		Size = UDim2.fromOffset(520, 360),
		Visible = false,
		Parent = gui,
	}, {
		Create.new("UIScale", { Scale = 1 }),
		Create.label({
			Name = "Title",
			Position = UDim2.fromOffset(0, 18),
			Size = UDim2.new(1, 0, 0, 44),
			TextSize = 38,
		}),
		Create.label({
			Name = "Reason",
			Position = UDim2.fromOffset(20, 70),
			Size = UDim2.new(1, -40, 0, 44),
			TextSize = 17,
			Font = Theme.FontBody,
			TextColor3 = Theme.Colors.TextDim,
			TextWrapped = true,
		}),
		Create.label({
			Name = "Reward",
			Position = UDim2.fromOffset(0, 112),
			Size = UDim2.new(1, 0, 0, 36),
			TextSize = 26,
			TextColor3 = Theme.Colors.Warn,
		}),
		Create.label({
			Name = "MvpTitle",
			Position = UDim2.fromOffset(24, 156),
			Size = UDim2.new(1, -48, 0, 20),
			Text = "MVPs",
			TextSize = 15,
			TextColor3 = Theme.Colors.Accent,
			TextXAlignment = Enum.TextXAlignment.Left,
		}),
		Create.new("Frame", {
			Name = "Mvps",
			Position = UDim2.fromOffset(20, 180),
			Size = UDim2.new(1, -40, 0, 126),
			BackgroundTransparency = 1,
		}),
		Create.label({
			Name = "Stats",
			Position = UDim2.new(0, 20, 1, -40),
			Size = UDim2.new(1, -40, 0, 26),
			TextSize = 14,
			Font = Theme.FontBody,
			TextColor3 = Theme.Colors.TextDim,
		}),
	})

	-- Practice-mode role picker
	soloPanel = Create.panel({
		Name = "Practice",
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 12, 0.5, 0),
		Size = UDim2.fromOffset(250, 128),
		Visible = false,
		Parent = gui,
	}, {
		Create.label({
			Position = UDim2.fromOffset(12, 8),
			Size = UDim2.new(1, -24, 0, 22),
			Text = "Practice mode",
			TextSize = 18,
			TextXAlignment = Enum.TextXAlignment.Left,
		}),
		Create.label({
			Position = UDim2.fromOffset(12, 30),
			Size = UDim2.new(1, -24, 0, 34),
			Text = "You're alone, so bots fill in. Next round you play:",
			TextSize = 13,
			Font = Theme.FontBody,
			TextColor3 = Theme.Colors.TextDim,
			TextWrapped = true,
			TextXAlignment = Enum.TextXAlignment.Left,
		}),
	})
	for i, role in { "Builder", "Hunter", "Spectator" } do
		local button = Create.new("TextButton", {
			Name = role,
			Position = UDim2.fromOffset(12 + (i - 1) * 78, 76),
			Size = UDim2.fromOffset(72, 38),
			BackgroundColor3 = Theme.roleColor(role),
			BackgroundTransparency = 0.35,
			Font = Theme.Font,
			TextSize = 16,
			TextColor3 = Theme.Colors.Text,
			Text = if role == "Spectator" then "Watch" else role,
			AutoButtonColor = true,
			Parent = soloPanel,
		}, {
			Create.new("UICorner", { CornerRadius = UDim.new(0, 8) }),
			Create.new("UIStroke", { Color = Theme.Colors.Stroke, Transparency = 1, Thickness = 2 }),
		})
		button.Activated:Connect(function()
			HudController.playSound(Theme.Sounds.Click, 0.3)
			pendingSoloRole = role
			Net.chooseSoloRole(role :: any)
		end)
		soloButtons[role] = button
	end

	-- Controls hint
	hintLabel = Create.label({
		Name = "Hint",
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 12, 1, -12),
		Size = UDim2.fromOffset(520, 22),
		TextSize = 14,
		Font = Theme.FontBody,
		TextColor3 = Theme.Colors.TextDim,
		TextStrokeTransparency = 0.6,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = gui,
	})
end

local function hintFor(role: string, phase: string, alive: boolean): string
	if role == "Builder" and alive and phase == "Build" then
		return "Click: place   1-7: block type   X: take back your block   Doors let builders through"
	elseif role == "Builder" and alive and phase == "Hunt" then
		return "Click or E on a damaged block: repair   Stay out of sight!"
	elseif role == "Hunter" and phase == "Build" then
		return "You are caged until the hunt starts. Study their fort."
	elseif role == "Hunter" and phase == "Hunt" then
		return "Click: breach block / tag builder   Q: Shockwave   E: Sprint"
	elseif phase == "Build" or phase == "Hunt" then
		return "Spectating. You will join the next round."
	end
	return ""
end

local function refreshStatic()
	local phase = State.phase()
	local role = State.role()
	local alive = State.alive()

	phaseLabel.Text = PHASE_TITLES[phase] or phase
	timerLabel.Visible = phase ~= "Waiting"

	local sub = ""
	if phase == "Waiting" then
		sub = string.format("%d / %d players", #Players:GetPlayers(), State.minPlayers())
	elseif phase == "Build" or phase == "Hunt" then
		local aliveCount, total = State.buildersAlive()
		sub = string.format("Builders alive: %d / %d", aliveCount, total)
		if State.solo() then
			sub ..= "   (practice)"
		end
	elseif phase == "Intermission" then
		sub = if State.solo() then "Practice round with bots" else "Get ready"
	end
	subLabel.Text = sub

	roleLabel.Text = string.upper(role)
	local class = Config.Classes[tostring(player:GetAttribute("Class"))]
	if role == "Builder" and class then
		roleLabel.Text ..= " · " .. string.upper(class.label)
	end
	roleLabel.TextColor3 = Theme.roleColor(role)
	roleBadge.Visible = role ~= "Spectator" or phase == "Build" or phase == "Hunt"
	if role ~= "Spectator" and not alive then
		roleLabel.Text = string.upper(role) .. " (OUT)"
	end

	hintLabel.Text = hintFor(role, phase, alive)

	local showSolo = State.soloAllowed()
		and #Players:GetPlayers() == 1
		and (phase == "Waiting" or phase == "Intermission" or phase == "Results")
	soloPanel.Visible = showSolo

	if phase == "Intermission" or phase == "Waiting" then
		resultsPanel.Visible = false
	end
end

local function reveal(role: string)
	local headline = if role == "Hunter" then "You are the HUNTER" else "You are a BUILDER"
	local detail = if role == "Hunter"
		then "Break into the fort and tag every builder."
		else "Fortify the base. Survive the hunt."
	revealLabel.Text = headline
	revealLabel.TextColor3 = Theme.roleColor(role)
	revealSub.Text = detail
	revealLabel.Size = UDim2.fromOffset(500, 50)
	local appear = TweenInfo.new(0.35, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
	TweenService:Create(revealLabel, appear, { TextTransparency = 0, Size = UDim2.fromOffset(700, 70) })
		:Play()
	TweenService:Create(revealSub, appear, { TextTransparency = 0 }):Play()
	task.delay(2.8, function()
		local fade = TweenInfo.new(0.6)
		TweenService:Create(revealLabel, fade, { TextTransparency = 1 }):Play()
		TweenService:Create(revealSub, fade, { TextTransparency = 1 }):Play()
	end)
end

local function showResults(result: any)
	local title = resultsPanel:FindFirstChild("Title") :: TextLabel
	local reason = resultsPanel:FindFirstChild("Reason") :: TextLabel
	local reward = resultsPanel:FindFirstChild("Reward") :: TextLabel
	if result.winner == "Builders" then
		title.Text = "BUILDERS WIN"
		title.TextColor3 = Theme.Colors.Builder
	elseif result.winner == "Hunter" then
		title.Text = "HUNTER WINS"
		title.TextColor3 = Theme.Colors.Hunter
	else
		title.Text = "ROUND VOID"
		title.TextColor3 = Theme.Colors.Spectator
	end
	reason.Text = REASONS[result.reason] or tostring(result.reason)
	local coins = result.rewards and result.rewards[tostring(player.UserId)]
	reward.Text = if coins then string.format("+%d coins", coins) else ""

	-- MVP rows: medal, name, role, coins.
	local list = resultsPanel:FindFirstChild("Mvps") :: Frame
	list:ClearAllChildren()
	local medals = { Theme.Colors.Coin, Color3.fromRGB(200, 205, 215), Color3.fromRGB(205, 130, 70) }
	for i, mvp in result.mvps or {} do
		local row = Create.panel({
			Position = UDim2.fromOffset(0, (i - 1) * 42),
			Size = UDim2.new(1, 0, 0, 36),
			BackgroundColor3 = if mvp.id == player.UserId
				then Theme.Colors.PanelRaised
				else Theme.Colors.PanelLight,
			Parent = list,
		}, {
			Create.new("Frame", {
				Position = UDim2.fromOffset(8, 6),
				Size = UDim2.fromOffset(24, 24),
				BackgroundColor3 = medals[i] or Theme.Colors.TextDim,
				BorderSizePixel = 0,
			}, {
				Create.new("UICorner", { CornerRadius = UDim.new(1, 0) }),
				Create.label({
					Size = UDim2.fromScale(1, 1),
					Text = tostring(i),
					TextSize = 14,
					TextColor3 = Theme.Colors.Panel,
				}),
			}),
			Create.label({
				Position = UDim2.fromOffset(42, 0),
				Size = UDim2.new(0.55, -42, 1, 0),
				Text = mvp.name,
				TextSize = 16,
				TextXAlignment = Enum.TextXAlignment.Left,
				TextTruncate = Enum.TextTruncate.AtEnd,
			}),
			Create.label({
				Position = UDim2.fromScale(0.55, 0),
				Size = UDim2.fromScale(0.2, 1),
				Text = string.upper(mvp.role),
				TextSize = 13,
				TextColor3 = Theme.roleColor(mvp.role),
			}),
			Create.label({
				AnchorPoint = Vector2.new(1, 0),
				Position = UDim2.new(1, -12, 0, 0),
				Size = UDim2.fromScale(0.25, 1),
				Text = "+" .. mvp.coins,
				TextSize = 16,
				TextColor3 = Theme.Colors.Coin,
				TextXAlignment = Enum.TextXAlignment.Right,
			}),
		})
		row.Name = "Mvp" .. i
	end
	local stats = result.stats
	local statsLabel = resultsPanel:FindFirstChild("Stats") :: TextLabel
	statsLabel.Text = if stats
		then string.format(
			"%d builders  ·  %d blocks still standing  ·  %d tags",
			stats.builders,
			stats.blocksStanding,
			stats.tags
		)
		else ""

	resultsPanel.Visible = true
	local scale = resultsPanel:FindFirstChildOfClass("UIScale") :: UIScale
	scale.Scale = 0.85
	TweenService
		:Create(scale, TweenInfo.new(0.35, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 })
		:Play()

	local won = (result.winner == "Builders" and table.find(result.survivors or {}, player.UserId) ~= nil)
		or (result.winner == "Hunter" and result.hunterId == player.UserId)
	if won then
		HudController.playSound(Theme.Sounds.Victory, 0.6)
	end
end

-- Counts the wallet up/down to the new value and floats a "+N" next to it.
local function animateCoins(target: number)
	local from = shownCoins
	shownCoins = target
	local delta = target - from
	if delta == 0 then
		coinLabel.Text = tostring(target)
		return
	end
	if delta > 0 and from > 0 then
		local float = Create.label({
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.new(1, -12, 0, 50),
			Size = UDim2.fromOffset(120, 24),
			Text = "+" .. tostring(delta),
			TextSize = 20,
			TextColor3 = Theme.Colors.Coin,
			TextStrokeTransparency = 0.5,
			TextXAlignment = Enum.TextXAlignment.Right,
			Parent = gui,
		})
		TweenService:Create(
			float,
			TweenInfo.new(1.1),
			{ Position = UDim2.new(1, -12, 0, 80), TextTransparency = 1, TextStrokeTransparency = 1 }
		):Play()
		task.delay(1.2, function()
			float:Destroy()
		end)
	end
	task.spawn(function()
		local steps = 12
		for i = 1, steps do
			if shownCoins ~= target then
				return -- a newer update took over
			end
			coinLabel.Text = tostring(math.floor(from + delta * i / steps + 0.5))
			task.wait(0.03)
		end
	end)
end

-- Holds the wallet still (e.g. while a crate reel spins, so it doesn't spoil the prize).
function HudController.freezeCoins(frozen: boolean)
	coinsFrozen = frozen
	if not frozen and Profile.current then
		animateCoins(Profile.current.coins)
	end
end

function HudController.start()
	buildGui()
	refreshStatic()

	local lastRole = State.role()
	State.changed:connect(function(name)
		refreshStatic()
		if name == "Role" then
			local role = State.role()
			if role ~= lastRole and (role == "Builder" or role == "Hunter") then
				reveal(role)
			end
			lastRole = role
		elseif name == "Phase" and State.phase() == "Hunt" then
			HudController.playSound(Theme.Sounds.HuntStart, 0.5)
		end
	end)
	Players.PlayerAdded:Connect(refreshStatic)
	Players.PlayerRemoving:Connect(function()
		task.defer(refreshStatic)
	end)

	Net.onNotify(function(kind, text)
		if kind ~= "feed" then
			HudController.toast(kind, text)
		end
	end)
	Net.onActionResult(function(action, ok, reason)
		if action == "ChooseSoloRole" and ok then
			-- Outline the role the server confirmed.
			for role, button in soloButtons do
				local stroke = button:FindFirstChildOfClass("UIStroke")
				if stroke then
					stroke.Transparency = if role == pendingSoloRole then 0 else 1
				end
			end
		end
		if not ok and reason then
			HudController.toast("warn", reason)
		end
	end)
	Net.onRoundResult(showResults)
	Profile.changed:connect(function(view)
		if not coinsFrozen then
			animateCoins(view.coins)
		end
	end)
	if Profile.current then
		animateCoins(Profile.current.coins)
	end

	-- Countdown: cheap enough to update every frame, but only touch the label when it changes.
	local lastText = ""
	RunService.Heartbeat:Connect(function()
		local text = formatTime(State.timeLeft())
		if text ~= lastText then
			lastText = text
			timerLabel.Text = text
			local urgent = State.timeLeft() <= 10 and (State.phase() == "Build" or State.phase() == "Hunt")
			timerLabel.TextColor3 = if urgent then Theme.Colors.Warn else Theme.Colors.Text
		end
	end)
end

return HudController
