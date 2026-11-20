--!strict
--[[
	Runs every `*.spec.luau` under `tests/` and `packages/*/tests/`.

		lune run test                 -- everything
		lune run test RateLimiter     -- only spec files whose path contains "RateLimiter"
]]

local fs = require("@lune/fs")
local process = require("@lune/process")

local TestKit = require("../tests/TestKit")

local filter = process.args[1]

local function collect(dir: string, out: { string })
	if not fs.isDir(dir) then
		return
	end
	for _, entry in fs.readDir(dir) do
		local path = dir .. "/" .. entry
		if fs.isDir(path) then
			collect(path, out)
		elseif string.sub(entry, -10) == ".spec.luau" then
			table.insert(out, path)
		end
	end
end

local files: { string } = {}
collect("tests", files)
if fs.isDir("packages") then
	for _, pkg in fs.readDir("packages") do
		collect("packages/" .. pkg .. "/tests", files)
	end
end
table.sort(files)

local passed, failed = 0, 0
local failures: { string } = {}

for _, file in files do
	if filter and not string.find(file, filter, 1, true) then
		continue
	end
	-- Paths are relative to the repo root; requires are relative to this script.
	local modulePath = "../" .. string.sub(file, 1, -6)
	local ok, specOrErr = pcall(require, modulePath)
	if not ok then
		failed += 1
		table.insert(failures, string.format("%s\n    failed to load: %s", file, tostring(specOrErr)))
		continue
	end
	for _, result in TestKit.run(specOrErr) do
		if result.ok then
			passed += 1
		else
			failed += 1
			table.insert(
				failures,
				string.format("%s\n    %s\n    %s", file, result.name, tostring(result.err))
			)
		end
	end
end

for _, f in failures do
	print("FAIL " .. f)
end
print(string.format("\n%d passed, %d failed (%d spec files)", passed, failed, #files))

if failed > 0 then
	process.exit(1)
end
