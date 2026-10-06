local n = 0
debug.sethook(function() n = n + 1 end, "c")
local function mk()
  local x = setmetatable({}, { __gc = function() local y = 1 return y end })
end
mk()
collectgarbage()
debug.sethook(nil)
print("hook events", n)
