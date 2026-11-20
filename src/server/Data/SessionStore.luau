--!strict
--[[
	Session-locked player records on top of any DataStore-like object (UpdateAsync is all it needs).

	Stored record:
		{
			version = 3,                     -- schema version of `data`
			data = { coins = ..., ... },     -- PlayerStats
			lock = { jobId, placeId, at }?,  -- which server owns the session, refreshed on every save
			savedAt = <unix seconds>,
		}

	Guarantees:
	  * One server at a time. `load` only succeeds if the record is unlocked, already locked by this
	    server, or locked by a server that has not refreshed it for `lockExpiry` seconds (a crashed
	    server never releases). A fresh foreign lock is retried with backoff. A player hopping
	    servers usually waits a few seconds for the old server's release save.
	  * Every write goes through UpdateAsync and re-checks ownership inside the transform. If
	    another server took the lock, the write is cancelled and the session is marked `lost`, so
	    a stale server can never overwrite newer progress.
	  * Records written by a newer schema are never loaded or overwritten (see Migrations).
	  * DataStore errors are retried with exponential backoff and jitter (see Retry).

	Pure Luau: the store, clock and wait function are injected, so all of this runs under Lune
	tests against MemoryDataStore.
]]

local Migrations = require("./Migrations")
local Retry = require("./Retry")

export type PlayerStats = Migrations.PlayerStats

export type Lock = { jobId: string, placeId: number, at: number }

export type Record = {
	version: number,
	data: { [string]: any },
	lock: Lock?,
	savedAt: number?,
}

export type DataStoreLike = {
	UpdateAsync: (self: any, key: string, transform: (any, any) -> ...any) -> ...any,
}

export type Options = {
	store: DataStoreLike,
	jobId: string,
	placeId: number,
	clock: () -> number, -- unix seconds; must agree across servers (os.time)
	wait: (seconds: number) -> (),
	lockExpiry: number,
	loadAttempts: number,
	saveAttempts: number,
	retryBaseDelay: number,
	random: (() -> number)?,
	log: ((message: string) -> ())?,
}

export type Session = {
	key: string,
	userId: number?,
	data: PlayerStats,
	lost: boolean,
	released: boolean,
	tookOverStaleLock: boolean,
}

export type LoadError = "SessionLocked" | "NewerSchema" | "StoreUnavailable"
export type SaveError = "SessionLost" | "StoreUnavailable" | "AlreadyReleased"

export type SessionStore = {
	load: (self: SessionStore, key: string, userId: number?) -> (Session?, LoadError?),
	save: (self: SessionStore, session: Session, release: boolean?) -> (boolean, SaveError?),
	_options: Options,
	_log: (self: SessionStore, message: string) -> (),
}

local SessionStore = {}
SessionStore.__index = SessionStore

function SessionStore.new(options: Options): SessionStore
	local self = setmetatable({ _options = options }, SessionStore)
	return self :: any
end

function SessionStore._log(self: SessionStore, message: string)
	if self._options.log then
		self._options.log(message)
	end
end

local function retryOptions(options: Options, attempts: number): Retry.Options
	return {
		attempts = attempts,
		baseDelay = options.retryBaseDelay,
		maxDelay = 16,
		wait = options.wait,
		random = options.random,
	}
end

function SessionStore.load(self: SessionStore, key: string, userId: number?): (Session?, LoadError?)
	local options = self._options
	local attemptsLeft = options.loadAttempts
	local attempt = 0

	while attemptsLeft > 0 do
		attemptsLeft -= 1
		attempt += 1

		-- Set inside the transform; UpdateAsync may call it more than once, so only the last call counts.
		local outcome: "ok" | "locked" | "newer" | nil = nil
		local loaded: PlayerStats? = nil
		local tookOver = false
		local holder: Lock? = nil

		local ok, err = pcall(function()
			options.store:UpdateAsync(key, function(old: Record?)
				local now = options.clock()
				local record: Record = old
					or { version = Migrations.CURRENT_VERSION, data = Migrations.template() }

				local lock = record.lock
				if lock and lock.jobId ~= options.jobId and now - lock.at < options.lockExpiry then
					outcome, holder = "locked", lock
					return nil -- cancel: someone else owns this session
				end

				local data, migrateErr = Migrations.migrate(record.data, record.version)
				if not data then
					outcome = "newer"
					self:_log(string.format("refusing %s: %s", key, tostring(migrateErr)))
					return nil
				end

				tookOver = lock ~= nil and lock.jobId ~= options.jobId
				outcome, loaded = "ok", data
				local newRecord: Record = {
					version = Migrations.CURRENT_VERSION,
					data = data,
					lock = { jobId = options.jobId, placeId = options.placeId, at = now },
					savedAt = record.savedAt,
				}
				return newRecord, if userId then { userId } else nil
			end)
		end)

		if ok and outcome == "ok" and loaded then
			if tookOver then
				self:_log(string.format("%s: took over a stale session lock", key))
			end
			return {
				key = key,
				userId = userId,
				data = loaded,
				lost = false,
				released = false,
				tookOverStaleLock = tookOver,
			},
				nil
		elseif ok and outcome == "newer" then
			return nil, "NewerSchema"
		end

		if attemptsLeft == 0 then
			return nil, if ok and outcome == "locked" then "SessionLocked" else "StoreUnavailable"
		end

		local delay = Retry.delayFor(attempt, retryOptions(options, options.loadAttempts))
		if not ok then
			self:_log(string.format("load %s failed (%s), retrying in %.1fs", key, tostring(err), delay))
		else
			self:_log(
				string.format(
					"load %s: locked by job %s, retrying in %.1fs",
					key,
					holder and holder.jobId or "?",
					delay
				)
			)
		end
		options.wait(delay)
	end

	return nil, "StoreUnavailable"
end

-- Writes the session's data. With `release`, also clears the lock so another server can load it.
function SessionStore.save(self: SessionStore, session: Session, release: boolean?): (boolean, SaveError?)
	local options = self._options
	if session.released then
		return false, "AlreadyReleased"
	end
	if session.lost then
		return false, "SessionLost"
	end

	local lostOwnership = false
	local ok, err = Retry.run(function()
		options.store:UpdateAsync(session.key, function(old: Record?)
			lostOwnership = false
			local now = options.clock()
			if old then
				local lock = old.lock
				if (lock and lock.jobId ~= options.jobId) or old.version > Migrations.CURRENT_VERSION then
					lostOwnership = true
					return nil
				end
			end
			local record: Record = {
				version = Migrations.CURRENT_VERSION,
				data = Migrations.copy(session.data) :: any,
				lock = if release
					then nil
					else { jobId = options.jobId, placeId = options.placeId, at = now },
				savedAt = now,
			}
			return record, if session.userId then { session.userId } else nil
		end)
	end, retryOptions(options, options.saveAttempts))

	if not ok then
		self:_log(string.format("save %s failed after retries: %s", session.key, tostring(err)))
		return false, "StoreUnavailable"
	end
	if lostOwnership then
		session.lost = true
		self:_log(string.format("save %s cancelled: session is owned by another server", session.key))
		return false, "SessionLost"
	end
	if release then
		session.released = true
	end
	return true, nil
end

return SessionStore
