--!strict
--[[
	Server entry point. Services are plain modules with `init()` (create state; may yield for
	boot-time IO) and `start()` (connect events, spawn loops). They are listed explicitly so the
	boot order is readable rather than discovered.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Log = require(ReplicatedStorage:WaitForChild("Shared").Util.Log)

local Services = script.Parent.Services
local BotService = require(Services.BotService)
local BuildService = require(Services.BuildService)
local CosmeticsService = require(Services.CosmeticsService)
local DataService = require(Services.DataService)
local DebugService = require(Services.DebugService)
local EconomyService = require(Services.EconomyService)
local HunterService = require(Services.HunterService)
local LobbyService = require(Services.LobbyService)
local MapService = require(Services.MapService)
local NetService = require(Services.NetService)
local PowerupService = require(Services.PowerupService)
local RoundService = require(Services.RoundService)

local ordered = {
	DebugService,
	NetService,
	DataService,
	MapService,
	RoundService,
	BuildService,
	HunterService,
	BotService,
	PowerupService,
	EconomyService,
	LobbyService,
	CosmeticsService,
} :: { { init: () -> (), start: () -> () } }

for _, service in ordered do
	service.init()
end

-- Every client intent, bound to the service that owns its rules. The Handlers type checks that
-- each one exists with the right signature; NetService asserts the set matches Protocol.
NetService.bindHandlers({
	PlaceBlock = BuildService.onPlaceBlock,
	RemoveBlock = BuildService.onRemoveBlock,
	RepairBlock = BuildService.onRepairBlock,
	Breach = HunterService.onBreach,
	Tag = HunterService.onTag,
	UseAbility = HunterService.onUseAbility,
	ChooseSoloRole = RoundService.chooseSoloRole,
	BuyItem = EconomyService.onBuyItem,
	OpenCrate = EconomyService.onOpenCrate,
	Equip = EconomyService.onEquip,
	ClaimDaily = EconomyService.onClaimDaily,
	ChooseClass = BuildService.onChooseClass,
})

DebugService.register("netStats", function()
	return NetService.getStats()
end)
DebugService.register("verbose", function(on: boolean)
	Log.verbose = on
	return on
end)
DebugService.register("data", function()
	return DataService.debugSnapshot()
end)
DebugService.register("rawRecord", function(userId: number)
	return DataService.debugRawRecord(userId)
end)
DebugService.register("grant", function(userId: number, field: DataService.StatField, amount: number)
	local player = Players:GetPlayerByUserId(userId)
	return player ~= nil and DataService.increment(player, field, amount)
end)
DebugService.register("rejoin", function(userId: number)
	local player = Players:GetPlayerByUserId(userId)
	return player and DataService.debugRejoin(player)
end)
DebugService.register("save", function(userId: number)
	local player = Players:GetPlayerByUserId(userId)
	return player ~= nil and DataService.saveNow(player)
end)

DebugService.register("round", function()
	local snapshot = RoundService.snapshot() :: any
	snapshot.attributes = ReplicatedStorage:WaitForChild("RoundState"):GetAttributes()
	return snapshot
end)
DebugService.register("place", function(id: number, x: number, y: number, z: number, kind: string)
	return BuildService.tryPlace(id, { x = x, y = y, z = z }, kind :: any)
end)
DebugService.register("damageBlock", function(blockId: number, amount: number)
	return BuildService.damageBlock(blockId, amount)
end)
DebugService.register("blocks", function()
	return BuildService.blockCount()
end)
DebugService.register("profile", function(userId: number)
	local player = Players:GetPlayerByUserId(userId)
	return player and EconomyService.debugProfile(player)
end)
-- Studio only: every finished round, recorded once from the round's own outcome event, so
-- bot-vs-bot balance can be measured in the real engine.
if RunService:IsStudio() then
	local roundLog = {}
	RoundService.roundEnded:connect(function(outcome)
		table.insert(roundLog, {
			round = outcome.round,
			builders = #outcome.builders,
			winner = outcome.winner,
			reason = outcome.reason,
			allBots = #outcome.bots == #outcome.builders + (if outcome.hunter then 1 else 0),
		})
	end)
	DebugService.register("roundLog", function()
		return roundLog
	end)
end
DebugService.register("practiceBots", function(count: number)
	return RoundService.setPracticeBotCount(count)
end)
DebugService.register("powerup", function(kind: string)
	return PowerupService.debugSpawn(kind)
end)
DebugService.register("skip", function()
	RoundService.skip()
	return true
end)

for _, service in ordered do
	service.start()
end

Log.info("Breachpoint", "server ready")
