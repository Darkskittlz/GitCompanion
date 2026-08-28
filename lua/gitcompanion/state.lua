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

local function log_debug(msg)
	vim.schedule(function()
		-- vim.notify("[GitCompanion Debug] " .. msg, vim.log.levels.DEBUG)
	end)
end

-------------------------------------------------------------------------------
-- 2. EXPORTED DATA & REFRESH METHODS
-------------------------------------------------------------------------------
---
------ Re-fetches status/changed files and re-builds the tree
function M.reload_files(cb)
	log_debug("reload_files START | Clearing state caches...")

	-- 1. Wipe cached UI tree structures completely
	M.Ui.changed_files = nil
	M.Ui.flat_nodes = nil
	M.Ui.tree_nodes = nil
	M.Ui.file_tree = nil
	M.Ui._last_rendered_files = nil
	M.Ui._last_files_len = nil

	local ok_data, data = pcall(require, "gitcompanion.git.data")

	-- Sync fetch status fallback
	if ok_data then
		if type(data.get_status) == "function" then
			M.Ui.changed_files = data.get_status()
		elseif type(data.load_status) == "function" then
			M.Ui.changed_files = data.load_status()
		end
	end

	-- 2. Force-rebuild the file tree
	local ok_tree, tree = pcall(require, "gitcompanion.ui.tree")
	if not ok_tree then
		ok_tree, tree = pcall(require, "gitcompanion.tree")
	end

	if ok_tree and type(tree) == "table" then
		if type(tree.build_tree) == "function" then
			tree.build_tree()
		elseif type(tree.init) == "function" then
			tree.init()
		end
	end

	-- 3. Render UI updates & immediate tree/layout redraw
	M.refresh_ui({ skip_fetch = true })

	if ok_tree and type(tree.render_files_tree) == "function" then
		tree.render_files_tree()
	end

	local layout_ok, layout_mod = pcall(require, "gitcompanion.ui.layout")
	if layout_ok and type(layout_mod.render_diff) == "function" then
		layout_mod.render_diff()
	end

	if type(cb) == "function" then
		cb()
	end
end

--- Invalidate cache for a specific branch or all caches
function M.invalidate_cache(branch_name)
	if branch_name and M.Ui.commit_graph_cache then
		M.Ui.commit_graph_cache[branch_name] = nil
		M.Ui.diff_cache = {} -- Force diff cache clearance to prevent index-shift stale diffs
	else
		M.Ui.commit_graph_cache = {}
		M.Ui.diff_cache = {}
	end
end

--- Lazy dispatch to layout.refresh_ui to avoid circular dependencies
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

--- Proxy load_commits_async lazily to break circular requires
function M.load_commits_async(branch_name, cb)
	if type(branch_name) == "function" then
		cb = branch_name
		branch_name = nil
	end

	local ok, data = pcall(require, "gitcompanion.git.data")
	if ok and data.load_commits_async then
		data.load_commits_async(branch_name, function(raw_or_table)
			local lines = raw_or_table
			if type(lines) == "string" then
				lines = vim.split(lines, "\n", { trimempty = true })
			end
			if type(cb) == "function" then
				cb(lines)
			end
		end)
	else
		if type(cb) == "function" then
			cb({})
		end
	end
end

--- Helper for keymaps to trigger a post-action fetch & reload cleanly
function M.reload_with_fetch(branch_name, cb)
	if type(branch_name) == "function" then
		cb = branch_name
		branch_name = nil
	end

	local target_branch = branch_name or M.Ui.branch_selected or M.Ui.current_branch
	M.invalidate_cache(target_branch)

	M.load_branches_async({ fetch = true }, function()
		-- 2. Reload commit history for the updated HEAD/branch
		M.load_commits_async(target_branch, function()
			-- 3. Now re-render the UI with fresh commit graph data
			M.refresh_ui({ skip_fetch = true })
			if type(cb) == "function" then
				cb()
			end
		end)
	end)
end

--- Fetch stashes asynchronously and update state
function M.load_stashes_async(cb)
	local ok, data = pcall(require, "gitcompanion.git.data")
	if ok and type(data.load_stashes_async) == "function" then
		data.load_stashes_async(function(stashes)
			M.Ui.stashes = stashes or {}
			if type(cb) == "function" then
				cb(M.Ui.stashes)
			end
		end)
	else
		-- Synchronous fallback
		M.Ui.stashes = vim.fn.systemlist("git stash list") or {}
		if type(cb) == "function" then
			cb(M.Ui.stashes)
		end
	end
end

--- Re-fetches stashes and status, switches view mode, and updates UI
function M.reload_stashes(cb)
	log_debug("reload_stashes START | Switching mode to stashes")

	-- 1. Force-wipe all file tree structures and caches synchronously first
	M.Ui.changed_files = nil
	M.Ui.flat_nodes = nil
	M.Ui.tree_nodes = nil
	M.Ui.file_tree = nil
	M.Ui.tree_root = M.init_tree_root()

	-- 2. Force UI mode to stashes so layout switches tabs automatically
	M.Ui.mode = "stashes"
	M.Ui.stashes_loaded = false

	local ok_data, data = pcall(require, "gitcompanion.git.data")
	local stashes = {}

	if ok_data and type(data.get_stashes) == "function" then
		stashes = data.get_stashes()
	else
		-- Direct CLI fallback if data helper missing
		local out = vim.fn.systemlist("git stash list")
		if vim.v.shell_error == 0 then
			stashes = out
		end
	end

	M.Ui.stashes = stashes or {}

	if M.Ui.selected_index and M.Ui.selected_index > #M.Ui.stashes then
		M.Ui.selected_index = math.max(1, #M.Ui.stashes)
	end

	-- 3. Force an immediate UI refresh for the new mode before invoking callbacks
	M.refresh_ui({ skip_fetch = true })

	if type(cb) == "function" then
		cb()
	end
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
