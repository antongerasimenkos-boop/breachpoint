--!strict
--[[
	Shop: permanent unlocks bought with in-game coins (pure; Config is passed in).
	All validation lives here so the server, the tests and any future admin tool agree.
]]

export type Data = { coins: number, owned: { [string]: boolean } }

export type PurchaseError = "UnknownItem" | "AlreadyOwned" | "NotEnoughCoins"

local Shop = {}

function Shop.find(config: any, itemId: string): any?
	for _, item in config.Shop do
		if item.id == itemId then
			return item
		end
	end
	return nil
end

function Shop.owns(data: Data, itemId: string): boolean
	return data.owned[itemId] == true
end

-- Whether a player may place `kind`: free kinds always, locked ones only once unlocked.
function Shop.canUseBlock(config: any, data: Data?, kind: string): boolean
	local cfg = config.Blocks[kind]
	if not cfg then
		return false
	end
	if not cfg.unlock then
		return true
	end
	return data ~= nil and data.owned[cfg.unlock] == true
end

-- Mutates `data` on success. Coins can never go negative.
function Shop.purchase(config: any, data: Data, itemId: string): (boolean, PurchaseError?)
	local item = Shop.find(config, itemId)
	if not item then
		return false, "UnknownItem"
	end
	if data.owned[itemId] then
		return false, "AlreadyOwned"
	end
	if data.coins < item.price then
		return false, "NotEnoughCoins"
	end
	data.coins -= item.price
	data.owned[itemId] = true
	return true, nil
end

return Shop
