--!strict
--[[
	HunterService: the hunter's actions, all validated against server state.

	  Breach    one block in range           phase, role, block exists, range, cooldown
	  Tag       one builder in range         phase, role, target alive, range, line of sight, cooldown
	  Shockwave every block around the hunter phase, role, cooldown
	  Sprint    temporary speed boost        phase, role, cooldown

	Distances use the server's view of positions plus a small `Config.RangeLeeway` for latency.
	Cooldowns are consumed last, so a rejected request never burns the ability.
	The practice bot hunter calls the same `try*` functions as a human hunter.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Types = require(Shared.Types)

local Services = script.Parent
local BuildService = require(Services.BuildService)
local Cooldowns = require(script.Parent.Parent.Gameplay.Cooldowns)
local DataService = require(Services.DataService)
local NetService = require(Services.NetService)
local Participants = require(Services.Participants)
local RoundService = require(Services.RoundService)

local HunterService = {}

local cooldowns = Cooldowns.new()
-- Set when roles are assigned: hunter damage scales with the team size (Config.Hunter.DamageByBuilders)
-- and the Heavy Hitter upgrade; Bloodhound shortens the Shockwave cooldown.
local damageMultiplier = 1
local shockwaveCooldown = Config.Hunter.Shockwave.Cooldown
-- Movement modifiers, combined by applySpeed so sprint and trap slows never fight each other.
local sprintUntil: { [number]: number } = {}
local slowUntil: { [number]: number } = {}
local HALF_DIAGONAL = Config.Grid.CellSize * math.sqrt(3) / 2

local function isActiveHunter(id: number): boolean
	return RoundService.getPhase() == "Hunt"
		and RoundService.getRole(id) == "Hunter"
		and RoundService.isAlive(id)
end

local function rewardBreak(hunterId: number, kind: string?)
	local player = if hunterId > 0 then Players:GetPlayerByUserId(hunterId) else nil
	if player then
		DataService.increment(player, "blocksBroken", 1)
		local coins = Config.Rewards.PerBlockBroken
		if kind == "Generator" then
			coins += Config.Rewards.GeneratorBroken
		end
		DataService.increment(player, "coins", coins)
	end
end

-- WalkSpeed = hunter base × sprint × slow, or the default once the hunt is over.
local function applySpeed(hunterId: number)
	local humanoid = Participants.humanoid(hunterId)
	if not humanoid then
		return
	end
	if not isActiveHunter(hunterId) then
		humanoid.WalkSpeed = Config.DefaultWalkSpeed
		return
	end
	local now = os.clock()
	local speed = Config.Hunter.WalkSpeed
	if (sprintUntil[hunterId] or 0) > now then
		speed *= Config.Hunter.Sprint.Multiplier
	end
	if (slowUntil[hunterId] or 0) > now then
		speed *= Config.Trap.SlowMultiplier
	end
	humanoid.WalkSpeed = speed
end

-- True if nothing solid stands between the two characters, checked body-to-body and
-- head-to-head: a builder fully walled in is safe, but a gap at either height exposes them.
local function hasLineOfSight(from: Model, to: Model, fromRoot: BasePart, toRoot: BasePart): boolean
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { from, to }
	for _, height in { 0, 1.5 } do
		local offset = Vector3.new(0, height, 0)
		local origin = fromRoot.Position + offset
		if workspace:Raycast(origin, toRoot.Position + offset - origin, params) == nil then
			return true
		end
	end
	return false
end

function HunterService.tryBreach(hunterId: number, blockId: number): (boolean, string?)
	if not isActiveHunter(hunterId) then
		return false, "Only the hunter can breach, during the hunt"
	end
	local root = Participants.root(hunterId)
	local center = BuildService.blockCenter(blockId)
	if not root or not center then
		return false, "That block is gone"
	end
	local reach = Config.Hunter.Breach.Range + HALF_DIAGONAL + Config.RangeLeeway
	if (root.Position - center).Magnitude > reach then
		return false, "Too far away"
	end
	if not cooldowns:use(hunterId, "Breach", Config.Hunter.Breach.Cooldown) then
		return false, "Cooling down"
	end
	local _, destroyed, kind =
		BuildService.damageBlock(blockId, Config.Hunter.Breach.Damage * damageMultiplier, true)
	if destroyed then
		rewardBreak(hunterId, kind)
	end
	return true, nil
end

function HunterService.tryTag(hunterId: number, targetId: number): (boolean, string?)
	if not isActiveHunter(hunterId) then
		return false, "Only the hunter can tag, during the hunt"
	end
	if RoundService.getRole(targetId) ~= "Builder" or not RoundService.isAlive(targetId) then
		return false, "Not a valid target"
	end
	local hunter, target = Participants.character(hunterId), Participants.character(targetId)
	local hunterRoot, targetRoot = Participants.root(hunterId), Participants.root(targetId)
	if not (hunter and target and hunterRoot and targetRoot) then
		return false, "Target not found"
	end
	if
		(hunterRoot.Position - targetRoot.Position).Magnitude
		> Config.Hunter.Tag.Range + Config.RangeLeeway
	then
		return false, "Too far away"
	end
	if not hasLineOfSight(hunter, target, hunterRoot, targetRoot) then
		return false, "Something is in the way"
	end
	if not cooldowns:use(hunterId, "Tag", Config.Hunter.Tag.Cooldown) then
		return false, "Cooling down"
	end
	local position = targetRoot.Position
	-- A Shield power-up absorbs one tag.
	local targetPlayer = if targetId > 0 then Players:GetPlayerByUserId(targetId) else nil
	if targetPlayer and targetPlayer:GetAttribute("Shield") then
		targetPlayer:SetAttribute("Shield", nil)
		NetService.effect("Repair", position)
		NetService.notify(targetPlayer, "success", "Your shield blocked a tag!")
		return false, "Their shield blocked the tag"
	end
	local ok, reason = RoundService.tag(hunterId, targetId)
	if ok then
		NetService.effect("Tag", position)
		local player = if hunterId > 0 then Players:GetPlayerByUserId(hunterId) else nil
		if player then
			DataService.increment(player, "tags", 1)
		end
	end
	return ok, reason
end

function HunterService.tryAbility(hunterId: number, ability: Types.HunterAbility): (boolean, string?)
	if not isActiveHunter(hunterId) then
		return false, "Only the hunter has abilities, during the hunt"
	end
	local root = Participants.root(hunterId)
	if not root then
		return false, "No character"
	end

	if ability == "Shockwave" then
		local cfg = Config.Hunter.Shockwave
		if not cooldowns:use(hunterId, "Shockwave", shockwaveCooldown) then
			return false, "Cooling down"
		end
		NetService.effect("Shockwave", root.Position)
		for _, blockId in BuildService.blocksWithin(root.Position, cfg.Radius) do
			local _, destroyed, kind = BuildService.damageBlock(blockId, cfg.Damage * damageMultiplier)
			if destroyed then
				rewardBreak(hunterId, kind)
			end
		end
		return true, nil
	elseif ability == "Sprint" then
		local cfg = Config.Hunter.Sprint
		local humanoid = Participants.humanoid(hunterId)
		if not humanoid then
			return false, "No character"
		end
		if not cooldowns:use(hunterId, "Sprint", cfg.Cooldown) then
			return false, "Cooling down"
		end
		sprintUntil[hunterId] = os.clock() + cfg.Duration
		applySpeed(hunterId)
		task.delay(cfg.Duration + 0.05, applySpeed, hunterId)
		return true, nil
	end
	return false, "Unknown ability"
end

function HunterService.damageMultiplier(): number
	return damageMultiplier
end

function HunterService.cooldownRemaining(id: number, ability: string): number
	return cooldowns:remaining(id, ability)
end

-- Network handlers ---------------------------------------------------------------------------

function HunterService.onBreach(player: Player, blockId: number)
	local ok, reason = HunterService.tryBreach(player.UserId, blockId)
	NetService.actionResult(player, "Breach", ok, reason)
end

function HunterService.onTag(player: Player, targetId: number)
	local ok, reason = HunterService.tryTag(player.UserId, targetId)
	NetService.actionResult(player, "Tag", ok, reason)
end

function HunterService.onUseAbility(player: Player, ability: Types.HunterAbility)
	local ok, reason = HunterService.tryAbility(player.UserId, ability)
	NetService.actionResult(player, "UseAbility", ok, if ok then ability else reason)
end

-- Lifecycle ----------------------------------------------------------------------------------

local function setHunterSpeed(speed: number)
	local hunter = RoundService.hunterId()
	local humanoid = hunter and Participants.humanoid(hunter)
	if humanoid then
		humanoid.WalkSpeed = speed
	end
end

function HunterService.init() end

function HunterService.start()
	RoundService.rolesAssigned:connect(function(hunter, builders)
		damageMultiplier = Config.hunterDamageMultiplier(#builders)
		shockwaveCooldown = Config.Hunter.Shockwave.Cooldown
		sprintUntil, slowUntil = {}, {}
		local player = if hunter > 0 then Players:GetPlayerByUserId(hunter) else nil
		if player then
			if DataService.owns(player, "HeavyHitter") then
				damageMultiplier *= 1 + Config.Perks.HeavyHitterDamage
			end
			if DataService.owns(player, "Bloodhound") then
				shockwaveCooldown -= Config.Perks.BloodhoundShockwaveReduction
			end
		end
	end)
	RoundService.phaseChanged:connect(function(_from, to)
		if to == "Hunt" then
			cooldowns:clear()
			setHunterSpeed(Config.Hunter.WalkSpeed)
		elseif to == "Results" then
			setHunterSpeed(Config.DefaultWalkSpeed)
		end
	end)
	BuildService.trapTriggered:connect(function(hunterId)
		slowUntil[hunterId] = os.clock() + Config.Trap.SlowDuration
		applySpeed(hunterId)
		task.delay(Config.Trap.SlowDuration + 0.05, applySpeed, hunterId)
	end)
	-- A hunter who respawns mid-hunt gets the hunter speed back.
	local characterConnections: { [Player]: RBXScriptConnection } = {}
	local function watch(player: Player)
		characterConnections[player] = player.CharacterAdded:Connect(function(character)
			if isActiveHunter(player.UserId) then
				local humanoid = character:WaitForChild("Humanoid", 5) :: Humanoid?
				if humanoid then
					humanoid.WalkSpeed = Config.Hunter.WalkSpeed
				end
			end
		end)
	end
	Players.PlayerAdded:Connect(watch)
	for _, player in Players:GetPlayers() do
		watch(player)
	end
	Players.PlayerRemoving:Connect(function(player)
		cooldowns:clear(player.UserId)
		local connection = characterConnections[player]
		if connection then
			connection:Disconnect()
			characterConnections[player] = nil
		end
	end)
end

return HunterService
