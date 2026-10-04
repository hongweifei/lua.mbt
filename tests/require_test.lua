local helper = require("tests.mod_helper")
assert(helper.double(21) == 42, "module function")
assert(helper.name == "mod_helper", "module field")
assert(require("tests.mod_helper") == helper, "require caches")
assert(package.loaded["tests.mod_helper"] == helper, "package.loaded")
assert(type(package.path) == "string", "package.path")
assert(type(package.searchpath("tests.mod_helper", package.path)) == "string", "searchpath")
local ok, err = pcall(require, "no.such.module")
assert(not ok and err:match("not found") ~= nil, "missing module message")

-- The host loader is really asked.  A file that will not open answers with its
-- own reason and names the step that failed, which is what a build with no
-- loader at all cannot do.
local f, why, step = package.loadlib("no_such_library_xyz", "luaopen_no_such")
assert(f == nil, "loadlib of a missing file answers nil")
assert(type(why) == "string" and #why > 0, "loadlib gives the loader's reason")
assert(step == "open", "and names the step that failed: " .. tostring(step))

-- A library the host does open, and an entry it does not have: only the reason
-- is host-specific, the step is not.  The candidate list is asserted, not
-- iterated quietly -- a host that opens none of them is a finding, not a skip.
local candidates = { "kernel32.dll", "libc.so.6", "libm.so.6", "libSystem.dylib" }
local opened, first
for i = 1, #candidates do
  local _, w, s = package.loadlib(candidates[i], "no_such_entry_here")
  if not first then first = candidates[i] .. ": " .. tostring(w) end
  if s == "init" then
    opened = candidates[i]
    break
  end
end
assert(opened, "no candidate library opened (first try: " .. tostring(first) .. ")")

-- A library the host opens *and* provides the entry for.  The answer is then the
-- one thing no build with a working loader gives, because this build can look but
-- cannot enter -- and it is not the old "not enabled" fallback, which is why the
-- message is asserted and not just the step.
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

-- `require` reports the loader's reason for a file `package.cpath` turned up.
-- Here the template finds a Lua source file, which no loader will open.
local saved = package.cpath
package.cpath = "./tests/?.lua"
local nok, nerr = pcall(require, "mod_helper")
package.cpath = saved
assert(not nok, "a file that is not a library does not load")
assert(nerr:match("error loading module 'mod_helper' from file"), nerr)

print("require: ok")
