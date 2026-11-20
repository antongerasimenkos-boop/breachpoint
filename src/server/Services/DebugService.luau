--!strict
--[[
	Studio-only debug hooks, exposed as a BindableFunction at ServerStorage.BreachpointDebug.

	Tests and the Studio command bar can call into the running game without reaching into
	module caches:

		game.ServerStorage.BreachpointDebug:Invoke("round")          --> snapshot table
		game.ServerStorage.BreachpointDebug:Invoke("skip")           --> force the next phase

	Nothing is created on live servers.
]]

local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")

local DebugService = {}

local commands: { [string]: (...any) -> ...any } = {}

function DebugService.register(name: string, fn: (...any) -> ...any)
	assert(commands[name] == nil, "debug command registered twice: " .. name)
	commands[name] = fn
end

function DebugService.init()
	if not RunService:IsStudio() then
		return
	end
	local existing = ServerStorage:FindFirstChild("BreachpointDebug")
	if existing then
		existing:Destroy()
	end
	local bindable = Instance.new("BindableFunction")
	bindable.Name = "BreachpointDebug"
	bindable.OnInvoke = function(name: string, ...: any)
		local command = commands[name]
		if not command then
			local names = {}
			for key in commands do
				table.insert(names, key)
			end
			table.sort(names)
			return "unknown command; available: " .. table.concat(names, ", ")
		end
		return command(...)
	end
	bindable.Parent = ServerStorage
end

function DebugService.start() end

return DebugService
