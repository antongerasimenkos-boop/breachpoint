--!strict
--[[
	End-of-round coin rewards (pure). Per-action coins (repairs, breaks, generator payouts) are paid
	the moment they happen; this covers what is only known when the round ends.

	  everyone who took part             Participation
	  builders, winning team             + BuilderTeamWin (caught or not)
	  builders still standing            + SurvivorBonus (only when builders win)
	  builders, blocks still standing    + PerBlockStanding each, capped at PerBlockStandingCap
	  hunter                             + PerTag per tag, + HunterWin on a win
	A voided round (winner "None") pays participation only.
]]

export type RoundSummary = {
	winner: string, -- "Builders" | "Hunter" | "None"
	hunter: number?,
	builders: { number },
	survivors: { number },
	tags: { [number]: number },
	standingByOwner: { [number]: number },
}

local Rewards = {}

-- Returns coins per participant id.
function Rewards.compute(config: any, summary: RoundSummary): { [number]: number }
	local r = config.Rewards
	local coins: { [number]: number } = {}
	local voided = summary.winner == "None"

	for _, id in summary.builders do
		local total = r.Participation
		if not voided then
			if summary.winner == "Builders" then
				total += r.BuilderTeamWin
				if table.find(summary.survivors, id) then
					total += r.SurvivorBonus
				end
			end
			total += math.min(r.PerBlockStandingCap, (summary.standingByOwner[id] or 0) * r.PerBlockStanding)
		end
		coins[id] = total
	end

	if summary.hunter then
		local total = r.Participation
		if not voided then
			total += (summary.tags[summary.hunter] or 0) * r.PerTag
			if summary.winner == "Hunter" then
				total += r.HunterWin
			end
		end
		coins[summary.hunter] = total
	end

	return coins
end

-- The round's MVPs: participants ordered by coins earned (ties broken by id, so the order is
-- stable), at most `limit` of them.
function Rewards.ranking(coins: { [number]: number }, limit: number): { { id: number, coins: number } }
	local list = {}
	for id, amount in coins do
		table.insert(list, { id = id, coins = amount })
	end
	table.sort(list, function(a, b)
		if a.coins ~= b.coins then
			return a.coins > b.coins
		end
		return a.id < b.id
	end)
	while #list > limit do
		table.remove(list)
	end
	return list
end

return Rewards
