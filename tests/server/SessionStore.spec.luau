--!strict
local MemoryDataStore = require("../../src/server/Data/MemoryDataStore")
local Migrations = require("../../src/server/Data/Migrations")
local SessionStore = require("../../src/server/Data/SessionStore")

return function(kit: any)
	local describe, it, expect = kit.describe, kit.it, kit.expect

	-- Two "servers" sharing one store and one wall clock.
	local function world()
		local w = {
			now = 1_000_000,
			store = MemoryDataStore.new(),
			waits = {} :: { number },
			onWait = nil :: ((number) -> ())?,
		}
		function w.server(jobId: string, overrides: { [string]: any }?)
			local options: { [string]: any } = {
				store = w.store,
				jobId = jobId,
				placeId = 1,
				clock = function()
					return w.now
				end,
				wait = function(seconds: number)
					table.insert(w.waits, seconds)
					w.now += seconds
					if w.onWait then
						w.onWait(seconds)
					end
				end,
				lockExpiry = 300,
				loadAttempts = 4,
				saveAttempts = 3,
				retryBaseDelay = 1,
				random = function()
					return 0
				end,
			}
			for k, v in overrides or {} do
				options[k] = v
			end
			return SessionStore.new(options :: any)
		end
		return w
	end

	describe("SessionStore.load", function()
		it("creates a fresh record with the template and takes the lock", function()
			local w = world()
			local a = w.server("A")
			local session = a:load("player_1", 1)
			expect(session).toBeTruthy()
			expect((session :: any).data).toEqual(Migrations.template())
			local stored = w.store:GetAsync("player_1")
			expect(stored.version).toBe(Migrations.CURRENT_VERSION)
			expect(stored.lock.jobId).toBe("A")
			expect(w.store.lastUserIds["player_1"]).toEqual({ 1 })
		end)

		it("refuses a session freshly locked by another server, after backing off", function()
			local w = world()
			w.server("A"):load("player_1")
			local session, err = w.server("B"):load("player_1")
			expect(session).toBeNil()
			expect(err).toBe("SessionLocked")
			expect(#w.waits).toBe(3) -- 4 attempts, 3 waits
			expect(w.waits).toEqual({ 1, 2, 4 }) -- exponential backoff (jitter pinned to 0)
		end)

		it("loads as soon as the other server releases while we wait", function()
			local w = world()
			local a = w.server("A")
			local aSession = a:load("player_1") :: any
			aSession.data.coins = 77
			w.onWait = function()
				if not aSession.released then
					a:save(aSession, true)
				end
			end
			local bSession = w.server("B"):load("player_1")
			expect(bSession).toBeTruthy()
			expect((bSession :: any).data.coins).toBe(77)
			expect(#w.waits).toBe(1)
		end)

		it("takes over a stale lock left by a crashed server", function()
			local w = world()
			w.server("A"):load("player_1")
			w.now += 301 -- server A never refreshed or released its lock
			local session = w.server("B"):load("player_1")
			expect(session).toBeTruthy()
			expect((session :: any).tookOverStaleLock).toBe(true)
			expect(w.store:GetAsync("player_1").lock.jobId).toBe("B")
		end)

		it("reloads immediately when this server already holds the lock (fast rejoin)", function()
			local w = world()
			local a = w.server("A")
			a:load("player_1")
			local again = a:load("player_1")
			expect(again).toBeTruthy()
			expect(#w.waits).toBe(0)
		end)

		it("retries DataStore errors and succeeds", function()
			local w = world()
			w.store:failNext(2)
			local session = w.server("A"):load("player_1")
			expect(session).toBeTruthy()
			expect(#w.waits).toBe(2)
		end)

		it("gives up with StoreUnavailable when every attempt errors", function()
			local w = world()
			w.store:failNext(100)
			local session, err = w.server("A"):load("player_1")
			expect(session).toBeNil()
			expect(err).toBe("StoreUnavailable")
		end)

		it("migrates an old record on load and stores it at the current version", function()
			local w = world()
			w.store:SetAsync("player_1", { version = 1, data = { coins = 5, wins = 2 } })
			local session = w.server("A"):load("player_1") :: any
			expect(session.data.coins).toBe(5)
			expect(session.data.builderWins).toBe(2)
			expect(session.data.blocksPlaced).toBe(0)
			expect(w.store:GetAsync("player_1").version).toBe(Migrations.CURRENT_VERSION)
		end)

		it("never loads or overwrites data from a newer schema", function()
			local w = world()
			local future = { version = 99, data = { coins = 1000, newField = true } }
			w.store:SetAsync("player_1", future)
			local writesBefore = w.store.writes
			local session, err = w.server("A"):load("player_1")
			expect(session).toBeNil()
			expect(err).toBe("NewerSchema")
			expect(w.store.writes).toBe(writesBefore)
			expect(w.store:GetAsync("player_1")).toEqual(future)
		end)
	end)

	describe("SessionStore.save", function()
		it("persists data and refreshes the lock timestamp", function()
			local w = world()
			local a = w.server("A")
			local session = a:load("player_1") :: any
			w.now += 60
			session.data.coins = 42
			expect((a:save(session))).toBe(true)
			local stored = w.store:GetAsync("player_1")
			expect(stored.data.coins).toBe(42)
			expect(stored.lock.at).toBe(w.now)
			expect(stored.savedAt).toBe(w.now)
		end)

		it("release clears the lock so another server can load instantly", function()
			local w = world()
			local a = w.server("A")
			local session = a:load("player_1") :: any
			expect((a:save(session, true))).toBe(true)
			expect(w.store:GetAsync("player_1").lock).toBeNil()
			expect(w.server("B"):load("player_1")).toBeTruthy()
			expect(#w.waits).toBe(0)
		end)

		it("refuses to save after release", function()
			local w = world()
			local a = w.server("A")
			local session = a:load("player_1") :: any
			a:save(session, true)
			local ok, err = a:save(session)
			expect(ok).toBe(false)
			expect(err).toBe("AlreadyReleased")
		end)

		it("marks the session lost instead of overwriting a newer owner's data", function()
			local w = world()
			local a = w.server("A")
			local aSession = a:load("player_1") :: any
			w.now += 301
			local bSession = w.server("B"):load("player_1") :: any
			bSession.data.coins = 500
			w.server("B"):save(bSession)

			aSession.data.coins = 1 -- stale server keeps playing with old data
			local ok, err = a:save(aSession)
			expect(ok).toBe(false)
			expect(err).toBe("SessionLost")
			expect(aSession.lost).toBe(true)
			expect(w.store:GetAsync("player_1").data.coins).toBe(500)
		end)

		it("retries transient errors while saving", function()
			local w = world()
			local a = w.server("A")
			local session = a:load("player_1") :: any
			session.data.coins = 9
			w.store:failNext(2)
			expect((a:save(session))).toBe(true)
			expect(w.store:GetAsync("player_1").data.coins).toBe(9)
		end)

		it("reports StoreUnavailable when saving keeps failing", function()
			local w = world()
			local a = w.server("A")
			local session = a:load("player_1") :: any
			w.store:failNext(100)
			local ok, err = a:save(session)
			expect(ok).toBe(false)
			expect(err).toBe("StoreUnavailable")
			expect(session.lost).toBe(false)
		end)

		it("does not let callers mutate stored data through the session table", function()
			local w = world()
			local a = w.server("A")
			local session = a:load("player_1") :: any
			a:save(session)
			session.data.coins = 123 -- not saved yet
			expect(w.store:GetAsync("player_1").data.coins).toBe(0)
		end)
	end)
end
