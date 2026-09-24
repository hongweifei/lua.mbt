-- Coroutines: what one resume/yield pair costs, and what a resume nested inside
-- another coroutine costs.

local t0 = os.clock()

local N = 100000
local gen = coroutine.wrap(function()
  for i = 1, N do coroutine.yield(i) end
  return 0
end)

local s = 0
for _ = 1, N do s = s + gen() end

local t1 = os.clock()

-- A coroutine that resumes another one: two switches per item, and the inner
-- body runs on a stack the outer one already entered.
local inner = coroutine.wrap(function()
  while true do coroutine.yield(1) end
end)
local outer = coroutine.wrap(function()
  for i = 1, N do
    inner()
    coroutine.yield(i)
  end
end)

local s2 = 0
for _ = 1, N do s2 = s2 + outer() end

local t2 = os.clock()

assert(s == 5000050000, "the direct generator: " .. s)
assert(s2 == 5000050000, "the nested one: " .. s2)
print(("bench\tcoroutine-switch\t%.3f\t%d"):format(t1 - t0, s))
print(("bench\tcoroutine-nested\t%.3f\t%d"):format(t2 - t1, s2))
