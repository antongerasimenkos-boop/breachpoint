--!strict
--[[
	EconomyService: everything coins.

	  round end     Rewards.compute → coins, wins and rounds played; RoundResult to clients
	  shop          BuyItem → Shop.purchase (permanent unlocks)
	  crates        OpenCrate → Crates.open, rolled here with a server-side Random (never on the
	                client); at most one open per CRATE_INTERVAL per player on top of the rate limit
	  cosmetics     Equip → only cosmetics the player owns, only into their own slot
	  daily         ClaimDaily → Daily.claim on the UTC day
	  lobby         small passive income for players waiting outside a round
	  profile       a snapshot of coins/unlocks/cosmetics/daily status is pushed to the owner on
	                load and after every change (batched to once per frame)

	All rules live in the pure Economy modules; this service is validation glue and Roblox I/O.
	Every purchase is paid with in-game coins. There is no Robux path.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Signal = require(Shared.Util.Signal)
local Types = require(Shared.Types)

local Economy = script.Parent.Parent.Economy
local Crates = require(Economy.Crates)
local Daily = require(Economy.Daily)
local Progression = require(Economy.Progression)
local Rewards = require(Economy.Rewards)
local Shop = require(Economy.Shop)

local Services = script.Parent
local BuildService = require(Services.BuildService)
local DataService = require(Services.DataService)
local Participants = require(Services.Participants)
local NetService = require(Services.NetService)
local RoundService = require(Services.RoundService)

local EconomyService = {}

export type Mvp = { id: number, name: string, role: string, coins: number }

-- Fires (outcome, mvps) after round rewards are paid; the lobby podium shows the MVPs.
EconomyService.roundRewarded = Signal.new() :: Signal.Signal<any, { Mvp }>

local CRATE_INTERVAL = 1.5

local rng = Random.new() -- seeded by the engine; the client never sees it
local lastCrateOpen: { [Player]: number } = {}
local pendingPush: { [Player]: boolean } = {}

local MESSAGES = {
	UnknownItem = "That item does not exist",
	AlreadyOwned = "You already own that",
	NotEnoughCoins = "Not enough coins",
	UnknownCrate = "That crate does not exist",
}

local function setToList(set: { [string]: boolean }): { string }
	local list = {}
	for id in set do
		table.insert(list, id)
	end
	table.sort(list)
	return list
end

local function profileView(data: DataService.PlayerStats): { [string]: any }
	local stats = {}
	for _, key in
		{
			"builderWins",
			"hunterWins",
			"roundsPlayed",
			"blocksPlaced",
			"blocksBroken",
			"blocksRepaired",
			"tags",
			"cratesOpened",
		}
	do
		stats[key] = (data :: any)[key]
	end
	return {
		coins = data.coins,
		owned = setToList(data.owned),
		cosmetics = setToList(data.cosmetics),
		equipped = table.clone(data.equipped),
		daily = Daily.status(Config, data.daily, Daily.today(os.time())),
		pity = table.clone(data.pity),
		stats = stats,
		progress = Progression.levelInfo(Config, data.xp),
		quests = Progression.view(Config, data.quests, Daily.today(os.time())),
	}
end

local function pushProfile(player: Player)
	if pendingPush[player] then
		return
	end
	pendingPush[player] = true
	task.defer(function()
		pendingPush[player] = nil
		local data = DataService.getStats(player)
		if data and player.Parent then
			NetService.profile(player, profileView(data))
		end
	end)
end

-- Network handlers ---------------------------------------------------------------------------

function EconomyService.onBuyItem(player: Player, itemId: string)
	local loaded, ok, err = DataService.mutate(player, function(data)
		return Shop.purchase(Config, data :: any, itemId)
	end)
	if not loaded then
		NetService.actionResult(player, "BuyItem", false, "Your data is still loading")
		return
	end
	NetService.actionResult(player, "BuyItem", ok == true, if ok then itemId else MESSAGES[err] or err)
	if ok then
		local item = Shop.find(Config, itemId)
		NetService.notify(player, "success", "Unlocked: " .. (if item then item.name else itemId))
	end
end

function EconomyService.onOpenCrate(player: Player, crateId: string)
	local now = os.clock()
	if now - (lastCrateOpen[player] or -math.huge) < CRATE_INTERVAL then
		NetService.actionResult(player, "OpenCrate", false, "Wait for the current crate")
		return
	end
	lastCrateOpen[player] = now
	local loaded, result, err = DataService.mutate(player, function(data)
		return Crates.open(Config, data :: any, crateId, function()
			return rng:NextNumber()
		end)
	end)
	if not loaded then
		NetService.actionResult(player, "OpenCrate", false, "Your data is still loading")
	elseif not result then
		NetService.actionResult(player, "OpenCrate", false, MESSAGES[err] or err)
	else
		NetService.crateResult(player, result)
		NetService.actionResult(player, "OpenCrate", true, crateId)
	end
end

function EconomyService.onEquip(player: Player, slot: Types.CosmeticSlot, cosmeticId: string)
	local loaded, ok, reason = DataService.mutate(player, function(data): (boolean, string?)
		if cosmeticId == "" then
			data.equipped[slot] = ""
			return true, nil
		end
		for _, cosmetic in Config.Cosmetics do
			if cosmetic.id == cosmeticId then
				if cosmetic.slot ~= slot then
					return false, "That does not go in this slot"
				end
				if not data.cosmetics[cosmeticId] then
					return false, "You do not own that"
				end
				data.equipped[slot] = cosmeticId
				return true, nil
			end
		end
		return false, "Unknown cosmetic"
	end)
	NetService.actionResult(
		player,
		"Equip",
		loaded and ok == true,
		if loaded then reason else "Your data is still loading"
	)
end

function EconomyService.onClaimDaily(player: Player)
	local loaded, ok, reward = DataService.mutate(player, function(data): (boolean, number)
		local claimed, coins = Daily.claim(Config, data.daily, Daily.today(os.time()))
		if claimed then
			data.coins += coins
		end
		return claimed, coins
	end)
	if loaded and ok then
		NetService.actionResult(player, "ClaimDaily", true, nil)
		NetService.notify(player, "success", string.format("Daily reward: +%d coins", reward))
	else
		NetService.actionResult(
			player,
			"ClaimDaily",
			false,
			if loaded then "Already claimed today" else "Your data is still loading"
		)
	end
end

-- Round rewards ------------------------------------------------------------------------------

local function onRoundEnded(outcome: RoundService.RoundOutcome)
	local coins = Rewards.compute(Config, {
		winner = outcome.winner,
		hunter = outcome.hunter,
		builders = outcome.builders,
		survivors = outcome.survivors,
		tags = outcome.tags,
		standingByOwner = BuildService.standingByOwner(),
	})
	local rewards: { [string]: number } = {}
	for id, amount in coins do
		local player = if id > 0 then Players:GetPlayerByUserId(id) else nil
		if not player then
			continue -- bots and players who already left
		end
		DataService.increment(player, "coins", amount)
		local _, before, after = DataService.mutate(player, function(data)
			return Progression.addXp(Config, data, amount)
		end)
		if before and after and after > before then
			player:SetAttribute("Level", after)
			NetService.notify(player, "levelup", string.format("Level up! You are now level %d", after))
			NetService.notifyAll("feed", string.format("%s reached level %d", player.DisplayName, after))
		end
		DataService.increment(player, "roundsPlayed", 1)
		if outcome.winner == "Builders" and table.find(outcome.builders, id) then
			DataService.increment(player, "builderWins", 1)
		elseif outcome.winner == "Hunter" and id == outcome.hunter then
			DataService.increment(player, "hunterWins", 1)
		end
		rewards[tostring(id)] = amount
	end
	local mvps = {}
	for _, entry in Rewards.ranking(coins, 3) do
		local character = Participants.character(entry.id)
		local player = if entry.id > 0 then Players:GetPlayerByUserId(entry.id) else nil
		table.insert(mvps, {
			id = entry.id,
			name = if player then player.DisplayName elseif character then character.Name else "?",
			role = if entry.id == outcome.hunter then "Hunter" else "Builder",
			coins = entry.coins,
		})
	end
	local standing = 0
	for _, count in BuildService.standingByOwner() do
		standing += count
	end
	local tags = 0
	for _, count in outcome.tags do
		tags += count
	end
	NetService.roundResult({
		round = outcome.round,
		winner = outcome.winner,
		reason = outcome.reason,
		hunterId = outcome.hunter,
		survivors = outcome.survivors,
		rewards = rewards,
		mvps = mvps,
		stats = { blocksStanding = standing, tags = tags, builders = #outcome.builders },
	})
	EconomyService.roundRewarded:fire(outcome, mvps)
end

-- Quests -------------------------------------------------------------------------------------

local questStats: { [string]: boolean } = {}
for _, quest in Config.Quests do
	questStats[quest.stat] = true
end

local function onIncremented(player: Player, field: string, amount: number)
	if not questStats[field] then
		return
	end
	local _, completed = DataService.mutate(player, function(data)
		return Progression.record(Config, data :: any, Daily.today(os.time()), field, amount)
	end)
	for _, quest in completed or {} do
		NetService.notify(
			player,
			"quest",
			string.format("Quest complete: %s  +%d coins", quest.text, quest.reward)
		)
	end
end

-- Lifecycle ----------------------------------------------------------------------------------

function EconomyService.init() end

function EconomyService.start()
	DataService.loaded:connect(function(player, data)
		player:SetAttribute("Level", Progression.levelInfo(Config, data.xp).level)
		pushProfile(player)
	end)
	DataService.incremented:connect(onIncremented)
	DataService.changed:connect(pushProfile)
	RoundService.roundEnded:connect(onRoundEnded)

	-- Lobby income: players waiting outside a round earn a little.
	task.spawn(function()
		while true do
			task.wait(Config.Rewards.LobbyIncomeInterval)
			for _, player in Players:GetPlayers() do
				if player:GetAttribute("Role") == "Spectator" then
					DataService.increment(player, "coins", Config.Rewards.LobbyIncome)
				end
			end
		end
	end)

	Players.PlayerRemoving:Connect(function(player)
		lastCrateOpen[player] = nil
		pendingPush[player] = nil
	end)
end

-- Debug: what the client would receive.
function EconomyService.debugProfile(player: Player): { [string]: any }?
	local data = DataService.getStats(player)
	return data and profileView(data)
end

return EconomyService
