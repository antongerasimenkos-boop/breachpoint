--!strict
--[[
	XP, levels and daily quests (pure).

	  XP       every coin earned from a round result is also earned as XP (Config.Progression)
	  levels   level n needs BaseXp + StepXp * (n - 1) XP to reach n + 1, so early levels come fast
	  quests   three per UTC day, rotated through Config.Quests by day number, so every player has
	           the same quests on a given day. Progress counts the same stat increments the game
	           already records; a quest pays its coins once, the moment it completes.
]]

export type QuestState = {
	day: number,
	progress: { [string]: number },
	done: { [string]: boolean },
}

export type LevelInfo = { level: number, into: number, need: number }

export type QuestView = {
	id: string,
	text: string,
	progress: number,
	target: number,
	reward: number,
	done: boolean,
}

local Progression = {}

function Progression.xpToNext(config: any, level: number): number
	local p = config.Progression
	return p.BaseXp + p.StepXp * (level - 1)
end

function Progression.levelInfo(config: any, xp: number): LevelInfo
	local level = 1
	local left = xp
	while level < config.Progression.MaxLevel do
		local need = Progression.xpToNext(config, level)
		if left < need then
			return { level = level, into = left, need = need }
		end
		left -= need
		level += 1
	end
	return { level = level, into = 0, need = 0 }
end

-- Adds XP. Returns the old and new level so the caller can celebrate a level-up.
function Progression.addXp(config: any, data: { xp: number }, amount: number): (number, number)
	local before = Progression.levelInfo(config, data.xp).level
	data.xp += math.max(0, math.floor(amount))
	return before, Progression.levelInfo(config, data.xp).level
end

function Progression.questsForDay(config: any, day: number): { any }
	local pool = config.Quests
	local picked = {}
	for i = 0, config.Progression.QuestsPerDay - 1 do
		table.insert(picked, pool[(day * config.Progression.QuestsPerDay + i) % #pool + 1])
	end
	return picked
end

-- Starts a fresh set of quests when the stored ones belong to another day.
function Progression.refresh(quests: QuestState, day: number)
	if quests.day ~= day then
		quests.day = day
		quests.progress = {}
		quests.done = {}
	end
end

-- Counts a stat increment towards today's quests and pays any quest it completes.
-- Returns the quests completed by this increment.
function Progression.record(
	config: any,
	data: { coins: number, quests: QuestState },
	day: number,
	stat: string,
	amount: number
): { any }
	Progression.refresh(data.quests, day)
	local completed = {}
	if amount <= 0 then
		return completed
	end
	for _, quest in Progression.questsForDay(config, day) do
		if quest.stat == stat and not data.quests.done[quest.id] then
			local progress = math.min(quest.target, (data.quests.progress[quest.id] or 0) + amount)
			data.quests.progress[quest.id] = progress
			if progress >= quest.target then
				data.quests.done[quest.id] = true
				data.coins += quest.reward
				table.insert(completed, quest)
			end
		end
	end
	return completed
end

function Progression.view(config: any, quests: QuestState, day: number): { QuestView }
	local current = quests.day == day
	local list = {}
	for _, quest in Progression.questsForDay(config, day) do
		table.insert(list, {
			id = quest.id,
			text = quest.text,
			progress = if current then quests.progress[quest.id] or 0 else 0,
			target = quest.target,
			reward = quest.reward,
			done = current and quests.done[quest.id] == true,
		})
	end
	return list
end

return Progression
