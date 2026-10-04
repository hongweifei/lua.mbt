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

-- `require` reports the loader's reason for a file `package.cpath` turned up.
-- Here the template finds a Lua source file, which no loader will open.
local saved_path, saved_cpath = package.path, package.cpath
package.cpath = "./tests/?.lua"
local nok, nerr = pcall(require, "mod_helper")
assert(not nok, "a file that is not a library does not load")
assert(nerr:match("error loading module 'mod_helper' from file"), nerr)
-- The file *was* found, so the search ends there: what comes back is the
-- loader's complaint, not the list of names that were tried.
assert(nerr:find("not found", 1, true) == nil, nerr)
package.cpath = saved_cpath

-- ---------------------------------------------------------------- searchers
-- The reference has four, and the fourth is the one that looks for the *root*
-- of a dotted name: `require("a.b")` asks the file the name `a` resolves to for
-- the entry `luaopen_a_b`, which is how one library can hold a whole tree.
assert(#package.searchers == 4, "four searchers")
for i = 1, 4 do
  assert(type(package.searchers[i]) == "function", "searcher " .. i .. " is a function")
end

-- `findfile` reads the path with `lua_tostring`, so a number is the text of
-- that number rather than an error.
package.path = 5
package.cpath = "./nowhere/?.so"
local ok_num, err_num = pcall(require, "q")
assert(not ok_num, "a number does not name a directory")
assert(err_num:find("no file '5'", 1, true), "5 is searched as the file '5'")
package.path = "./nowhere/?.lua"

-- The whole report, line for line: every file the four searchers tried, in the
-- order they tried them.  Both the reference build and this one are asked to
-- agree with the text below, which is why the templates name nothing that
-- exists.
package.cpath = "./nowhere/?.so;./nowhere/loadall.so"
local sep = package.config:sub(1, 1)
local function file_lines(path_list, name)
  local file = name:gsub("%.", sep)
  local out = {}
  for tmpl in (path_list .. ";"):gmatch("(.-);") do
    out[#out + 1] = tmpl:gsub("?", function() return file end)
  end
  return table.concat(out, "'\n\tno file '")
end
local function report(name, root)
  local lines = {
    "module '" .. name .. "' not found:",
    "\tno field package.preload['" .. name .. "']",
    "\tno file '" .. file_lines(package.path, name) .. "'",
    "\tno file '" .. file_lines(package.cpath, name) .. "'",
  }
  if root then
    lines[#lines + 1] = "\tno file '" .. file_lines(package.cpath, root) .. "'"
  end
  return table.concat(lines, "\n")
end
local function not_found(name)
  local ok, err = pcall(require, name)
  assert(not ok, "require(" .. name .. ") does not resolve")
  assert(type(err) == "string", "the report is the message itself")
  return err
end
assert(not_found("x") == report("x", nil), "a name with no dot has no root")
assert(not_found("a.b") == report("a.b", "a"), "the root of a.b is a")
assert(not_found("a.b.c") == report("a.b.c", "a"), "and it stops at the first dot")

-- A root whose file *is* there is a different answer: the file was found, so
-- the search stops and the complaint is the loader's.  This template resolves
-- `helper` to a Lua source file, which no loader will open.
package.cpath = "./tests/mod_?.lua"
local rok, rerr = pcall(require, "helper.x")
assert(not rok, "the root's file is not a library either")
assert(
  rerr:find(
    "error loading module 'helper.x' from file './tests/mod_helper.lua':",
    1, true),
  "the root searcher names the module, not the entry: " .. tostring(rerr))
assert(rerr:find("not found", 1, true) == nil, "and it does not go on looking")

package.path, package.cpath = saved_path, saved_cpath

print("require: ok")
