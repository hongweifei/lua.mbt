-- A module loaded through `require`.
local M = {}
function M.double(x) return x * 2 end
M.name = "mod_helper"
return M
