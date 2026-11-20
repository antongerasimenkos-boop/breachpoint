--!strict
-- Screen-to-world targeting shared by the build and hunter controllers (mouse and touch).

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")

local Pointer = {}

local player = Players.LocalPlayer
local MAX_DISTANCE = 250

-- Last touch position, so tap-to-act works on mobile.
local lastTouch: Vector2? = nil
UserInputService.TouchStarted:Connect(function(touch, processed)
	if not processed then
		lastTouch = Vector2.new(touch.Position.X, touch.Position.Y)
	end
end)

function Pointer.screenPosition(): Vector2
	if UserInputService.TouchEnabled and not UserInputService.MouseEnabled and lastTouch then
		return lastTouch
	end
	return UserInputService:GetMouseLocation()
end

function Pointer.raycast(exclude: { any }?): RaycastResult?
	local camera = workspace.CurrentCamera
	if not camera then
		return nil
	end
	local position = Pointer.screenPosition()
	local ray = camera:ViewportPointToRay(position.X, position.Y)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local ignore: { Instance } = { camera }
	if player.Character then
		table.insert(ignore, player.Character)
	end
	for _, instance in (exclude or {}) :: { any } do
		table.insert(ignore, instance)
	end
	params.FilterDescendantsInstances = ignore
	return workspace:Raycast(ray.Origin, ray.Direction * MAX_DISTANCE, params)
end

-- The character model (with a Humanoid) that an instance belongs to, if any.
function Pointer.characterOf(instance: Instance?): Model?
	local current = instance
	while current and current ~= workspace do
		if current:IsA("Model") and current:FindFirstChildOfClass("Humanoid") then
			return current
		end
		current = current.Parent
	end
	return nil
end

-- Participant id for a character: UserId for players, the ParticipantId attribute for bots.
function Pointer.participantId(model: Model): number?
	local owner = Players:GetPlayerFromCharacter(model)
	if owner then
		return owner.UserId
	end
	local id = model:GetAttribute("ParticipantId")
	return if type(id) == "number" then id else nil
end

return Pointer
