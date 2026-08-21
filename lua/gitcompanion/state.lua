local M = {}

-- Ensure global UI container exists safely
_G.Ui = _G.Ui or {}

-------------------------------------------------------------------------------
-- 1. STATE & CACHE INITIALIZATION
-------------------------------------------------------------------------------
Ui.diff_cache = Ui.diff_cache or {}
Ui.commit_graph_cache = Ui.commit_graph_cache or {}
Ui.current_branch = Ui.current_branch or ""
Ui.branches = Ui.branches or {}
Ui.changed_files = Ui.changed_files or {}
Ui.stashes = Ui.stashes or {}
Ui.selected_index = Ui.selected_index or 1
Ui.mode = Ui.mode or "branches"

--- Initializes or resets the tree root node
---@param root_name string|nil
---@return table
function M.init_tree_root(root_name)
   root_name = root_name or vim.fn.fnamemodify(vim.fn.getcwd(), ":t")
   Ui.tree_root = {
      name = root_name,
      is_dir = true,
      expanded = true,
      children = {},
   }
   return Ui.tree_root
end

-- Default initial tree root
Ui.tree_root = Ui.tree_root or M.init_tree_root()

-------------------------------------------------------------------------------
-- 2. CACHE & STATE MANAGEMENT HELPERS
-------------------------------------------------------------------------------

--- Clear transient caches (diffs and commit graphs)
function M.clear_cache()
   Ui.diff_cache = {}
   Ui.commit_graph_cache = {}
end

--- Reset complete UI state back to default
---@param root_name string|nil
function M.reset_state(root_name)
   M.clear_cache()
   Ui.current_branch = ""
   Ui.branches = {}
   Ui.changed_files = {}
   Ui.stashes = {}
   Ui.selected_index = 1
   Ui.mode = "branches"
   M.init_tree_root(root_name)
end

return M
