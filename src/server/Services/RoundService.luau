--!strict
--[[
	RoundService runs the pure RoundMachine and turns its events into side effects in the world.

	  Heartbeat ──► machine:update(dt) ──► flush() ──► per-event handlers
	  Players     ──► addPlayer / removePlayer ──► flush()
	  Tag/Died    ──► machine:tag / eliminate ──► flush()

	Replicated state, for clients to render:
	  ReplicatedStorage.RoundState attributes: Phase, EndsAt (server time), Round, Solo, HunterId,
	                                           BuildersAlive, BuildersTotal
	  Player attributes:                       Role ("Builder" | "Hunter" | "Spectator"), Alive

	Other services subscribe to the Signals below instead of being called from here, which keeps
	the dependency graph one-way (Round -> Map/Data/Net; Build/Hunter/Bot -> Round).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Cleanup = require(Shared.Util.Cleanup)
local Config = require(Shared.Config)
local Log = require(Shared.Util.Log)
local Signal = require(Shared.Util.Signal)
local Types = require(Shared.Types)

local Services = script.Parent
local MapService = require(Services.MapService)
local NetService = require(Services.NetService)

local RoundMachine = require(script.Parent.Parent.Round.RoundMachine)

type Event = RoundMachine.Event

local RoundService = {}

RoundService.phaseChanged = Signal.new() :: Signal.Signal<Types.Phase, Types.Phase, number>
-- (hunterId, builderIds, botIds, solo)
RoundService.rolesAssigned = Signal.new() :: Signal.Signal<number, { number }, { number }, boolean>
-- (id, byId?, reason)
RoundService.eliminated = Signal.new() :: Signal.Signal<number, number?, string>
export type RoundOutcome = {
	round: number,
	winner: Types.Winner,
	reason: string,
	hunter: number?,
	builders: { number },
	survivors: { number },
	tags: { [number]: number },
	bots: { number },
}

RoundService.roundEnded = Signal.new() :: Signal.Signal<RoundOutcome>

local soloAllowed = if RunService:IsStudio() then Config.Solo.EnabledInStudio else Config.Solo.EnabledLive

local machine = RoundMachine.new({
	timings = Config.Timings,
	soloTimings = Config.SoloTimings,
	minPlayers = Config.MinPlayers,
	soloAllowed = soloAllowed,
	botBuilderCount = Config.Solo.BotBuilderCount,
})

local stateFolder: Folder
local flush: () -> ()
local playerCleanups: { [Player]: Cleanup.Cleanup } = {}
local characterCleanups: { [Player]: Cleanup.Cleanup } = {}
local spawnIndex = 0

local function setState(name: string, value: any)
	stateFolder:SetAttribute(name, value)
end

local function countBuilders(): (number, number)
	local snapshot = machine:snapshot()
	local alive = 0
	for _, id in snapshot.builders do
		if machine:isAlive(id) then
			alive += 1
		end
	end
	return alive, #snapshot.builders
end

local function refreshBuilderCounts()
	local alive, total = countBuilders()
	setState("BuildersAlive", alive)
	setState("BuildersTotal", total)
end

local function applyCollisionGroup(character: Model, group: string)
	for _, descendant in character:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.CollisionGroup = group
		end
	end
end

-- Puts a character where its current role belongs. Called on spawn and on every role/phase change.
local function placeCharacter(player: Player)
	local character = player.Character
	if not character then
		return
	end
	local id = player.UserId
	local role = machine:getRole(id)
	local alive = machine:isAlive(id)
	local phase = machine.phase

	applyCollisionGroup(
		character,
		if role == "Builder" and alive then MapService.Groups.Builders else "Default"
	)

	spawnIndex += 1
	if role == "Builder" and alive and (phase == "Build" or phase == "Hunt") then
		MapService.teleport(character, MapService.builderSpawn(spawnIndex))
	elseif role == "Hunter" and phase == "Build" then
		MapService.teleport(character, MapService.cageSpawn())
	elseif role == "Hunter" and phase == "Hunt" then
		MapService.teleport(character, MapService.huntStart())
	else
		MapService.teleport(character, MapService.lobbySpawn(spawnIndex))
	end
end

local function setPlayerRole(player: Player)
	player:SetAttribute("Role", machine:getRole(player.UserId))
	player:SetAttribute("Alive", machine:isAlive(player.UserId))
end

local function onPhaseChanged(from: Types.Phase, to: Types.Phase, duration: number)
	setState("Phase", to)
	setState("EndsAt", workspace:GetServerTimeNow() + duration)
	setState("Round", machine.round)
	setState("Solo", machine.solo)
	Log.info("Round", string.format("%s -> %s (%ds)", from, to, duration))

	if to == "Build" then
		MapService.setCageOpen(false)
	elseif to == "Hunt" then
		MapService.setCageOpen(true)
		local hunter = machine:hunterId()
		local player = if hunter and hunter > 0 then Players:GetPlayerByUserId(hunter) else nil
		if player then
			placeCharacter(player)
		end
		NetService.notifyAll("warn", "The hunt is on!")
	elseif to == "Intermission" or to == "Waiting" then
		setState("HunterId", 0)
		for _, player in Players:GetPlayers() do
			setPlayerRole(player)
			if from == "Results" then
				placeCharacter(player)
			end
		end
		refreshBuilderCounts()
	end

	RoundService.phaseChanged:fire(from, to, duration)
end

local function onRolesAssigned(event: Event)
	assert(event.type == "RolesAssigned", "expected a RolesAssigned event")
	setState("HunterId", event.hunter)
	refreshBuilderCounts()
	for _, player in Players:GetPlayers() do
		setPlayerRole(player)
		placeCharacter(player)
	end
	RoundService.rolesAssigned:fire(event.hunter, event.builders, event.bots, event.solo)
end

local function onEliminated(event: Event)
	assert(event.type == "Eliminated", "expected an Eliminated event")
	Log.info("Round", string.format("participant %d out (%s)", event.id, event.reason))
	refreshBuilderCounts()
	local player = if event.id > 0 then Players:GetPlayerByUserId(event.id) else nil
	if player then
		setPlayerRole(player)
		if event.reason == "Tagged" then
			placeCharacter(player)
		end
	end
	if event.reason == "Tagged" then
		local name = if player then player.DisplayName else "A bot"
		NetService.notifyAll("feed", name .. " was caught!")
	end
	RoundService.eliminated:fire(event.id, event.by, event.reason)
end

local function onRoundEnded(event: Event)
	assert(event.type == "RoundEnded", "expected a RoundEnded event")
	Log.info("Round", string.format("round %d over: %s (%s)", event.round, event.winner, event.reason))
	local bots = {}
	for _, id in event.builders do
		if machine:isBot(id) then
			table.insert(bots, id)
		end
	end
	if event.hunter and machine:isBot(event.hunter) then
		table.insert(bots, event.hunter)
	end
	-- Rewards are EconomyService's job; this service only reports what happened.
	RoundService.roundEnded:fire({
		round = event.round,
		winner = event.winner,
		reason = event.reason,
		hunter = event.hunter,
		builders = event.builders,
		survivors = event.survivors,
		tags = event.tags,
		bots = bots,
	})
end

-- Applies every pending machine event. Called after anything that can mutate the machine.
-- Each event is handled in isolation: one failing side effect must not swallow the events after it.
flush = function()
	for _, event in machine:drainEvents() do
		local ok, err = pcall(function()
			if event.type == "PhaseChanged" then
				onPhaseChanged(event.from, event.to, event.duration)
			elseif event.type == "RolesAssigned" then
				onRolesAssigned(event)
			elseif event.type == "Eliminated" then
				onEliminated(event)
			elseif event.type == "RoundEnded" then
				onRoundEnded(event)
			end
		end)
		if not ok then
			Log.warn("Round", string.format("handling %s failed: %s", event.type, tostring(err)))
		end
	end
end

local function groupFor(player: Player): string
	local id = player.UserId
	return if machine:getRole(id) == "Builder" and machine:isAlive(id)
		then MapService.Groups.Builders
		else "Default"
end

local function onCharacterAdded(player: Player, character: Model)
	local previous = characterCleanups[player]
	if previous then
		previous:clean()
	end
	local cleanup = Cleanup.new()
	characterCleanups[player] = cleanup

	-- Accessories stream in after spawn; give them the same collision group as the body.
	cleanup:add(character.DescendantAdded:Connect(function(descendant)
		if descendant:IsA("BasePart") then
			descendant.CollisionGroup = groupFor(player)
		end
	end))

	local humanoid = character:WaitForChild("Humanoid", 5) :: Humanoid?
	if humanoid then
		cleanup:add(humanoid.Died:Connect(function()
			if machine:getRole(player.UserId) == "Builder" then
				machine:eliminate(player.UserId, "Died")
				flush()
			end
		end))
	end

	-- Wait (bounded) until the rig is assembled before moving it; a character destroyed while
	-- spawning must not leave this thread waiting forever.
	if not character.PrimaryPart and not character:WaitForChild("HumanoidRootPart", 5) then
		return
	end
	task.defer(placeCharacter, player)
end

local function onPlayerAdded(player: Player)
	local cleanup = Cleanup.new()
	playerCleanups[player] = cleanup
	setPlayerRole(player)
	cleanup:add(player.CharacterAdded:Connect(function(character)
		onCharacterAdded(player, character)
	end))
	if player.Character then
		task.spawn(onCharacterAdded, player, player.Character)
	end
	machine:addPlayer(player.UserId)
	flush()
end

local function onPlayerRemoving(player: Player)
	local playerCleanup = playerCleanups[player]
	if playerCleanup then
		playerCleanup:clean()
		playerCleanups[player] = nil
	end
	local characterCleanup = characterCleanups[player]
	if characterCleanup then
		characterCleanup:clean()
		characterCleanups[player] = nil
	end
	machine:removePlayer(player.UserId)
	flush()
end

function RoundService.init()
	local existing = ReplicatedStorage:FindFirstChild("RoundState")
	if existing then
		existing:Destroy()
	end
	stateFolder = Instance.new("Folder")
	stateFolder.Name = "RoundState"
	stateFolder:SetAttribute("Phase", "Waiting")
	stateFolder:SetAttribute("EndsAt", 0)
	stateFolder:SetAttribute("Round", 0)
	stateFolder:SetAttribute("Solo", false)
	stateFolder:SetAttribute("HunterId", 0)
	stateFolder:SetAttribute("BuildersAlive", 0)
	stateFolder:SetAttribute("BuildersTotal", 0)
	stateFolder:SetAttribute("MinPlayers", Config.MinPlayers)
	stateFolder:SetAttribute("SoloAllowed", soloAllowed)
	stateFolder.Parent = ReplicatedStorage
end

function RoundService.start()
	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(onPlayerRemoving)
	for _, player in Players:GetPlayers() do
		task.spawn(onPlayerAdded, player)
	end

	RunService.Heartbeat:Connect(function(dt)
		machine:update(dt)
		flush()
	end)
end

-- Queries used by other services ------------------------------------------------------------

function RoundService.getPhase(): Types.Phase
	return machine.phase
end

function RoundService.getRole(id: number): Types.Role
	return machine:getRole(id)
end

function RoundService.isAlive(id: number): boolean
	return machine:isAlive(id)
end

function RoundService.isBot(id: number): boolean
	return machine:isBot(id)
end

function RoundService.hunterId(): number?
	return machine:hunterId()
end

function RoundService.snapshot(): RoundMachine.Snapshot
	return machine:snapshot()
end

-- Mutations (already validated spatially by the caller) -------------------------------------

function RoundService.tag(hunterId: number, targetId: number): (boolean, string?)
	local ok, reason = machine:tag(hunterId, targetId)
	flush()
	return ok, reason
end

function RoundService.eliminateBot(botId: number)
	machine:eliminate(botId, "Died")
	flush()
end

function RoundService.chooseSoloRole(player: Player, role: Types.Role)
	local ok, reason = machine:setSoloRole(player.UserId, role)
	NetService.actionResult(player, "ChooseSoloRole", ok, reason)
	if ok then
		local text = if role == "Spectator"
			then "Next practice round: you watch bots play both sides"
			else "Next practice round: you play " .. role
		NetService.notify(player, "success", text)
	end
end

function RoundService.setPracticeBotCount(count: number): boolean
	return machine:setPracticeBotCount(count)
end

function RoundService.skip()
	machine:skip()
end

return RoundService
