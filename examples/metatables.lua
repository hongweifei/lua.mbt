-- Metatables: operator overloading, defaults and deterministic cleanup.
--
--   moon run cmd/main -- examples/metatables.lua

local function eq(actual, expected, what)
  assert(actual == expected,
    ("%s: expected %s, got %s"):format(what, tostring(expected), tostring(actual)))
end

-- A 2-D vector whose operators are overloaded.
local Vector = {}
Vector.__index = Vector

function Vector.new(x, y)
  return setmetatable({ x = x, y = y }, Vector)
end

function Vector.__add(a, b) return Vector.new(a.x + b.x, a.y + b.y) end
function Vector.__sub(a, b) return Vector.new(a.x - b.x, a.y - b.y) end
function Vector.__unm(v) return Vector.new(-v.x, -v.y) end
function Vector.__mul(a, k) return Vector.new(a.x * k, a.y * k) end
function Vector.__eq(a, b) return a.x == b.x and a.y == b.y end
function Vector.__len(v) return 2 end
function Vector.__tostring(v) return ("(%d, %d)"):format(v.x, v.y) end
function Vector.__index(self, key)
  -- A method that is not defined on the metatable and not a field falls
  -- through to this function.
  return function(...) error("no such member: " .. key, 2) end
end

local a, b = Vector.new(1, 2), Vector.new(3, 4)
eq(tostring(a + b), "(4, 6)", "__add and __tostring")
eq(tostring(a - b), "(-2, -2)", "__sub")
eq(tostring(-a), "(-1, -2)", "__unm")
eq(tostring(a * 10), "(10, 20)", "__mul")
eq(a == Vector.new(1, 2), true, "__eq compares fields")
eq(a == b, false, "and reports inequality")
eq(#a, 2, "__len")
local ok, err = pcall(function() return a.nope() end)
eq(ok, false, "an unknown member is refused")
eq(err:match("no such member: nope"), "no such member: nope", "__index supplied the method")

-- `__index` can also be a table, which is what makes inheritance work.
local Shape = {}
Shape.__index = Shape
function Shape.new(name) return setmetatable({ name = name }, Shape) end
function Shape:describe() return "a " .. self.name end

local Circle = setmetatable({}, { __index = Shape })
Circle.__index = Circle
function Circle.new(r) return setmetatable({ r = r }, Circle) end
function Circle:area() return math.pi * self.r ^ 2 end

local c = Circle.new(2)
local okz, errz = pcall(function() return c:describe() end)
eq(okz, false, "an inherited method that reads a missing field fails")
c.name = "circle"
eq(c:describe(), "a circle", "the method came down the chain of __index tables")
eq(c:area() > 12.56 and c:area() < 12.57, true, "the circle's own method")

-- `__newindex` sees writes the table does not have, which is how a read-only
-- proxy is built.
local backing = { count = 0 }
local proxy = setmetatable({}, {
  __index = backing,
  __newindex = function(_, k) error("read-only: " .. k, 2) end,
})
eq(proxy.count, 0, "__index reads through")
local ok2, err2 = pcall(function() proxy.count = 1 end)
eq(ok2, false, "a write is refused")
-- `-` is a pattern quantifier, so the message is located with a plain find.
eq(err2:find("read-only: count", 1, true) ~= nil, true, "by __newindex")
eq(backing.count, 0, "and the table is untouched")

-- `__call` makes a value callable; `__concat` and `__lt` follow the same idea.
local callable = setmetatable({}, { __call = function(self, x) return x * 2 end })
eq(callable(21), 42, "__call")
-- `..` accepts strings and numbers only, so a value with `__tostring` has to
-- be converted explicitly.
eq("v=" .. tostring(Vector.new(1, 1)), "v=(1, 1)", "tostring is explicit there")

-- A to-be-closed variable runs its handler when the block ends, however it
-- ends -- which is what makes a lock or a file deterministic.
local log = {}
local function guard(name)
  return setmetatable({}, { __close = function(_, err) log[#log + 1] = name .. (err and ":error" or "") end })
end
do
  local a <close> = guard("first")
  local b <close> = guard("second")
  log[#log + 1] = "body"
end
eq(table.concat(log, ","), "body,second,first",
  "handlers run in reverse order when the block ends")

log = {}
local ok3 = pcall(function()
  local g <close> = guard("closing")
  error("inside the block")
end)
eq(ok3, false, "the block raised")
eq(log[1], "closing:error", "and the handler saw the error")

print("metatables.lua: ok")
