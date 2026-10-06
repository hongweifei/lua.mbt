local x = setmetatable({}, { __gc = function() print("fin") end })
os.exit(false, true)
