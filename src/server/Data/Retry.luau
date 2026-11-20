--!strict
--[[
	Retry with exponential backoff and jitter, for flaky calls such as DataStore requests.

		local ok, result, attempts = Retry.run(function()
			return store:GetAsync(key)
		end, { attempts = 4, baseDelay = 1, wait = task.wait })

	The delay before attempt n+1 is `baseDelay * 2^(n-1)`, capped at `maxDelay`, plus up to
	`jitter` × that delay of random spread. Without jitter, every server retries in lockstep
	after a DataStore outage.
]]

export type Options = {
	attempts: number,
	baseDelay: number,
	maxDelay: number?,
	jitter: number?, -- 0..1, fraction of the delay added at random. Default 0.25.
	wait: (seconds: number) -> (),
	random: (() -> number)?, -- returns [0, 1). Defaults to math.random.
	onRetry: ((attempt: number, err: string, delay: number) -> ())?,
}

local Retry = {}

function Retry.delayFor(attempt: number, options: Options): number
	local base = options.baseDelay * 2 ^ (attempt - 1)
	local capped = math.min(base, options.maxDelay or 30)
	local jitter = options.jitter or 0.25
	local random: () -> number = options.random or function()
		return math.random()
	end
	return capped + capped * jitter * random()
end

-- Calls `fn` until it succeeds or attempts run out.
-- Returns (true, result, attemptsUsed) or (false, lastError, attemptsUsed).
function Retry.run(fn: () -> ...any, options: Options): (boolean, any, number)
	assert(options.attempts >= 1, "attempts must be >= 1")
	local lastError: any = nil
	for attempt = 1, options.attempts do
		local ok, result = pcall(fn)
		if ok then
			return true, result, attempt
		end
		lastError = result
		if attempt < options.attempts then
			local delay = Retry.delayFor(attempt, options)
			if options.onRetry then
				options.onRetry(attempt, tostring(result), delay)
			end
			options.wait(delay)
		end
	end
	return false, lastError, options.attempts
end

return Retry
