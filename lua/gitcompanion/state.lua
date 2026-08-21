local M = {}

-- Ensure unified UI container
M.Ui = _G.Ui or {}
_G.Ui = M.Ui

-------------------------------------------------------------------------------
-- 1. STATE & CACHE INITIALIZATION
-------------------------------------------------------------------------------
M.Ui.diff_cache = M.Ui.diff_cache or {}
M.Ui.commit_graph_cache = M.Ui.commit_graph_cache or {}
M.Ui.current_branch = M.Ui.current_branch or ""
M.Ui.branches = M.Ui.branches or {}
M.Ui.changed_files = M.Ui.changed_files or {}
M.Ui.stashes = M.Ui.stashes or {}
M.Ui.selected_index = M.Ui.selected_index or 1
M.Ui.mode = M.Ui.mode or "branches"

--- Initializes or resets the tree root node
---@param root_name string|nil
---@return table
function M.init_tree_root(root_name)
   root_name = root_name or vim.fn.fnamemodify(vim.fn.getcwd(), ":t")
   M.Ui.tree_root = {
      name = root_name,
      is_dir = true,
      expanded = true,
      children = {},
   }
   return M.Ui.tree_root
end

-- Default initial tree root
M.Ui.tree_root = M.Ui.tree_root or M.init_tree_root()

-------------------------------------------------------------------------------
-- 2. EXPORTED DATA & REFRESH METHODS
-------------------------------------------------------------------------------

--- Proxy load_branches_async lazily to break circular requires
function M.load_branches_async(opts, cb)
   local data = require("gitcompanion.git.data")
   if type(data.load_branches_async) == "function" then
      data.load_branches_async(opts, cb)
   end
end

--- Setter to register your main UI refresh function dynamically
function M.register_refresh_ui(refresh_fn)
   M.refresh_ui = refresh_fn
end

-------------------------------------------------------------------------------
-- 3. CACHE & STATE MANAGEMENT HELPERS
-------------------------------------------------------------------------------

--- Clear transient caches (diffs and commit graphs)
function M.clear_cache()
   M.Ui.diff_cache = {}
   M.Ui.commit_graph_cache = {}
end

--- Reset complete UI state back to default
---@param root_name string|nil
function M.reset_state(root_name)
   M.clear_cache()
   M.Ui.current_branch = ""
   M.Ui.branches = {}
   M.Ui.changed_files = {}
   M.Ui.stashes = {}
   M.Ui.selected_index = 1
   M.Ui.mode = "branches"
   M.init_tree_root(root_name)
end

return M
