local lib = require("nvim-tree.lib")
local find_file = require("nvim-tree.actions.finders.find-file")

local M = {}

---Focus the source file in the tree without leaving the tree window.
---Does nothing if the source window is invalid or does not contain a file.
---@return boolean true if the source file was found
function M.fn()
  local target = lib.target_winid
  if not target or target == 0 or not vim.api.nvim_win_is_valid(target) then
    return false
  end

  local path = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(target))
  if path == "" or not vim.uv.fs_realpath(path) then
    return false
  end

  find_file.fn(path)
  return true
end

return M
