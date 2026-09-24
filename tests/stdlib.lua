-- Standard library behaviour: strings and patterns, tables, math, os, io,
-- together with the multiple assignment and iteration corner cases.

local function eq(a, b, what)
  if a ~= b then
    error(string.format("%s: expected %s, got %s", what or "value", tostring(b), tostring(a)), 2)
  end
end

-- ---------------------------------------------------------------- strings
eq(string.len("hello"), 5, "len")
eq(string.sub("hello", 2, 4), "ell", "sub")
eq(string.sub("hello", -3), "llo", "sub with a negative start")
eq(string.sub("hello", 2), "ello", "sub to the end")
eq(string.sub("hello", 5, 2), "", "empty when the range is inverted")
eq(string.rep("ab", 3, "-"), "ab-ab-ab", "rep with a separator")
eq(string.byte("A"), 65, "byte")
eq(select("#", string.byte("abc", 1, 3)), 3, "byte range")
eq(string.char(104, 105), "hi", "char")
eq(string.upper("aBc"), "ABC", "upper")
eq(string.lower("aBc"), "abc", "lower")
eq(string.reverse("abc"), "cba", "reverse")
eq(string.format("%5.2f|%-6s|%03d", 3.14159, "ab", 7), " 3.14|ab    |007", "format flags")
eq(string.format("%q", 'a"b'), '"a\\"b"', "quoted")
eq(string.format("%x %X %o", 255, 255, 8), "ff FF 10", "integer formats")
eq(string.format("%g", 1/3):sub(1, 4), "0.33", "g format")
eq(("%s=%s"):format("a", "b"), "a=b", "format as a method")
eq(("abc"):byte(1), 97, "string methods through the metatable")

-- ---------------------------------------------------------------- patterns
eq(string.find("hello world", "world"), 7, "find returns the start")
eq(string.find("hello", "l+"), 3, "pattern with a quantifier")
eq(select("#", string.find("hello", "l+")), 2, "find returns start and end")
eq(string.find("hello", "xyz"), nil, "find fails")
eq(string.find("a.b", ".", 1, true), 2, "plain find")
-- A plain search is the reference's `lmemfind`, so its edges are the subject
-- bounds, the empty pattern and the byte values.  The expectations below were
-- read off a reference build, one input at a time (`find` answers start and
-- end, and for an empty pattern the end is one before the start).
local subject = "hello world, hello there"
eq(#subject, 24, "the subject of the cases below")
eq(string.find(subject, "wor", 1, true), 7, "a plain hit")
eq(string.find(subject, "zzz", 1, true), nil, "a plain miss")
eq(string.find(subject, "hello", 2, true), 14, "init skips the first hit")
eq(string.find(subject, "hello", -13, true), 14, "a negative init counts back")
eq(string.find(subject, "hello", 0, true), 1, "init 0 is the first byte")
eq(string.find(subject, "hello", #subject + 2, true), nil, "an init past the end fails")
eq(string.find(subject, "world"), 7, "no specials takes the plain path too")
eq(string.find("abc", "", 1, true), 1, "the empty pattern is at init")
eq(string.find(subject, "", 5, true), 5, "and end is one before it")
eq(string.find(subject, "", #subject + 1, true), #subject + 1, "even at the end")
eq(string.find("ab", "abcdef", 1, true), nil, "a pattern longer than the subject")
eq(string.find("abab", "abab", 1, true), 1, "a subject that is the pattern")
eq(string.find("aaaa", "aa", 1, true), 1, "an overlapping match")
eq(string.find("a\0b\0c", "\0b", 1, true), 2, "a NUL in the pattern")
eq(string.find("\0\0ab", "ab", 1, true), 3, "and in the subject")
eq(string.find("\0\0\0", "\0", 2, true), 2, "a NUL found from an init")
eq(string.find("\255\254\253", "\254", 1, true), 2, "a byte above 127")
eq(string.find("\255\254\253", "\252", 1, true), nil, "and one that is absent")
-- A back reference compares the captured bytes with the subject in place; it
-- used to allocate a slice of each side to compare them.
eq(string.match("abcabc", "(abc)%1"), "abc", "a back reference matches")
eq(string.match("abcabd", "(abc)%1"), nil, "and fails when the bytes differ")
eq(string.match("aabb", "(a+)%1"), "a", "a greedy capture backtracks to fit")
eq(string.match("abc", "()a%1"), nil, "a back reference to a position never matches")
eq(string.gsub("abcabc", "(abc)%1", "X"), "X", "gsub through a back reference")
eq(string.find("hello hello", "(%a+) %1"), 1, "find through one")
eq(string.find("hello hello", "(%a+) %1", 3), nil, "which is a failed search here")
eq(string.match("a\0\0a\0\0", "(a\0\0)%1"), "a\0\0", "over NUL bytes")
eq(select(2, pcall(string.match, "abc", "%1")), "invalid capture index %1",
  "an index with no capture is refused")
eq(string.match("key=value", "(%w+)=(%w+)"), "key", "match first capture")
eq(select(2, string.match("key=value", "(%w+)=(%w+)")), "value", "match second capture")
eq(string.match("2024-01-15", "(%d+)-(%d+)-(%d+)"), "2024", "date pattern")
eq(string.gsub("hello world", "o", "0"), "hell0 w0rld", "gsub")
eq(select(2, string.gsub("hello", "l", "L")), 2, "gsub counts")
eq(string.gsub("hello", "l+", "L"), "heLo", "gsub with a quantifier")
eq(string.gsub("abc", "%w", function(c) return c:upper() end), "ABC", "gsub with a function")
eq(string.gsub("a=1,b=2", "(%w+)=(%w+)", "%2=%1"), "1=a,2=b", "gsub with captures")
eq(string.gsub("k", "k", {k = "v"}), "v", "gsub with a table")
eq(string.gsub("hello", "l", "L", 1), "heLlo", "gsub with a limit")
local words = {}
for w in string.gmatch("one two three", "%a+") do words[#words + 1] = w end
eq(table.concat(words, ","), "one,two,three", "gmatch")
local pairsFound = {}
for k, v in string.gmatch("a=1,b=2", "(%w+)=(%w+)") do pairsFound[k] = v end
eq(pairsFound.a, "1", "gmatch with captures")
eq(string.match("  trim  ", "^%s*(.-)%s*$"), "trim", "frontier and lazy match")
eq(string.match("x(a(b)c)y", "%b()"), "(a(b)c)", "balanced match")
eq(string.match("hello", "h(.)(.)"), "e", "positional captures")
eq(("[a]"):match("%[(%a)%]"), "a", "escaped brackets")
eq(string.match("abc", "^abc$"), "abc", "anchors")
eq(string.match("a12b", "%d%d"), "12", "digit class")
eq(string.match("x", "%u"), nil, "uppercase class")
eq(("abc"):gsub("", "-"), "-a-b-c-", "empty pattern matches everywhere")

-- ---------------------------------------------------------------- tables
local t = {3, 1, 2}
table.sort(t)
eq(table.concat(t, ","), "1,2,3", "sort ascending")
table.sort(t, function(a, b) return a > b end)
eq(table.concat(t, ","), "3,2,1", "sort with a comparator")
local s = {"b", "a", "c"}
table.sort(s)
eq(table.concat(s), "abc", "sort strings")
table.insert(t, 4)
eq(t[4], 4, "insert at the end")
table.insert(t, 1, 9)
eq(t[1], 9, "insert at the front")
eq(#t, 5, "length after insert")
eq(table.remove(t, 1), 9, "remove returns the element")
eq(table.remove(t), 4, "remove from the end")
local packed = table.pack("a", "b", nil, "d")
eq(packed.n, 4, "pack records n")
eq(select("#", table.unpack(packed, 1, packed.n)), 4, "unpack with the stored n")
local dst = table.move({1, 2, 3}, 1, 3, 2, {})
eq(dst[2], 1, "move")
eq(dst[4], 3, "move to a later position")
local sparse = {}
sparse[1] = "a"
sparse[2] = "b"
sparse[4] = "d"
local seen = {}
for k, v in pairs(sparse) do seen[k] = v end
eq(seen[4], "d", "pairs visits every key")
eq(seen[3], nil, "pairs skips absent keys")
eq(table.concat({"a", "b", "c"}, "-", 2, 3), "b-c", "concat with a range")

-- ---------------------------------------------------------------- math
eq(math.floor(3.7), 3, "floor")
eq(math.ceil(3.2), 4, "ceil")
eq(math.abs(-5), 5, "abs of an integer")
eq(math.abs(-5.5), 5.5, "abs of a float")
eq(math.max(1, 5, 3), 5, "max")
eq(math.min(1, 5, 3), 1, "min")
eq(math.fmod(-7, 3), -1, "fmod keeps the sign of the dividend")
eq(-7 % 3, 2, "modulo follows the sign of the divisor")
local ipart, fpart = math.modf(3.75)
eq(ipart, 3.0, "modf integer part")
eq(math.floor(fpart * 100) / 100, 0.75, "modf fractional part")
eq(math.tointeger(3.0), 3, "tointeger of a float")
eq(math.tointeger(3.5), nil, "tointeger of a fraction")
eq(math.type(3), "integer", "math.type")
eq(math.ult(1, 2), true, "unsigned comparison")
eq(math.ult(-1, 2), false, "unsigned comparison of a negative")
eq(math.sqrt(16), 4.0, "sqrt")
eq(math.huge > 1e308, true, "huge")
eq(math.pi > 3.14 and math.pi < 3.15, true, "pi")
math.randomseed(42)
local r1 = math.random()
local r2 = math.random()
eq(r1 >= 0 and r1 < 1, true, "random in [0,1)")
eq(r1 == r2, false, "random advances")
math.randomseed(42)
eq(math.random(), r1, "randomseed is reproducible")
local ri = math.random(10)
eq(ri >= 1 and ri <= 10 and math.type(ri) == "integer", true, "random range")
eq(math.random(0) ~= math.random(0), true, "random(0) gives full integers")

-- ---------------------------------------------------------------- os and io
eq(type(os.time()), "number", "os.time")
eq(type(os.clock()), "number", "os.clock")
local now = os.time()
eq(type(os.date("%Y", now)), "string", "os.date with a format")
local dt = os.date("*t", now)
eq(type(dt), "table", "os.date table")
eq(type(dt.year), "number", "date field")
eq(dt.month >= 1 and dt.month <= 12, true, "month range")
eq(dt.wday >= 1 and dt.wday <= 7, true, "weekday range")
eq(os.time(dt) >= now - 1, true, "os.time accepts a table")
eq(os.getenv("PATH") ~= nil, true, "getenv")
eq(os.getenv("DEFINITELY_NOT_SET_12345"), nil, "getenv of an unset variable")

local path = os.tmpname()
local f = assert(io.open(path, "wb"))
assert(f:write("line one\n", "line two\n"))
assert(f:close())
local g = assert(io.open(path, "rb"))
eq(g:read("l"), "line one", "read a line")
eq(g:read("*a"), "line two\n", "read the rest")
eq(g:read("l"), nil, "read at the end of file")
assert(g:close())
eq(io.type(g), "closed file", "io.type of a closed file")
eq(io.type(42), nil, "io.type of a non file")
local h = assert(io.open(path, "rb"))
eq(h:seek("end"), 18, "seek to the end")
eq(h:seek("set", 5), 5, "seek to an offset")
eq(h:read(4), "one\n", "read a fixed number of bytes")
assert(h:close())
local lines = {}
for line in io.lines(path) do lines[#lines + 1] = line end
eq(#lines, 2, "io.lines")
eq(lines[2], "line two", "io.lines content")
eq(os.remove(path), true, "remove")
eq(io.open(path, "r"), nil, "opening a removed file fails")

-- ---------------------------------------------------------------- pcall and select
eq(select("#", 1, 2, 3), 3, "select count")
eq(select(2, "a", "b", "c"), "b", "select from")
eq(select(-1, "a", "b", "c"), "c", "select from the end")
eq(assert(42), 42, "assert returns its argument")
eq(select("#", assert(1, 2, 3)), 3, "assert forwards extra values")

-- ------------------------------------------------------------------ debug names
-- A metamethod frame is named after the event, without its '__' prefix, and a
-- metamethod entered from the host is not named at all.
do
  local function name(level)
    local info = debug.getinfo(level, "n")
    local named = tostring(info.name) .. "/" .. info.namewhat
    return named
  end
  local collected
  local t = setmetatable({}, {
    __index = function() local r = name(2) return r end,
    __newindex = function() collected = name(2) end,
    __add = function() local r = name(2) return r end,
    __tostring = function() local r = name(2) return r end,
  })
  eq(t.x, "index/metamethod", "the __index frame is named 'index'")
  t.y = 1
  eq(collected, "newindex/metamethod", "the __newindex frame is named")
  eq(({} + t), "add/metamethod", "an arithmetic frame is named after the event")
  eq(tostring(t), "nil/", "a metamethod entered from the host is unnamed")
  local closed
  do
    local _ <close> = setmetatable({}, {__close = function() closed = name(2) end})
  end
  eq(closed, "close/metamethod", "a to-be-closed handler is named 'close'")
end

-- ------------------------------------------------------------------- math.random
-- The generator is the reference one, seeded the way 'setseed' seeds it, so the
-- first value after a seed is fixed and the seeds come back for a replay.
do
  math.randomseed(1007)
  eq(math.random(0), 0x7a7040a5a323c9d6, "the first value after seed 1007")
  math.randomseed(1007)
  eq(math.random(), 0x0.7a7040a5a323c9d6, "the same value as a float")
  local x, y = math.randomseed()
  local r = math.random(0)
  math.randomseed(x, y)
  eq(math.random(0), r, "resuming from the seeds repeats the state")
end

-- ------------------------------------------------------------- nested protections
-- Each protected call costs one C level, so a chain of them stops at the limit
-- instead of exhausting the stack, and a handler that fails the same way ends in
-- "error in error handling".
do
  local function loop() assert(pcall(loop)) end
  local ok, msg = xpcall(loop, loop)
  eq(ok, false, "the overflow is not caught by the handler")
  assert(string.find(msg, "error"), "the message says error handling gave up: " .. tostring(msg))
end

-- --------------------------------------------------------------- line hook traces
-- Which line an instruction is attributed to decides the trace a line hook
-- sees: the test of an `if` belongs to its `then`, the test of a numeric `for`
-- to the `for` and its setup to the `do`, and returning from a call resumes on
-- the line of the call rather than looking like a new one.
do
  local function trace (s, want)
    local got = {}
    local function f (_, line) got[#got + 1] = line end
    debug.sethook(f, "l"); load(s)(); debug.sethook()
    eq(table.concat(got, ","), table.concat(want, ","), "trace of " .. s)
  end
  trace([[if
math.sin(1)
then
  a=1
else
  a=2
end
]], {2, 3, 4, 7})
  trace([[
local function foo()
end
foo()
A = 1
A = 2
]], {2, 3, 2, 4, 5})
  trace([[a=1
repeat
  a=a+1
until a==3
]], {1, 3, 4, 3, 4})
  trace([[ do
  return
end
]], {2})
  trace([[local a
a=1
while a<=3 do
  a=a+1
end
]], {1, 2, 3, 4, 3, 4, 3, 4, 3, 5})
  trace([[for i=1,3 do
  a=i
end
]], {1, 2, 1, 2, 1, 2, 1, 3})
  trace([[for i=1,4 do a=1 end]], {1, 1, 1, 1})
  trace([[for i=1,3 do
end
]], {1, 1, 1, 2})
  trace([[for i,v in pairs{'a','b'} do
  a=tostring(i) .. v
end
]], {1, 2, 1, 2, 1, 3})
  -- A condition that cannot be false is not tested at all.
  trace([[while true do
  break
end
]], {2, 3})
  trace([[if 1
then
elseif 2
then
else
end
]], {2, 6})
  _G.a, _G.A = nil, nil
end

-- ------------------------------------------------------------- debug.getlocal at 0
-- Level 0 addresses the arguments of the query itself, and no slot beyond them.
do
  local n, v = debug.getlocal(0, 1)
  eq(n, "(C temporary)", "the first argument of the call")
  eq(v, 0, "its value")
  local n2 = debug.getlocal(0, 2)
  eq(n2, "(C temporary)", "the second argument")
  assert(not debug.getlocal(0, 3), "no third argument")
  assert(not debug.getlocal(0, 0), "index 0 is not a variable")
end

-- ------------------------------------------------------- currentline in a hook
-- `debug.getinfo(2, "l").currentline` names the line the hook was called for,
-- not the one before it.
do
  local bad = 0
  local function check(_, line)
    if debug.getinfo(2, "l").currentline ~= line then bad = bad + 1 end
  end
  local a = 0
  debug.sethook(check, "l")
  for i = 1, 2 do
    a = a + i
    if a == 3 then a = a * 2 end
  end
  while a > 0 do a = a - 1 end
  debug.sethook()
  eq(bad, 0, "every line event names its own line")
end

-- ------------------------------------------------------- transfer info in a hook
-- `debug.getinfo(level, "r")` reports the values a frame transferred: a call
-- event says where the arguments start and how many there are, a return event
-- the same for the results.  It is per frame, and it lasts only as long as the
-- hook it was recorded for -- the reference keeps it in the hook's own call
-- status, which is cleared when the hook returns.
do
  local seen = {}
  local function hook(event)
    local ar = debug.getinfo(2, "r")
    if ar.ntransfer > 0 then
      seen[#seen + 1] = event .. ":" .. ar.ftransfer .. "," .. ar.ntransfer
    end
  end
  local function f(a, b) local x = a + b return x, x end
  debug.sethook(hook, "cr")
  f(10, 20)
  debug.sethook()
  -- `f`'s frame is the one the two events are about: its arguments start at
  -- slot 1 (two of them) and its results at slot 4 (also two).  The hook's own
  -- call, with no arguments, reports nothing.
  eq(#seen, 2, "only the two events of `f` carry transfer information")
  eq(seen[1], "call:1,2", "a call event names its arguments")
  eq(seen[2], "return:4,2", "a return event names its results")
end

-- A chunk read from a file is named `@path`, which is what `debug.getinfo`
-- reports as its source (standard input is `=stdin`).
do
  local path = os.tmpname()
  local h = assert(io.open(path, "w"))
  h:write("return function () return 1 end")
  h:close()
  local chunk = assert(loadfile(path))
  eq(debug.getinfo(chunk).source, "@" .. path, "a file's chunk is named after it")
  eq(chunk()(), 1, "and it runs")
  os.remove(path)
end

-- -------------------------------------------------------------------- tail calls
-- A tail call hands its frame over to the callee: the levels below it collapse
-- into one, the frame that took over reports as a tail call and has no name,
-- and whatever the caller still held open is closed before its slots are used.
do
  local info
  local function leaf()
    info = debug.getinfo(1, "nlt")
    return debug.getinfo(2, "S").what
  end
  local function mid() return leaf() end
  local function outer() return mid() end
  eq(outer(), "main", "a chain of tail calls leaves one frame")
  eq(info.istailcall, true, "the frame that took over says tail call")
  eq(info.name, nil, "a tail call is not named")

  local keep
  local function make (n)
    keep = function () return n end
    return table.pack(keep)  -- the argument lands on the slot that held 'n'
  end
  local packed = make(42)
  eq(packed[1], keep, "the tail call returned what the callee gave back")
  eq(keep(), 42, "the upvalue kept its value across the handover")

  -- A yield still passes through a protected call reached by a tail call.
  local co = coroutine.create(function()
    return pcall(function() return coroutine.yield("y") end)
  end)
  local ok1, v1 = coroutine.resume(co)
  eq(v1, "y", "the yield inside the tail-called pcall")
  local ok2, r1, r2 = coroutine.resume(co, "back")
  eq(r1, true, "pcall reported success")
  eq(r2, "back", "the value the resume passed in")
  eq(coroutine.status(co), "dead", "the body ended")

  -- The protected function is the first argument of `pcall` and of `xpcall`
  -- alike, however the frames were arranged to get there.
  local values = coroutine.wrap(function()
    return xpcall(pcall, function(...) return ... end,
                  function()
                    local s = 0
                    for i = 1, 3 do s = s + i end
                    error({s})
                  end)
  end)
  local x1, x2, obj = values()
  eq(x1, true, "xpcall itself did not fail")
  eq(x2, false, "the protected call caught the error")
  eq(obj[1], 6, "the error object came through")
end

-- ---------------------------------------------------------------- debug.traceback
-- A traceback names each frame by the global its function is stored under,
-- gives the frame a `yield` left as level 0 of a suspended coroutine, marks the
-- frames that took over another's place, and abbreviates a long stack with the
-- number of levels it left out.
do
  -- The frame lines of a traceback: everything after the message line and the
  -- "stack traceback:" header.  Every case below passes a message, so the two
  -- lines cut off are the same two.
  local function frames(s)
    local out = {}
    local i = 0
    for l in string.gmatch(s, "[^\n]+\n?") do
      i = i + 1
      if i > 2 then out[#out + 1] = l end
    end
    return out
  end

  local M = {}
  function M.leaf()
    return debug.traceback("msg", 0)
  end
  local f = frames(M.leaf())
  assert(string.find(f[1], "'debug.traceback'", 1, true),
    "the debug function names itself by its global: " .. f[1])
  assert(string.find(f[2], "in field 'leaf'", 1, true),
    "a function reachable only through a local is named by its call site: "
      .. f[2])

  local co = coroutine.create(function()
    coroutine.yield(1)
  end)
  coroutine.resume(co)
  local f0 = frames(debug.traceback(co, "x", 0))
  assert(string.find(f0[1], "coroutine.yield", 1, true),
    "the yield a coroutine stopped in is a level: " .. f0[1])
  assert(string.find(f0[2], "in function <", 1, true),
    "the body of the coroutine is the next level: " .. f0[2])
  local i0 = debug.getinfo(co, 0)
  assert(i0.what == "C" and i0.name == "yield",
    "level 0 of a suspended coroutine is the yield that stopped it")
  assert(debug.getinfo(co, 3) == nil, "levels stop with the frames there are")
  local f1 = frames(debug.traceback(co, "x", 1))
  assert(#f1 == 1 and string.find(f1[1], "in function <", 1, true),
    "starting one level in leaves the yield out")

  local function tail(n)
    if n > 0 then return tail(n - 1) end
    return debug.traceback("t", 1)
  end
  local ft = frames(tail(2))
  assert(string.find(ft[1], "in function <", 1, true),
    "the chain of tail calls is one frame: " .. ft[1])
  assert(string.find(ft[2], "(...tail calls...)", 1, true),
    "and the frame that took over says so: " .. ft[2])

  -- A protected call is a level of the stack in its own right, so a trace taken
  -- inside the protected function names it.
  local inside
  local function protected(n)
    if n > 0 then return protected(n - 1) end
    inside = debug.traceback("p", 0)
    return 1
  end
  local okp = pcall(protected, 1)
  eq(okp, true, "the protected call returned")
  local fp = frames(inside)
  local named = nil
  for i = 1, #fp do
    if string.find(fp[i], "'pcall'", 1, true) then named = i end
  end
  assert(named ~= nil, "pcall stands in the trace of what it protects")

  -- A value that cannot be called is reported to the protected call that asked
  -- for it, not out of the program.
  local okn, errn = pcall(nil, 1)
  eq(okn, false, "pcall reports an uncallable value")
  assert(string.find(errn, "attempt to call a nil value", 1, true), errn)
  local okx, errx = xpcall(1, function(e) return "H:" .. e end)
  eq(okx, false, "xpcall reports it too")
  assert(string.find(errx, "^H:", 1, false),
    "and the handler saw the error: " .. tostring(errx))
  assert(string.find(errx, "attempt to call a number value", 1, true), errx)

  local function deep(lvl)
    if lvl == 0 then return debug.traceback("m", 1) end
    return (deep(lvl - 1))
  end
  local fd = frames(deep(40))
  local brk = nil
  for i = 1, #fd do
    if string.find(fd[i], "%.%.%.\t%(skipping", 1, false) then brk = i end
  end
  assert(brk ~= nil, "a long trace is abbreviated")
  assert(brk == 11, "the first part shows ten levels, got " .. (brk - 1))
  assert(#fd - brk >= 10, "the second part shows the end of the stack")
end

-- ------------------------------------------------ close during unwinding, dead coroutines
-- When an error unwinds the stack, the `__close` handlers run after the frame
-- that owns the variable is gone, so the protected call is what called them.
-- A coroutine that died from an error keeps its frames until it is closed.
do
  local seen = {}
  local function foo ()
    local z <close> = setmetatable({}, {__close = function (self, msg)
      seen = {debug.getinfo(2).what, debug.getinfo(2).name,
              debug.getinfo(3).what}
      error("@Y")
    end})
    error(4)
  end
  local ok, msg = xpcall(foo, debug.traceback)
  eq(ok, false, "the close's own error escapes the protected call")
  eq(msg == nil, false, "a message came back")
  eq(seen[1], "C", "the frame above a close handler during unwinding")
  eq(seen[2], "xpcall", "names the protected call")
  eq(seen[3], "main", "the caller of the protected call")

  local function f(i)
    if i == 0 then
      error(0)
    else
      coroutine.yield()
      f(i - 1)
    end
  end
  local co = coroutine.create(function(x) f(x) end)
  coroutine.resume(co, 2)
  while coroutine.status(co) == "suspended" do
    coroutine.resume(co)
  end
  eq(coroutine.status(co), "dead", "the coroutine ended in an error")
  local trace = debug.traceback(co, nil, 0)
  assert(string.find(trace, "in function 'error'", 1, true),
    "the error call tops the trace of a dead coroutine")
  local n = 0
  for _ in string.gmatch(trace, "\n") do n = n + 1 end
  eq(n, 5, "error, two calls of f, the body and the header")
  local okc, msgc = coroutine.close(co)
  eq(okc, false, "close reports the error that killed it")
  eq(msgc, 0, "the very error object")
  local after = debug.traceback(co, nil, 0)
  eq(after, "stack traceback:", "closing empties the stack")
end

-- --------------------------------------------------- argument errors
-- The shape of an argument error is part of what a program sees: a typed check
-- names the type it wanted and reports a missing argument as "no value", while
-- `checkany`-style functions say "value expected"; a library function called
-- from another host function has no position to report; and a *runtime* error
-- takes its position from the running frame only.  All of these were checked
-- against the reference one by one, and two of them used to abort the process
-- (`os.date("%")` reached the host's `strftime` with a specifier it does not
-- know, and `debug.setmetatable({})` read a second argument that was not there).
do
  local function msg(f, ...)
    local ok, e = pcall(f, ...)
    -- drop the position prefix: what is compared here is the message itself
    return ok and "ok" or (tostring(e):gsub("^[^:]*:%d+: ", ""))
  end
  eq(msg(string.rep), "bad argument #1 to 'string.rep' (string expected, got no value)",
    "a typed check names the type and the missing value")
  eq(msg(string.rep, 5), "bad argument #2 to 'string.rep' (number expected, got no value)",
    "a number coerces to a string, so the count is what is missing")
  eq(msg(string.rep, {}, 2), "bad argument #1 to 'string.rep' (string expected, got table)",
    "and a table is what is refused")
  eq(msg(table.concat), "bad argument #1 to 'table.concat' (table expected, got no value)",
    "table checks say table")
  eq(msg(math.floor), "bad argument #1 to 'math.floor' (number expected, got no value)",
    "math checks say number")
  eq(msg(pcall), "bad argument #1 to 'pcall' (value expected)",
    "a check for any value says value expected")
  eq(msg(rawlen, 1), "bad argument #1 to 'rawlen' (table or string expected, got number)",
    "a two-type check names both")
  eq(msg(setmetatable, {}), "bad argument #2 to 'setmetatable' (nil or table expected, got no value)",
    "the metatable is required")
  eq(msg(debug.setmetatable, {}), "bad argument #2 to 'debug.setmetatable' (nil or table expected, got no value)",
    "as it is in the debug library")
  eq(msg(debug.getupvalue), "bad argument #2 to 'debug.getupvalue' (number expected, got no value)",
    "the upvalue index is checked before the closure")
  eq(msg(coroutine.resume), "bad argument #1 to 'coroutine.resume' (thread expected, got no value)",
    "a coroutine function wants a thread")
  eq(msg(load, {}), "bad argument #1 to 'load' (function expected, got table)",
    "a non-string chunk has to be a reader function")
  eq(msg(pairs, 1), "ok", "pairs takes any value and fails when it is used")
  eq(msg(table.unpack), "attempt to get length of a nil value",
    "unpack asks for the length before it checks anything")
  -- No position when the library function was called by another host function
  -- (`pcall`), and one naming the line when a Lua function called it.
  local ok_host, err_host = pcall(string.rep)
  eq(err_host:find("^bad argument") ~= nil, true,
    "a host caller leaves no position")
  local ok_lua, err_lua = pcall(function() return string.rep() end)
  eq(err_lua:find(":%d+: bad argument") ~= nil, true,
    "a Lua caller does leave one")
  -- a specifier the host's strftime does not know is refused, not passed on
  eq(msg(os.date, "%q", 0),
    "bad argument #1 to 'os.date' (invalid conversion specifier '%q')",
    "an unknown date specifier is refused")
  eq(msg(os.date, "x%", 0),
    "bad argument #1 to 'os.date' (invalid conversion specifier '%')",
    "including a trailing one")
  eq(os.date("%a %Y", 0) ~= nil, true, "a valid format still works")
  eq(#os.date(string.rep("x", 300), 0), 300, "and a long literal is not truncated")
end

-- The edges of the library that only a diff against the reference finds: what
-- `__tostring` may return, the type of `math.modf`'s integral part, which
-- errors carry a position, how a file is read and closed, and the name an
-- argument error reports.
do
  local function err(f, ...)
    local ok, e = pcall(f, ...)
    return ok and "ok" or tostring(e)
  end
  local function bare(e)
    return (tostring(e):gsub("^[^:]*:%d+: ", ""))
  end

  -- `lua_isstring` accepts a number, so a `__tostring` may return one and
  -- `lua_tolstring` writes it out.
  local numstr = setmetatable({}, {__tostring = function() return 42 end})
  eq(tostring(numstr), "42", "__tostring may return a number")
  eq(string.format("%s", numstr), "42", "which %s accepts too")
  -- `%q` switches on the type instead, so a `__tostring` does not help it.
  eq(bare(select(2, pcall(string.format, "%q", numstr))),
    "bad argument #2 to 'string.format' (value has no literal form)",
    "%q of a table has no literal form")
  eq(err(tostring, setmetatable({}, {__tostring = function() return true end})),
    "'__tostring' must return a string", "anything else is still refused")

  -- A value with no literal form names the argument it was found in.
  eq(bare(select(2, pcall(string.format, "%q", {}))),
    "bad argument #2 to 'string.format' (value has no literal form)",
    "%q of a table names the argument")

  -- The integral part of a number is an integer when it fits (`pushnumint`).
  eq(math.type((math.modf(3.7))), "integer", "modf's integral part is an integer")
  eq(math.type(select(2, math.modf(3.7))), "float", "and the fraction is a float")
  eq(math.type(math.floor(3.7)), "integer", "floor gives an integer")
  eq(math.type(math.ceil(3.2)), "integer", "so does ceil")
  eq(math.type(math.floor(math.huge)), "float", "unless it cannot fit")
  eq(math.type((math.modf(math.huge))), "float", "and modf of an infinity stays one")

  -- A bad key to `next` is raised where `next` runs, which is a host function
  -- with no line, so it carries no position even from a Lua caller.
  local okn, mn = pcall(function() return next({10}, 99) end)
  eq(okn, false, "a bad key fails")
  eq(mn, "invalid key to 'next'", "and next reports it bare")

  -- A reader that answers with something which is not a string is a load
  -- failure, not an error: `load` returns nil with the message, and that
  -- message carries the position of whoever called `load` because
  -- `generic_reader` raises it through `luaL_error`.
  local lf, lmsg = load(function() return {} end)
  eq(lf, nil, "a reader that returns a table makes load fail")
  eq(bare(lmsg), "reader function must return a string", "with the reference's text")
  eq(lmsg:match("^.-:%d+: ") ~= nil, true, "and a position in front of it")

  -- `load` reads a reader only as far as the parser needed, which is what the
  -- reference does through `luaZ_fill`: a reader with side effects is left where
  -- the parse stopped, and one that never ends fails on the syntax error its
  -- extra input causes instead of being read forever.  Every count below was
  -- read off a reference build.
  do
    local pieces = { "local x = ", "((", "and more", "and more again" }
    local calls, i = 0, 0
    local broken = load(function()
      calls = calls + 1
      i = i + 1
      return pieces[i]
    end)
    eq(broken, nil, "a broken chunk handed over in pieces does not load")
    eq(calls, 3, "and the reader stopped where the parser did")

    local n = 0
    local endless = load(function()
      n = n + 1
      if n > 4 then error("read far too much") end
      return "return 1"
    end)
    eq(endless, nil, "a reader that never ends does not load")
    eq(n, 2, "it fails on the second piece, not after reading forever")

    -- The file behind a reader is left where the parse stopped as well.
    local name = "stdlib_probe_reader.lua"
    local out = assert(io.open(name, "w"))
    out:write("local x = = 1\nprint('one')\nprint('two')\n")
    out:close()
    local h = assert(io.open(name, "r"))
    local fromfile = load(function() return h:read("L") end)
    eq(fromfile, nil, "the file does not compile")
    local pos, size = h:seek(), h:seek("end")
    eq(pos < size, true, "and the reader stopped before the end of the file")
    h:close()
    os.remove(name)

    -- A piece may be a number, because `lua_isstring` accepts one.
    local k = 0
    local with_number = load(function()
      k = k + 1
      if k == 1 then return "return " end
      if k == 2 then return 42 end
      return nil
    end)
    eq(type(with_number), "function", "a number is a piece of source text")
    eq(with_number(), 42, "and the chunk it built returns it")

    -- The mode is decided by the first piece, before the rest is read.
    local reads = 0
    local refused, why = load(function()
      reads = reads + 1
      return "return 1"
    end, "=reader", "b")
    eq(refused, nil, "a text chunk is refused in binary mode")
    eq(why, "attempt to load a text chunk (mode is 'b')", "with the reference's words")
    eq(reads, 1, "and only the first piece was read")
  end

  -- `assert` hands its message to `error`, whose default level names the
  -- caller; only a string message gets the position.
  local oka, ma = pcall(function() return assert(false, "boom") end)
  eq(oka, false, "assert fails")
  eq(ma:find(":%d+: boom") ~= nil, true, "assert's message carries the caller's position")
  local okb, mb = pcall(function() return assert(nil, {}) end)
  eq(okb, false, "assert fails with a table message")
  eq(type(mb), "table", "which is passed on as it is")

  -- A timestamp is an integer, so a fraction is refused (`l_checktime`).
  eq(bare(select(2, pcall(os.difftime, 1.5, 0.5))),
    "bad argument #1 to 'os.difftime' (number has no integer representation)",
    "difftime wants integers")
  eq(os.difftime(100, 50), 50.0, "and answers a float")

  -- `warn` requires at least one string argument.
  eq(bare(select(2, pcall(warn))),
    "bad argument #1 to 'warn' (string expected, got no value)",
    "warn with no argument is an argument error")
  eq(bare(select(2, pcall(warn, {}))),
    "bad argument #1 to 'warn' (string expected, got table)",
    "and a table is refused")

  -- A name that neither the call site nor `package.loaded` can give is `?`.
  eq(bare(select(2, pcall(io.stdin.read, io.stdin, "x"))),
    "bad argument #2 to '?' (invalid format)",
    "a file method passed as a value is not named")

  -- The collector's own handler still checks its argument (`tolstream`), so
  -- calling it with none is an argument error rather than a silent no-op.
  eq(bare(select(2, pcall(getmetatable(io.stdin).__gc))),
    "bad argument #1 to '?' (FILE* expected, got no value)",
    "a file's __gc wants a file")
end

-- Reading and closing a file, against the same reference.
do
  local function bare(e)
    return (tostring(e):gsub("^[^:]*:%d+: ", ""))
  end
  local name = "stdlib_probe_io.txt"
  os.remove(name)
  local missing = "cannot open file '" .. name .. "' (No such file or directory)"
  -- A file named by `io.lines`/`io.input`/`io.output` is opened through
  -- `opencheck`, which reports the failure differently from `io.open`.
  local function openfail(f)
    local ok, e = pcall(function() return f(name) end)
    return bare(e)
  end
  eq(openfail(io.lines), missing, "io.lines says what it could not open")
  eq(openfail(io.input), missing, "io.input too")
  -- `io.output` opens for writing, so it needs a name it cannot create either.
  local outname = "stdlib_probe_dir/out.txt"
  local okw, ew = pcall(function() return io.output(outname) end)
  eq(okw, false, "io.output refuses a name in a directory that is not there")
  eq(bare(ew),
    "cannot open file '" .. outname .. "' (No such file or directory)",
    "and says the same way")
  local f, m = io.open(name, "r")
  eq(f, nil, "io.open answers nil instead")
  eq(type(m), "string", "with a message")

  -- Reading a numeral takes a sign before a hexadecimal one, so `-0x1p4` is a
  -- single number.
  f = assert(io.open(name, "w"))
  f:write("-0x1p4 0x10 .5e2 12x")
  f:close()
  f = assert(io.open(name, "r"))
  eq(f:read("n"), -16.0, "a signed hexadecimal numeral is one number")
  eq(f:read("n"), 16, "a plain hexadecimal integer")
  eq(f:read("n"), 50.0, "a fraction with an exponent")
  eq(f:read("n"), 12, "and a numeral stops at the first byte that is not one")
  eq(f:read(1), "x", "leaving the rest for the next read")

  -- A count the buffer cannot hold is a memory error, not a short read.
  eq(select(2, pcall(f.read, f, -1)), "not enough memory",
    "a negative count cannot be read")
  f:close()

  -- A *stream* that fails is reported as `nil, message, errno` -- not as the
  -- empty string a read that merely hit the end answers.  The message is the
  -- host C library's text for the number, so only its shape is pinned here.
  local wf = assert(io.open(name, "w"))
  local r1, r2, r3 = wf:read("a")
  eq(r1, nil, "reading a handle opened for writing fails")
  eq(type(r2), "string", "with a message from the host")
  eq(type(r3), "number", "and the error number")
  local r4, r5 = wf:read("a")
  eq(r4, nil, "and it fails the same way when read again")
  eq(r5, r2, "the message being the one the stream still reports")
  wf:close()

  -- Closing twice is an error; only the collector's own handler ignores it.
  f = assert(io.open(name, "r"))
  eq(f:close(), true, "the first close succeeds")
  eq(select(2, pcall(f.close, f)), "attempt to use a closed file",
    "the second is refused")
  eq(select(2, pcall(f.read, f)), "attempt to use a closed file",
    "as is any other use")
  eq(pcall(function() local g <close> = f end), true,
    "a to-be-closed variable that is already closed is not an error")
  os.remove(name)
end

-- The `debug` library's edges: the names an argument error gives, what an
-- out-of-range upvalue answers, the light-userdata type name, and the two
-- entries that are not about inspecting a running program.
do
  local function msg(f, ...)
    local ok, e = pcall(f, ...)
    return ok and "ok" or tostring(e)
  end
  local function bare(e)
    return (tostring(e):gsub("^[^:]*:%d+: ", ""))
  end

  eq(bare(msg(debug.getinfo, print, "x")),
    "bad argument #2 to 'debug.getinfo' (invalid option)",
    "an unknown getinfo option")
  eq(bare(msg(debug.getinfo, print, ">S")),
    "bad argument #2 to 'debug.getinfo' (invalid option '>')",
    "and a leading '>' has its own message")
  eq(bare(msg(debug.getinfo, print, 5)),
    "bad argument #2 to 'debug.getinfo' (invalid option)",
    "a number is an option string, not a type error")

  -- An out-of-range upvalue index answers with nothing at all.
  local f = function() end
  eq(select("#", debug.getupvalue(f, 9)), 0, "getupvalue answers with nothing")
  eq(select("#", debug.setupvalue(f, 9, 1)), 0, "and so does setupvalue")

  -- A light userdata reports "userdata", like a full one.
  local a = 1
  local g = function() return a end
  eq(type(debug.upvalueid(g, 1)), "userdata", "a light userdata is a userdata")
  eq(bare(msg(debug.setuservalue, debug.upvalueid(g, 1), {}))
       :find("userdata expected, got light userdata", 1, true) ~= nil,
    true, "and an argument error tells the two apart")

  -- `sethook` ignores mask letters it does not know and accepts a number.
  eq(msg(debug.sethook, function() end, "x"), "ok",
    "an unknown hook letter is ignored")
  eq(msg(debug.sethook, function() end, 5), "ok",
    "and a numeric mask is an option string")
  debug.sethook()

  -- `debug.traceback` writes a number out as the message; anything else is
  -- handed back untouched.
  eq(debug.traceback(5):find("5\nstack traceback:", 1, true) ~= nil, true,
    "a number message is written out")
  local t = {}
  eq(debug.traceback(t), t, "anything else is handed back")

  -- `debug.setcstacklimit` is the leftover knob; it answers the old limit.
  eq(debug.setcstacklimit(100), 200, "setcstacklimit answers the limit")
  eq(type(debug.debug), "function", "and debug.debug exists")
end

-- `string.pack`, including the value a format asks for when none was given.
do
  local function bare(e)
    return (tostring(e):gsub("^[^:]*:%d+: ", ""))
  end
  eq(bare(select(2, pcall(string.pack, "i4"))),
    "bad argument #2 to 'string.pack' (number expected, got nil)",
    "a missing value reads as nil")
  eq(bare(select(2, pcall(string.pack, "z"))),
    "bad argument #2 to 'string.pack' (string expected, got nil)",
    "and a string option says string")
  eq(string.packsize("!4i4i1"), 5, "a maximum alignment is honoured")
  eq(bare(select(2, pcall(string.packsize, "s"))),
    "bad argument #1 to 'string.packsize' (variable-length format)",
    "a variable-length format has no size")
end

print("stdlib: ok")
