local function mk()
  local x = setmetatable({}, { __gc = function() coroutine.yield(1) end })
end
mk()
collectgarbage()
print("after collect")
