-- Lua calls: recursion, a method call, a closure call.
--
-- Every case in bench/ prints one line for tools/run_bench.mbtx:
--     bench <name> <cpu seconds> <checksum>
-- and asserts its checksum, so both implementations have to agree on what the
-- work produced, not only on how long it took.  The constants were taken from a
-- build of the reference implementation (see README, "License and sources").

local N = 24

local function fib(n)
  if n < 2 then return n end
  return fib(n - 1) + fib(n - 2)
end

local Counter = {}
Counter.__index = Counter
function Counter.new() return setmetatable({ n = 0 }, Counter) end
function Counter:bump(k)
  self.n = self.n + k
  return self.n
end

local function make_adder(k)
  return function(x) return x + k end
end

local t0 = os.clock()

local sum = fib(N)                                   -- 46368

local c = Counter.new()
for _ = 1, 20000 do c:bump(1) end
sum = sum + c.n                                      -- 20000

local add3 = make_adder(3)
for i = 1, 20000 do sum = sum + add3(i) end          -- 200070000

local dt = os.clock() - t0
assert(sum == 200136368, "calls: " .. sum)
print(("bench\tcalls\t%.3f\t%d"):format(dt, sum))
