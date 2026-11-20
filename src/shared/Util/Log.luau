--!strict
-- Tagged logging. `debug` lines are off by default and can be switched on at runtime in Studio.

local Log = {}

Log.verbose = false

function Log.info(tag: string, message: string)
	print(string.format("[%s] %s", tag, message))
end

function Log.debug(tag: string, message: string)
	if Log.verbose then
		print(string.format("[%s] %s", tag, message))
	end
end

function Log.warn(tag: string, message: string)
	warn(string.format("[%s] %s", tag, message))
end

return Log
