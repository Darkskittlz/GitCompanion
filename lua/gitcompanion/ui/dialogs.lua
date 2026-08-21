-- lua/gitcompanion/ui/dialogs.lua
local M = {}

local function debug_log(msg, level)
	vim.schedule(function()
		vim.notify("[CommitSuccess Debug] " .. msg, level or vim.log.levels.INFO)
	end)
end

local function on_commit_success(state)
	if not state then
		debug_log("Aborted: state is nil", vim.log.levels.WARN)
		return
	end
	local Ui = state.Ui or state

	debug_log("Starting on_commit_success | Initial Mode: " .. tostring(Ui.mode))

	-- 1. Reset state changed files and clear tree root caches
	Ui.changed_files = {}
	Ui.tree_root = nil
	Ui.visible_tree_lines = {}
	Ui.flat_nodes = {}
	Ui._last_rendered_files = nil

	-- 2. Clear commit graph & diff caches
	Ui.commit_graph_cache = {}
	Ui.diff_cache = {}

	-- 3. Refocus mode to "branches"
	Ui.mode = "branches"

	-- 4. Get ACTUAL current branch synchronously from Git to avoid race conditions
	local current_head = vim.trim(vim.fn.system("git rev-parse --abbrev-ref HEAD"))
	debug_log("Git HEAD rev-parse output: '" .. current_head .. "'")

	if current_head ~= "" and not current_head:match("fatal") then
		Ui.current_branch = current_head
		Ui.branch_selected = current_head
	end

	local active_branch = Ui.current_branch or Ui.branch_selected or "HEAD"
	debug_log("Resolved active_branch: " .. active_branch)

	-- Helper to align index and update active cursor
	local function sync_branch_selection(branch_list, stage_name)
		stage_name = stage_name or "sync"
		local count = branch_list and #branch_list or 0
		debug_log(string.format("[%s] Syncing branches (Count: %d). Looking for: %s", stage_name, count, active_branch))

		if not branch_list or #branch_list == 0 then
			debug_log(string.format("[%s] branch_list is empty/nil", stage_name), vim.log.levels.WARN)
			return
		end

		local found = false
		for idx, b in ipairs(branch_list) do
			debug_log(string.format("[%s] Index %d: %s", stage_name, idx, b))
			if b == active_branch then
				Ui.selected_index = idx
				Ui.branch_selected = b
				found = true
				debug_log(string.format("[%s] MATCH FOUND at index %d", stage_name, idx))
				break
			end
		end

		if not found then
			debug_log(
				string.format("[%s] Active branch '%s' NOT FOUND in list", stage_name, active_branch),
				vim.log.levels.WARN
			)
		end

		-- Explicitly set window cursor to match selected_index
		if Ui.left_win and vim.api.nvim_win_is_valid(Ui.left_win) then
			local line_count = vim.api.nvim_buf_line_count(Ui.left_buf or 0)
			local target = math.max(1, math.min(Ui.selected_index or 1, line_count))
			debug_log(
				string.format(
					"[%s] Setting left_win cursor to line %d (selected_index: %s, line_count: %d)",
					stage_name,
					target,
					tostring(Ui.selected_index),
					line_count
				)
			)
			pcall(vim.api.nvim_win_set_cursor, Ui.left_win, { target, 0 })
		else
			debug_log(string.format("[%s] left_win is invalid or nil", stage_name), vim.log.levels.WARN)
		end
	end

	sync_branch_selection(Ui.branches, "Initial Sync")

	-- 5. Fetch status and graph for true active branch
	local status = require("gitcompanion.git.status")
	local layout = require("gitcompanion.ui.layout")
	local graph = require("gitcompanion.git.graph")

	local load_status = status.load_status_async or state.load_status_async
	if type(load_status) == "function" then
		debug_log("Calling load_status_async")
		load_status()
	end

	local fetch_graph = graph.fetch_git_graph_async or Ui.fetch_git_graph_async
	if type(fetch_graph) == "function" then
		debug_log("Calling fetch_git_graph_async for: " .. active_branch)
		fetch_graph(active_branch)
	end

	local load_branches = status.load_branches_async or state.load_branches_async
	if type(load_branches) == "function" then
		debug_log("Calling load_branches_async")
		load_branches(function(branches)
			debug_log("Async load_branches returned " .. (branches and #branches or 0) .. " branches")
			if branches then
				Ui.branches = branches
				sync_branch_selection(branches, "Async Callback Sync")
			end

			-- Re-fetch graph after fresh branch list loads
			if type(fetch_graph) == "function" then
				local target = Ui.branch_selected or active_branch
				debug_log("Re-fetching graph post-async for: " .. target)
				fetch_graph(target)
			end

			debug_log("Triggering UI refresh from async callback")
			if type(state.refresh_ui) == "function" then
				state.refresh_ui()
			elseif type(layout.refresh_ui) == "function" then
				layout.refresh_ui()
			end
		end)
	else
		debug_log("load_branches_async not found, triggering immediate refresh", vim.log.levels.WARN)
		if type(state.refresh_ui) == "function" then
			state.refresh_ui()
		elseif type(layout.refresh_ui) == "function" then
			layout.refresh_ui()
		end
	end
end

-- comment

function M.open_commit_modal(state)
	local Ui = state.Ui or state
	local branch = (Ui.branches and Ui.branches[Ui.selected_index]) or Ui.branch_selected or "HEAD"

	local width = math.floor(vim.o.columns * 0.9)
	local height_title = 1
	local height_desc = 4
	local height_diff = math.floor(vim.o.lines * 0.72)
	local spacing = 1
	local col = math.floor((vim.o.columns - width) / 2)

	-- 1. Backdrop Overlay Window
	local buf_overlay = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(buf_overlay, 0, -1, false, { string.rep(" ", width) })
	local win_overlay = vim.api.nvim_open_win(buf_overlay, false, {
		relative = "editor",
		width = vim.o.columns,
		height = vim.o.lines,
		row = 0,
		col = 0,
		style = "minimal",
		border = "none",
		zindex = 200,
	})

	-- 2. Staged Diff Buffer & Window
	local buf_diff = vim.api.nvim_create_buf(false, true)
	vim.bo[buf_diff].buftype = "nofile"
	vim.bo[buf_diff].bufhidden = "wipe"
	vim.bo[buf_diff].filetype = "diff"

	local diff_lines = vim.fn.systemlist("git diff --cached")
	if vim.v.shell_error ~= 0 or #diff_lines == 0 then
		diff_lines = { "[No staged changes]" }
	end
	vim.api.nvim_buf_set_lines(buf_diff, 0, -1, false, diff_lines)
	vim.bo[buf_diff].modifiable = false

	local win_diff = vim.api.nvim_open_win(buf_diff, false, {
		relative = "editor",
		width = width,
		height = height_diff - 3,
		row = 4,
		col = col,
		style = "minimal",
		border = "rounded",
		zindex = 300,
		focusable = true,
		title = " Commit ",
		title_pos = "center",
	})

	-- 3. Title Input Buffer & Window
	local buf_title = vim.api.nvim_create_buf(false, true)
	vim.bo[buf_title].buftype = "acwrite"
	vim.bo[buf_title].bufhidden = "wipe"

	local win_title = vim.api.nvim_open_win(buf_title, true, {
		relative = "editor",
		width = width,
		height = height_title,
		row = 2 + height_diff + spacing,
		col = col,
		style = "minimal",
		border = "rounded",
		zindex = 300,
		title = " Title ",
		title_pos = "center",
	})

	-- 4. Description Input Buffer & Window
	local buf_desc = vim.api.nvim_create_buf(false, true)
	vim.bo[buf_desc].buftype = "acwrite"
	vim.bo[buf_desc].bufhidden = "wipe"
	vim.api.nvim_buf_set_lines(buf_desc, 0, -1, false, { "", "", "" })

	local win_desc = vim.api.nvim_open_win(buf_desc, true, {
		relative = "editor",
		width = width,
		height = height_desc - 1,
		row = height_diff + height_title + 5,
		col = col,
		style = "minimal",
		border = "rounded",
		zindex = 300,
		title = " Description ",
		title_pos = "center",
	})

	-- Cleanup popup windows and return focus to main UI
	local function close_commit_popup()
		for _, w in ipairs({ win_title, win_desc, win_diff, win_overlay }) do
			if vim.api.nvim_win_is_valid(w) then
				vim.api.nvim_win_close(w, true)
			end
		end

		if Ui.left_win and vim.api.nvim_win_is_valid(Ui.left_win) then
			vim.api.nvim_set_current_win(Ui.left_win)
		end
	end

	-- Execute git commit command
	local function commit_changes()
		vim.cmd("stopinsert")
		local title = vim.api.nvim_buf_get_lines(buf_title, 0, -1, false)[1] or ""
		local body = table.concat(vim.api.nvim_buf_get_lines(buf_desc, 0, -1, false), "\n")

		if not title:match("%S") then
			vim.notify("Commit title cannot be empty", vim.log.levels.WARN)
			return
		end

		local cmd = "git commit -m " .. vim.fn.shellescape(title)
		if body:match("%S") then
			cmd = cmd .. " -m " .. vim.fn.shellescape(body)
		end

		local out = vim.fn.system(cmd)
		if vim.v.shell_error ~= 0 then
			vim.notify("Commit failed:\n" .. out, vim.log.levels.ERROR)
			return
		end

		if state.show_centered_message then
			state.show_centered_message("Committed changes on branch: " .. branch, "🌸")
		end

		close_commit_popup()
		on_commit_success(state)

		local ok, commits_keymaps = pcall(require, "gitcompanion.keymaps.commits")
		if ok and type(commits_keymaps.on_commit_success) == "function" then
			commits_keymaps.on_commit_success(state)
		end
	end

	-- Navigation & modal controls
	for _, b in ipairs({ buf_title, buf_desc, buf_diff }) do
		vim.keymap.set("n", "q", close_commit_popup, { buffer = b, noremap = true, silent = true })
		vim.keymap.set("n", "<Esc>", close_commit_popup, { buffer = b, noremap = true, silent = true })

		vim.keymap.set({ "n", "i" }, "<Tab>", function()
			vim.api.nvim_set_current_win(win_desc)
		end, { buffer = b, noremap = true, silent = true })

		vim.keymap.set({ "n", "i" }, "<S-Tab>", function()
			vim.api.nvim_set_current_win(win_title)
		end, { buffer = b, noremap = true, silent = true })

		vim.keymap.set("n", "<C-d>", function()
			vim.api.nvim_win_call(win_diff, function()
				vim.cmd("normal! \12")
			end)
		end, { buffer = b, noremap = true, silent = true })

		vim.keymap.set("n", "<C-u>", function()
			vim.api.nvim_win_call(win_diff, function()
				vim.cmd("normal! \21")
			end)
		end, { buffer = b, noremap = true, silent = true })
	end

	-- Submit bindings
	vim.keymap.set("n", "<CR>", commit_changes, { buffer = buf_title, noremap = true, silent = true })
	vim.keymap.set("n", "<CR>", commit_changes, { buffer = buf_desc, noremap = true, silent = true })
	vim.keymap.set("i", "<C-s>", commit_changes, { buffer = buf_title, noremap = true, silent = true })
	vim.keymap.set("i", "<C-s>", commit_changes, { buffer = buf_desc, noremap = true, silent = true })

	-- Focus setup
	vim.api.nvim_buf_set_lines(buf_title, 0, -1, false, { "" })
	vim.api.nvim_set_current_win(win_title)
	vim.cmd("startinsert!")
end

return M
