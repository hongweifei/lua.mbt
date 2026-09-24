-- Coroutines: produce, consume, and hand control back and forth.
--
--   moon run cmd/main -- examples/coroutines.lua

local function eq(actual, expected, what)
  assert(actual == expected,
    ("%s: expected %s, got %s"):format(what, tostring(expected), tostring(actual)))
end

-- A generator written with coroutine.wrap: each call resumes the body up to
-- its next yield.
local function count_from(n)
  return coroutine.wrap(function()
    while true do
      coroutine.yield(n)
      n = n + 1
    end
  end)
end

local numbers = count_from(10)
eq(numbers(), 10, "the first resume runs to the first yield")
eq(numbers(), 11, "and the next continues from there")

-- A producer that drives a consumer through a second coroutine.
local function producer(consumer)
  return coroutine.create(function()
    for i = 1, 5 do consumer(i) end
    return "produced 5"
  end)
end

local seen = {}
local ok, result = coroutine.resume(producer(function(i) seen[#seen + 1] = i * i end))
eq(ok, true, "the producer finished without error")
eq(result, "produced 5", "and its return value comes back from resume")
eq(table.concat(seen, ","), "1,4,9,16,25", "the consumer saw every item")

-- A metamethod may yield: the call it serves is a Lua call, so the coroutine
-- keeps its own stack.  (A comparator inside `table.sort` may not -- that one
-- is a callback from a host function, and yields across it are refused.)
local walker = coroutine.create(function()
  local t = setmetatable({}, {
    __index = function(_, k)
      coroutine.yield("looking up " .. k)
      return k .. "!"
    end,
  })
  return t.hello
end)
local _, event = coroutine.resume(walker)
eq(event, "looking up hello", "a metamethod may yield")
eq(coroutine.status(walker), "suspended", "which leaves the coroutine suspended")
local ok2, done = coroutine.resume(walker)
eq(ok2 and done, "hello!", "and resuming runs it to the end")
eq(coroutine.status(walker), "dead", "a finished coroutine is dead")

-- Errors do not escape `resume`.
local failing = coroutine.create(function() error("inside") end)
local ok3, err = coroutine.resume(failing)
eq(ok3, false, "resume reports the failure instead of raising")
eq(err:match("inside"), "inside", "with the message")
eq(coroutine.status(failing), "dead", "the coroutine is dead after an error")
local ok4, err4 = coroutine.close(failing)
eq(ok4, false, "closing it reports the error it died with")
eq(err4:match("inside"), "inside", "which is that error")

-- `coroutine.close` also runs the to-be-closed variables a suspended body owns.
local cleaned = false
local suspended = coroutine.create(function()
  local guard <close> = setmetatable({}, { __close = function() cleaned = true end })
  coroutine.yield()
  return "never resumed"
end)
coroutine.resume(suspended)
eq(cleaned, false, "a suspended body has not closed its variables")
eq(coroutine.close(suspended), true, "closing the coroutine succeeds")
eq(cleaned, true, "and runs the handler")

-- Inside a coroutine a yield is allowed; the main thread is not yieldable.
eq(coroutine.isyieldable(), false, "the main thread cannot yield")
local co = coroutine.create(function() return coroutine.isyieldable() end)
local _, inside = coroutine.resume(co)
eq(inside, true, "a coroutine can")

print("coroutines.lua: ok")
