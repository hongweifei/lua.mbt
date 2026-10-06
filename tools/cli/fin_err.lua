local function mk()
  local x = setmetatable({}, { __gc = function() error("bad fin") end })
end
mk()
collectgarbage()
print("after collect")
mk()
