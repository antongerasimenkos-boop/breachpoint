--!strict
--[[
	Runtime type checks for values arriving from the network.

	A Check is `(value: any) -> (boolean, string?)`: it returns true, or false plus a reason.
	Every check assumes hostile input. Numbers must be finite unless stated otherwise, strings
	must be valid UTF-8 and bounded, and tables are checked for unexpected keys.
]]

export type Check = (value: any) -> (boolean, string?)

local t = {}

local DEFAULT_MAX_STRING = 200

local function isFinite(n: number): boolean
	return n == n and n ~= math.huge and n ~= -math.huge
end

-- Anything except nil.
function t.any(value: any): (boolean, string?)
	if value == nil then
		return false, "expected a value, got nil"
	end
	return true
end

function t.boolean(value: any): (boolean, string?)
	if type(value) ~= "boolean" then
		return false, "expected boolean, got " .. typeof(value)
	end
	return true
end

-- A finite number (rejects NaN and +/-inf, which break most arithmetic and comparisons).
function t.number(value: any): (boolean, string?)
	if type(value) ~= "number" then
		return false, "expected number, got " .. typeof(value)
	end
	if not isFinite(value) then
		return false, "expected finite number"
	end
	return true
end

function t.numberRange(min: number, max: number): Check
	return function(value: any): (boolean, string?)
		local ok, err = t.number(value)
		if not ok then
			return false, err
		end
		if value < min or value > max then
			return false,
				string.format(
					"expected number in [%s, %s], got %s",
					tostring(min),
					tostring(max),
					tostring(value)
				)
		end
		return true
	end
end

function t.integer(min: number?, max: number?): Check
	return function(value: any): (boolean, string?)
		local ok, err = t.number(value)
		if not ok then
			return false, err
		end
		if value % 1 ~= 0 then
			return false, "expected integer, got " .. tostring(value)
		end
		if (min and value < min) or (max and value > max) then
			return false, string.format("integer %d out of range", value)
		end
		return true
	end
end

function t.string(maxLength: number?): Check
	local limit = maxLength or DEFAULT_MAX_STRING
	return function(value: any): (boolean, string?)
		if type(value) ~= "string" then
			return false, "expected string, got " .. typeof(value)
		end
		if #value > limit then
			return false, string.format("string longer than %d bytes", limit)
		end
		if utf8.len(value) == nil then
			return false, "string is not valid UTF-8"
		end
		return true
	end
end

-- One of a fixed set of values (usually string enums).
function t.literal(...: any): Check
	local allowed = {}
	local names = {}
	for _, v in { ... } do
		allowed[v] = true
		table.insert(names, tostring(v))
	end
	local expected = table.concat(names, " | ")
	return function(value: any): (boolean, string?)
		if value == nil or not allowed[value] then
			return false, "expected one of " .. expected
		end
		return true
	end
end

function t.vector3(value: any): (boolean, string?)
	if typeof(value) ~= "Vector3" then
		return false, "expected Vector3, got " .. typeof(value)
	end
	if not (isFinite(value.X) and isFinite(value.Y) and isFinite(value.Z)) then
		return false, "expected finite Vector3"
	end
	return true
end

-- An Instance that IsA `className` and is still parented in the DataModel.
function t.instanceIsA(className: string): Check
	return function(value: any): (boolean, string?)
		if typeof(value) ~= "Instance" then
			return false, "expected Instance, got " .. typeof(value)
		end
		if not value:IsA(className) then
			return false, "expected " .. className .. ", got " .. value.ClassName
		end
		if value.Parent == nil then
			return false, "instance is not in the DataModel"
		end
		return true
	end
end

function t.optional(check: Check): Check
	return function(value: any): (boolean, string?)
		if value == nil then
			return true
		end
		return check(value)
	end
end

function t.union(...: Check): Check
	local checks = { ... }
	return function(value: any): (boolean, string?)
		for _, check in checks do
			if check(value) then
				return true
			end
		end
		return false, "value matched none of the allowed types"
	end
end

-- A dense array (keys 1..n, no holes, no extra keys) of at most `maxLength` items.
function t.array(check: Check, maxLength: number): Check
	return function(value: any): (boolean, string?)
		if type(value) ~= "table" then
			return false, "expected array, got " .. typeof(value)
		end
		local count = 0
		for key in value do
			count += 1
			if type(key) ~= "number" or key % 1 ~= 0 or key < 1 then
				return false, "array has a non-index key"
			end
		end
		if count ~= #value then
			return false, "array has holes"
		end
		if count > maxLength then
			return false, string.format("array longer than %d", maxLength)
		end
		for i, item in value do
			local ok, err = check(item)
			if not ok then
				return false, string.format("[%d] %s", i, err or "invalid")
			end
		end
		return true
	end
end

-- A table with exactly these fields (optional fields may be absent), no extra keys.
function t.strictInterface(shape: { [string]: Check }): Check
	return function(value: any): (boolean, string?)
		if type(value) ~= "table" then
			return false, "expected table, got " .. typeof(value)
		end
		for key in value do
			if type(key) ~= "string" or shape[key] == nil then
				return false, "unexpected key " .. tostring(key)
			end
		end
		for key, check in shape do
			local ok, err = check(value[key])
			if not ok then
				return false, key .. ": " .. (err or "invalid")
			end
		end
		return true
	end
end

return t
