--!strict
local RemoteGuard = require("../src")
local t = RemoteGuard.t

return function(kit: any)
	local describe, it, expect = kit.describe, kit.it, kit.expect

	local function newPlayer(id: number)
		return { UserId = id, Name = "Player" .. id }
	end

	local function makeGuard()
		local now = 0
		local rejections = {}
		local guard = RemoteGuard.new({
			name = "PlaceBlock",
			args = { t.integer(0, 10), t.literal("Wood", "Stone") },
			rateLimit = { capacity = 2, refillPerSecond = 1 },
			clock = function()
				return now
			end,
			onReject = function(player, reason, detail)
				table.insert(rejections, { player = player, reason = reason, detail = detail })
			end,
		})
		return guard, rejections, function(dt: number)
			now += dt
		end
	end

	describe("RemoteGuard", function()
		it("calls the handler with validated arguments", function()
			local guard = makeGuard()
			local received = {}
			local handler = guard:wrap(function(player, x, kind)
				table.insert(received, { player.UserId, x, kind })
			end)
			handler(newPlayer(1), 3, "Wood")
			expect(received).toEqual({ { 1, 3, "Wood" } })
			expect(guard.stats.accepted).toBe(1)
		end)

		it("rejects bad argument types and reports which argument", function()
			local guard, rejections = makeGuard()
			local called = false
			local handler = guard:wrap(function()
				called = true
			end)
			handler(newPlayer(1), 3, "Gold")
			expect(called).toBe(false)
			expect(rejections[1].reason).toBe("BadArg")
			expect(rejections[1].detail).toContain("arg #2")
		end)

		it("rejects missing arguments", function()
			local guard, rejections = makeGuard()
			guard:wrap(function() end)(newPlayer(1), 3)
			expect(rejections[1].reason).toBe("BadArg")
		end)

		it("rejects extra arguments (smuggled payloads)", function()
			local guard, rejections = makeGuard()
			guard:wrap(function() end)(newPlayer(1), 3, "Wood", { evil = true })
			expect(rejections[1].reason).toBe("TooManyArgs")
		end)

		it("rate-limits per player and recovers over time", function()
			local guard, rejections, advance = makeGuard()
			local count = 0
			local handler = guard:wrap(function()
				count += 1
			end)
			local spammer = newPlayer(1)
			local bystander = newPlayer(2)
			for _ = 1, 10 do
				handler(spammer, 1, "Wood")
			end
			handler(bystander, 1, "Wood")
			expect(count).toBe(3) -- 2 from the spammer's burst + 1 from the bystander
			expect(#rejections).toBe(8)
			expect(rejections[1].reason).toBe("RateLimited")
			advance(1)
			handler(spammer, 1, "Wood")
			expect(count).toBe(4)
		end)

		it("spends a token on invalid requests too", function()
			local guard, rejections = makeGuard()
			local handler = guard:wrap(function() end)
			local p = newPlayer(1)
			handler(p, "garbage", "Wood")
			handler(p, "garbage", "Wood")
			handler(p, 1, "Wood")
			expect(rejections[3].reason).toBe("RateLimited")
		end)

		it("isolates handler errors and reports them", function()
			local guard, rejections = makeGuard()
			local handler = guard:wrap(function()
				error("boom")
			end)
			handler(newPlayer(1), 1, "Wood")
			expect(rejections[1].reason).toBe("HandlerError")
			expect(rejections[1].detail).toContain("boom")
		end)

		it("returns handler results for RemoteFunction-style use", function()
			local guard = makeGuard()
			local handler = guard:wrap(function(_, x)
				return x * 2, "ok"
			end)
			local a, b = handler(newPlayer(1), 4, "Stone")
			expect(a).toBe(8)
			expect(b).toBe("ok")
		end)

		it("can share one limiter between guards", function()
			local now = 0
			local shared = RemoteGuard.RateLimiter.new({
				capacity = 1,
				refillPerSecond = 0,
				clock = function()
					return now
				end,
			})
			local a = RemoteGuard.new({ name = "A", args = {}, limiter = shared })
			local b = RemoteGuard.new({ name = "B", args = {}, limiter = shared })
			local p = newPlayer(1)
			expect((a:check(p))).toBe(true)
			expect((b:check(p))).toBe(false)
		end)

		it("forget() clears a player's rate-limit state", function()
			local guard = makeGuard()
			local p = newPlayer(1)
			guard:check(p, 1, "Wood")
			guard:check(p, 1, "Wood")
			expect((guard:check(p, 1, "Wood"))).toBe(false)
			guard:forget(p)
			expect((guard:check(p, 1, "Wood"))).toBe(true)
		end)
	end)
end
