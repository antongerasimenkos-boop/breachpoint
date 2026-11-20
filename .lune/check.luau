--!strict
--[[
	One command for every quality gate:

		lune run check

	1. StyLua formatting (check only — run `stylua src packages tests sim .lune` to fix)
	2. Selene lint
	3. luau-lsp strict type check (see typecheck.luau)
	4. Lune unit tests
	5. `rojo build` of the deliverable place
	6. Smoke test of the built place (see verify-build.luau)
]]

local fs = require("@lune/fs")
local process = require("@lune/process")

if not fs.isDir("build") then
	fs.writeDir("build")
end

type Step = { name: string, program: string, args: { string } }

local LUA_DIRS = { "src", "packages", "tests", "sim", ".lune" }

local steps: { Step } = {
	{ name = "stylua", program = "stylua", args = { "--check", table.unpack(LUA_DIRS) } },
	{ name = "selene", program = "selene", args = LUA_DIRS },
	{ name = "typecheck", program = "lune", args = { "run", "typecheck" } },
	{ name = "tests", program = "lune", args = { "run", "test" } },
	{
		name = "rojo build",
		program = "rojo",
		args = { "build", "default.project.json", "-o", "build/Breachpoint.rbxl" },
	},
	{ name = "verify-build", program = "lune", args = { "run", "verify-build" } },
}

local results: { string } = {}
local anyFailed = false

for _, step in steps do
	print(string.format("\n== %s ==", step.name))
	local result = process.exec(step.program, step.args, { stdio = "inherit" })
	local status = if result.ok then "ok" else "FAILED (exit " .. tostring(result.code) .. ")"
	if not result.ok then
		anyFailed = true
	end
	table.insert(results, string.format("  %-12s %s", step.name, status))
end

print("\n== summary ==")
for _, line in results do
	print(line)
end

process.exit(if anyFailed then 1 else 0)
