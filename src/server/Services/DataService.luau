--!strict
--[[
	DataService owns every player's persistent session (see Data/SessionStore for the locking rules).

	Lifecycle per player:
	  PlayerAdded     -> wait for any in-flight release of the same user on this server
	                  -> SessionStore:load (lock + migrate)
	                  -> if the player already left while we were loading, release immediately
	                  -> leaderstats + `loaded` signal
	  every N seconds -> autosave (refreshes the lock); a lost session kicks the player
	  PlayerRemoving  -> final save + release (serialised behind any autosave in flight)
	  BindToClose     -> release every session in parallel, bounded by a deadline

	Backing store: the real DataStore on live servers. In Studio, when DataStores are unavailable
	(unpublished place / API access off), it falls back to MemoryDataStore and says so in the
	output. Progress then lasts only for the play session.
]]

local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Log = require(Shared.Util.Log)
local Signal = require(Shared.Util.Signal)

local Data = script.Parent.Parent.Data
local MemoryDataStore = require(Data.MemoryDataStore)
local Migrations = require(Data.Migrations)
local SessionStore = require(Data.SessionStore)

export type StatField =
	"coins"
	| "builderWins"
	| "hunterWins"
	| "roundsPlayed"
	| "blocksPlaced"
	| "blocksBroken"
	| "blocksRepaired"
	| "tags"
	| "cratesOpened"
export type PlayerStats = Migrations.PlayerStats

type Entry = {
	player: Player,
	session: SessionStore.Session,
	busy: boolean, -- a save is in flight; saves for one player are serialised
	nextAutosave: number,
	leaderstats: Folder,
}

local DataService = {}

-- Fires (player, stats) once a player's data is ready.
DataService.loaded = Signal.new() :: Signal.Signal<Player, PlayerStats>
-- Fires (player) after any change to a loaded player's data (coins, unlocks, cosmetics...).
DataService.changed = Signal.new() :: Signal.Signal<Player>
-- Fires (player, field, amount) after a counter grows, so systems like quests can follow stats.
DataService.incremented = Signal.new() :: Signal.Signal<Player, StatField, number>

DataService.backend = "none" :: "DataStore" | "Memory" | "none"

local sessionStore: SessionStore.SessionStore
local entries: { [Player]: Entry } = {}
local releasing: { [number]: boolean } = {} -- userId -> release in flight on this server
local closing = false

local function keyFor(userId: number): string
	return Config.Data.KeyPrefix .. tostring(userId)
end

local function chooseStore(): SessionStore.DataStoreLike
	local ok, storeOrErr = pcall(function()
		local store = DataStoreService:GetDataStore(Config.Data.StoreName)
		-- GetDataStore can succeed in Studio while every request fails, so probe once.
		store:GetAsync("__probe")
		return store
	end)
	if ok then
		DataService.backend = "DataStore"
		return storeOrErr :: any
	end
	if RunService:IsStudio() then
		DataService.backend = "Memory"
		Log.info(
			"Data",
			"NOTICE: DataStores are unavailable in this Studio session ("
				.. tostring(storeOrErr)
				.. "). Using an in-memory store; progress will NOT persist after you stop playing."
		)
		return MemoryDataStore.new() :: any
	end
	-- Live server: never silently drop to memory. Use the real store and let retries/kicks handle it.
	Log.warn("Data", "DataStore probe failed on a live server: " .. tostring(storeOrErr))
	DataService.backend = "DataStore"
	return DataStoreService:GetDataStore(Config.Data.StoreName) :: any
end

local function buildLeaderstats(player: Player, stats: PlayerStats): Folder
	local folder = Instance.new("Folder")
	folder.Name = "leaderstats"
	local coins = Instance.new("IntValue")
	coins.Name = "Coins"
	coins.Value = stats.coins
	coins.Parent = folder
	local wins = Instance.new("IntValue")
	wins.Name = "Wins"
	wins.Value = stats.builderWins + stats.hunterWins
	wins.Parent = folder
	folder.Parent = player
	return folder
end

local function refreshLeaderstats(entry: Entry)
	local stats = entry.session.data
	local coins = entry.leaderstats:FindFirstChild("Coins") :: IntValue?
	local wins = entry.leaderstats:FindFirstChild("Wins") :: IntValue?
	if coins then
		coins.Value = stats.coins
	end
	if wins then
		wins.Value = stats.builderWins + stats.hunterWins
	end
end

-- Runs `fn` with exclusive access to the entry's save slot.
local function withSaveLock(entry: Entry, fn: () -> ())
	while entry.busy do
		task.wait()
	end
	entry.busy = true
	local ok, err = pcall(fn :: any)
	entry.busy = false
	if not ok then
		Log.warn("Data", "save task failed: " .. tostring(err))
	end
end

local function saveEntry(entry: Entry, release: boolean)
	withSaveLock(entry, function()
		if entry.session.released then
			return
		end
		local ok, err = sessionStore:save(entry.session, release)
		if not ok and err == "SessionLost" and entry.player.Parent then
			entry.player:Kick("Your data was loaded on another server. Please rejoin.")
		end
	end)
end

local function releasePlayer(player: Player)
	local entry = entries[player]
	if not entry then
		return
	end
	entries[player] = nil
	releasing[player.UserId] = true
	saveEntry(entry, true)
	releasing[player.UserId] = nil
	entry.leaderstats:Destroy()
end

local function loadPlayer(player: Player)
	local userId = player.UserId
	-- Same-server rejoin: wait for our own release write to land first, or we could read
	-- the record before it and lose the last few seconds of progress.
	while releasing[userId] do
		task.wait(0.1)
	end

	local session, err = sessionStore:load(keyFor(userId), userId)
	if not session then
		if player.Parent then
			local message = if err == "SessionLocked"
				then "Your data is still in use by another server. Please rejoin in a minute."
				elseif
					err == "NewerSchema"
				then "This server is out of date. Please rejoin to get a newer server."
				else "Could not load your data right now. Please rejoin."
			player:Kick(message)
		end
		Log.warn("Data", string.format("load failed for %d: %s", userId, tostring(err)))
		return
	end

	if not player.Parent or closing then
		-- Left (or the server began shutting down) while we were loading: release, don't keep a lock.
		sessionStore:save(session, true)
		return
	end

	local entry: Entry = {
		player = player,
		session = session,
		busy = false,
		nextAutosave = os.clock() + Config.Data.AutosaveInterval,
		leaderstats = buildLeaderstats(player, session.data),
	}
	entries[player] = entry
	DataService.loaded:fire(player, Migrations.copy(session.data))
end

function DataService.init()
	local jobId = if game.JobId ~= "" then game.JobId else "studio-" .. HttpService:GenerateGUID(false)
	sessionStore = SessionStore.new({
		store = chooseStore(),
		jobId = jobId,
		placeId = game.PlaceId,
		clock = os.time,
		wait = task.wait,
		lockExpiry = Config.Data.LockExpiry,
		loadAttempts = Config.Data.LoadAttempts,
		saveAttempts = Config.Data.SaveAttempts,
		retryBaseDelay = Config.Data.RetryBaseDelay,
		log = function(message)
			Log.info("Data", message)
		end,
	})
end

function DataService.start()
	Players.PlayerAdded:Connect(function(player)
		loadPlayer(player)
	end)
	for _, player in Players:GetPlayers() do
		task.spawn(loadPlayer, player)
	end
	Players.PlayerRemoving:Connect(releasePlayer)

	-- Autosave: each entry has its own due time (staggered by join time), checked every few seconds.
	task.spawn(function()
		while not closing do
			task.wait(5)
			local now = os.clock()
			for _, entry in entries do
				if now >= entry.nextAutosave and not entry.busy then
					entry.nextAutosave = now + Config.Data.AutosaveInterval
					task.spawn(saveEntry, entry, false)
				end
			end
		end
	end)

	game:BindToClose(function()
		closing = true
		local players = {}
		for player in entries do
			table.insert(players, player)
		end
		local pending = 0
		for _, player in players do
			pending += 1
			task.spawn(function()
				releasePlayer(player)
				pending -= 1
			end)
		end
		local deadline = os.clock() + 25 -- Roblox allows ~30 s in BindToClose
		while pending > 0 and os.clock() < deadline do
			task.wait(0.1)
		end
		if pending > 0 then
			Log.warn("Data", string.format("shutdown: %d session(s) did not finish saving", pending))
		end
	end)
end

function DataService.isLoaded(player: Player): boolean
	return entries[player] ~= nil
end

-- A read-only copy of the player's stats, or nil if not loaded.
function DataService.getStats(player: Player): PlayerStats?
	local entry = entries[player]
	return if entry then Migrations.copy(entry.session.data) else nil
end

-- True if the player's data is loaded and they own the shop unlock.
function DataService.owns(player: Player, itemId: string): boolean
	local entry = entries[player]
	return entry ~= nil and entry.session.data.owned[itemId] == true
end

-- Applies `fn` to the live data (for multi-field changes such as purchases, which must be atomic:
-- `fn` must not yield). Returns `fn`'s results, or nil if the data is not loaded.
function DataService.mutate(player: Player, fn: (data: PlayerStats) -> ...any): (boolean, ...any)
	local entry = entries[player]
	if not entry or entry.session.lost then
		return false
	end
	local results = table.pack(fn(entry.session.data))
	refreshLeaderstats(entry)
	DataService.changed:fire(player)
	return true, table.unpack(results, 1, results.n)
end

-- Adds `amount` to a counter. Returns false if the player's data is not loaded.
function DataService.increment(player: Player, field: StatField, amount: number): boolean
	local entry = entries[player]
	if not entry or entry.session.lost then
		return false
	end
	assert(amount == amount and math.abs(amount) < 1e9, "invalid increment")
	local data = entry.session.data :: any
	data[field] = math.max(0, data[field] + math.floor(amount))
	refreshLeaderstats(entry)
	DataService.changed:fire(player)
	if amount >= 1 then
		DataService.incremented:fire(player, field, math.floor(amount))
	end
	return true
end

function DataService.saveNow(player: Player): boolean
	local entry = entries[player]
	if not entry then
		return false
	end
	saveEntry(entry, false)
	return not entry.session.lost
end

-- Debug helpers (reachable only through DebugService, which exists only in Studio).
function DataService.debugSnapshot(): { [string]: any }
	local out = { backend = DataService.backend, players = {} }
	for player, entry in entries do
		out.players[tostring(player.UserId)] = Migrations.copy(entry.session.data)
	end
	return out
end

-- Runs the same release -> load sequence as a same-server rejoin, without the player leaving.
function DataService.debugRejoin(player: Player): { [string]: any }
	local before = DataService.debugRawRecord(player.UserId)
	task.spawn(releasePlayer, player)
	local afterRelease = DataService.debugRawRecord(player.UserId)
	loadPlayer(player) -- waits for the in-flight release first
	return {
		lockBefore = before and before.lock ~= nil,
		lockAfterRelease = afterRelease and afterRelease.lock ~= nil,
		reloaded = entries[player] ~= nil,
		coins = entries[player] and entries[player].session.data.coins,
	}
end

function DataService.debugRawRecord(userId: number): any
	local store = (sessionStore :: any)._options.store
	return store:GetAsync(keyFor(userId))
end

return DataService
