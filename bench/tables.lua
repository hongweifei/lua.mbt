-- Tables: array growth, integer and string keys in the hash part, small table
-- construction, and deletion.

local N = 300000

local t0 = os.clock()

local t = {}
for i = 1, N do t[i] = i end

local s = 0
for i = 1, N do s = s + t[i] end

local t1 = os.clock()

local h = {}
for i = 1, 50000 do h["k" .. (i % 1000)] = i end
for i = 1, 50000 do s = s + h["k" .. (i % 1000)] end

local t2 = os.clock()

local small = 0
for i = 1, 150000 do
  local u = { 1, 2, 3 }
  small = small + u[2]
end

local t3 = os.clock()

for i = 1, N, 2 do t[i] = nil end
local n = 0
for _ in pairs(t) do n = n + 1 end

local t4 = os.clock()

assert(small == 300000, "the small-table loop")
assert(n == 150000, "half the array was deleted: " .. n)
print(("bench\ttable-array\t%.3f\t%d"):format(t1 - t0, s))
print(("bench\ttable-hash\t%.3f\t%d"):format(t2 - t1, s))
print(("bench\ttable-small\t%.3f\t%d"):format(t3 - t2, small))
print(("bench\ttable-delete\t%.3f\t%d"):format(t4 - t3, n))
