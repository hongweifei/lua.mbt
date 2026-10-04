-- `package.loadc` is this implementation's own extension.  The reference can
-- only hand back a `lua_CFunction`, which has to call the interpreter back, and
-- this build cannot be called back into from a library; what it can do is call a
-- plain C function found in a library named at run time, through a signature the
-- program declares.  So the reference has no `package.loadc` at all and would
-- refuse this file -- it is kept separate for the same reason the UTF-8 names are.

local sep = package.config:sub(1, 1)
local win = sep == "\\"
local MATH = win and "msvcrt.dll" or "libm.so.6"
local LIBC = win and "msvcrt.dll" or "libc.so.6"

-- Loading is asserted, not skipped: a library or an entry this host does not have
-- is a failure of the test's premise, and saying so is the point.
local function load(lib, decl)
  local f, why, step = package.loadc(lib, decl)
  if not f then
    error(
      "cannot load " .. decl .. " from " .. lib .. ": " .. tostring(why) ..
        " [" .. tostring(step) .. "]", 2)
  end
  return f
end

local pow = load(MATH, "double pow(double, double)")
local sqrt = load(MATH, "double sqrt(double)")
local strcmp = load(LIBC, "int strcmp(string, string)")
local strlen = load(LIBC, "int strlen(string)")
local abs = load(LIBC, "int abs(int)")
local atoi = load(LIBC, "int atoi(string)")
local strchr = load(LIBC, "string strchr(string, int)")
local strerror = load(LIBC, "string strerror(int)")
local srand = load(LIBC, "void srand(int)")
local rand = load(LIBC, "int rand()")

assert(pow(2, 10) == 1024.0, "two double arguments, a double answer")
assert(pow(4, 0.5) == 2.0, "and a fractional one")
assert(sqrt(9) == 3.0, "one double argument")
assert(strcmp("abc", "abc") == 0, "two string arguments")
assert(strcmp("abc", "abd") ~= 0, "and unequal ones")
assert(strlen("hello") == 5, "a string argument, an int answer")
assert(atoi("12345abc") == 12345, "a string a C function stops reading")
assert(abs(-7) == 7, "an int argument")

-- A `char*` answer is copied out.  What it says is the host's own wording, so
-- only that it is a string is checked -- except for `strchr`, which points back
-- into the string that was passed in and so says something fixed.
assert(type(strerror(0)) == "string" and #strerror(0) > 0, "a char* becomes a string")
assert(strchr("abcdef", string.byte("c")) == "cdef", "a pointer into the argument")
assert(strchr("abcdef", string.byte("z")) == nil, "a null answer is nil, not an error")

-- `void` answers with no values at all, and the call really happened.
assert(srand(42) == nil, "a void answer returns nothing")
local r1, r2 = rand(), rand()
srand(42)
assert(r1 == rand() and r2 == rand(), "the seed took, so the numbers repeat")

-- Arguments are converted the way the C API converts them: `luaL_checknumber`
-- accepts a numeric string, and blames the argument by number when it cannot.
assert(pow("2", 10) == 1024.0, "a numeric string is a number to the C API")
local ok, msg = pcall(pow, "x", 2)
assert(not ok, "a string that is not a number is refused")
assert(msg:find("bad argument #1", 1, true), "named by argument: " .. tostring(msg))
assert(msg:find("number expected, got string", 1, true), "with the library's own wording")
ok, msg = pcall(pow)
assert(not ok and msg:find("got no value", 1, true), "a missing argument is reported")
ok, msg = pcall(strcmp, {})
assert(not ok and msg:find("string expected, got table", 1, true), "the same for a string")

-- A signature this build cannot express is a soft failure, with the reason.
local function reject(decl, needle)
  local f, why = package.loadc(LIBC, decl)
  assert(f == nil, "refused: " .. decl)
  assert(type(why) == "string" and why:find(needle, 1, true) ~= nil,
    "the reason says why: " .. tostring(why))
end
reject("float area(float)", "cannot return a 'float'")
reject("int sum(int, int, int)", "at most 2 arguments")
reject("int main(int*)", "expected ',' or ')'")
reject("int f(", "expected a type in the argument list")
reject("int(double, double)", "expected a function name")
reject("int f(double))", "unexpected text")

-- The loader's own answers keep the reference's three-step shape.
local f, why, step = package.loadc(win and "no_such_lib.dll" or "no_such_lib.so",
                                   "int getpid()")
assert(f == nil and step == "open", "a library that will not open: " .. tostring(why))
f, why, step = package.loadc(LIBC, "int no_such_entry_here()")
assert(f == nil and step == "init", "a library with no such entry")

-- A loaded function is an ordinary value: it survives a collection, and two of
-- them can be alive at once.
local keeper = abs
collectgarbage("collect")
assert(keeper(-3) == 3, "still callable after a collection")
assert(pow(3, 3) == 27 and strcmp("a", "a") == 0, "and so is the rest of them")

-- What `package.loadlib` answers once the host both opens the library and finds
-- the entry: the one thing no build with a working loader answers, because this
-- build can look but cannot enter.  It is not the old "not enabled" fallback,
-- so the message is asserted and not just the step.  The reference hands back a
-- callable here, which is why this lives with the extension suite and not with
-- `require`.
local entries = {
  { "kernel32.dll", "LoadLibraryA" },
  { "libc.so.6", "malloc" },
  { "libm.so.6", "malloc" },
  { "libSystem.dylib", "malloc" },
}
local entered, why_entered
for i = 1, #entries do
  local e = entries[i]
  local _, w, s = package.loadlib(e[1], e[2])
  if not why_entered then
    why_entered = e[1] .. ": " .. tostring(w) .. " [" .. tostring(s) .. "]"
  end
  if s == "absent" then
    entered = w
    break
  end
end
assert(
  entered == "dynamic libraries cannot be entered by this build",
  "no candidate gave both the library and the entry (first try: " ..
    tostring(why_entered) .. ")"
)

print("native_libs: ok")
