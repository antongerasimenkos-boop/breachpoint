--!strict
--[[
	RemoteGuard — typed argument validation and per-player rate limiting for Roblox remotes.

		local RemoteGuard = require(ReplicatedStorage.Packages.RemoteGuard)
		local t = RemoteGuard.t

		local placeGuard = RemoteGuard.new({
			name = "PlaceBlock",
			args = { t.integer(-20, 20), t.integer(0, 8), t.integer(-20, 20), t.literal("Wood", "Stone") },
			rateLimit = { capacity = 10, refillPerSecond = 6 },
			onReject = function(player, reason, detail) ... end,
		})

		placeGuard:connect(remotes.PlaceBlock, function(player, x, y, z, kind)
			-- only runs for well-typed, in-budget requests
		end)

		Players.PlayerRemoving:Connect(function(player) placeGuard:forget(player) end)

	The pipeline for every request is: rate limit -> argument count -> each argument's check ->
	handler (in xpcall). The first failure rejects the request and calls `onReject`. A request
	rejected for bad arguments still spends a token, so spamming garbage costs the sender too.

	See packages/remote-guard/README.md for the full API.
]]

local RateLimiter = require("@self/RateLimiter")
local t = require("@self/t")

export type Check = t.Check
export type RateLimiter = RateLimiter.RateLimiter

export type Reason = "RateLimited" | "TooManyArgs" | "BadArg" | "HandlerError"

export type Stats = {
	accepted: number,
	rejected: { [Reason]: number },
}

export type Options = {
	name: string,
	args: { Check },
	rateLimit: { capacity: number, refillPerSecond: number }?,
	-- Share one bucket between several guards (e.g. a global per-player budget).
	limiter: RateLimiter?,
	clock: (() -> number)?,
	onReject: ((player: any, reason: Reason, detail: string) -> ())?,
}

export type Guard = {
	name: string,
	stats: Stats,
	check: (self: Guard, player: any, ...any) -> (boolean, Reason?, string?),
	wrap: (self: Guard, handler: (player: any, ...any) -> ...any) -> (player: any, ...any) -> ...any,
	connect: (
		self: Guard,
		remote: RemoteEvent,
		handler: (player: Player, ...any) -> ()
	) -> RBXScriptConnection,
	bindFunction: (self: Guard, remote: RemoteFunction, handler: (player: Player, ...any) -> ...any) -> (),
	forget: (self: Guard, player: any) -> (),
	_options: Options,
	_limiters: { RateLimiter },
	_reject: (self: Guard, player: any, reason: Reason, detail: string) -> (),
}

local Guard = {}
Guard.__index = Guard

local RemoteGuard = {
	t = t,
	RateLimiter = RateLimiter,
}

function RemoteGuard.new(options: Options): Guard
	assert(type(options.name) == "string", "RemoteGuard.new: name is required")
	assert(type(options.args) == "table", "RemoteGuard.new: args must be a list of checks")

	local self = setmetatable({}, Guard) :: any
	self.name = options.name
	self.stats = { accepted = 0, rejected = {} }
	self._options = options
	self._limiters = {}
	if options.limiter then
		table.insert(self._limiters, options.limiter)
	end
	if options.rateLimit then
		table.insert(
			self._limiters,
			RateLimiter.new({
				capacity = options.rateLimit.capacity,
				refillPerSecond = options.rateLimit.refillPerSecond,
				clock = options.clock,
			})
		)
	end
	return self :: Guard
end

function Guard._reject(self: Guard, player: any, reason: Reason, detail: string)
	self.stats.rejected[reason] = (self.stats.rejected[reason] or 0) + 1
	local onReject = self._options.onReject
	if onReject then
		onReject(player, reason, detail)
	end
end

-- Runs the whole validation pipeline without calling a handler.
function Guard.check(self: Guard, player: any, ...: any): (boolean, Reason?, string?)
	for _, limiter in self._limiters do
		if not limiter:consume(player) then
			return false, "RateLimited", self.name
		end
	end

	local argChecks = self._options.args
	local count = select("#", ...)
	if count > #argChecks then
		return false,
			"TooManyArgs",
			string.format("%s: got %d args, expected at most %d", self.name, count, #argChecks)
	end

	for i, check in argChecks do
		local ok, err = check((select(i, ...)))
		if not ok then
			return false, "BadArg", string.format("%s arg #%d: %s", self.name, i, err or "invalid")
		end
	end

	return true
end

-- Returns a function with the same signature as `handler` that only calls it for valid requests.
-- Rejected requests return nothing (nil for RemoteFunctions).
function Guard.wrap(self: Guard, handler: (player: any, ...any) -> ...any): (player: any, ...any) -> ...any
	return function(player: any, ...: any): ...any
		local ok, reason, detail = self:check(player, ...)
		if not ok then
			self:_reject(player, reason :: Reason, detail or "")
			return
		end
		self.stats.accepted += 1
		local results = table.pack(xpcall(handler, debug.traceback, player, ...))
		if not results[1] then
			self:_reject(player, "HandlerError", string.format("%s: %s", self.name, tostring(results[2])))
			return
		end
		return table.unpack(results, 2, results.n)
	end
end

function Guard.connect(
	self: Guard,
	remote: RemoteEvent,
	handler: (player: Player, ...any) -> ()
): RBXScriptConnection
	return remote.OnServerEvent:Connect(self:wrap(handler))
end

function Guard.bindFunction(self: Guard, remote: RemoteFunction, handler: (player: Player, ...any) -> ...any)
	remote.OnServerInvoke = self:wrap(handler)
end

-- Drops rate-limit state for a player. Call on PlayerRemoving.
function Guard.forget(self: Guard, player: any)
	for _, limiter in self._limiters do
		limiter:forget(player)
	end
end

return RemoteGuard
