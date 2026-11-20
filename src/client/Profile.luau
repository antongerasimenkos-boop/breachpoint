--!strict
--[[
	Client copy of the player's economy snapshot (coins, unlocks, cosmetics, daily status).
	The server pushes it on load and after every change; this module only stores it.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Signal = require(Shared.Util.Signal)

local Net = require(script.Parent.Net)

export type View = {
	coins: number,
	owned: { string },
	cosmetics: { string },
	equipped: { BlockSkin: string, Trail: string, Title: string },
	daily: { canClaim: boolean, streak: number, reward: number },
	pity: { sinceEpic: number, sinceLegendary: number },
	stats: { [string]: number },
	progress: { level: number, into: number, need: number },
	quests: { { id: string, text: string, progress: number, target: number, reward: number, done: boolean } },
}

local Profile = {}

Profile.current = nil :: View?
Profile.changed = Signal.new() :: Signal.Signal<View>

function Profile.owns(itemId: string): boolean
	local view = Profile.current
	return view ~= nil and table.find(view.owned, itemId) ~= nil
end

function Profile.hasCosmetic(id: string): boolean
	local view = Profile.current
	return view ~= nil and table.find(view.cosmetics, id) ~= nil
end

function Profile.coins(): number
	return if Profile.current then Profile.current.coins else 0
end

Net.onProfile(function(view)
	Profile.current = view
	Profile.changed:fire(view)
end)

return Profile
