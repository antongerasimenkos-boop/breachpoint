--!strict
--[[
	Client entry point. The client renders state and sends intents; it decides nothing.
	Controllers start in order: the HUD first, because the others add to its ScreenGui.
]]

local Controllers = script.Parent.Controllers

local ordered = {
	require(Controllers.HudController),
	require(Controllers.BuildController),
	require(Controllers.HunterController),
	require(Controllers.ShopController),
	require(Controllers.ProgressController),
	require(Controllers.ClassController),
	require(Controllers.FeedController),
	require(Controllers.EffectsController),
	require(Controllers.IntroController),
} :: { { start: () -> () } }

for _, controller in ordered do
	controller.start()
end

print("[Breachpoint] client ready")
