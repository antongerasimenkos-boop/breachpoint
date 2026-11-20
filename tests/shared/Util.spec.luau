--!strict
local Cleanup = require("../../src/shared/Util/Cleanup")
local Signal = require("../../src/shared/Util/Signal")

return function(kit: any)
	local describe, it, expect = kit.describe, kit.it, kit.expect

	describe("Signal", function()
		it("fires handlers in connection order with arguments", function()
			local signal = Signal.new()
			local log = {}
			signal:connect(function(a, b)
				table.insert(log, "first " .. a .. b)
			end)
			signal:connect(function(a, b)
				table.insert(log, "second " .. a .. b)
			end)
			signal:fire("x", "y")
			expect(log).toEqual({ "first xy", "second xy" })
		end)

		it("disconnect stops delivery, including during a fire", function()
			local signal = Signal.new()
			local calls = 0
			local second
			signal:connect(function()
				second:disconnect()
			end)
			second = signal:connect(function()
				calls += 1
			end)
			signal:fire()
			signal:fire()
			expect(calls).toBe(0)
			expect(signal:connectionCount()).toBe(1)
		end)

		it("once fires a single time", function()
			local signal = Signal.new()
			local calls = 0
			signal:once(function()
				calls += 1
			end)
			signal:fire()
			signal:fire()
			expect(calls).toBe(1)
		end)

		it("an erroring handler does not stop the others", function()
			local signal = Signal.new()
			local previous = Signal.onError
			local errors = 0
			Signal.onError = function()
				errors += 1
			end
			local reached = false
			signal:connect(function()
				error("bad")
			end)
			signal:connect(function()
				reached = true
			end)
			signal:fire()
			Signal.onError = previous
			expect(reached).toBe(true)
			expect(errors).toBe(1)
		end)
	end)

	describe("Cleanup", function()
		it("releases functions and disconnectables in reverse order", function()
			local cleanup = Cleanup.new()
			local order = {}
			cleanup:add(function()
				table.insert(order, 1)
			end)
			cleanup:add({
				disconnect = function()
					table.insert(order, 2)
				end,
			})
			cleanup:add(function()
				table.insert(order, 3)
			end)
			cleanup:clean()
			expect(order).toEqual({ 3, 2, 1 })
			expect(cleanup:count()).toBe(0)
		end)

		it("keeps releasing after one item fails", function()
			local cleanup = Cleanup.new()
			local released = false
			cleanup:add(function()
				released = true
			end)
			cleanup:add(function()
				error("fail")
			end)
			cleanup:clean()
			expect(released).toBe(true)
		end)

		it("can be reused after clean()", function()
			local cleanup = Cleanup.new()
			local n = 0
			cleanup:add(function()
				n += 1
			end)
			cleanup:clean()
			cleanup:add(function()
				n += 1
			end)
			cleanup:clean()
			expect(n).toBe(2)
		end)

		it("works with Signal connections", function()
			local cleanup = Cleanup.new()
			local signal = Signal.new()
			local calls = 0
			cleanup:add(signal:connect(function()
				calls += 1
			end))
			cleanup:clean()
			signal:fire()
			expect(calls).toBe(0)
		end)
	end)
end
