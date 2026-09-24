-- A tour of the language as this interpreter runs it.
--
--   moon run cmd/main -- examples/basics.lua
--
-- The checks below are assertions rather than expected output, so running the
-- file through any Lua 5.4 is the test:
--
--   lua examples/basics.lua

local function eq(actual, expected, what)
  assert(actual == expected,
    ("%s: expected %s, got %s"):format(what, tostring(expected), tostring(actual)))
end

-- ---------------------------------------------------------------- numbers
-- Integers and floats are distinct subtypes, and they compare by value.
eq(math.type(3), "integer", "3 is an integer")
eq(math.type(3.0), "float", "3.0 is a float")
eq(3 == 3.0, true, "an integer and an equal float compare equal")
eq(math.maxinteger + 1 == math.mininteger, true, "integer arithmetic wraps around")
eq(2 ^ 53 + 1 == 2 ^ 53, true, "a float holds 53 bits of mantissa")
eq(7 // 2, 3, "floor division")
eq(7 % -2, -1, "the remainder takes the divisor's sign")
eq(1 / 0, math.huge, "division of integers is float division")

-- ---------------------------------------------------------------- strings
-- A Lua string is a byte sequence, not text.
local s = "hello, world"
eq(#s, 12, "length in bytes")
eq(s:sub(-5), "world", "a negative index counts from the end")
eq(("a,b,,c"):gsub(",", ";"), "a;b;;c", "gsub with a replacement string")
eq(("a1b2"):gsub("%d", function(d) return "[" .. d .. "]" end), "a[1]b[2]",
  "gsub with a function")
eq(("%5.1f|%-5s"):format(3.2, "ab"), "  3.2|ab   ", "format takes width and precision")
local first, last = ("words here"):find("here")
eq(first, 7, "find reports the first index")
eq(last, 10, "and the last")

-- ---------------------------------------------------------------- tables
local t = { 10, 20, 30, name = "triple" }
t[3] = t[3] + 1
eq(#t, 3, "the length operator")
eq(t.name, "triple", "a field")
-- `t[1.0]` and `t[1]` denote the same slot.
eq(t[1.0], 10, "an integral float key normalises to an integer")
local count = 0
for k, v in pairs(t) do count = count + 1 end
eq(count, 4, "pairs visits every key")
table.sort(t, function(a, b) return a > b end)
eq(table.concat(t, ","), "31,20,10", "sort with a comparator")
eq(table.unpack({ 1, 2, 3 }), 1, "unpack returns the first element")

-- ---------------------------------------------------------------- functions
-- A closure captures its upvalues by reference.
local function counter()
  local n = 0
  return function() n = n + 1 return n end
end
local next_number = counter()
next_number()
eq(next_number(), 2, "the closure keeps its state")

local function sum(...)
  local total = 0
  for _, v in ipairs({ ... }) do total = total + v end
  return total
end
eq(sum(1, 2, 3, 4), 10, "varargs")

-- A tail call does not grow the stack.
local function count_down(n) if n == 0 then return "bottom" end return count_down(n - 1) end
eq(count_down(100000), "bottom", "a tail call is iterative")

-- ---------------------------------------------------------------- errors
local ok, err = pcall(function() error("boom") end)
eq(ok, false, "pcall catches")
eq(err:match("boom"), "boom", "and hands back the message")
local ok2, err2 = pcall(function() error({ code = 42 }) end)
eq(err2.code, 42, "an error value need not be a string")
local handled = xpcall(function() error("x") end,
  function(e) return "handled:" .. e end)
eq(handled, false, "xpcall reports failure")
eq(debug.traceback ~= nil, true, "the debug library is present")

print("basics.lua: ok")
