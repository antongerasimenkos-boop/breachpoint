--!strict
--[[
	Token-bucket rate limiter keyed by any value (normally a Player).

	Each key gets `capacity` tokens and regains `refillPerSecond` tokens per second, up to
	`capacity`. A request costs one token by default. Bursts up to `capacity` are allowed, and
	sustained traffic is capped at `refillPerSecond`.

	Buckets for table/userdata keys live in a weak-keyed table, so a forgotten `forget(player)`
	cannot leak memory forever. Still call `forget` on PlayerRemoving so a rejoin starts fresh.
]]

export type Options = {
	capacity: number,
	refillPerSecond: number,
	clock: (() -> number)?,
}

type Bucket = {
	tokens: number,
	updatedAt: number,
}

export type RateLimiter = {
	capacity: number,
	refillPerSecond: number,
	consume: (self: RateLimiter, key: any, cost: number?) -> boolean,
	peek: (self: RateLimiter, key: any) -> number,
	forget: (self: RateLimiter, key: any) -> (),
	_buckets: { [any]: Bucket },
	_clock: () -> number,
	_refill: (self: RateLimiter, key: any) -> Bucket,
}

local RateLimiter = {}
RateLimiter.__index = RateLimiter

function RateLimiter.new(options: Options): RateLimiter
	assert(type(options) == "table", "RateLimiter.new expects an options table")
	assert(options.capacity > 0, "capacity must be > 0")
	assert(options.refillPerSecond >= 0, "refillPerSecond must be >= 0")

	local self = setmetatable({}, RateLimiter) :: any
	self.capacity = options.capacity
	self.refillPerSecond = options.refillPerSecond
	self._clock = options.clock or os.clock
	self._buckets = setmetatable({}, { __mode = "k" })
	return self :: RateLimiter
end

function RateLimiter._refill(self: RateLimiter, key: any): Bucket
	local now = self._clock()
	local bucket: Bucket? = self._buckets[key]
	if bucket == nil then
		local fresh: Bucket = { tokens = self.capacity, updatedAt = now }
		self._buckets[key] = fresh
		return fresh
	end
	local elapsed = math.max(0, now - bucket.updatedAt)
	bucket.tokens = math.min(self.capacity, bucket.tokens + elapsed * self.refillPerSecond)
	bucket.updatedAt = now
	return bucket
end

-- Returns true and spends `cost` tokens if available; returns false (spending nothing) otherwise.
function RateLimiter.consume(self: RateLimiter, key: any, cost: number?): boolean
	local price = cost or 1
	local bucket = self:_refill(key)
	if bucket.tokens + 1e-9 < price then
		return false
	end
	bucket.tokens -= price
	return true
end

function RateLimiter.peek(self: RateLimiter, key: any): number
	return self:_refill(key).tokens
end

function RateLimiter.forget(self: RateLimiter, key: any)
	self._buckets[key] = nil
end

return RateLimiter
