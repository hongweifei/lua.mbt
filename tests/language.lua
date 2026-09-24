-- Language level behaviour: values, operators, control flow, closures,
-- multiple results, varargs, metatables, errors, goto and coroutines.

local function eq(a, b, what)
  if a ~= b then
    error(string.format("%s: expected %s, got %s", what or "value", tostring(b), tostring(a)), 2)
  end
end

-- ---------------------------------------------------------------- numbers
eq(1 + 2, 3, "integer addition")
eq(7 // 2, 3, "floor division")
eq(-7 // 2, -4, "floor division of a negative")
eq(7 % 3, 1, "modulo")
eq(-7 % 3, 2, "modulo of a negative")
eq(2^10, 1024.0, "power is a float")
eq(10 / 4, 2.5, "division is a float")
eq(math.type(1), "integer", "integer subtype")
eq(math.type(1.0), "float", "float subtype")
eq(1 == 1.0, true, "cross subtype equality")
eq(math.maxinteger + 1 == math.mininteger, true, "integers wrap around")
eq(0xFFFFFFFFFFFFFFFF, -1, "hexadecimal wraps around")
eq(3 & 5, 1, "bitwise and")
eq(3 | 5, 7, "bitwise or")
eq(5 ~ 3, 6, "bitwise xor")
eq(1 << 62, 4611686018427387904, "shift left")
eq(-1 >> 1, 0x7FFFFFFFFFFFFFFF, "shift right fills with zeros")
eq(1 // 0.0, math.huge, "float division by zero")
eq(tostring(1/0), "inf", "infinity prints as inf")
eq(tostring(0/0), "nan", "nan prints as nan")

-- ---------------------------------------------------------------- strings
eq("a" .. "b" .. 1 .. 2, "ab12", "concatenation coerces numbers")
eq(#"hello", 5, "length operator")
eq(("x"):rep(3), "xxx", "string.rep as a method")
eq("10" + 5, 15, "string arithmetic")
eq(tonumber("0x1p4"), 16.0, "hexadecimal float")
eq(tonumber("  42  "), 42, "tonumber skips spaces")
eq(tonumber("ff", 16), 255, "tonumber with a base")
eq(tonumber("z"), nil, "tonumber of garbage")

-- ---------------------------------------------------------------- tables
local t = {1, 2, 3}
eq(#t, 3, "sequence length")
t[2] = nil
eq(#t, 3, "a border may be any index whose successor is nil")
t[3] = nil
eq(#t, 1, "the border falls back to the first hole")
t[2] = 2
t[3] = 3
eq(#t, 3, "restoring the elements")
t.x = "y"
eq(t.x, "y", "field assignment")
eq(t["x"], "y", "field access by string")
eq(#t, 3, "fields do not affect the border")
local keyed = {[1] = "a", ["b"] = 2, [true] = 3}
eq(keyed[1], "a", "integer key")
eq(keyed.b, 2, "string key")
eq(keyed[true], 3, "boolean key")
local floatkey = {}
floatkey[1.0] = "one"
eq(floatkey[1], "one", "integral float key normalises to an integer")

-- ---------------------------------------------------------------- control flow
local sum = 0
for i = 1, 10 do sum = sum + i end
eq(sum, 55, "numeric for")
sum = 0
for i = 10, 1, -2 do sum = sum + i end
eq(sum, 30, "numeric for with a step")
sum = 0
local i = 0
while i < 5 do i = i + 1 sum = sum + i end
eq(sum, 15, "while loop")
sum = 0
repeat sum = sum + 1 until sum >= 3
eq(sum, 3, "repeat loop")
local found = nil
for n = 1, 10 do if n % 4 == 0 then found = n break end end
eq(found, 4, "break")

-- ---------------------------------------------------------------- functions
local function add(a, b) return a + b end
eq(add(2, 3), 5, "function call")
local function multi() return 1, 2, 3 end
local a, b, c, d = multi()
eq(a, 1, "first result")
eq(c, 3, "third result")
eq(d, nil, "missing result")
eq(select("#", multi()), 3, "select counts results")
eq((multi()), 1, "parentheses truncate to one value")
local function count(...) return select("#", ...) end
eq(count(1, nil, 3), 3, "varargs count")
local function tail(...) return ... end
eq(select("#", tail(multi())), 3, "varargs expand a call")
local function default(a, b) return b == nil and "default" or b end
eq(default(1), "default", "missing argument is nil")

-- closures and upvalues
local function counter()
  local n = 0
  return function() n = n + 1 return n end
end
local c1 = counter()
c1()
eq(c1(), 2, "closure keeps its own state")
local fs = {}
for k = 1, 3 do fs[k] = function() return k end end
eq(fs[1]() + fs[2]() + fs[3](), 6, "loop variable per iteration")

-- ---------------------------------------------------------------- metatables
local mt = {}
mt.__index = function(_, k) return "default:" .. k end
mt.__newindex = function(tbl, k, v) rawset(tbl, k, v .. "!") end
mt.__add = function(x, y) return x.value + y.value end
mt.__eq = function(x, y) return x.value == y.value end
mt.__lt = function(x, y) return x.value < y.value end
mt.__len = function() return 42 end
mt.__call = function(self, x) return self.value + x end
mt.__tostring = function() return "obj" end
local o = setmetatable({value = 10}, mt)
local p = setmetatable({value = 20}, mt)
eq(o.missing, "default:missing", "__index function")
o.field = "v"
eq(o.field, "v!", "__newindex")
eq(o + p, 30, "__add")
eq(o < p, true, "__lt")
eq(o == setmetatable({value = 10}, mt), true, "__eq")
eq(#o, 42, "__len")
eq(o(5), 15, "__call")
eq(tostring(o), "obj", "__tostring")
local base = {greet = function() return "hi" end}
local derived = setmetatable({}, {__index = base})
eq(derived.greet(), "hi", "__index table")

-- ---------------------------------------------------------------- errors
local ok, err = pcall(function() error("boom") end)
eq(ok, false, "pcall catches an error")
eq(err:match("boom") ~= nil, true, "error message travels")
eq(select("#", pcall(function() return 1, 2 end)), 3, "pcall returns all results")
local ok2, err2 = pcall(function() local x = nil return x.field end)
eq(ok2, false, "indexing nil raises")
eq(err2:match("attempt to index") ~= nil, true, "index error message")
local ok3, err3 = xpcall(function() error("x") end, function(e) return "handled:" .. e end)
eq(ok3, false, "xpcall reports failure")
eq(err3:match("handled:") ~= nil, true, "xpcall handler result")
local ok4 = pcall(error, {code = 7})
eq(ok4, false, "non string errors propagate")
local _, err4 = pcall(error, {code = 7})
eq(type(err4), "table", "error object stays a table")
eq(pcall(function() return 1/0 end), true, "no error for infinity")

-- ---------------------------------------------------------------- goto
local n = 0
for k = 1, 10 do
  if k % 2 == 0 then goto continue end
  n = n + 1
  ::continue::
end
eq(n, 5, "goto skips")

-- ---------------------------------------------------------------- coroutines
local co = coroutine.create(function(a, b)
  local c = coroutine.yield(a + b)
  return c * 2
end)
local ok5, v5 = coroutine.resume(co, 1, 2)
eq(ok5, true, "coroutine resumes")
eq(v5, 3, "yield value")
eq(coroutine.status(co), "suspended", "suspended status")
local ok6, v6 = coroutine.resume(co, 10)
eq(ok6, true, "second resume")
eq(v6, 20, "return value after resume")
eq(coroutine.status(co), "dead", "dead status")
eq(select(1, coroutine.resume(co)), false, "resuming a dead coroutine fails")
local gen = coroutine.wrap(function() for k = 1, 3 do coroutine.yield(k) end end)
eq(gen() + gen() + gen(), 6, "wrap iterator")
local nested = coroutine.wrap(function()
  local inner = coroutine.wrap(function() coroutine.yield("inner") return "done" end)
  coroutine.yield(inner())
  return inner()
end)
eq(nested(), "inner", "nested coroutines")
eq(nested(), "done", "nested coroutines finish")

-- A failure inside a wrapped coroutine is re-raised where the wrapper was
-- called, with that call's position in front of the coroutine's own message,
-- so the two positions tell the failure and the call apart.  A call made from
-- a C function -- an ordinary `pcall`, say -- has no position to add.
do
  local src = debug.getinfo(1, "S").short_src
  local function occurrences(s, needle)
    local n, i = 0, 1
    while true do
      local _, b = string.find(s, needle, i, true)
      if not b then return n end
      n, i = n + 1, b + 1
    end
  end
  local f = coroutine.wrap(function () error("inner") end)
  local st, msg = pcall(f)
  eq(st, false, "a wrapped failure propagates")
  eq(string.find(msg, "inner", 1, true) ~= nil, true, "the failure is named")
  eq(msg:sub(1, #src) == src, true, "the coroutine's own position comes first")

  local g = coroutine.wrap(function () error("inner") end)
  local st2, msg2 = pcall(function () g() end)
  eq(st2, false, "a wrapped failure propagates from a Lua caller too")
  eq(occurrences(msg2, src), occurrences(msg, src) + 1,
     "the caller's position is prefixed to it")

  -- An error object that is not a string is passed on untouched.
  local h = coroutine.wrap(function () error({}) end)
  local st3, obj = pcall(h)
  eq(st3, false, "a wrapped table error propagates")
  eq(type(obj), "table", "and is not turned into a string")
end

-- yield inside pcall must work
local co2 = coroutine.create(function()
  local ok7, y = pcall(function() return coroutine.yield("from pcall") end)
  return ok7, y
end)
local ok8, y1 = coroutine.resume(co2)
eq(y1, "from pcall", "yield inside pcall")
local ok9, r1, r2 = coroutine.resume(co2, "resumed")
eq(r1, true, "pcall succeeded")
eq(r2, "resumed", "pcall returned the resume value")

-- ------------------------------------------------------- table keys and traversal
-- Keys are held by identity, and every kind of value can be one.
do
  local f = function() end
  local t = {
    [1] = 1, [1.5] = 2, x = 3, [string.rep("y ", 300)] = 4,
    [f] = 5, [print] = 6, [coroutine.running()] = 7, [true] = 8,
    [io.stdin] = 9, [{}] = 10,
  }
  local n = 0
  for k in pairs(t) do n = n + 1 end
  eq(n, 10, "every kind of key is traversed")
  eq(t[f], 5, "a function key reads back")
end

-- Clearing a value leaves the key in place, so a traversal that deletes the key
-- it was given can still be resumed with it.
do
  local t = {}
  local keys = {}
  for i = 1, 6 do local k = {}; keys[i] = k; t[k] = i end
  local seen = 0
  for k, v in pairs(t) do
    seen = seen + 1
    eq(t[k], v, "value before clearing")
    t[k] = nil
    eq(t[k], nil, "value after clearing")
  end
  eq(seen, 6, "a traversal with deletions visits everything")
  eq(next(t), nil, "and leaves the table empty")
end

-- ------------------------------------------------------------- numeric for edges
-- An integer loop counts its iterations, so it cannot wrap around at the end of
-- the range, and a limit beyond the integers stops the loop on the right side.
do
  local function count(first, last, step)
    local n = 0
    if step == nil then
      for _ = first, last do n = n + 1 end
    else
      for _ = first, last, step do n = n + 1 end
    end
    return n
  end
  eq(count(math.maxinteger - 1, math.maxinteger), 2, "up to the largest integer")
  eq(count(math.mininteger, math.mininteger + 1), 2, "from the smallest integer")
  eq(count(math.maxinteger, math.maxinteger), 1, "one iteration at the top")
  eq(count(1, 10.5), 10, "a float limit is rounded down")
  eq(count(1, 10.5, "1"), 10, "a string step makes it a float loop")
  eq(count("10", "1", "-2"), 5, "string bounds are converted")
  eq(count(math.mininteger, math.maxinteger, math.maxinteger), 3, "a huge step from the bottom")
  eq(count(math.mininteger, -10e100), 0, "a limit below the range stops an up loop")
  eq(count(math.maxinteger, 10e100, -1), 0, "a limit above the range stops a down loop")
  eq(count(math.maxinteger, 10e100), 1, "a limit beyond the range still runs once")
  local seen = {}
  for i = "10", "1", "-2" do seen[#seen + 1] = i end
  eq(seen[1] == 10 and seen[5] == 2, true, "float loop values")
end

-- A `goto` may leave the scope of a to-be-closed variable, and leaving it has
-- to close the variable just as falling off the end of the block would.
do
  local closed = false
  do
    local x <close> = setmetatable({}, {__close = function () closed = true end})
    do
      goto out
    end
    ::out::
  end
  eq(closed, true, "jumping out of its scope closes the variable")
end

-- A failing `__close` handler does not stop the ones declared before it: its
-- error becomes the one the next handler receives, and the last failure is
-- what propagates.  The message handler of an enclosing `xpcall` runs where the
-- error was raised, so it still sees the `__close` frame.
do
  local function closable(f) return setmetatable({}, {__close = f}) end
  local seen = {}
  local n = 0
  local function foo()
    do
      local x1 <close> = closable(function (_, msg) n = n + 1; seen[n] = msg; error("@Y") end)
      local x2 <close> = closable(function (_, msg) n = n + 1; seen[n] = msg; error("@X") end)
    end
  end
  local st, msg = xpcall(foo, debug.traceback)
  eq(st, false, "the block fails")
  eq(seen[1], nil, "the first handler closed gets no error")
  eq(string.find(seen[2], "@X") ~= nil, true, "the second gets the first failure")
  eq(string.match(msg, "^[^ ]* @Y") ~= nil, true, "the last failure is what propagates")
  eq(string.find(seen[2], "in metamethod 'close'") ~= nil, true, "the close frame is named")
end

-- A to-be-closed variable declared inside a close method is closed by the same
-- unwinding, each handler receiving the error before it.
do
  local function closable(f) return setmetatable({}, {__close = f}) end
  local track = {}
  local function foo()
    local x0 <close> = closable(function (_, msg)
      eq(msg, 202, "the outermost handler gets the last error")
      track[#track + 1] = "x0"
    end)
    local x <close> = closable(function ()
      local xx <close> = closable(function (_, msg)
        eq(msg, 101, "the inner handler gets the first error")
        track[#track + 1] = "xx"
        error(202)
      end)
      track[#track + 1] = "x"
      error(101)
    end)
    track[#track + 1] = "foo"
  end
  local st, msg = pcall(foo)
  eq(st, false, "the call fails")
  eq(msg, 202, "the last failure is reported")
  eq(table.concat(track, ","), "foo,x,xx,x0", "every handler ran, innermost first")
end

-- The declaration names the variable that is not closable, and removing the
-- metamethod later reports it as a call of the metamethod.
do
  local function foo()
    local xyz <close> = {}
  end
  local st, msg = pcall(foo)
  eq(st, false, "a non-closable value is refused")
  eq(string.find(msg, "variable 'xyz' got a non%-closable value") ~= nil, true, "named")

  local function bar()
    local abc <close> = setmetatable({}, {__close = print})
    getmetatable(abc).__close = nil
  end
  local st2, msg2 = pcall(bar)
  eq(st2, false, "the removal is noticed at the close")
  eq(string.find(msg2, "metamethod 'close'") ~= nil, true, "reported as the metamethod")
end

-- A close handler that turns the return hook on is still followed by the event
-- for the return it interrupted.
do
  local trace = {}
  local function hook(event) trace[#trace + 1] = event .. " " .. debug.getinfo(2).name end
  local function foo(...)
    local x <close> = setmetatable({}, {__close = function () trace[#trace + 1] = "x" end})
    local y <close> = setmetatable({}, {__close = function () debug.sethook(hook, "r") end})
    return ...
  end
  local t = {foo(10, 20, 30)}
  debug.sethook()
  eq(table.concat(t, ","), "10,20,30", "the results are the arguments")
  eq(table.concat(trace, "|"),
     "return sethook|return close|x|return close|return foo",
     "the return event follows the closes")
end

-- Closing a coroutine drops the message handler it was suspended inside, so an
-- `xpcall` does not handle what the closing raises.
do
  local c = coroutine.create(function()
    local clo <close> = setmetatable({}, {__close = function () error(134) end})
    xpcall(coroutine.yield, function () return "XXX" end)
  end)
  local ok = coroutine.resume(c)
  eq(ok, true, "the yield suspends the coroutine")
  eq(coroutine.status(c), "suspended", "and leaves it suspended")
  local st, msg = coroutine.close(c)
  eq(st, false, "the close reports the failure")
  eq(msg, 134, "not the suspended message handler")
end

-- A `yield` standing as the argument of a protected call suspends the thread
-- just as one called directly does.
do
  local got
  local c = coroutine.create(function ()
    got = select(2, xpcall(coroutine.yield, function () return "XXX" end))
  end)
  eq(coroutine.resume(c), true, "the protected call yields")
  eq(coroutine.status(c), "suspended", "and stays suspended")
  eq(coroutine.resume(c, 7), true, "a later resume finishes the yield")
  eq(got, 7, "the value reaches the protected call's results")
  eq(coroutine.status(c), "dead", "and the body is done")
end

-- A `__close` handler may yield.  The coroutine suspends inside it, and the
-- return it interrupted runs again when it is resumed, which is what closes the
-- variable that is still pending.
do
  local trace = {}
  local co = coroutine.wrap(function ()
    local x <close> = setmetatable({}, {__close = function (_, msg)
      eq(msg, nil, "the first handler has no error")
      trace[#trace + 1] = "x1"
      coroutine.yield("x")
      trace[#trace + 1] = "x2"
    end})
    local y <close> = setmetatable({}, {__close = function (_, msg)
      eq(msg, nil, "the second handler has no error")
      trace[#trace + 1] = "y1"
      coroutine.yield("y")
      trace[#trace + 1] = "y2"
    end})
    return 10, 20
  end)
  eq(co(), "y", "the last declared variable closes first and yields")
  eq(co(), "x", "the next one yields too")
  eq(co(), 10, "and the return finally produces its values")
  eq(table.concat(trace, ","), "y1,y2,x1,x2", "both handlers ran to the end")
end

-- A weak table drops a value that is a host function, which is what a wrapped
-- coroutine is.
do
  local w = setmetatable({}, {__mode = "v"})
  local co = coroutine.wrap(function () coroutine.yield() end)
  co()
  w[1] = co
  co = nil
  collectgarbage()
  eq(w[1], nil, "the wrapped coroutine was collected")
end

-- A metamethod that yields suspends the coroutine wherever the call it
-- interrupted can be carried on: a value-producing instruction takes the
-- result when the thread resumes, a concatenation carries its fold on, and a
-- comparison takes its answer and decides the jump.
do
  local function val(x) return type(x) == "table" and x.x or x end
  local mt = {
    __add = function (a, b) coroutine.yield(nil, "add"); return val(a) + val(b) end,
    __lt = function (a, b) coroutine.yield(nil, "lt"); return val(a) < val(b) end,
    __concat = function (a, b)
      coroutine.yield(nil, "concat")
      return val(a) .. val(b)
    end,
  }
  local function new(x) return setmetatable({x = x}, mt) end
  local a, b, c = new(10), new(12), new"hello"

  local function run(f, t)
    local i = 1
    local co = coroutine.wrap(f)
    while true do
      local res, stat = co()
      if res then return res, t end
      eq(stat, t[i], "the " .. i .. "th yield")
      i = i + 1
    end
  end

  eq(run(function () return a + b end, {"add"}), 22, "an arithmetic metamethod")
  eq(run(function () return a < b end, {"lt"}), true, "a comparison metamethod")
  eq(run(function () return a .. b .. c end, {"concat", "concat"}),
     "1012hello", "a concatenation carries its fold on")
  eq(run(function () return "a" .. "b" .. a .. "c" .. c .. b .. "x" end,
          {"concat", "concat", "concat"}),
     "ab10chello12x", "however many operands it has left")
end

-- A `__close` handler that yields during the unwinding of a failed `pcall` is
-- resumed: the closing keeps what it has left on the marker of that call.
do
  local function closable(f) return setmetatable({}, {__close = f}) end
  local seen = {}
  local co = coroutine.wrap(function ()
    local function foo(err)
      local z <close> = closable(function (_, msg)
        seen[#seen + 1] = msg
        coroutine.yield("z")
      end)
      local y <close> = closable(function (_, msg)
        seen[#seen + 1] = msg
        coroutine.yield("y")
        if err then error(err + 20) end
      end)
      local x <close> = closable(function (_, msg)
        seen[#seen + 1] = msg
        coroutine.yield("x")
      end)
      if err == 10 then error(err) else return 10, 20 end
    end
    return pcall(foo, 10)
  end)
  eq(co(), "x", "the first handler yields with the original error")
  eq(co(), "y", "the second too")
  eq(co(), "z", "and the third, with the error the second raised")
  eq(select(1, co()), false, "the protected call reports the failure")
  eq(seen[1], 10, "the first handler saw the original error")
  eq(seen[2], 10, "so did the second")
  eq(seen[3], 30, "the third saw what the second raised")
end

-- The fourth value of a generic `for` is to-be-closed: leaving the loop early
-- runs its handler, whether by `break` or by `goto`.
do
  local function closable(f) return setmetatable({}, {__close = f}) end
  local open = 0
  local function gen(x)
    open = open + 1
    return function () x = x - 1; if x > 0 then return x end end,
      nil, nil,
      closable(function () open = open - 1 end)
  end
  local s = 0
  for i in gen(10) do
    if i < 5 then break end
    s = s + i
  end
  eq(s, 35, "the loop broke where it should")
  eq(open, 0, "and its closing value was closed")

  local t = 0
  for i in gen(10) do
    for j in gen(10) do
      if i + j < 5 then goto done end
      t = t + i
    end
  end
  ::done::
  eq(t, 375, "the jump left both loops")
  eq(open, 0, "and closed what both of them owned")
end

-- `pairs` may yield through a `__pairs`, which finishes the call it stands for
-- instead of calling it again.
do
  local t = setmetatable({10, 20, 30}, {__pairs = function (self)
    local inc = coroutine.yield()
    return function (_, i)
             if i > 1 then return i - inc, self[i - inc] end
           end, self, #self + 1
  end})
  local res = {}
  local co = coroutine.wrap(function ()
    for _, p in pairs(t) do res[#res + 1] = p end
  end)
  co()
  co(1)
  eq(table.concat(res, ","), "30,20,10", "the iterator ran to the end")
end

-- A wrapped coroutine that dies with an error closes the to-be-closed
-- variables its frames still own.
do
  local closed = false
  local co = coroutine.wrap(function ()
    local x <close> = setmetatable({}, {__close = function () closed = true end})
    error(23)
  end)
  local ok, msg = pcall(co)
  eq(ok, false, "the failure reaches the caller")
  eq(msg, 23, "with the error the coroutine raised")
  eq(closed, true, "and its variables were closed")
end

-- Reachability is transitive: a weak table keeps an entry whose object is
-- reached only through something else that is still alive.
do
  local w = setmetatable({}, {__mode = "v"})
  local holder = {}
  w[1] = holder          -- reached from a live local
  local deep = {inner = {deeper = {}}}
  w[2] = deep.inner.deeper  -- reached only two levels down
  collectgarbage()
  eq(w[1] ~= nil, true, "a value held by a live local survives")
  eq(w[2] ~= nil, true, "so does one reached only through it")
  holder = nil
  deep = nil
  collectgarbage()
  eq(w[1], nil, "and goes once nothing reaches it")
  eq(w[2], nil, "both of them")
end

-- Values leave a weak table before the objects awaiting finalization are
-- resurrected, keys after: an object with a `__gc` can therefore free a value
-- from a weak table while a weak *key* pointing at it still survives.
do
  local t = {x = 10}
  local C = setmetatable({key = t}, {__mode = "v"})
  local C1 = setmetatable({[t] = 1}, {__mode = "k"})
  local a = {x = t}
  setmetatable(a, {__gc = function ()
    eq(C.key, nil, "the value went")
    eq(type(next(C1)), "table", "the key stayed")
  end})
  a, t = nil, nil
  collectgarbage()
  collectgarbage()
  eq(next(C), nil, "and both are gone afterwards")
  eq(next(C1), nil, "once nothing resurrects them")
end

-- The collector runs by itself as a program allocates, without being asked.
do
  local w = setmetatable({}, {__mode = "v"})
  w[1] = {}
  local spin = true
  local n = 0
  repeat
    local garbage = {}
    n = n + 1
  until w[1] == nil or n > 200000
  eq(w[1], nil, "an automatic collection cleared the weak table")
end

-- An ephemeron chain goes in one cycle, not one link per cycle: an entry whose
-- key is reached only through another entry's value has to be dropped with it,
-- or every later collection takes one more link.
do
  local a = setmetatable({}, {__mode = "k"})
  local x = nil
  for i = 1, 40 do local n = {}; a[n] = {k = {x}}; x = n end
  local function links()
    local n, i = x, 0
    while n do n = a[n].k[1]; i = i + 1 end
    return i
  end
  local function entries()
    local c = 0
    for _ in pairs(a) do c = c + 1 end
    return c
  end
  eq(links(), 40, "the chain is intact")
  eq(entries(), 40, "with one entry per link")
  x = nil
  collectgarbage()
  eq(entries(), 0, "and all of it goes at once")
end

-- `collectgarbage("count")` reports what the live set holds, the bytes of its
-- strings included, and falls when a cycle frees what nothing reaches.
do
  collectgarbage()
  collectgarbage()
  local m = collectgarbage("count")
  local a = setmetatable({}, {__mode = "kv"})
  local key = string.rep("a", 2^20)
  a[key] = 25
  a[string.rep("b", 2^20)] = {}
  eq(collectgarbage("count") - m > 1000, true, "the strings show in the count")
  collectgarbage()
  local k = next(a)
  eq(k, key, "a string key is never weak, so it stays")
  eq(next(a, k), nil, "while the entry with a collectable value goes")
end

-- A later assignment target can disturb an earlier indexed one: the stores run
-- from the last target to the first, so the table and the key an indexed target
-- reads are copied when a later target would change them.
do
  local a, i, j, b
  a = {"a", "b"}
  i = 1
  j = 2
  b = a
  i, a[i], a, j, a[j], a[i+j] = j, i, i, b, j, i
  eq(i, 2, "the first target took its value")
  eq(a, 1, "the table local became a number")
  eq(b[1], 1, "and the table it used kept the field")
  eq(b[2], 2, "written under the key the target captured")
  eq(b[3], 1, "and under the sum of both keys")
end

-- The numbers a program hands the collector are its own, so an extreme pause
-- or step size must stay usable: neither may wrap the threshold, and a step
-- size cannot wrap the work a step is charged (which would leave the cycle
-- unable to finish).
do
  collectgarbage()
  local w = setmetatable({}, {__mode = "v"})
  w[1] = {}
  local prevpause = collectgarbage("setpause", 0x7ffffffe)
  collectgarbage("setpause", prevpause)
  collectgarbage()
  eq(collectgarbage("count") > 0, true, "an extreme pause is still usable")
  collectgarbage("step", 0x7ffffffe)
  collectgarbage("step", 20000)
  collectgarbage()
  eq(w[1], nil, "and an extreme step size still collects")
end

-- `setstepmul` scales the work one step is worth, which is what it does in the
-- reference (`incstep` multiplies the debt by it): a larger multiplier finishes a
-- cycle in fewer calls than a smaller one.  A parameter is stored as a multiple
-- of four, as the reference stores it, so what it last reported comes back
-- rounded down.
do
  local function steps(mul, size)
    collectgarbage("setstepmul", mul)
    collectgarbage()
    local n = 0
    repeat n = n + 1 until collectgarbage("step", size)
    return n
  end
  eq(steps(5000, 2) < steps(100, 2), true, "a larger stepmul needs fewer steps")
  eq(steps(50, 2) > steps(100, 2), true, "and a smaller one needs more")
  eq(steps(100, 20000), 1, "a step of a cycle's size still finishes it at once")
  collectgarbage("setstepmul", 50)
  eq(collectgarbage("setstepmul", 100), 48, "a parameter comes back a multiple of four")
end

-- `count` carries the objects a library function makes, not only the strings.
do
  collectgarbage()
  local before = collectgarbage("count")
  local t = {}
  for i = 1, 20000 do t[i] = {i} end
  eq(collectgarbage("count") > before, true, "the tables a program makes show in the count")
end

-- A fresh state is in *generational* mode: the mode a change reports is the one
-- being left, so the first switch to incremental answers "generational".
do
  eq(collectgarbage("incremental"), "generational",
    "a fresh state starts in generational mode")
  eq(collectgarbage("generational"), "incremental",
    "and the mode it left is what a change reports")
end

-- Inside a `__gc` the collector is closed: a collection cannot be started from
-- one, and `collectgarbage` answers nil rather than doing anything.
do
  local res = "untouched"
  local u = setmetatable({}, {__gc = function () res = collectgarbage() end})
  u = nil
  collectgarbage()
  eq(res, nil, "a collection inside a finalizer does not happen")
end

-- `string.dump(f, true)` drops the debug information, and what is left says so:
-- no source, no names, no lines -- while a chunk merely *named* "" keeps its
-- name.
do
  local f = load("return function () local a = 12; return a end")()
  local stripped = load(string.dump(f, true))
  local i = debug.getinfo(stripped)
  eq(i.source, "=?", "a stripped chunk has no source")
  eq(i.short_src, "?", "and shortens it to a question mark")
  eq(i.linedefined > 0 and i.lastlinedefined == i.linedefined, true,
     "but keeps where it was defined")

  local g = load("local a = 12; return function () return a end")
  local h = load(string.dump(g()))
  eq(debug.getinfo(h, "u").nups, 1, "a dumped closure still has its upvalue")
  eq(select(1, debug.getupvalue(h, 1)), "a", "named")
  local hs = load(string.dump(h, true))
  eq(select(1, debug.getupvalue(hs, 1)), "(no name)", "and unnamed when stripped")

  local named = load("return 1", "")
  eq(debug.getinfo(named).short_src, '[string ""]', "an empty name is a name")

  -- A hook in stripped code is told no line rather than a wrong one.
  local saw_nil = false
  debug.sethook(function (e, l) if l == nil then saw_nil = true end end, "l")
  local r = stripped(); debug.sethook(nil)
  eq(r, 12, "the stripped function runs")
  eq(saw_nil, true, "and its hook is told no line")
end

-- A `...` outside a vararg function is a syntax error, not something the
-- enclosing function's varargs are read for.  Only a function whose parameter
-- list ends in `...`, and the main chunk, are vararg.
do
  local function bad(src) return load(src) == nil end
  eq(bad("local function f() return ... end"), true,
     "a plain function cannot use '...'")
  eq(bad("return function() return ... end"), true,
     "nor a nested one")
  eq(bad("local f = function() return select('#', ...) end"), true,
     "nor in any other expression")
  eq(bad("return function(...) return function() return ... end end"), true,
     "a vararg function does not make its nested function vararg")
  eq(bad("return function(...) return ... end") , false,
     "a vararg function may")
  eq(load("return ...") ~= nil, true, "and so may the main chunk")
  local ok, err = load("local function f() return ... end")
  eq(err:find("cannot use '...' outside a vararg function", 1, true) ~= nil,
     true, "with the reference's message")
end

-- Pattern matching: the caret, a back reference to a position, and the
-- messages a bad capture and a bad replacement give.
do
  local function count(s, pat)
    local n = 0
    for _ in string.gmatch(s, pat) do n = n + 1 end
    return n
  end
  -- `gmatch` hands the pattern to the matcher unchanged, so a leading caret is
  -- an ordinary character there (`find`, `match` and `gsub` do strip it).
  eq(count("abc", "^a"), 0, "a caret is not an anchor in gmatch")
  eq(count("^abc", "^a"), 1, "it is a literal there")
  eq(count("a^b", "^"), 1, "on its own too")
  eq(count("abc", "^"), 0, "and it matches nothing when absent")
  eq(string.find("abc", "^a"), 1, "while find still anchors")

  eq(select(2, pcall(string.find, "abc", "%1")), "invalid capture index %1",
     "a back reference with no capture is refused")
  eq(select(2, pcall(string.find, "abc", "()%1")), nil,
     "and one to a position capture never matches")

  eq(select(2, pcall(string.format, "%q", {})),
     "bad argument #2 to 'string.format' (value has no literal form)",
     "%q of a value with no literal form names the argument")
  eq(select(2, pcall(string.gsub, "abc", "b")),
     "bad argument #3 to 'string.gsub' (string/function/table expected, got no value)",
     "a missing replacement is reported like a wrong one")
  eq(select(2, pcall(string.gsub, "abc", "b", true)),
     "bad argument #3 to 'string.gsub' (string/function/table expected, got boolean)",
     "and a wrong one says what it got")
end

-- The value an operation blames, and the name it gives it.
do
  local function msg(f) local ok, e = pcall(f); return ok and "ok" or tostring(e) end

  -- The operand of a concatenation that cannot become text is named where it
  -- was read from.
  local t = setmetatable({}, {})
  local function from_upvalue() return t .. "" end
  eq(msg(from_upvalue):find("attempt to concatenate a table value (upvalue 't')", 1, true) ~= nil,
     true, "a concatenation names its operand")
  eq(msg(function() local l = {}; return l .. "" end)
       :find("attempt to concatenate a table value (local 'l')", 1, true) ~= nil,
     true, "as a local")

  -- An `__index` chain that ends on a value with no metatable blames *that*
  -- value, which came out of a metatable and so has no name to report.
  local indexed = msg(function()
    local x = setmetatable({}, {__index = 5}); return x.y
  end)
  eq(indexed:find("attempt to index a number value", 1, true) ~= nil, true,
     "an index chain blames the value it stopped on")
  eq(indexed:find("(local 'x')", 1, true), nil, "which has no name of its own")

  -- A to-be-closed value is only refused when it has no `__close` at all; one
  -- that is there but cannot be called fails when it is called.
  eq(select(2, pcall(function() local a <close> = 5 end))
       :find("variable 'a' got a non-closable value", 1, true) ~= nil,
     true, "a value with no __close is refused where it is declared")
  eq(select(2, pcall(function()
       local a <close> = setmetatable({}, {__close = 5})
     end)):find("attempt to call a number value (metamethod 'close')", 1, true) ~= nil,
     true, "and one with an unusable __close when the scope ends")
end

print("language: ok")
