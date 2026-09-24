-- Every runnable example in `examples/` must run and pass its own checks.
--
--   moon run cmd/main -- examples/basics.lua          -- by hand
--
-- An example asserts its results rather than printing expected output, so
-- running one *is* the test; this file is what makes `moon test` run them, and
-- what keeps them from rotting silently.

local examples = { "basics", "coroutines", "metatables" }

for _, name in ipairs(examples) do
  local path = "examples/" .. name .. ".lua"
  local chunk, err = loadfile(path)
  assert(chunk, path .. ": " .. tostring(err))
  local ok, failure = pcall(chunk)
  assert(ok, path .. ": " .. tostring(failure))
end

print("examples: ok")
