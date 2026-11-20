--!strict
local RateLimiter = require("../src/RateLimiter")

return function(kit: any)
	local describe, it, expect = kit.describe, kit.it, kit.expect

	local function fakeClock()
		local now = 0
		return function()
			return now
		end, function(dt: number)
			now += dt
		end
	end

	describe("RateLimiter", function()
		it("allows a burst up to capacity, then rejects", function()
			local clock = fakeClock()
			local limiter = RateLimiter.new({ capacity = 3, refillPerSecond = 1, clock = clock })
			local key = {}
			expect(limiter:consume(key)).toBe(true)
			expect(limiter:consume(key)).toBe(true)
			expect(limiter:consume(key)).toBe(true)
			expect(limiter:consume(key)).toBe(false)
		end)

		it("refills over time at refillPerSecond", function()
			local clock, advance = fakeClock()
			local limiter = RateLimiter.new({ capacity = 2, refillPerSecond = 4, clock = clock })
			local key = "p"
			limiter:consume(key)
			limiter:consume(key)
			expect(limiter:consume(key)).toBe(false)
			advance(0.25) -- 4/s * 0.25s = 1 token
			expect(limiter:consume(key)).toBe(true)
			expect(limiter:consume(key)).toBe(false)
		end)

		it("never refills above capacity", function()
			local clock, advance = fakeClock()
			local limiter = RateLimiter.new({ capacity = 2, refillPerSecond = 10, clock = clock })
			advance(100)
			expect(limiter:peek("k")).toBe(2)
		end)

		it("caps sustained throughput at the refill rate", function()
			local clock, advance = fakeClock()
			local limiter = RateLimiter.new({ capacity = 5, refillPerSecond = 10, clock = clock })
			local accepted = 0
			-- 1000 requests spread over 10 seconds (100/s) from one spammer.
			for _ = 1, 1000 do
				if limiter:consume("spammer") then
					accepted += 1
				end
				advance(0.01)
			end
			-- capacity + 10 s * 10/s, allowing for float rounding at the boundary.
			expect(accepted <= 5 + 100 + 1).toBe(true)
			expect(accepted >= 100).toBe(true)
		end)

		it("keeps keys independent", function()
			local clock = fakeClock()
			local limiter = RateLimiter.new({ capacity = 1, refillPerSecond = 0, clock = clock })
			expect(limiter:consume("a")).toBe(true)
			expect(limiter:consume("a")).toBe(false)
			expect(limiter:consume("b")).toBe(true)
		end)

		it("supports a custom cost and spends nothing on rejection", function()
			local clock = fakeClock()
			local limiter = RateLimiter.new({ capacity = 5, refillPerSecond = 0, clock = clock })
			expect(limiter:consume("k", 4)).toBe(true)
			expect(limiter:consume("k", 2)).toBe(false)
			expect(limiter:peek("k")).toBe(1)
			expect(limiter:consume("k", 1)).toBe(true)
		end)

		it("forget() resets a key to a full bucket", function()
			local clock = fakeClock()
			local limiter = RateLimiter.new({ capacity = 1, refillPerSecond = 0, clock = clock })
			limiter:consume("k")
			expect(limiter:consume("k")).toBe(false)
			limiter:forget("k")
			expect(limiter:consume("k")).toBe(true)
		end)

		it("rejects invalid configuration", function()
			expect(function()
				RateLimiter.new({ capacity = 0, refillPerSecond = 1 })
			end).toThrow("capacity")
		end)
	end)
end
