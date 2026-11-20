--!strict
--[[
	Maps participant ids to characters, for humans (UserId > 0) and practice bots (id < 0).
	Gameplay code asks "where is participant N?" without caring which kind it is.
]]

local Players = game:GetService("Players")

local Participants = {}

local bots: { [number]: Model } = {}

function Participants.registerBot(id: number, model: Model)
	assert(id < 0, "bot ids must be negative")
	model:SetAttribute("ParticipantId", id)
	bots[id] = model
end

function Participants.unregisterBot(id: number)
	bots[id] = nil
end

function Participants.character(id: number): Model?
	if id < 0 then
		local model = bots[id]
		return if model and model.Parent then model else nil
	end
	local player = Players:GetPlayerByUserId(id)
	return player and player.Character
end

function Participants.root(id: number): BasePart?
	local character = Participants.character(id)
	return character and character.PrimaryPart
end

function Participants.humanoid(id: number): Humanoid?
	local character = Participants.character(id)
	return character and character:FindFirstChildOfClass("Humanoid")
end

function Participants.idFromCharacter(model: Model): number?
	local player = Players:GetPlayerFromCharacter(model)
	if player then
		return player.UserId
	end
	local id = model:GetAttribute("ParticipantId")
	return if type(id) == "number" then id else nil
end

function Participants.allCharacters(): { Instance }
	local list: { Instance } = {}
	for _, player in Players:GetPlayers() do
		if player.Character then
			table.insert(list, player.Character)
		end
	end
	for _, model in bots do
		if model.Parent then
			table.insert(list, model)
		end
	end
	return list
end

return Participants
