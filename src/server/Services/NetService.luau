--!strict
--[[
	NetService creates every remote declared in Shared/Protocol and guards every client intent.

	Each client -> server event is wrapped in a RemoteGuard built from its Protocol spec
	(argument types plus a per-player token bucket). A rejected request also spends from a
	per-player "abuse budget". Rate-limit hits cost little and malformed payloads cost a lot.
	A player who drains the budget is kicked, because honest clients cannot produce malformed
	payloads.

	Handlers are bound once through `bindHandlers`, whose `Handlers` type pins the exact
	signature of each intent.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Log = require(Shared.Util.Log)
local Protocol = require(Shared.Protocol)
local Types = require(Shared.Types)
local RemoteGuard = require(ReplicatedStorage:WaitForChild("Packages"):WaitForChild("RemoteGuard"))

export type Handlers = {
	PlaceBlock: (player: Player, x: number, y: number, z: number, kind: Types.BlockKind) -> (),
	RemoveBlock: (player: Player, blockId: number) -> (),
	RepairBlock: (player: Player, blockId: number) -> (),
	Breach: (player: Player, blockId: number) -> (),
	Tag: (player: Player, targetId: number) -> (),
	UseAbility: (player: Player, ability: Types.HunterAbility) -> (),
	ChooseSoloRole: (player: Player, role: Types.Role) -> (),
	BuyItem: (player: Player, itemId: string) -> (),
	OpenCrate: (player: Player, crateId: string) -> (),
	Equip: (player: Player, slot: Types.CosmeticSlot, cosmeticId: string) -> (),
	ClaimDaily: (player: Player) -> (),
	ChooseClass: (player: Player, className: string) -> (),
}

export type NotifyKind = "info" | "warn" | "success" | "quest" | "levelup" | "feed"
export type EffectKind =
	"BlockHit"
	| "BlockBroken"
	| "Shockwave"
	| "Tag"
	| "Place"
	| "Repair"
	| "Coins"
	| "Trap"

local REJECT_WEIGHT: { [RemoteGuard.Reason]: number } = {
	RateLimited = 1,
	BadArg = 5,
	TooManyArgs = 5,
	HandlerError = 0, -- our bug, not the player's
}

local NetService = {}

local folder: Folder
local clientEvents: { [string]: RemoteEvent } = {}
local serverEvents: { [string]: RemoteEvent } = {}
local guards: { [string]: RemoteGuard.Guard } = {}
local abuse = RemoteGuard.RateLimiter.new({
	capacity = Config.Net.AbuseCapacity,
	refillPerSecond = Config.Net.AbuseRefillPerSecond,
})
local kicked: { [Player]: boolean } = setmetatable({}, { __mode = "k" }) :: any

local function onReject(player: Player, reason: RemoteGuard.Reason, detail: string)
	if reason == "HandlerError" then
		Log.warn("Net", detail)
		return
	end
	Log.debug("Net", string.format("rejected %s from %s: %s", reason, player.Name, detail))
	local weight = REJECT_WEIGHT[reason]
	if weight > 0 and not abuse:consume(player, weight) and not kicked[player] then
		kicked[player] = true
		Log.warn(
			"Net",
			string.format("kicking %s (%d): too many invalid requests", player.Name, player.UserId)
		)
		player:Kick("Too many invalid requests.")
	end
end

function NetService.init()
	local existing = ReplicatedStorage:FindFirstChild(Protocol.FolderName)
	if existing then
		existing:Destroy()
	end
	folder = Instance.new("Folder")
	folder.Name = Protocol.FolderName

	for name in Protocol.ClientToServer do
		local remote = Instance.new("RemoteEvent")
		remote.Name = name
		remote.Parent = folder
		clientEvents[name] = remote
	end
	for _, name in Protocol.ServerToClient do
		assert(not clientEvents[name], "duplicate remote name " .. name)
		local remote = Instance.new("RemoteEvent")
		remote.Name = name
		remote.Parent = folder
		serverEvents[name] = remote
		-- Server -> client only. An unconnected OnServerEvent queues every invocation, so a client
		-- firing these would grow that queue for free; listen and charge it as a malformed request.
		remote.OnServerEvent:Connect(function(player)
			onReject(player, "BadArg", name .. " is a server-to-client event")
		end)
	end

	folder.Parent = ReplicatedStorage
end

function NetService.bindHandlers(handlers: Handlers)
	local handlerMap = handlers :: any
	for name, spec in Protocol.ClientToServer do
		local handler = handlerMap[name]
		assert(type(handler) == "function", "NetService: no handler bound for " .. name)
		local guard = RemoteGuard.new({
			name = name,
			args = spec.args,
			rateLimit = spec.rateLimit,
			onReject = onReject,
		})
		guards[name] = guard
		guard:connect(clientEvents[name], handler)
	end
	for name in handlerMap do
		assert(
			(Protocol.ClientToServer :: any)[name],
			"NetService: handler for undeclared event " .. tostring(name)
		)
	end
end

function NetService.start()
	Players.PlayerRemoving:Connect(function(player)
		for _, guard in guards do
			guard:forget(player)
		end
		abuse:forget(player)
	end)
end

function NetService.notify(player: Player, kind: NotifyKind, text: string)
	serverEvents.Notify:FireClient(player, kind, text)
end

function NetService.notifyAll(kind: NotifyKind, text: string)
	serverEvents.Notify:FireAllClients(kind, text)
end

function NetService.actionResult(player: Player, action: Protocol.ClientEvent, ok: boolean, reason: string?)
	serverEvents.ActionResult:FireClient(player, action, ok, reason)
end

function NetService.roundResult(result: Types.RoundResult)
	serverEvents.RoundResult:FireAllClients(result)
end

function NetService.effect(kind: EffectKind, position: Vector3)
	serverEvents.Effect:FireAllClients(kind, position)
end

function NetService.profile(player: Player, view: { [string]: any })
	serverEvents.Profile:FireClient(player, view)
end

function NetService.crateResult(player: Player, result: { [string]: any })
	serverEvents.CrateResult:FireClient(player, result)
end

function NetService.getStats(): { [string]: RemoteGuard.Stats }
	local stats = {}
	for name, guard in guards do
		stats[name] = guard.stats
	end
	return stats
end

return NetService
