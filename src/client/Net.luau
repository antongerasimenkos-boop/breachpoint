--!strict
--[[
	Typed client-side wrapper over the remotes declared in Shared/Protocol.
	Controllers call these functions instead of touching RemoteEvents directly, so a payload shape
	lives in exactly two places: here and the server's NetService.Handlers type.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Protocol = require(Shared.Protocol)
local Types = require(Shared.Types)

local folder = ReplicatedStorage:WaitForChild(Protocol.FolderName)

local function remote(name: string): RemoteEvent
	return folder:WaitForChild(name) :: RemoteEvent
end

local Net = {}

function Net.placeBlock(cell: Types.Cell, kind: Types.BlockKind)
	remote("PlaceBlock"):FireServer(cell.x, cell.y, cell.z, kind)
end

function Net.removeBlock(blockId: number)
	remote("RemoveBlock"):FireServer(blockId)
end

function Net.repairBlock(blockId: number)
	remote("RepairBlock"):FireServer(blockId)
end

function Net.breach(blockId: number)
	remote("Breach"):FireServer(blockId)
end

function Net.tag(participantId: number)
	remote("Tag"):FireServer(participantId)
end

function Net.useAbility(ability: Types.HunterAbility)
	remote("UseAbility"):FireServer(ability)
end

function Net.chooseSoloRole(role: Types.Role)
	remote("ChooseSoloRole"):FireServer(role)
end

function Net.buyItem(itemId: string)
	remote("BuyItem"):FireServer(itemId)
end

function Net.openCrate(crateId: string)
	remote("OpenCrate"):FireServer(crateId)
end

function Net.equip(slot: Types.CosmeticSlot, cosmeticId: string)
	remote("Equip"):FireServer(slot, cosmeticId)
end

function Net.claimDaily()
	remote("ClaimDaily"):FireServer()
end

function Net.chooseClass(className: string)
	remote("ChooseClass"):FireServer(className)
end

function Net.onProfile(handler: (profile: any) -> ()): RBXScriptConnection
	return remote("Profile").OnClientEvent:Connect(handler)
end

function Net.onCrateResult(handler: (result: any) -> ()): RBXScriptConnection
	return remote("CrateResult").OnClientEvent:Connect(handler)
end

function Net.onNotify(handler: (kind: string, text: string) -> ()): RBXScriptConnection
	return remote("Notify").OnClientEvent:Connect(handler)
end

function Net.onActionResult(
	handler: (action: Protocol.ClientEvent, ok: boolean, reason: string?) -> ()
): RBXScriptConnection
	return remote("ActionResult").OnClientEvent:Connect(handler)
end

function Net.onRoundResult(handler: (result: Types.RoundResult) -> ()): RBXScriptConnection
	return remote("RoundResult").OnClientEvent:Connect(handler)
end

function Net.onEffect(handler: (kind: string, position: Vector3) -> ()): RBXScriptConnection
	return remote("Effect").OnClientEvent:Connect(handler)
end

return Net
