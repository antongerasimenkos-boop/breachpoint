--!strict
--[[
	TestKit — a deliberately tiny describe/it/expect harness for Lune.

	Spec files return a function that receives the kit, so specs never hard-code a path to it.
	That keeps the RemoteGuard package's specs portable outside this repository.

		return function(kit)
			kit.describe("Thing", function()
				kit.it("works", function()
					kit.expect(1 + 1).toBe(2)
				end)
			end)
		end
]]

export type Expectation = {
	toBe: (expected: any) -> (),
	toEqual: (expected: any) -> (),
	toBeNil: () -> (),
	toBeTruthy: () -> (),
	toBeFalsy: () -> (),
	toBeCloseTo: (expected: number, epsilon: number?) -> (),
	toBeGreaterThan: (n: number) -> (),
	toBeLessThan: (n: number) -> (),
	toContain: (item: any) -> (),
	toHaveLength: (n: number) -> (),
	toThrow: (pattern: string?) -> (),
}

export type Kit = {
	describe: (name: string, body: () -> ()) -> (),
	it: (name: string, body: () -> ()) -> (),
	expect: (value: any) -> Expectation,
}

export type Result = {
	name: string,
	ok: boolean,
	err: string?,
}

local TestKit = {}

local function format(value: any): string
	if type(value) == "string" then
		return string.format("%q", value)
	elseif type(value) == "table" then
		local parts = {}
		local count = 0
		for k, v in value do
			count += 1
			if count > 8 then
				table.insert(parts, "...")
				break
			end
			table.insert(parts, tostring(k) .. "=" .. format(v))
		end
		return "{" .. table.concat(parts, ", ") .. "}"
	end
	return tostring(value)
end

local function deepEqual(a: any, b: any): boolean
	if a == b then
		return true
	end
	if type(a) ~= "table" or type(b) ~= "table" then
		return false
	end
	for k, v in a do
		if not deepEqual(v, b[k]) then
			return false
		end
	end
	for k in b do
		if a[k] == nil then
			return false
		end
	end
	return true
end

local function fail(message: string): never
	error(message, 3)
end

local function expect(value: any): Expectation
	local e = {}

	function e.toBe(expected: any)
		if value ~= expected then
			fail(string.format("expected %s to be %s", format(value), format(expected)))
		end
	end

	function e.toEqual(expected: any)
		if not deepEqual(value, expected) then
			fail(string.format("expected %s to deep-equal %s", format(value), format(expected)))
		end
	end

	function e.toBeNil()
		if value ~= nil then
			fail(string.format("expected nil, got %s", format(value)))
		end
	end

	function e.toBeTruthy()
		if not value then
			fail(string.format("expected truthy, got %s", format(value)))
		end
	end

	function e.toBeFalsy()
		if value then
			fail(string.format("expected falsy, got %s", format(value)))
		end
	end

	function e.toBeCloseTo(expected: number, epsilon: number?)
		local eps = epsilon or 1e-6
		if type(value) ~= "number" or math.abs(value - expected) > eps then
			fail(
				string.format(
					"expected %s to be within %s of %s",
					format(value),
					tostring(eps),
					tostring(expected)
				)
			)
		end
	end

	function e.toBeGreaterThan(n: number)
		if type(value) ~= "number" or not (value > n) then
			fail(string.format("expected %s > %s", format(value), tostring(n)))
		end
	end

	function e.toBeLessThan(n: number)
		if type(value) ~= "number" or not (value < n) then
			fail(string.format("expected %s < %s", format(value), tostring(n)))
		end
	end

	function e.toContain(item: any)
		if type(value) == "string" then
			if not string.find(value, item, 1, true) then
				fail(string.format("expected %s to contain %s", format(value), format(item)))
			end
			return
		end
		if type(value) == "table" then
			for _, v in value do
				if deepEqual(v, item) then
					return
				end
			end
		end
		fail(string.format("expected %s to contain %s", format(value), format(item)))
	end

	function e.toHaveLength(n: number)
		if type(value) ~= "table" and type(value) ~= "string" then
			fail("toHaveLength needs a table or string")
		end
		if #value ~= n then
			fail(string.format("expected length %d, got %d", n, #value))
		end
	end

	function e.toThrow(pattern: string?)
		if type(value) ~= "function" then
			fail("toThrow needs a function")
		end
		local ok, err = pcall(value)
		if ok then
			fail("expected function to throw")
		end
		if pattern and not string.find(tostring(err), pattern, 1, true) then
			fail(
				string.format("expected error containing %s, got %s", format(pattern), format(tostring(err)))
			)
		end
	end

	return e
end

-- Runs one spec module and returns the flat list of results.
function TestKit.run(spec: (Kit) -> ()): { Result }
	local results: { Result } = {}
	local prefix: { string } = {}

	local kit: Kit = {
		describe = function(name: string, body: () -> ())
			table.insert(prefix, name)
			body()
			table.remove(prefix)
		end,
		it = function(name: string, body: () -> ())
			local fullName = table.concat(prefix, " > ") .. " > " .. name
			local ok, err = xpcall(body, function(e)
				return tostring(e)
			end)
			table.insert(results, { name = fullName, ok = ok, err = if ok then nil else err })
		end,
		expect = expect,
	}

	spec(kit)
	return results
end

TestKit.deepEqual = deepEqual

return TestKit
