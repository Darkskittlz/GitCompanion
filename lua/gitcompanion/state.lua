local M = {}

-- Ensure unified UI container exists globally
_G.Ui = _G.Ui or {}
M.Ui = _G.Ui

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
---
------ Re-fetches status/changed files and re-builds the tree
---@param cb function|nil
function M.reload_files(cb)
   local ok, data = pcall(require, "gitcompanion.git.data")
   if ok and type(data.load_status_async) == "function" then
      data.load_status_async(function()
         M.refresh_ui({ skip_fetch = true })
         if type(cb) == "function" then
            cb()
         end
      end)
   else
      -- Fallback to general refresh if load_status_async is named differently
      M.refresh_ui()
      if type(cb) == "function" then
         cb()
      end
   end
end

--- Invalidate cache for a specific branch or all caches
---@param branch_name string|nil
function M.invalidate_cache(branch_name)
   if branch_name and M.Ui.commit_graph_cache then
      M.Ui.commit_graph_cache[branch_name] = nil
   else
      M.Ui.commit_graph_cache = {}
      M.Ui.diff_cache = {}
   end
end

--- Lazy dispatch to layout.refresh_ui to avoid circular dependencies
---@param opts table|nil
function M.refresh_ui(opts)
   if type(M._registered_refresh_ui) == "function" then
      M._registered_refresh_ui(opts)
      return
   end

   local ok, layout = pcall(require, "gitcompanion.layout")
   if ok and type(layout.refresh_ui) == "function" then
      layout.refresh_ui(opts)
   end
end

--- Register explicit refresh function dynamically if preferred
---@param refresh_fn function
function M.register_refresh_ui(refresh_fn)
   M._registered_refresh_ui = refresh_fn
end

--- Proxy load_branches_async lazily to break circular requires
function M.load_branches_async(opts, cb)
   local ok, data = pcall(require, "gitcompanion.git.data")
   if ok and type(data.load_branches_async) == "function" then
      data.load_branches_async(opts, cb)
   elseif type(opts) == "function" then
      opts()
   elseif type(cb) == "function" then
      cb()
   end
end

--- Helper for keymaps to trigger a post-action fetch & reload cleanly
---@param branch_name string|nil
---@param cb function|nil
function M.reload_with_fetch(branch_name, cb)
   if type(branch_name) == "function" then
      cb = branch_name
      branch_name = nil
   end

   local target_branch = branch_name or M.Ui.branch_selected or M.Ui.current_branch
   M.invalidate_cache(target_branch)

   M.load_branches_async({ fetch = true }, function()
      M.refresh_ui({ skip_fetch = true })
      if type(cb) == "function" then
         cb()
      end
   end)
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
