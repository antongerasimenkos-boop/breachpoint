--!strict
--[[
	Smoke test for the deliverable place:

		lune run verify-build

	Opens build/Breachpoint.rbxl with Lune's Roblox library and checks that every entry point exists
	with the right class and that each script's source matches the file on disk. That catches a
	broken project file or a file silently left out of the build.
]]

local fs = require("@lune/fs")
local process = require("@lune/process")
local roblox = require("@lune/roblox")

local PLACE = "build/Breachpoint.rbxl"
assert(fs.isFile(PLACE), PLACE .. " not found; run `rojo build -o " .. PLACE .. "` first")

local game = roblox.deserializePlace(fs.readFile(PLACE))

local failures: { string } = {}

local function find(path: string): any
	local current: any = game
	for name in string.gmatch(path, "[^%.]+") do
		current = if current == game then game:GetService(name) else current:FindFirstChild(name)
		if not current then
			return nil
		end
	end
	return current
end

local function expectInstance(path: string, className: string, file: string?)
	local instance = find(path)
	if not instance then
		table.insert(failures, "missing " .. path)
		return
	end
	if instance.ClassName ~= className then
		table.insert(failures, string.format("%s is a %s, expected %s", path, instance.ClassName, className))
		return
	end
	if file then
		local expected = string.gsub(fs.readFile(file), "\r\n", "\n")
		local actual = string.gsub(instance.Source, "\r\n", "\n")
		if actual ~= expected then
			table.insert(failures, path .. " source does not match " .. file)
		end
	end
end

expectInstance("ServerScriptService.Server.Main", "Script", "src/server/Main.server.luau")
expectInstance("StarterPlayer.StarterPlayerScripts.Client.Main", "LocalScript", "src/client/Main.client.luau")
expectInstance("ReplicatedStorage.Shared.Protocol", "ModuleScript", "src/shared/Protocol.luau")
expectInstance("ReplicatedStorage.Shared.Config", "ModuleScript", "src/shared/Config.luau")
expectInstance(
	"ReplicatedStorage.Packages.RemoteGuard",
	"ModuleScript",
	"packages/remote-guard/src/init.luau"
)
expectInstance(
	"ReplicatedStorage.Packages.RemoteGuard.RateLimiter",
	"ModuleScript",
	"packages/remote-guard/src/RateLimiter.luau"
)

-- Every .luau file under the mapped folders must appear as a script in the place.
local function countFiles(dir: string): number
	local n = 0
	for _, entry in fs.readDir(dir) do
		local path = dir .. "/" .. entry
		if fs.isDir(path) then
			n += countFiles(path)
		elseif string.sub(entry, -5) == ".luau" then
			n += 1
		end
	end
	return n
end

local expectedScripts = countFiles("src") + countFiles("packages/remote-guard/src")
local actualScripts = 0
for _, root in
	{
		find("ServerScriptService.Server"),
		find("StarterPlayer.StarterPlayerScripts.Client"),
		find("ReplicatedStorage.Shared"),
		find("ReplicatedStorage.Packages"),
	}
do
	if root then
		if root:IsA("LuaSourceContainer") then
			actualScripts += 1
		end
		for _, descendant in root:GetDescendants() do
			if descendant:IsA("LuaSourceContainer") then
				actualScripts += 1
			end
		end
	end
end
if actualScripts ~= expectedScripts then
	table.insert(
		failures,
		string.format("place has %d scripts, repo has %d .luau files", actualScripts, expectedScripts)
	)
end

if #failures > 0 then
	for _, failure in failures do
		print("FAIL " .. failure)
	end
	process.exit(1)
end
print(string.format("verify-build: %d scripts, entry points and sources match the repo", actualScripts))
