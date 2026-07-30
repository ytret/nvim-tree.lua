local lib = require("nvim-tree.lib")

local M = {}

---Focus the source window that was active before opening nvim-tree.
---Does nothing if the source window is no longer valid.
---@return boolean true if the focus was successful
function M.fn()
  local target = lib.target_winid
  if target and target ~= 0 and vim.api.nvim_win_is_valid(target) then
    vim.api.nvim_set_current_win(target)
    return true
  end
  return false
end

return M