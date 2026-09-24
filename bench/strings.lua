-- Strings: building one, searching it, and the library operations that walk
-- their input.

local t0 = os.clock()

local parts = {}
for i = 1, 20000 do parts[i] = "item" .. i end
local s = table.concat(parts, ",")

local t1 = os.clock()

-- A plain search for a pattern that sits near the end: the whole subject is
-- scanned once per call, which is where this implementation is furthest behind.
local found = 0
for _ = 1, 20 do
  if s:find("item19999", 1, true) then found = found + 1 end
end

local t2 = os.clock()

local g = 0
for _ = 1, 20000 do
  local _, n = ("a,b,c,d,e,f"):gsub(",", ";")
  g = g + n
end

local t3 = os.clock()

local sub = 0
for i = 1, 60000 do sub = sub + #s:sub(i, i + 4) end

local t4 = os.clock()

local rep = 0
for i = 1, 60000 do rep = rep + #("ab"):rep(i % 20) end

local t5 = os.clock()

assert(found == 20, "the searches all hit")
assert(g == 100000, "the substitutions")
-- Each residue 0..19 appears equally often, so the average length is 2 * 9.5.
assert(rep == 1140000, "the repetitions")
print(("bench\tstring-build\t%.3f\t%d"):format(t1 - t0, #s))
print(("bench\tstring-find\t%.3f\t%d"):format(t2 - t1, found))
print(("bench\tstring-gsub\t%.3f\t%d"):format(t3 - t2, g))
print(("bench\tstring-sub\t%.3f\t%d"):format(t4 - t3, sub))
print(("bench\tstring-rep\t%.3f\t%d"):format(t5 - t4, rep))
