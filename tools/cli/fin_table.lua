local function mk()
  local x = setmetatable({}, { __gc = function() error({ 1, 2 }) end })
end
mk()
collectgarbage()
print("after collect")
