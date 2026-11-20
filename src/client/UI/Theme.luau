--!strict
-- Visual constants for the code-built HUD. One palette, one corner radius, one set of fonts.

local Theme = {}

Theme.Font = Enum.Font.GothamBold
Theme.FontBody = Enum.Font.GothamMedium
Theme.FontBlack = Enum.Font.GothamBlack

Theme.Colors = {
	Panel = Color3.fromRGB(16, 18, 28),
	PanelLight = Color3.fromRGB(32, 36, 54),
	PanelRaised = Color3.fromRGB(44, 49, 72),
	Stroke = Color3.fromRGB(255, 255, 255),
	Text = Color3.fromRGB(245, 245, 250),
	TextDim = Color3.fromRGB(165, 172, 192),
	Builder = Color3.fromRGB(80, 160, 255),
	Hunter = Color3.fromRGB(240, 80, 80),
	Spectator = Color3.fromRGB(150, 150, 165),
	Success = Color3.fromRGB(90, 210, 120),
	Warn = Color3.fromRGB(255, 190, 60),
	Info = Color3.fromRGB(120, 200, 255),
	Valid = Color3.fromRGB(90, 230, 120),
	Invalid = Color3.fromRGB(240, 70, 70),
	Coin = Color3.fromRGB(255, 200, 60),
	Accent = Color3.fromRGB(255, 140, 60),
}

Theme.PanelTransparency = 0.12
Theme.Corner = UDim.new(0, 12)

Theme.Sounds = {
	Place = "rbxasset://sounds/snap.mp3",
	Hit = "rbxasset://sounds/hit.wav",
	Break = "rbxasset://sounds/collide.wav",
	Shockwave = "rbxasset://sounds/bass.mp3",
	Tag = "rbxasset://sounds/electronicpingshort.wav",
	HuntStart = "rbxasset://sounds/swordslash.wav",
	Victory = "rbxasset://sounds/victory.wav",
	Click = "rbxasset://sounds/button.wav",
	Coins = "rbxasset://sounds/electronicpingshort.wav",
	Reel = "rbxasset://sounds/clickfast.wav",
	Reveal = "rbxasset://sounds/victory.wav",
	Trap = "rbxasset://sounds/uuhhh.mp3",
}

function Theme.roleColor(role: string): Color3
	if role == "Builder" then
		return Theme.Colors.Builder
	elseif role == "Hunter" then
		return Theme.Colors.Hunter
	end
	return Theme.Colors.Spectator
end

function Theme.rgb(values: { number }): Color3
	return Color3.fromRGB(values[1], values[2], values[3])
end

return Theme
