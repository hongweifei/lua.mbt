-- Integer, float and bitwise arithmetic in tight loops: the cost of the
-- dispatch itself, with as little else as possible in the body.

local t0 = os.clock()

local a, b, s = 1, 2, 0
for i = 1, 600000 do
  a = (a + i) % 1000003
  b = (b * 3) % 1000003
  s = s + a + b
end

local t1 = os.clock()

local f = 0.0
for i = 1, 500000 do
  f = f + i * 0.5
end

local t2 = os.clock()

local bits = 0
for i = 1, 500000 do
  bits = bits ~ (i << 3)
end

local t3 = os.clock()

assert(math.type(s) == "integer", "the integer loop stayed integral")
assert(math.type(f) == "float", "the float loop stayed a float")
assert(math.type(bits) == "integer", "the bitwise loop stayed integral")
print(("bench\tarith-int\t%.3f\t%d"):format(t1 - t0, s))
print(("bench\tarith-float\t%.3f\t%d"):format(t2 - t1, f))
print(("bench\tarith-bits\t%.3f\t%d"):format(t3 - t2, bits))
