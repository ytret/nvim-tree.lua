local lib = require("nvim-tree.lib")
local core = require("nvim-tree.core")
local find_file = require("nvim-tree.actions.finders.find-file")
local notify = require("nvim-tree.notify")
local utils = require("nvim-tree.utils")

local M = {}

---Expand and focus the source file in the tree without leaving the tree window.
---Warns when the source file is outside the tree.
---@return boolean true if the source file was found
function M.fn()
  local target = lib.target_winid
  if not target or target == 0 or not vim.api.nvim_win_is_valid(target) then
    return false
  end

  local path = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(target))
  path = path ~= "" and vim.uv.fs_realpath(path) or nil
  if not path then
    return false
  end

  local explorer = core.get_explorer()
  local root = explorer and explorer.absolute_path
  if not root or (path ~= root and not vim.startswith(path, utils.path_add_trailing(root))) then
    notify.warn(string.format("Source file is outside the tree: %s", notify.render_path(path)))
    return false
  end

  return find_file.fn(path)
end

return M
