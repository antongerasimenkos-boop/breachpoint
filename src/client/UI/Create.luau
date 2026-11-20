--!strict
--[[
	Tiny declarative helper for building GUI from code.

		local frame = Create("Frame", {
			Size = UDim2.fromOffset(200, 50),
			Parent = screenGui,
		}, {
			Create("UICorner", { CornerRadius = UDim.new(0, 8) }),
		})
]]

local TweenService = game:GetService("TweenService")

local Theme = require(script.Parent.Theme)

local function Create(className: string, props: { [string]: any }?, children: { any }?): any
	local instance = Instance.new(className)
	local parent = nil
	for key, value in (props or {}) :: { [string]: any } do
		if key == "Parent" then
			parent = value -- assign last, after children, to avoid replication/layout churn
		else
			(instance :: any)[key] = value
		end
	end
	for _, child in (children or {}) :: { any } do
		child.Parent = instance
	end
	if parent then
		instance.Parent = parent
	end
	return instance
end

-- A rounded, semi-transparent panel with a subtle outline.
local function panel(props: { [string]: any }, children: { any }?): Frame
	local merged: { [string]: any } = {
		BackgroundColor3 = Theme.Colors.Panel,
		BackgroundTransparency = Theme.PanelTransparency,
		BorderSizePixel = 0,
	}
	for key, value in props do
		merged[key] = value
	end
	local list: { any } = children or {}
	table.insert(list, Create("UICorner", { CornerRadius = Theme.Corner }))
	table.insert(
		list,
		Create("UIStroke", { Color = Theme.Colors.Stroke, Transparency = 0.85, Thickness = 1 })
	)
	-- Subtle top-to-bottom shading gives flat panels some depth.
	table.insert(
		list,
		Create("UIGradient", {
			Rotation = 90,
			Color = ColorSequence.new(Color3.new(1, 1, 1), Color3.fromRGB(190, 195, 215)),
		})
	)
	return Create("Frame", merged, list)
end

-- A chunky rounded button with a gradient, outline and hover/press feedback.
local function button(props: { [string]: any }, onActivated: () -> ()): TextButton
	local color: Color3 = props.Color or Theme.Colors.PanelRaised
	props.Color = nil
	local merged: { [string]: any } = {
		BackgroundColor3 = color,
		BorderSizePixel = 0,
		AutoButtonColor = false,
		Font = Theme.Font,
		TextSize = 16,
		TextColor3 = Theme.Colors.Text,
	}
	for key, value in props do
		merged[key] = value
	end
	local scale = Create("UIScale", { Scale = 1 })
	local b = Create("TextButton", merged, {
		Create("UICorner", { CornerRadius = UDim.new(0, 10) }),
		Create("UIStroke", {
			Color = Theme.Colors.Stroke,
			Transparency = 0.75,
			Thickness = 1.5,
			ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
		}),
		Create("UIGradient", {
			Rotation = 90,
			Color = ColorSequence.new(Color3.new(1, 1, 1), Color3.fromRGB(170, 170, 185)),
		}),
		scale,
	})
	local info = TweenInfo.new(0.12, Enum.EasingStyle.Quad)
	b.MouseEnter:Connect(function()
		TweenService:Create(scale, info, { Scale = 1.04 }):Play()
	end)
	b.MouseLeave:Connect(function()
		TweenService:Create(scale, info, { Scale = 1 }):Play()
	end)
	b.MouseButton1Down:Connect(function()
		TweenService:Create(scale, info, { Scale = 0.96 }):Play()
	end)
	b.MouseButton1Up:Connect(function()
		TweenService:Create(scale, info, { Scale = 1.04 }):Play()
	end)
	b.Activated:Connect(onActivated)
	return b
end

-- A small round coin icon (no image assets needed).
local function coinIcon(size: number): Frame
	return Create("Frame", {
		Size = UDim2.fromOffset(size, size),
		BackgroundColor3 = Theme.Colors.Coin,
		BorderSizePixel = 0,
	}, {
		Create("UICorner", { CornerRadius = UDim.new(1, 0) }),
		Create("UIStroke", { Color = Color3.fromRGB(200, 130, 20), Thickness = math.max(1, size / 10) }),
		Create("UIGradient", {
			Rotation = 45,
			Color = ColorSequence.new(Color3.fromRGB(255, 240, 160), Color3.fromRGB(240, 170, 40)),
		}),
	})
end

local function label(props: { [string]: any }): TextLabel
	local merged: { [string]: any } = {
		BackgroundTransparency = 1,
		Font = Theme.Font,
		TextColor3 = Theme.Colors.Text,
		TextScaled = false,
		TextSize = 18,
	}
	for key, value in props do
		merged[key] = value
	end
	return Create("TextLabel", merged)
end

return {
	new = Create,
	panel = panel,
	label = label,
	button = button,
	coinIcon = coinIcon,
}
