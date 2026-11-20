--!strict
--[[
	BuildController: the builder's tools.

	  Build phase  hotbar (1/2/3), ghost preview snapped to the grid, click to place, X to take back
	  Hunt phase   click or E on a damaged block to repair it

	The preview mirrors the server's blocks into a local BlockGrid, so it applies the *same* rules
	(bounds, occupancy, support) plus budget and reach. Invalid placements are caught locally and
	never sent. The server still re-checks everything.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local BlockGrid = require(Shared.Logic.BlockGrid)
local Config = require(Shared.Config)
local Types = require(Shared.Types)

local Client = script.Parent.Parent
local Create = require(Client.UI.Create)
local HudController = require(script.Parent.HudController)
local Net = require(Client.Net)
local Pointer = require(Client.Pointer)
local Profile = require(Client.Profile)
local State = require(Client.State)
local Theme = require(Client.UI.Theme)

local player = Players.LocalPlayer

local BuildController = {}

local CELL = Config.Grid.CellSize
local HALF_DIAGONAL = CELL * math.sqrt(3) / 2
local PLACE_REPEAT = 0.18
local NUMBER_KEYS = {
	[Enum.KeyCode.One] = 1,
	[Enum.KeyCode.Two] = 2,
	[Enum.KeyCode.Three] = 3,
	[Enum.KeyCode.Four] = 4,
	[Enum.KeyCode.Five] = 5,
	[Enum.KeyCode.Six] = 6,
	[Enum.KeyCode.Seven] = 7,
}

local grid = BlockGrid.new(Config.Grid)
local mirrored: { [BasePart]: number } = {} -- part -> local grid id

local selected: Types.BlockKind = "Wood"
local ghost: Part
local outline: SelectionBox
local hotbar: Frame
local slots: { [Types.BlockKind]: Frame } = {}
local available: { Types.BlockKind } = {} -- kinds this player can place, in hotbar order
local budgetLabel: TextLabel

local target: { cell: Types.Cell?, valid: boolean, reason: string?, block: BasePart? } = {
	cell = nil,
	valid = false,
	reason = nil,
	block = nil,
}
local holding = false
local lastSent: { key: string, at: number } = { key = "", at = 0 }

-- Mirror ---------------------------------------------------------------------------------------

local function mirrorAdd(part: Instance)
	if not part:IsA("BasePart") or mirrored[part] then
		return
	end
	local cell = grid:worldToCell(part.Position.X, part.Position.Y, part.Position.Z)
	local block = grid:insert(cell, tostring(part:GetAttribute("Kind")), 0, 1)
	if block then
		mirrored[part] = block.id
	end
end

local function mirrorRemove(part: Instance)
	local id = mirrored[part :: BasePart]
	if id then
		grid:remove(id)
		mirrored[part :: BasePart] = nil
	end
end

-- Targeting ----------------------------------------------------------------------------------

local function blockPartOf(instance: Instance?): BasePart?
	if instance and instance:IsA("BasePart") and instance:GetAttribute("BlockId") then
		return instance
	end
	return nil
end

local function computeTarget()
	target.cell, target.valid, target.reason, target.block = nil, false, nil, nil
	local result = Pointer.raycast({ ghost })
	if not result then
		return
	end
	local block = blockPartOf(result.Instance)
	target.block = block

	local cell: Types.Cell
	if block then
		-- Build on the face that was clicked.
		local normal = result.Normal
		local base = grid:worldToCell(block.Position.X, block.Position.Y, block.Position.Z)
		cell = {
			x = base.x + math.round(normal.X),
			y = base.y + math.round(normal.Y),
			z = base.z + math.round(normal.Z),
		}
	else
		local p = result.Position + result.Normal * 0.05
		cell = grid:worldToCell(p.X, p.Y, p.Z)
	end
	target.cell = cell

	local ok, err = grid:canPlace(cell)
	if selected == "Trap" then
		-- Traps are floor plates: an empty ground cell, no support rule.
		ok = grid:inBounds(cell) and cell.y == Config.Grid.MinY and grid:getAt(cell) == nil
		err = if ok then nil elseif not grid:inBounds(cell) then "OutOfBounds" else "Occupied"
	end
	if not ok then
		target.reason = if err == "OutOfBounds"
			then "Build inside the fort zone"
			elseif err == "Unsupported" then "Blocks need support below or beside them"
			else "That spot is taken"
		return
	end
	if State.budget() < Config.Blocks[selected].cost then
		target.reason = "Not enough budget"
		return
	end
	local root = player.Character and player.Character.PrimaryPart
	local x, y, z = grid:cellCenter(cell)
	if not root or (root.Position - Vector3.new(x, y, z)).Magnitude > Config.Build.Reach + HALF_DIAGONAL then
		target.reason = "Too far away"
		return
	end
	target.valid = true
end

-- UI -------------------------------------------------------------------------------------------

local function refreshHotbar()
	for key, slot in slots do
		local kind: Types.BlockKind = key :: any
		local stroke = slot:FindFirstChildOfClass("UIStroke") :: UIStroke
		local isSelected = kind == selected
		stroke.Transparency = if isSelected then 0 else 0.85
		stroke.Thickness = if isSelected then 2 else 1
		local affordable = State.budget() >= Config.Blocks[kind].cost
		slot.BackgroundTransparency = if affordable then Theme.PanelTransparency else 0.6
	end
	budgetLabel.Text = string.format("Budget: %d", State.budget())
end

local function selectKind(kind: Types.BlockKind)
	if not table.find(available, kind) then
		return
	end
	selected = kind
	refreshHotbar()
end

local function usableKinds(): { Types.BlockKind }
	local list: { Types.BlockKind } = {}
	for _, entry in Config.BlockOrder do
		local kind: Types.BlockKind = entry :: any
		local unlock = Config.Blocks[kind].unlock
		if not unlock or Profile.owns(unlock) then
			table.insert(list, kind)
		end
	end
	return list
end

-- (Re)builds the slots for the kinds this player can use; called again after a shop unlock.
local function rebuildHotbar()
	for _, slot in slots do
		slot:Destroy()
	end
	slots = {}
	available = usableKinds()
	if not table.find(available, selected) then
		selected = available[1]
	end
	hotbar.Size = UDim2.fromOffset(#available * 96 + (#available - 1) * 8, 112)
	for i, entry in available do
		local kind: Types.BlockKind = entry :: any -- (luau-lsp widens the singleton union here)
		local cfg = Config.Blocks[kind]
		local slot = Create.panel({
			Name = kind,
			Position = UDim2.fromOffset((i - 1) * 104, 28),
			Size = UDim2.fromOffset(96, 84),
			Parent = hotbar,
		}, {
			Create.new("Frame", {
				Name = "Swatch",
				AnchorPoint = Vector2.new(0.5, 0),
				Position = UDim2.new(0.5, 0, 0, 10),
				Size = UDim2.fromOffset(30, 30),
				BackgroundColor3 = Theme.rgb(cfg.color),
				BorderSizePixel = 0,
			}, { Create.new("UICorner", { CornerRadius = UDim.new(0, 6) }) }),
			Create.label({
				Position = UDim2.fromOffset(0, 44),
				Size = UDim2.new(1, 0, 0, 18),
				Text = string.format("%d  %s", i, cfg.label),
				TextSize = 14,
			}),
			Create.label({
				Position = UDim2.fromOffset(0, 62),
				Size = UDim2.new(1, 0, 0, 16),
				Text = if kind == "Trap"
					then string.format("cost %d · slows", cfg.cost)
					elseif kind == "Generator" then string.format("cost %d · +coins", cfg.cost)
					else string.format("cost %d · %d HP", cfg.cost, cfg.health),
				TextSize = 12,
				Font = Theme.FontBody,
				TextColor3 = Theme.Colors.TextDim,
			}),
		})
		local button = Create.new("TextButton", {
			Size = UDim2.fromScale(1, 1),
			BackgroundTransparency = 1,
			Text = "",
			Parent = slot,
		})
		button.Activated:Connect(function()
			selectKind(kind)
		end)
		slots[kind] = slot
	end
	refreshHotbar()
end

local function buildGui()
	local gui = player:WaitForChild("PlayerGui"):WaitForChild("HUD")
	hotbar = Create.new("Frame", {
		Name = "Hotbar",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -16),
		Size = UDim2.fromOffset(3 * 96 + 2 * 8, 112),
		BackgroundTransparency = 1,
		Visible = false,
		Parent = gui,
	})
	budgetLabel = Create.label({
		Size = UDim2.new(1, 0, 0, 22),
		TextSize = 18,
		TextColor3 = Theme.Colors.Warn,
		TextStrokeTransparency = 0.5,
		Parent = hotbar,
	})
	rebuildHotbar()
	Profile.changed:connect(rebuildHotbar)
end

local function buildGhost()
	ghost = Create.new("Part", {
		Name = "BuildGhost",
		Anchored = true,
		CanCollide = false,
		CanQuery = false,
		CanTouch = false,
		CastShadow = false,
		Size = Vector3.one * CELL,
		Material = Enum.Material.SmoothPlastic,
		Transparency = 1,
		Parent = workspace.CurrentCamera,
	})
	outline = Create.new("SelectionBox", {
		Adornee = ghost,
		LineThickness = 0.06,
		Transparency = 1,
		Parent = ghost,
	})
end

local function hideGhost()
	ghost.Transparency = 1
	outline.Transparency = 1
end

-- Actions --------------------------------------------------------------------------------------

-- Sends a placement unless the same cell was just requested: the new block may not have
-- replicated yet, and re-sending would only earn an "Occupied" rejection.
local function sendPlace(cell: Types.Cell)
	local key = string.format("%d,%d,%d", cell.x, cell.y, cell.z)
	local now = os.clock()
	if key == lastSent.key and now - lastSent.at < 0.6 then
		return
	end
	lastSent = { key = key, at = now }
	Net.placeBlock(cell, selected)
end

local function tryPlace()
	if not target.cell then
		return
	end
	if not target.valid then
		if target.reason then
			HudController.toast("warn", target.reason)
		end
		return
	end
	sendPlace(target.cell)
end

local function tryRemove()
	local block = target.block
	if not block then
		return
	end
	if block:GetAttribute("OwnerId") ~= player.UserId then
		HudController.toast("warn", "You can only take back your own blocks")
		return
	end
	Net.removeBlock(block:GetAttribute("BlockId") :: number)
end

local function tryRepair()
	local block = target.block
	if not block then
		return
	end
	local health, maxHealth =
		block:GetAttribute("Health") :: number, block:GetAttribute("MaxHealth") :: number
	if health >= maxHealth then
		HudController.toast("info", "That block is not damaged")
		return
	end
	Net.repairBlock(block:GetAttribute("BlockId") :: number)
end

local function primaryAction()
	if not State.isActiveBuilder() then
		return
	end
	if State.phase() == "Build" then
		tryPlace()
	elseif State.phase() == "Hunt" then
		tryRepair()
	end
end

function BuildController.start()
	buildGui()
	buildGhost()

	local blocksFolder = workspace:WaitForChild("Map"):WaitForChild("Blocks")
	for _, part in blocksFolder:GetChildren() do
		mirrorAdd(part)
	end
	blocksFolder.ChildAdded:Connect(mirrorAdd)
	blocksFolder.ChildRemoved:Connect(mirrorRemove)

	State.changed:connect(function()
		hotbar.Visible = State.isActiveBuilder() and State.phase() == "Build"
		refreshHotbar()
	end)

	UserInputService.InputBegan:Connect(function(input, processed)
		if processed then
			return
		end
		if
			input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch
		then
			holding = true
			computeTarget()
			primaryAction()
		elseif NUMBER_KEYS[input.KeyCode] then
			local kind: Types.BlockKind? = available[NUMBER_KEYS[input.KeyCode]] :: any
			if kind then
				selectKind(kind)
			end
		elseif input.KeyCode == Enum.KeyCode.X and State.isActiveBuilder() and State.phase() == "Build" then
			computeTarget()
			tryRemove()
		elseif input.KeyCode == Enum.KeyCode.E and State.isActiveBuilder() and State.phase() == "Hunt" then
			computeTarget()
			tryRepair()
		end
	end)
	UserInputService.InputEnded:Connect(function(input)
		if
			input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch
		then
			holding = false
		end
	end)

	-- Holding the button keeps placing as the cursor sweeps over new cells.
	local lastRepeat = 0
	RunService.RenderStepped:Connect(function()
		local building = State.isActiveBuilder() and State.phase() == "Build"
		if not building then
			hideGhost()
			return
		end
		computeTarget()
		local cell = target.cell
		if not cell then
			hideGhost()
			return
		end
		local x, y, z = grid:cellCenter(cell)
		if selected == "Trap" then
			ghost.Size = Vector3.new(CELL, 0.4, CELL)
			ghost.Position = Vector3.new(x, y - CELL / 2 + 0.2, z)
		else
			ghost.Size = Vector3.one * CELL
			ghost.Position = Vector3.new(x, y, z)
		end
		local color = if target.valid then Theme.Colors.Valid else Theme.Colors.Invalid
		ghost.Color = color
		outline.Color3 = color
		ghost.Transparency = 0.55
		outline.Transparency = 0

		if holding and target.valid and os.clock() - lastRepeat > PLACE_REPEAT then
			lastRepeat = os.clock()
			sendPlace(cell)
		end
	end)
end

return BuildController
