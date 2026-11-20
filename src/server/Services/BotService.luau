--!strict
--[[
	BotService: bodies and behaviour for practice-mode bots (solo play in Studio).

	The bots run the same pure brains as the balance simulation (sim/RoundSim.luau):
	  Bot builders   FortPlanner team fort, built one block at a time, then BuilderBrain repairs
	                 (most damaged block in reach) during the hunt.
	  Bot hunter     HunterBrain: Dijkstra over columns (travel + break time), breaches the weakest
	                 point, tags with line of sight, Shockwave when surrounded, Sprint on long runs.

	Bots never touch game state directly. They call BuildService.tryPlace/tryRepair and
	HunterService.tryBreach/tryTag/tryAbility, the same validated paths human requests take.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Cleanup = require(Shared.Util.Cleanup)
local Config = require(Shared.Config)
local Log = require(Shared.Util.Log)
local Types = require(Shared.Types)

local Gameplay = script.Parent.Parent.Gameplay
local BuilderBrain = require(Gameplay.BuilderBrain)
local FortPlanner = require(Gameplay.FortPlanner)
local HunterBrain = require(Gameplay.HunterBrain)

local Services = script.Parent
local BuildService = require(Services.BuildService)
local HunterService = require(Services.HunterService)
local MapService = require(Services.MapService)
local Participants = require(Services.Participants)
local RoundService = require(Services.RoundService)

local BotService = {}

local TICK = 0.1
local HUNTER_REACTION = 0.3
local HUNTER_SKILL = 0.8 -- share of ready breach moments used (middle of the simulated range)
local BUILDER_ATTENTION = 0.72 -- share of repair opportunities used (middle of the simulated range)
local PLACE_INTERVAL = 0.3
local CELL = Config.Grid.CellSize

local roundCleanup = Cleanup.new()
local bots: { [number]: { model: Model, role: Types.Role } } = {}

local function cellCenter(cell: Types.Cell): Vector3
	return Vector3.new(
		(cell.x + 0.5) * CELL,
		Config.Grid.GroundY + (cell.y + 0.5) * CELL,
		(cell.z + 0.5) * CELL
	)
end

-- A simple blocky figure. Built from parts so it works offline and in any place.
local function buildRig(name: string, color: Color3, anchored: boolean): Model
	local model = Instance.new("Model")
	model.Name = name

	local root = Instance.new("Part")
	root.Name = "HumanoidRootPart"
	root.Size = Vector3.new(2, 2, 1)
	root.Transparency = 1
	root.Anchored = anchored
	root.Parent = model

	local function limb(partName: string, size: Vector3, offset: Vector3, limbColor: Color3)
		local p = Instance.new("Part")
		p.Name = partName
		p.Size = size
		p.Color = limbColor
		p.Material = Enum.Material.SmoothPlastic
		p.CFrame = root.CFrame * CFrame.new(offset)
		p.CanCollide = false
		p.Massless = true
		local weld = Instance.new("WeldConstraint")
		weld.Part0 = root
		weld.Part1 = p
		weld.Parent = p
		p.Parent = model
		return p
	end
	limb("Torso", Vector3.new(2, 2, 1), Vector3.zero, color)
	local head =
		limb("Head", Vector3.new(1.2, 1.2, 1.2), Vector3.new(0, 1.6, 0), Color3.fromRGB(255, 220, 180))
	limb("Legs", Vector3.new(2, 2, 1), Vector3.new(0, -2, 0), color:Lerp(Color3.new(0, 0, 0), 0.4))
	local face = Instance.new("Decal")
	face.Texture = "rbxasset://textures/face.png"
	face.Face = Enum.NormalId.Front
	face.Parent = head

	local humanoid = Instance.new("Humanoid")
	humanoid.HipHeight = 2
	humanoid.WalkSpeed = Config.DefaultWalkSpeed
	humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.Viewer
	humanoid.Parent = model

	model.PrimaryPart = root
	return model
end

local function spawnBot(id: number, role: Types.Role, label: string, at: CFrame)
	local isHunter = role == "Hunter"
	local color = if isHunter then Color3.fromRGB(200, 60, 60) else Color3.fromRGB(70, 130, 220)
	local model = buildRig(label, color, not isHunter)
	model:PivotTo(at)
	model.Parent = MapService.botsFolder()
	Participants.registerBot(id, model)
	bots[id] = { model = model, role = role }
	roundCleanup:add(function()
		Participants.unregisterBot(id)
		bots[id] = nil
		model:Destroy()
	end)
end

local function freeKinds(): { [string]: FortPlanner.KindInfo }
	local kinds = {}
	for _, name in Config.Balance.FreeKinds do
		local cfg = (Config.Blocks :: any)[name]
		kinds[name] = { cost = cfg.cost, health = cfg.health }
	end
	return kinds
end

-- Bot builders: build their share of the team fort, then repair during the hunt.
local function runBuilder(id: number, placements: { FortPlanner.Placement })
	roundCleanup:add(task.spawn(function()
		task.wait(0.5 + math.random())
		for _, step in placements do
			if RoundService.getPhase() ~= "Build" or not bots[id] then
				break
			end
			BuildService.tryPlace(id, step.cell :: any, step.kind :: any)
			task.wait(PLACE_INTERVAL)
		end
		while bots[id] and RoundService.getPhase() == "Build" do
			task.wait(0.25)
		end
		while bots[id] and RoundService.getPhase() == "Hunt" and RoundService.isAlive(id) do
			local root = Participants.root(id)
			local blockId = if root
				then BuilderBrain.chooseRepair(
					BuildService.gridView() :: any,
					root.Position.X,
					root.Position.Y,
					root.Position.Z,
					Config.Repair.Reach,
					BuildService.isUnderFire
				)
				else nil
			if blockId then
				if math.random() < BUILDER_ATTENTION then
					BuildService.tryRepair(id, blockId)
				end
				task.wait(Config.Repair.Cooldown) -- a used or missed opportunity costs the cooldown
			else
				task.wait(0.2)
			end
		end
	end))
end

local function aliveBuilderTargets(): { HunterBrain.Target }
	local targets = {}
	for _, id in RoundService.snapshot().alive do
		if RoundService.getRole(id) == "Builder" then
			local root = Participants.root(id)
			if root then
				table.insert(targets, { id = id, x = root.Position.X, z = root.Position.Z })
			end
		end
	end
	return targets
end

-- The bot hunter: the same decision loop as the simulation.
local function runHunter(id: number)
	local bot = bots[id]
	if not bot then
		return
	end
	local model = bot.model
	local humanoid = model:FindFirstChildOfClass("Humanoid") :: Humanoid
	local root = model.PrimaryPart :: BasePart

	roundCleanup:add(task.spawn(function()
		local nextThink = 0
		local nextSwing = 0
		local breachTarget: number? = nil
		while bots[id] and model.Parent do
			task.wait(TICK)
			if RoundService.getPhase() ~= "Hunt" then
				continue
			end
			local now = os.clock()
			local grid = BuildService.gridView() :: any
			if breachTarget and not grid:get(breachTarget) then
				nextThink = now
			end
			if now >= nextThink then
				nextThink = now + HUNTER_REACTION
				breachTarget = nil
				local tuning = HunterBrain.tuningFromConfig(Config, HunterService.damageMultiplier())
				local decision = HunterBrain.decide(
					grid,
					tuning,
					root.Position.X,
					root.Position.Z,
					aliveBuilderTargets(),
					{
						shockwaveReady = HunterService.cooldownRemaining(id, "Shockwave") == 0,
						sprintReady = HunterService.cooldownRemaining(id, "Sprint") == 0,
					}
				)
				if decision.shockwave and math.random() < HUNTER_SKILL then
					HunterService.tryAbility(id, "Shockwave")
				end
				if decision.sprint then
					HunterService.tryAbility(id, "Sprint")
				end
				if decision.action == "tag" and decision.targetId then
					HunterService.tryTag(id, decision.targetId)
				elseif decision.action == "breach" and decision.blockId then
					breachTarget = decision.blockId
					nextThink = now + 1.5
					humanoid:MoveTo(root.Position)
				elseif decision.action == "move" and decision.x and decision.z then
					humanoid:MoveTo(Vector3.new(decision.x, root.Position.Y, decision.z))
				end
			end
			-- One roll per swing, like the simulation: a missed swing waits out a full cooldown.
			if breachTarget and os.clock() >= nextSwing then
				nextSwing = os.clock() + Config.Hunter.Breach.Cooldown
				if math.random() < HUNTER_SKILL then
					HunterService.tryBreach(id, breachTarget)
				end
			end
		end
	end))
end

local function despawnAll()
	roundCleanup:clean()
end

function BotService.init() end

function BotService.start()
	RoundService.rolesAssigned:connect(function(hunter, builders, botIds)
		despawnAll()
		if #botIds == 0 then
			return
		end

		local botBuilders = {}
		for _, id in botIds do
			if id ~= hunter and table.find(builders, id) then
				table.insert(botBuilders, id)
			end
		end
		if #botBuilders > 0 then
			-- Like the simulation: bots waste 0-20% of their budget, as real builders do.
			local waste = math.random() * 0.2
			local budgets = {}
			for i = 1, #botBuilders do
				budgets[i] = math.floor(Config.Build.BudgetPerBuilder * (1 - waste))
			end
			local plan = FortPlanner.plan({
				builderCount = #botBuilders,
				budgets = budgets,
				kinds = freeKinds(),
				bounds = Config.Grid,
			})
			local byOwner: { { FortPlanner.Placement } } = {}
			for i = 1, #botBuilders do
				byOwner[i] = {}
			end
			for _, placement in plan.placements do
				table.insert(byOwner[placement.owner], placement)
			end
			for i, id in botBuilders do
				-- Stand on the spot: the root sits 3 studs above the ground (legs below it).
				local feet = cellCenter(plan.spots[i]) - Vector3.new(0, CELL / 2, 0)
				spawnBot(id, "Builder", "Bot Builder " .. i, CFrame.new(feet + Vector3.new(0, 3, 0)))
				runBuilder(id, byOwner[i])
			end
		end
		if table.find(botIds, hunter) then
			spawnBot(hunter, "Hunter", "Bot Hunter", MapService.cageSpawn())
			runHunter(hunter)
		end
		Log.info("Bots", string.format("spawned %d practice bot(s)", #botIds))
	end)

	RoundService.phaseChanged:connect(function(_from, to)
		if to == "Hunt" then
			local hunter = RoundService.hunterId()
			local bot = hunter and bots[hunter]
			if bot then
				bot.model:PivotTo(MapService.huntStart())
			end
		elseif to == "Intermission" or to == "Waiting" then
			despawnAll()
		end
	end)

	RoundService.eliminated:connect(function(id)
		local bot = bots[id]
		if bot then
			-- A caught bot leaves the arena; its id stays registered until the round ends.
			bot.model:PivotTo(MapService.lobbySpawn(-id))
		end
	end)

	Players.PlayerRemoving:Connect(function()
		-- Practice bots exist only for a lone player; nothing to keep once they leave.
		if #Players:GetPlayers() <= 1 then
			despawnAll()
		end
	end)
end

return BotService
