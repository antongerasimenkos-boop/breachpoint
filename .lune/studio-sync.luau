--!strict
--[[
	studio-sync — a minimal, one-way "Rojo lite" used for live testing through the Studio MCP bridge.

		lune run studio-sync          -- serves on http://localhost:34880

	It reads default.project.json, maps the file tree exactly like Rojo does for the subset this
	project uses (folders, init scripts, .server/.client/.luau files) and serves:

		GET /tree   JSON description of every managed root
		GET /apply  Luau source that, executed in Studio's Edit DataModel, fetches /tree and
		            rebuilds the managed roots so Studio matches the repo

	In Studio (command bar or MCP execute_luau):
		loadstring(game:GetService("HttpService"):GetAsync("http://localhost:34880/apply"))()

	The real deliverable is still produced by `rojo build`; this only exists so automated playtests
	(or a developer without the Rojo plugin) can push the repo into an open place without clicking.
]]

local fs = require("@lune/fs")
local net = require("@lune/net")
local serde = require("@lune/serde")
local process = require("@lune/process")

local PORT = tonumber(process.args[1]) or 34880

type Node = {
	name: string,
	className: string,
	source: string?,
	children: { Node },
}

type Root = {
	parentPath: { string },
	node: Node,
}

local function scriptInfo(fileName: string): (string?, string?)
	for _, ext in { ".luau", ".lua" } do
		if string.sub(fileName, -#ext) == ext then
			local base = string.sub(fileName, 1, -#ext - 1)
			if string.sub(base, -7) == ".server" then
				return string.sub(base, 1, -8), "Script"
			elseif string.sub(base, -7) == ".client" then
				return string.sub(base, 1, -8), "LocalScript"
			end
			return base, "ModuleScript"
		end
	end
	return nil, nil
end

local function readSource(path: string): string
	-- Normalise line endings so Studio sees the same text regardless of git autocrlf.
	return (string.gsub(fs.readFile(path), "\r\n", "\n"))
end

local function fromPath(path: string, name: string): Node?
	if fs.isFile(path) then
		local fileName = string.match(path, "[^/]+$") or path
		local _, className = scriptInfo(fileName)
		if not className then
			return nil
		end
		return { name = name, className = className, source = readSource(path), children = {} }
	end

	local node: Node = { name = name, className = "Folder", children = {} }
	local entries = fs.readDir(path)
	table.sort(entries)
	for _, entry in entries do
		local childPath = path .. "/" .. entry
		local childName, className = scriptInfo(entry)
		if fs.isFile(childPath) and childName == "init" and className then
			node.className = className
			node.source = readSource(childPath)
		end
	end
	for _, entry in entries do
		local childPath = path .. "/" .. entry
		if fs.isDir(childPath) then
			local child = fromPath(childPath, entry)
			if child then
				table.insert(node.children, child)
			end
		else
			local childName = scriptInfo(entry)
			if childName and childName ~= "init" then
				local child = fromPath(childPath, childName)
				if child then
					table.insert(node.children, child)
				end
			end
		end
	end
	return node
end

local function fromProjectNode(name: string, projectNode: { [string]: any }): Node?
	local node: Node?
	if projectNode["$path"] then
		node = fromPath(projectNode["$path"], name)
	else
		node = { name = name, className = projectNode["$className"] or "Folder", children = {} }
	end
	if not node then
		return nil
	end
	for key, child in projectNode do
		if string.sub(key, 1, 1) ~= "$" and type(child) == "table" then
			local childNode = fromProjectNode(key, child)
			if childNode then
				table.insert(node.children, childNode)
			end
		end
	end
	return node
end

-- Nodes without $path/$className are existing containers (services, StarterPlayerScripts);
-- everything below them that the project defines is a managed root that gets rebuilt.
local function collectRoots(projectNode: { [string]: any }, parentPath: { string }, out: { Root })
	for key, child in projectNode do
		if string.sub(key, 1, 1) == "$" or type(child) ~= "table" then
			continue
		end
		if child["$path"] or child["$className"] then
			local node = fromProjectNode(key, child)
			if node then
				table.insert(out, { parentPath = table.clone(parentPath), node = node })
			end
		else
			local nextPath = table.clone(parentPath)
			table.insert(nextPath, key)
			collectRoots(child, nextPath, out)
		end
	end
end

local function buildTree(): { roots: { Root }, scripts: number }
	local project = serde.decode("json", fs.readFile("default.project.json"))
	local roots: { Root } = {}
	collectRoots(project.tree, {}, roots)

	local count = 0
	local function countScripts(node: Node)
		if node.source then
			count += 1
		end
		for _, c in node.children do
			countScripts(c)
		end
	end
	for _, r in roots do
		countScripts(r.node)
	end
	return { roots = roots, scripts = count }
end

local APPLY_SOURCE = [[
local HttpService = game:GetService("HttpService")
local manifest = HttpService:JSONDecode(HttpService:GetAsync("http://localhost:%d/tree"))
local function build(node)
	local inst = Instance.new(node.className)
	inst.Name = node.name
	if node.source then
		inst.Source = node.source
	end
	for _, child in node.children do
		build(child).Parent = inst
	end
	return inst
end
local applied = {}
for _, root in manifest.roots do
	local parent = game
	for i, name in root.parentPath do
		parent = if i == 1 then game:GetService(name) else parent:WaitForChild(name, 5)
		assert(parent, "studio-sync: missing container " .. name)
	end
	local existing = parent:FindFirstChild(root.node.name)
	if existing then
		existing:Destroy()
	end
	build(root.node).Parent = parent
	table.insert(applied, table.concat(root.parentPath, ".") .. "." .. root.node.name)
end
return string.format("studio-sync: %%d scripts -> %%s", manifest.scripts, table.concat(applied, ", "))
]]

net.serve(PORT, function(request)
	local ok, result = pcall(function()
		if request.path == "/tree" then
			return { status = 200, body = serde.encode("json", buildTree()) }
		elseif request.path == "/apply" then
			return { status = 200, body = string.format(APPLY_SOURCE, PORT) }
		end
		return { status = 404, body = "not found" }
	end)
	if ok then
		return result
	end
	print("[studio-sync] error: " .. tostring(result))
	return { status = 500, body = tostring(result) }
end)

print(string.format("[studio-sync] serving %s on http://localhost:%d", process.cwd, PORT))
