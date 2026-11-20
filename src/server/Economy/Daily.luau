--!strict
--[[
	Daily login reward with a streak (pure).

	Days are UTC day numbers (os.time() // 86400), so every server agrees on when a day starts.
	  * claim on the day after the last claim  -> streak + 1 (capped at DailyMaxStreak)
	  * claim after missing a day or more      -> streak resets to 1
	  * second claim on the same day           -> refused
	Reward = DailyBase + DailyStep × (streak - 1).
]]

export type DailyState = { lastDay: number, streak: number }

export type Status = { canClaim: boolean, streak: number, reward: number }

local Daily = {}

function Daily.today(now: number): number
	return now // 86400
end

local function nextStreak(config: any, state: DailyState, today: number): number
	if state.lastDay == today - 1 then
		return math.min(state.streak + 1, config.Rewards.DailyMaxStreak)
	end
	return 1
end

function Daily.rewardFor(config: any, streak: number): number
	return config.Rewards.DailyBase + config.Rewards.DailyStep * (math.max(1, streak) - 1)
end

-- What claiming today would give (or why not).
function Daily.status(config: any, state: DailyState, today: number): Status
	if state.lastDay >= today then
		return { canClaim = false, streak = state.streak, reward = 0 }
	end
	local streak = nextStreak(config, state, today)
	return { canClaim = true, streak = streak, reward = Daily.rewardFor(config, streak) }
end

-- Mutates `state` on success and returns the coin reward.
function Daily.claim(config: any, state: DailyState, today: number): (boolean, number)
	local status = Daily.status(config, state, today)
	if not status.canClaim then
		return false, 0
	end
	state.lastDay = today
	state.streak = status.streak
	return true, status.reward
end

return Daily
