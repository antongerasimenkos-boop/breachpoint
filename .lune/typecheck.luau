--!strict
--[[
	Strict type check of all game and package source with luau-lsp:

		lune run typecheck

	1. downloads the Roblox type definitions matching the pinned luau-lsp version (cached in build/)
	2. generates a Rojo sourcemap so instance paths (script.Parent.X, ReplicatedStorage.Shared...) resolve
	3. runs `luau-lsp analyze` over src/ and packages/*/src

	luau-lsp cannot open files under a non-ASCII path (e.g. a folder named in Cyrillic). When the
	repo lives under one, the sources are copied to an ASCII temp folder and checked there.
	Spec files are excluded: they run under Lune, whose globals are not part of the Roblox definitions.
]]

local fs = require("@lune/fs")
local net = require("@lune/net")
local process = require("@lune/process")
local serde = require("@lune/serde")

local function pinnedVersion(): string
	local manifest = serde.decode("toml", fs.readFile("rokit.toml"))
	local spec: string = manifest.tools["luau-lsp"]
	return assert(string.match(spec, "@(.+)$"), "luau-lsp is not pinned in rokit.toml")
end

local function ensureDefinitions(version: string): string
	local path = "build/globalTypes-" .. version .. ".d.luau"
	if fs.isFile(path) then
		return path
	end
	if not fs.isDir("build") then
		fs.writeDir("build")
	end
	local url = "https://raw.githubusercontent.com/JohnnyMorganz/luau-lsp/"
		.. version
		.. "/scripts/globalTypes.d.luau"
	print("downloading Roblox type definitions: " .. url)
	local response = net.request(url)
	assert(response.ok, "download failed: " .. tostring(response.statusCode))
	fs.writeFile(path, response.body)
	return path
end

local function isAscii(path: string): boolean
	return not string.find(path, "[\128-\255]")
end

local function copyTree(from: string, to: string)
	if fs.isDir(from) then
		fs.writeDir(to)
		for _, entry in fs.readDir(from) do
			copyTree(from .. "/" .. entry, to .. "/" .. entry)
		end
	else
		fs.writeFile(to, fs.readFile(from))
	end
end

local definitions = ensureDefinitions(pinnedVersion())

local workDir = "."
if not isAscii(process.cwd) then
	local temp = process.env.TEMP or process.env.TMPDIR or "/tmp"
	workDir = temp .. "/breachpoint-typecheck"
	if fs.isDir(workDir) then
		fs.removeDir(workDir)
	end
	fs.writeDir(workDir)
	for _, item in { "src", "packages", "default.project.json", ".luaurc", "rokit.toml" } do
		copyTree(item, workDir .. "/" .. item)
	end
	fs.writeFile(workDir .. "/globalTypes.d.luau", fs.readFile(definitions))
	definitions = "globalTypes.d.luau"
	print("non-ASCII repo path; checking a copy in " .. workDir)
end

local function run(program: string, args: { string }): boolean
	local result = process.exec(program, args, { cwd = workDir, stdio = "inherit" })
	return result.ok
end

assert(run("rojo", { "sourcemap", "default.project.json", "-o", "sourcemap.json" }), "rojo sourcemap failed")

local targets = { "src" }
for _, pkg in fs.readDir("packages") do
	if fs.isDir("packages/" .. pkg .. "/src") then
		table.insert(targets, "packages/" .. pkg .. "/src")
	end
end

local args = { "analyze", "--platform=roblox", "--defs=" .. definitions, "--sourcemap=sourcemap.json" }
for _, target in targets do
	table.insert(args, target)
end

local ok = run("luau-lsp", args)
print(if ok then "\ntypecheck: no type errors" else "\ntypecheck: FAILED")
process.exit(if ok then 0 else 1)
