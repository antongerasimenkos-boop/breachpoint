--!strict
--[[
	Read-only view of the replicated game state for client controllers.

	The server publishes round state as attributes (ReplicatedStorage.RoundState) and per-player
	state as attributes on each Player. This module wraps them in typed getters and a `changed`
	signal, so UI code never parses attribute names itself.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Signal = require(Shared.Util.Signal)
local Types = require(Shared.Types)

local player = Players.LocalPlayer
local roundState = ReplicatedStorage:WaitForChild("RoundState")

local State = {}

-- Fires with the attribute name whenever round or local-player state changes.
State.changed = Signal.new() :: Signal.Signal<string>

roundState.AttributeChanged:Connect(function(name)
	State.changed:fire(name)
end)
player.AttributeChanged:Connect(function(name)
	State.changed:fire(name)
end)

function State.phase(): Types.Phase
	return roundState:GetAttribute("Phase") or "Waiting"
end

function State.timeLeft(): number
	local endsAt = roundState:GetAttribute("EndsAt") or 0
	return math.max(0, endsAt - workspace:GetServerTimeNow())
end

function State.round(): number
	return roundState:GetAttribute("Round") or 0
end

function State.solo(): boolean
	return roundState:GetAttribute("Solo") == true
end

function State.soloAllowed(): boolean
	return roundState:GetAttribute("SoloAllowed") == true
end

function State.minPlayers(): number
	return roundState:GetAttribute("MinPlayers") or 2
end

function State.hunterId(): number
	return roundState:GetAttribute("HunterId") or 0
end

function State.buildersAlive(): (number, number)
	return roundState:GetAttribute("BuildersAlive") or 0, roundState:GetAttribute("BuildersTotal") or 0
end

function State.role(): Types.Role
	return player:GetAttribute("Role") or "Spectator"
end

function State.alive(): boolean
	return player:GetAttribute("Alive") == true
end

function State.budget(): number
	return player:GetAttribute("Budget") or 0
end

function State.isActiveBuilder(): boolean
	return State.role() == "Builder" and State.alive()
end

function State.isActiveHunter(): boolean
	return State.role() == "Hunter" and State.alive()
end

return State
