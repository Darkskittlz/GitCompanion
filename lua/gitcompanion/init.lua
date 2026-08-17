---@diagnostic disable: undefined-global
local M = {}

-- TODO: add rename context to git commit

-- Highlights
vim.api.nvim_set_hl(0, "GitBranchCurrent", { fg = "#549afc" })
vim.api.nvim_set_hl(0, "GitUnstaged", { fg = "#f99c67", bold = true, italic = true })
vim.api.nvim_set_hl(0, "GitStaged", { fg = "#a6e22e", bold = true })
vim.api.nvim_set_hl(0, "GitPickerTitle", { fg = "#268bd3", bold = true })

vim.api.nvim_set_hl(0, "DiffAdd", { fg = "#00aa00", bg = "", bold = false }) -- green
vim.api.nvim_set_hl(0, "DiffDelete", { fg = "#f92672", bg = "", bold = false }) -- red/pink
vim.api.nvim_set_hl(0, "DiffChange", { fg = "#fd971f", bg = "", bold = false }) -- orange/yellow

vim.api.nvim_set_hl(0, "MergeBlue", { fg = "#4da3ff", bold = true })
vim.api.nvim_set_hl(0, "MergeGreen", { fg = "#32cd32", bold = true })
vim.api.nvim_set_hl(0, "MergeRed", { fg = "#ff4444", bold = true })
vim.api.nvim_set_hl(0, "MergeWhite", { fg = "#bbbbbb", bold = true })

vim.api.nvim_set_hl(0, "ResetBlue", { fg = "#4da3ff", bold = true })
vim.api.nvim_set_hl(0, "ResetGreen", { fg = "#32cd32", bold = true })
vim.api.nvim_set_hl(0, "ResetRed", { fg = "#ff4444", bold = true })
vim.api.nvim_set_hl(0, "ResetWhite", { fg = "#bbbbbb", bold = true })

vim.api.nvim_set_hl(0, "GitGraphSymbol", { fg = "#5f87ff" })

-- Light Mode Colors
vim.api.nvim_set_hl(0, "GitHash", { fg = "#00d7ff", bold = true })
vim.api.nvim_set_hl(0, "GitDate", { fg = "#db302d", italic = true })
vim.api.nvim_set_hl(0, "GitAuthor", { fg = "#00a77d", italic = true })
vim.api.nvim_set_hl(0, "GitOutput", { fg = "#40a02b", bold = false, italic = false }) -- Light green for stdout (success)
vim.api.nvim_set_hl(0, "GitError", { fg = "#FF6F69", bold = false, italic = false }) -- Red for stderr (error)
vim.api.nvim_set_hl(0, "GitMsg", { fg = "#777777", bold = false, italic = false })

-- Dark Mode Colors
-- vim.api.nvim_set_hl(0, "GitHash", { fg = "#11518c", bold = true, italic = false })
-- vim.api.nvim_set_hl(0, "GitDate", { fg = "#006400", bold = false, italic = true })
-- vim.api.nvim_set_hl(0, "GitMsg", { fg = "#ffffff" })

-- Git Graph Colors
local graph_chars = { "◯", "│", "╮", "╯", "─" }

-- branch colors
local graph_colors = {
	"#5fff5f", -- green
	"#5fd7ff", -- cyan
	"#ffaf5f", -- orange
	"#ff5fff", -- magenta
	"#ffff5f", -- yellow
	"#5f5fff", -- blue
	"#5fffff", -- light cyan
	"#ff5f5f", -- red
}

for i, c in ipairs(graph_colors) do
	vim.api.nvim_set_hl(0, "GitGraphSymbol" .. i, { fg = c })
end

vim.cmd([[
highlight GitStaged guifg=green
highlight GitStagedFile guifg=green
highlight GitUnstaged guifg=orange
highlight GitUnstagedFile guifg=orange
highlight GitBranchCurrent guifg=#00BFFF
]])

local Ui = {
	left_buf = nil,
	left_win = nil,
	right_buf = nil,
	right_win = nil,
	mode = "branches",
	branches = {},
	stashes = {},
	changed_files = {},
	selected_index = 1,
	branch_selected = nil,
}

local function git_root()
	local root = vim.fn.systemlist("git rev-parse --show-toplevel")[1]
	return root ~= "" and root or "."
end

local function run_git(cmd)
	if type(cmd) == "table" then
		return vim.fn.systemlist(cmd)
	end
	return vim.fn.systemlist(cmd)
end

---------------------------------------------------------------------------
-- 🔄 Load list of Git branches
---------------------------------------------------------------------------
local function load_branches()
	local branches = run_git("git branch --list --format='%(refname:short)'") or {}

	-- Filter out empty/whitespace-only lines
	local cleaned = {}
	for _, b in ipairs(branches) do
		if b and b:match("%S") then
			table.insert(cleaned, b)
		end
	end

	-- Get the current branch
	local current = run_git("git rev-parse --abbrev-ref HEAD")[1] or ""

	-- Get ahead/behind info
	Ui.branch_ahead_behind = {}
	local tracking_info = run_git("git for-each-ref --format='%(refname:short)|%(upstream:track)' refs/heads/") or {}
	for _, line in ipairs(tracking_info) do
		local b, track = line:match("^(.-)|(.*)$")
		if b and b ~= "" then
			local ah = track:match("ahead (%d+)")
			local bh = track:match("behind (%d+)")
			local track_str = ""
			if ah then
				track_str = track_str .. "↑" .. ah
			end
			if bh then
				track_str = track_str .. "↓" .. bh
			end
			Ui.branch_ahead_behind[b] = track_str
		end
	end

	-- Store branch statuses separately
	local branch_statuses = {}
	local status = run_git("git status --porcelain")
	for _, branch in ipairs(cleaned) do
		if branch == current then
			local staged = false
			local unstaged = false
			for _, line in ipairs(status) do
				local x = line:sub(1, 1) -- staged
				local y = line:sub(2, 2) -- unstaged

				if x ~= " " then
					staged = true
				end
				if y ~= " " then
					unstaged = true
				end
			end

			if unstaged then
				branch_statuses[branch] = "💣" -- unstaged changes exist
			elseif staged then
				branch_statuses[branch] = "✅" -- staged changes ready to commit
			else
				branch_statuses[branch] = "" -- clean
			end
		else
			branch_statuses[branch] = "" -- other branches just blank
		end
	end

	-- Reorder so current branch is first
	table.sort(cleaned, function(a, b)
		if a == current then
			return true
		end
		if b == current then
			return false
		end
		return a < b
	end)

	-- Save pure branch names
	Ui.branches = cleaned
	Ui.branch_statuses = branch_statuses

	-- Default selected branch
	Ui.branch_selected = Ui.branch_selected or Ui.branches[1]
end

---------------------------------------------------------------------------
-- 🕵️ Load list of Git stashes
---------------------------------------------------------------------------
local function load_stashes()
	local raw = run_git("git stash list --pretty='%gd: %s'") or {}
	Ui.stashes = vim.tbl_filter(function(s)
		return s and #s > 0
	end, raw)
end

---------------------------------------------------------------------------
-- 🧩 Load list of changed files (staged + unstaged)
--  branch: optional branch or commit ref (defaults to HEAD)
---------------------------------------------------------------------------
local function get_changed_files(branch)
	branch = branch or "HEAD" -- fallback if not provided

	-------------------------------------------------------------------------
	-- Run Git commands:
	--   - `git diff --cached --name-status` → staged changes
	--   - `git diff --name-status`          → unstaged changes
	-------------------------------------------------------------------------
	local staged_lines = run_git("git diff --cached --name-status " .. branch) or {}
	local unstaged_lines = run_git("git diff --name-status " .. branch) or {}
	local untracked_lines = run_git("git ls-files --others --exclude-standard") or {}

	-------------------------------------------------------------------------
	-- Prepare data structures:
	--   index   → map of path → { value, status, staged }
	--   results → list of all files (for ordered display)
	-------------------------------------------------------------------------
	local index, results = {}, {}

	-------------------------------------------------------------------------
	-- Helper: add(status, path, staged_flag)
	-------------------------------------------------------------------------
	local function add(status, path, staged_flag)
		if not index[path] then
			index[path] = {
				value = path,
				status = status or "M",
				staged = staged_flag or false,
			}
			table.insert(results, index[path])
		else
			-- Update staged flag and status if necessary
			if staged_flag then
				index[path].staged = true
				index[path].status = status or index[path].status
			else
				index[path].staged = index[path].staged or false
				index[path].status = status or index[path].status
			end
		end
		-- print(
		--   "get_changed_files: file=",
		--   path,
		--   "status=",
		--   status,
		--   "staged=",
		--   index[path].staged
		-- )
	end

	-------------------------------------------------------------------------
	-- Parse staged lines
	-------------------------------------------------------------------------
	for _, line in ipairs(staged_lines) do
		if line and line:match("%S") then
			-- line format: "M  path/to/file" or "A  path/to/file"
			local s, p = line:match("^(%S+)%s+(.*)$")
			if not s then
				-- fallback if --name-status didn't provide status
				s, p = "M", line
			end
			if p then
				add(s, p, true)
			end
		end
	end

	-------------------------------------------------------------------------
	-- Parse unstaged lines
	-------------------------------------------------------------------------
	for _, line in ipairs(unstaged_lines) do
		if line and line:match("%S") then
			local s, p = line:match("^(%S+)%s+(.*)$")
			if not s then
				s, p = "M", line
			end
			if p then
				add(s, p, false)
			end
		end
	end

	-------------------------------------------------------------------------
	-- Parse untracked lines
	-------------------------------------------------------------------------
	for _, line in ipairs(untracked_lines) do
		if line and line:match("%S") then
			add("U", line, false) -- "U" stands for Untracked
		end
	end

	-------------------------------------------------------------------------
	-- Store final list
	-------------------------------------------------------------------------
	Ui.changed_files = results
end

-- Diff preview
local function get_diff_for_target(target)
	if not target or target == "" then
		return { "[No target]" }
	end
	local root = git_root()
	local cmd = string.format(
		"git -C %s diff -- %s; echo '\n--- STAGED CHANGES ---\n'; git -C %s diff --cached -- %s",
		vim.fn.fnameescape(root),
		vim.fn.shellescape(target),
		vim.fn.fnameescape(root),
		vim.fn.shellescape(target)
	)
	local out = vim.fn.systemlist({ "bash", "-c", cmd })
	if vim.v.shell_error ~= 0 or #out == 0 then
		return { "[No changes]" }
	end
	return out
end

---------------------------------------------------------------------------
-- Render the left panel (branches or changed files)
---------------------------------------------------------------------------
local function render_left()
	if not Ui.left_buf then
		-- print("render_left: no left buffer")
		return
	end

	-- print("render_left: starting, mode =", Ui.mode)
	vim.api.nvim_buf_set_option(Ui.left_buf, "modifiable", true)

	local lines = {} -- lines to write
	local highlights = {} -- highlight info

	if Ui.mode == "branches" then
		load_branches()
		local current = run_git("git rev-parse --abbrev-ref HEAD")[1] or ""
		for i, b in ipairs(Ui.branches) do
			local marker = (b == current) and "*" or " "
			local status = Ui.branch_statuses[b] or ""
			local ahead_behind = Ui.branch_ahead_behind[b] or ""
			local line = string.format("%2s %s %s %s", marker, b, status, ahead_behind)
			table.insert(lines, line)

			if b == current then
				table.insert(highlights, { line = i, hl = "GitBranchCurrent" })
			end
		end
	elseif Ui.mode == "stashes" then
		load_stashes()
		for i, s in ipairs(Ui.stashes) do
			table.insert(lines, "  " .. s)
			table.insert(highlights, { line = i, hl = "GitMsg", col = 0, length = -1 })
		end
	else
		-- print(
		--   "render_left: rendering changed files, selected branch =",
		--   Ui.branch_selected
		-- )
		-- print("render_left: get_changed_files call")
		get_changed_files(Ui.branch_selected)
		-- print(
		--   "render_left: Ui.changed_files count =",
		--   #Ui.changed_files
		-- )
		for i, f in ipairs(Ui.changed_files) do
			local prefix = f.staged and "✅" or "💣"
			-- print("render_left: prefix =", prefix)
			local line = string.format(" %s %s %s", prefix, f.status or "", f.value)
			table.insert(lines, line)

			-- Highlight prefix color
			table.insert(highlights, {
				line = i,
				hl = f.staged and "GitStaged" or "GitUnstaged",
				col = 0,
				length = #line, -- only highlight [U]/[S]
			})

			-- Highlight filename differently
			table.insert(highlights, {
				line = i,
				hl = f.staged and "GitStagedFile" or "GitUnstagedFile",
				col = 4,
				length = #f.value,
			})
		end
	end

	-- print(
	--   "render_left: writing lines to buffer, line count =",
	--   #lines
	-- )
	vim.api.nvim_buf_set_lines(Ui.left_buf, 0, -1, false, lines)

	-- Apply highlights
	vim.api.nvim_buf_clear_namespace(Ui.left_buf, -1, 0, -1)
	for _, h in ipairs(highlights) do
		vim.api.nvim_buf_add_highlight(Ui.left_buf, -1, h.hl, h.line - 1, h.col or 0, h.length or -1)
	end

	vim.api.nvim_buf_set_option(Ui.left_buf, "modifiable", false)
	-- print("render_left: done")
end

---------------------------------------------------------------------------
-- Git Graph Functions
---------------------------------------------------------------------------
local function convert_graph(line)
	line = line:gsub("%*%-", "*-") -- star + horizontal
	line = line:gsub("|\\", "|\\") -- merge down-right
	line = line:gsub("|/", "|/") -- merge down-left
	return line
end

-- Fetch git log and convert graph symbols
local function git_graph(limit, branch)
	limit = limit or 20
	branch = branch or "HEAD"
	local cmd = string.format(
		[[git --no-pager log --graph --pretty=format:'%%h %%cd %%an %%s' --date=format:'%%I:%%M%%p' -n %d %s]],
		limit,
		branch
	)
	local lines = vim.fn.systemlist(cmd)
	if vim.v.shell_error ~= 0 then
		return { "Not a git repo or branch does not exist" }
	end
	for i, line in ipairs(lines) do
		lines[i] = convert_graph(line)
	end
	return lines
end

---------------------------------------------------------------------------

-- Render the right panel (commit log or diff preview)
---------------------------------------------------------------------------
local graph_chars = { "*", "|", "/", "\\", "-" }

-- Git Graph Colors (per column)
local graph_colors = {
	"#5fff5f", -- green
	"#5fd7ff", -- cyan
	"#ffaf5f", -- orange
	"#ff5fff", -- magenta
	"#ffff5f", -- yellow
	"#5f5fff", -- blue
	"#5fffff", -- light cyan
	"#ff5f5f", -- red
}

-- Set highlight groups for graph columns
for i, c in ipairs(graph_colors) do
	vim.api.nvim_set_hl(0, "GitGraphSymbol" .. i, { fg = c })
end

-- Convert git --graph lines (ASCII identity)
local function convert_graph(line)
	line = line:gsub("%*%-", "*-")
	line = line:gsub("|\\", "|\\")
	line = line:gsub("|/", "|/")
	return line
end

local function git_graph(limit, branch)
	limit = limit or 20
	branch = branch or "HEAD"
	local cmd = string.format(
		[[git --no-pager log --graph --pretty=format:'%%h %%cd %%an %%s' --date=format:'%%I:%%M%%p' -n %d %s]],
		limit,
		branch
	)
	local lines = vim.fn.systemlist(cmd)
	if vim.v.shell_error ~= 0 then
		return { "Not a git repo or branch does not exist" }
	end
	for i, line in ipairs(lines) do
		lines[i] = convert_graph(line)
	end
	return lines
end

-- Render right panel (commit log)
local function render_right()
	if not Ui or not Ui.right_buf then
		return
	end
	vim.api.nvim_buf_set_option(Ui.right_buf, "modifiable", true)
	vim.api.nvim_buf_clear_namespace(Ui.right_buf, -1, 0, -1)

	local branch = Ui.branch_selected or "HEAD"
	local out = git_graph(40, branch)
	if #out == 0 then
		out = { "[No commits]" }
	end
	vim.api.nvim_buf_set_lines(Ui.right_buf, 0, -1, false, out)

	Ui.branch_colors = Ui.branch_colors or {}

	for i, line in ipairs(out) do
		-- highlight graph per column
		for pos = 1, #line do
			local char = line:sub(pos, pos)
			if vim.tbl_contains(graph_chars, char) then
				if not Ui.branch_colors[pos] then
					local color = graph_colors[((pos - 1) % #graph_colors) + 1]
					Ui.branch_colors[pos] = color
					vim.api.nvim_set_hl(0, "GitGraphSymbol" .. pos, { fg = color })
				end
				vim.api.nvim_buf_add_highlight(Ui.right_buf, -1, "GitGraphSymbol" .. pos, i - 1, pos - 1, pos)
			end
		end

		-- highlight commit hash/date/author/message
		local hash, date, author, msg = line:match("([0-9a-f]+)%s+([0-9:APM]+)%s+(%S+)%s+(.+)")
		if hash then
			local s = line:find(hash, 1, true)
			if s then
				vim.api.nvim_buf_add_highlight(Ui.right_buf, -1, "GitHash", i - 1, s - 1, s - 1 + #hash)
			end
		end
		if date then
			local s = line:find(date, 1, true)
			if s then
				vim.api.nvim_buf_add_highlight(Ui.right_buf, -1, "GitDate", i - 1, s - 1, s - 1 + #date)
			end
		end
		if author then
			local s = line:find(author, 1, true)
			if s then
				vim.api.nvim_buf_add_highlight(Ui.right_buf, -1, "GitAuthor", i - 1, s - 1, s - 1 + #author)
			end
		end
		if msg then
			local s = line:find(msg, 1, true)
			if s then
				vim.api.nvim_buf_add_highlight(Ui.right_buf, -1, "GitMsg", i - 1, s - 1, -1)
			end
		end
	end

	vim.api.nvim_buf_set_option(Ui.right_buf, "modifiable", false)
end

-- Render diff panel (Code Changes)
local function render_diff()
	if not Ui or not Ui.diff_buf or not vim.api.nvim_buf_is_valid(Ui.diff_buf) then
		return
	end
	vim.api.nvim_buf_set_option(Ui.diff_buf, "modifiable", true)
	vim.api.nvim_buf_clear_namespace(Ui.diff_buf, -1, 0, -1)

	local out = { "" }

	if Ui.mode == "files" then
		if Ui.left_win and vim.api.nvim_win_is_valid(Ui.left_win) then
			local cursor = vim.api.nvim_win_get_cursor(Ui.left_win)
			Ui.selected_index = cursor[1]
		end
		local sel = Ui.changed_files[Ui.selected_index]
		out = sel and get_diff_for_target(sel.value) or { "[No file selected]" }
	elseif Ui.mode == "stashes" then
		if Ui.left_win and vim.api.nvim_win_is_valid(Ui.left_win) then
			local cursor = vim.api.nvim_win_get_cursor(Ui.left_win)
			Ui.selected_index = cursor[1]
		end
		local entry = Ui.stashes and Ui.stashes[Ui.selected_index]
		if entry then
			local ref = entry:match("(stash@{%d+})")
			if ref then
				local diff_lines = vim.fn.systemlist("git --no-pager stash show -p " .. ref)
				if vim.v.shell_error == 0 and #diff_lines > 0 then
					out = diff_lines
				end
			end
		else
			out = { "[No stash selected]" }
		end
	elseif Ui.mode == "branches" then
		if Ui.right_win and vim.api.nvim_win_is_valid(Ui.right_win) then
			local cursor = vim.api.nvim_win_get_cursor(Ui.right_win)
			local line = vim.api.nvim_buf_get_lines(Ui.right_buf, cursor[1] - 1, cursor[1], false)[1] or ""

			-- Extract hash correctly, skipping graph symbols
			local hash = line:match("([0-9a-f]+)%s+[0-9:APM]+%s+")
			if hash then
				local diff_lines = vim.fn.systemlist("git --no-pager show " .. hash)
				if vim.v.shell_error == 0 then
					out = diff_lines
				end
			else
				out = { "[No commit selected]" }
			end
		end
	end

	vim.api.nvim_buf_set_lines(Ui.diff_buf, 0, -1, false, out)
	vim.api.nvim_buf_set_option(Ui.diff_buf, "filetype", "diff")

	for i, line in ipairs(out) do
		if line:match("^%+.*") then
			vim.api.nvim_buf_add_highlight(Ui.diff_buf, -1, "DiffAdd", i - 1, 0, -1)
		elseif line:match("^%-.*") then
			vim.api.nvim_buf_add_highlight(Ui.diff_buf, -1, "DiffDelete", i - 1, 0, -1)
		elseif line:match("^\\+\\-") or line:match("^!.*") then
			vim.api.nvim_buf_add_highlight(Ui.diff_buf, -1, "DiffChange", i - 1, 0, -1)
		elseif line:match("^diff ") then
			vim.api.nvim_buf_add_highlight(Ui.diff_buf, -1, "DiffFile", i - 1, 0, -1)
		elseif line:match("^@@") then
			vim.api.nvim_buf_add_highlight(Ui.diff_buf, -1, "DiffHeader", i - 1, 0, -1)
		end
	end

	vim.api.nvim_buf_set_option(Ui.diff_buf, "modifiable", false)
end

---------------------------------------------------------------------------
-- Refresh UI on close
---------------------------------------------------------------------------
local function refresh_ui()
	-- Ensure Ui.selected_index is valid after switching to branches view
	if Ui.mode == "branches" then
		local total_branches = #Ui.branches
		Ui.selected_index = math.min(Ui.selected_index, total_branches)
		Ui.branch_selected = Ui.branches[Ui.selected_index]
	end

	-- Render the panes
	render_left()
	render_right()
	render_diff()

	-- Handle edge cases for bounds
	local total = (Ui.mode == "branches") and #Ui.branches
		or (Ui.mode == "stashes" and #Ui.stashes or #Ui.changed_files)
	Ui.selected_index = math.max(1, math.min(Ui.selected_index, total))

	-- Update left window title and cursor
	if Ui.left_win and vim.api.nvim_win_is_valid(Ui.left_win) then
		local title_str = " Files Changed "
		if Ui.mode == "branches" then
			title_str = " Git Branches "
		end
		if Ui.mode == "stashes" then
			title_str = " Stashes "
		end

		vim.api.nvim_win_set_config(Ui.left_win, { title = title_str })
		pcall(vim.api.nvim_win_set_cursor, Ui.left_win, { Ui.selected_index, 0 })
	end

	-- Update the right window title
	if Ui.right_win and vim.api.nvim_win_is_valid(Ui.right_win) then
		vim.api.nvim_win_set_config(Ui.right_win, { title = " Commit Log " })
	end
end

---------------------------------------------------------------------------
-- 🌸 Floating window functions to display git output after an operation
---------------------------------------------------------------------------
local floating_windows = {}

-- Store the current active window
local current_win = nil
local current_buf = nil

-- Function to save the current active window
local function save_active_window()
	current_win = vim.api.nvim_get_current_win()
	current_buf = vim.api.nvim_win_get_buf(current_win)
end

-- Function to restore the active window after closing floating windows
local function restore_active_window()
	if current_win and vim.api.nvim_win_is_valid(current_win) then
		vim.api.nvim_set_current_win(current_win) -- Restore the previously active window
	elseif current_buf and vim.api.nvim_buf_is_valid(current_buf) then
		-- If the previous window is no longer valid, set the buffer in the current window
		vim.api.nvim_win_set_buf(vim.api.nvim_get_current_win(), current_buf)
	end
end

-- Function to close floating windows and return to branches view
local function close_floating()
	print("Closing floating windows...")
	for _, w in pairs(floating_windows) do
		if vim.api.nvim_win_is_valid(w) then
			print("Closing window:", w)
			vim.api.nvim_win_close(w, true)
		else
			print("Window is not valid:", w)
		end
	end
	floating_windows = {} -- Reset floating windows table

	-- After closing floating windows, restore the active window and return to branches view
	Ui.mode = "branches"
	refresh_ui()
	restore_active_window() -- Restore the last active window
end

-- Keybinding to close floating windows and go back to branches view
vim.keymap.set("n", "q", function()
	close_floating()
end, { buffer = buf_out, nowait = true, silent = true })

-- Keybinding to close error window as well
vim.keymap.set("n", "q", function()
	close_floating()
end, { buffer = buf_err, nowait = true, silent = true })

-- Show output and error windows in floating style
local function show_floating_pair(stdout_lines, stderr_lines)
	save_active_window()

	local ui = vim.api.nvim_list_uis()[1]
	local width = math.min(80, ui.width - 4)

	-- Calculate window heights
	local h_out = math.max(#stdout_lines + 2, 3)
	local h_err = math.max(#stderr_lines + 2, 3)
	local total_h = math.floor(editor_h * 0.95)

	-- Calculate top row and column for centering
	local top = math.floor((ui.height - total_h) / 2)
	local col = math.floor((ui.width - width) / 2)

	-- Create and show the output window (stdout)
	local buf_out = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(buf_out, 0, -1, false, stdout_lines)
	vim.api.nvim_buf_set_option(buf_out, "modifiable", false)

	-- Apply a highlight group to colorize the output window (stdout)
	vim.api.nvim_buf_add_highlight(buf_out, -1, "GitOutput", 0, 0, -1)

	local win_out = vim.api.nvim_open_win(buf_out, true, {
		relative = "editor",
		width = width,
		height = h_out,
		row = top,
		col = col,
		style = "minimal",
		border = "rounded",
		title = " Git Output ",
		title_pos = "center",
		zindex = 600,
	})

	floating_windows.stdout = win_out -- Store reference to output window

	-- Create and show the error window (stderr)
	local buf_err = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(buf_err, 0, -1, false, stderr_lines)
	vim.api.nvim_buf_set_option(buf_err, "modifiable", false)

	vim.api.nvim_buf_add_highlight(buf_err, -1, "GitError", 0, 0, -1)

	local win_err = vim.api.nvim_open_win(buf_err, false, {
		relative = "editor",
		width = width,
		height = h_err,
		row = top + h_out + 2, -- Right below output window
		col = col,
		style = "minimal",
		border = "rounded",
		title = " Git Errors ",
		title_pos = "center",
		zindex = 600,
	})

	floating_windows.stderr = win_err -- Store reference to error window

	-- H/L navigation between floating windows
	-- We only set the keymap once for both windows
	vim.keymap.set("n", "H", function()
		if floating_windows.stdout and vim.api.nvim_win_is_valid(floating_windows.stdout) then
			vim.api.nvim_set_current_win(floating_windows.stdout)
		elseif floating_windows.stderr and vim.api.nvim_win_is_valid(floating_windows.stderr) then
			vim.api.nvim_set_current_win(floating_windows.stderr)
		end
	end, { nowait = true, silent = true })

	vim.keymap.set("n", "L", function()
		if floating_windows.stderr and vim.api.nvim_win_is_valid(floating_windows.stderr) then
			vim.api.nvim_set_current_win(floating_windows.stderr)
		elseif floating_windows.stdout and vim.api.nvim_win_is_valid(floating_windows.stdout) then
			vim.api.nvim_set_current_win(floating_windows.stdout)
		end
	end, { nowait = true, silent = true })

	-- Bind 'q' to close floating windows and return to branches view
	vim.keymap.set("n", "q", function()
		close_floating()
		Ui.mode = "branches" -- Return to branches view after closing
		refresh_ui()
	end, { nowait = true, silent = true })
end

---------------------------------------------------------------------------
-- Function to reload the current file buffer after exiting git picker
---------------------------------------------------------------------------
local function file_differs_from_disk(bufnr)
	local path = vim.api.nvim_buf_get_name(bufnr)
	if path == "" then
		return false
	end

	local ok, disk = pcall(vim.fn.readfile, path)
	if not ok then
		return false
	end

	local buf = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

	return table.concat(disk, "\n") ~= table.concat(buf, "\n")
end

local function reload_file_buffer()
	local bufnr = vim.api.nvim_get_current_buf()
	if not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end

	if vim.api.nvim_buf_get_option(bufnr, "modified") then
		return
	end

	if file_differs_from_disk(bufnr) then
		-- This creates a true Yes/No prompt in the cmdline (always focused)
		local choice = vim.fn.confirm("File changed on disk. Reload?", "&Yes\n&No", 2)

		if choice == 1 then
			vim.cmd("e!")
		end
	end
end

-- Focus helpers
---------------------------------------------------------------------------
local function focus_left()
	if Ui.left_win and vim.api.nvim_win_is_valid(Ui.left_win) then
		vim.api.nvim_set_current_win(Ui.left_win)
	end
end

local function focus_right()
	if Ui.right_win and vim.api.nvim_win_is_valid(Ui.right_win) then
		vim.api.nvim_set_current_win(Ui.right_win)
	end
end

-- When initializing your UI
local function init_ui()
	-- Load branches and changed files
	load_branches()
	get_changed_files(Ui.branch_selected)

	-- Determine initial mode based on whether there are changes
	if #Ui.changed_files > 0 then
		Ui.mode = "files"
	else
		Ui.mode = "branches"
	end

	Ui.selected_index = 1

	-- Create buffers / windows here if needed
	refresh_ui()
	focus_left()
end

local function update_window_layout()
	if not Ui or not Ui.diff_win or not vim.api.nvim_win_is_valid(Ui.diff_win) then
		return
	end

	local ui = vim.api.nvim_list_uis()[1]
	local editor_w = ui and ui.width or vim.o.columns
	local editor_h = ui and ui.height or vim.o.lines

	local statusline_h = (vim.o.laststatus > 0) and 1 or 0
	local available_h = editor_h - vim.o.cmdheight - statusline_h

	local w = math.floor(editor_w * 0.9)
	local col = math.floor((editor_w - w) / 2)

	local help_h = 1
	local branch_h = 4
	local log_h = 8
	local lower_h = 8

	local help_row = available_h - help_h - 2
	local branch_row = help_row - branch_h - 2
	local log_row = branch_row - log_h - 2
	local lower_row = help_row - lower_h - 2

	local diff_row = 2

	vim.notify(
		string.format(
			"[GitCompanion LayoutUpdate] Mode: %s | available_h: %d | help_row: %d | log_row: %d | lower_row: %d",
			tostring(Ui.mode),
			available_h,
			help_row,
			log_row,
			lower_row
		),
		vim.log.levels.WARN
	)

	if Ui.mode == "branches" then
		local diff_h = math.max(log_row - diff_row - 2, 1)

		if Ui.right_win and vim.api.nvim_win_is_valid(Ui.right_win) then
			vim.api.nvim_win_set_config(Ui.right_win, {
				relative = "editor",
				hide = false,
				row = log_row,
				col = col,
				width = w,
				height = log_h,
			})
		end

		if Ui.left_win and vim.api.nvim_win_is_valid(Ui.left_win) then
			vim.api.nvim_win_set_config(Ui.left_win, {
				relative = "editor",
				row = branch_row,
				col = col,
				width = w,
				height = branch_h,
				title = " Git Branches ",
				title_pos = "center",
			})
		end

		vim.api.nvim_win_set_config(Ui.diff_win, {
			relative = "editor",
			row = diff_row,
			col = col,
			width = w,
			height = diff_h,
		})
	else
		local diff_h = math.max(lower_row - diff_row - 2, 1)

		if Ui.right_win and vim.api.nvim_win_is_valid(Ui.right_win) then
			vim.api.nvim_win_set_config(Ui.right_win, { hide = true })
		end

		if Ui.left_win and vim.api.nvim_win_is_valid(Ui.left_win) then
			vim.api.nvim_win_set_config(Ui.left_win, {
				relative = "editor",
				row = lower_row,
				col = col,
				width = w,
				height = lower_h,
				title = (Ui.mode == "stashes") and " Stashes " or " Files Changed ",
				title_pos = "center",
			})
		end

		vim.api.nvim_win_set_config(Ui.diff_win, {
			relative = "editor",
			row = diff_row,
			col = col,
			width = w,
			height = diff_h,
		})
	end

	if Ui.help_win and vim.api.nvim_win_is_valid(Ui.help_win) then
		vim.api.nvim_win_set_config(Ui.help_win, {
			relative = "editor",
			row = help_row,
			col = col,
			width = w,
			height = help_h,
		})
	end
end

local function toggle_mode(dir)
	if not Ui then
		return
	end

	local modes = { "branches", "files", "stashes" }
	local current_idx = 1
	for i, m in ipairs(modes) do
		if m == Ui.mode then
			current_idx = i
			break
		end
	end

	if dir == "prev" then
		current_idx = (current_idx == 1) and #modes or (current_idx - 1)
	else
		current_idx = (current_idx == #modes) and 1 or (current_idx + 1)
	end

	Ui.mode = modes[current_idx]
	Ui.selected_index = 1

	if Ui.mode == "files" then
		local _ = run_git("git diff --cached --name-only")
	elseif Ui.mode == "stashes" then
		load_stashes()
	end

	if type(update_window_layout) == "function" then
		update_window_layout()
	end
	refresh_ui()
	focus_left()
end

-- Stage or unstage the selected file
local function stage_unstage_selected()
	if Ui.mode ~= "files" then
		-- print(
		--   "stage_unstage_selected: not in files mode, exiting"
		-- )
		return
	end

	local sel = Ui.changed_files[Ui.selected_index]
	if not sel then
		-- print(
		--   "stage_unstage_selected: no file selected at index",
		--   Ui.selected_index
		-- )
		return
	end

	-- print(
	--   "stage_unstage_selected: selected file =",
	--   sel.value,
	--   "staged =",
	--   sel.staged
	-- )

	local root = git_root()
	local staged_files = run_git("git diff --cached --name-only")
	-- print(
	--   "stage_unstage_selected: currently staged files:",
	--   table.concat(staged_files, ", ")
	-- )

	local cmd
	if vim.tbl_contains(staged_files, sel.value) then
		-- print(
		--   "stage_unstage_selected: file is staged, will unstage"
		-- )
		cmd = {
			"git",
			"restore",
			"--staged",
			root .. "/" .. sel.value,
		}
	else
		-- print(
		--   "stage_unstage_selected: file is not staged, will stage"
		-- )
		cmd = { "git", "add", root .. "/" .. sel.value }
	end

	-- Run the git command
	local result = vim.fn.system(cmd)
	-- print(
	--   "stage_unstage_selected: git command executed, output:\n",
	--   result
	-- )

	-- Refresh changed files
	-- print(
	--   "stage_unstage_selected: refreshing changed files"
	-- )
	get_changed_files(Ui.branch_selected)
	-- print(
	--   "stage_unstage_selected: Ui.changed_files after refresh:"
	-- )
	for i, f in ipairs(Ui.changed_files) do
		-- print(
		--   string.format(
		--     "  [%d] %s staged=%s status=%s",
		--     i,
		--     f.value,
		--     tostring(f.staged),
		--     f.status or ""
		--   )
		-- )
	end

	-- Redraw panels
	-- print(
	--   "stage_unstage_selected: rendering left panel"
	-- )
	render_left()
	-- print(
	--   "stage_unstage_selected: rendering right panel"
	-- )
	render_right()
	render_diff()

	-- Highlight selected line briefly
	vim.api.nvim_buf_add_highlight(Ui.left_buf, -1, "Visual", Ui.selected_index - 1, 0, -1)
	vim.defer_fn(function()
		-- print(
		--   "stage_unstage_selected: deferred render_left"
		-- )
		render_left()
	end, 100)

	vim.api.nvim_win_set_cursor(Ui.left_win, { Ui.selected_index, 0 })
	-- print("stage_unstage_selected: finished")
end

-- Discard changes for the selected file
local function discard_changes_selected()
	if Ui.mode ~= "files" then
		print("Exiting: Ui.mode is not 'files', current mode:", Ui.mode)
		return
	end

	local sel = Ui.changed_files[Ui.selected_index]
	if not sel then
		print("Exiting: No selected file at index", Ui.selected_index)
		return
	end

	print("Selected file to discard:", sel.value)

	local confirm_result = vim.fn.confirm("Discard changes to " .. sel.value .. "?", "Yes\nNo", 2)
	print("Confirm result:", confirm_result)

	if confirm_result ~= 1 then
		print("Discard canceled by user")
		return
	end

	local root = git_root()
	print("Git root detected:", root)

	local cmd = { "git", "restore", root .. "/" .. sel.value }
	print("Running command:", table.concat(cmd, " "))

	local result = vim.fn.system(cmd)
	local err = vim.v.shell_error
	print("Command output:", result)
	print("Shell error code:", err)

	if err ~= 0 then
		print("Error discarding changes!")
	else
		print("Successfully discarded changes")
	end

	refresh_ui()
	print("UI refreshed")
end

local function show_centered_message(msg, icon)
	-- print(
	--   "[DEBUG] show_centered_message called with msg:",
	--   msg or "nil",
	--   "icon:",
	--   icon or "nil"
	-- )

	icon = icon or "❄️" -- default icon
	local buf = vim.api.nvim_create_buf(false, true)
	if not buf or buf == 0 then
		-- print("[DEBUG] Failed to create buffer")
		return
	end
	-- print("[DEBUG] Created buffer:", buf)

	local lines = vim.split(msg or "", "\n")
	if #lines > 0 then
		lines[1] = icon .. " " .. lines[1]
	else
		lines = { icon }
	end
	-- print(
	--   "[DEBUG] Lines prepared:",
	--   table.concat(lines, " | ")
	-- )

	-- Set lines
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	-- print("[DEBUG] Lines set in buffer")

	-- Create highlight
	vim.api.nvim_set_hl(0, "CenteredMessage", { fg = "#FFFFFF", bold = true })
	-- print(
	--   "[DEBUG] Highlight defined: CenteredMessage"
	-- )

	for i = 0, #lines - 1 do
		vim.api.nvim_buf_add_highlight(buf, -1, "CenteredMessage", i, 0, -1)
	end
	-- print("[DEBUG] Highlights applied")

	-- Get UI info
	local ui_list = vim.api.nvim_list_uis()
	if not ui_list or #ui_list == 0 then
		-- print(
		--   "[DEBUG] No UI available — skipping window creation"
		-- )
		return
	end
	local ui = ui_list[1]
	-- print(
	--   "[DEBUG] UI info — width:",
	--   ui.width,
	--   "height:",
	--   ui.height
	-- )

	local width = math.max(60, math.min(80, #lines[1] + 4))
	local height = #lines
	-- print(
	--   "[DEBUG] Calculated window size:",
	--   width,
	--   "x",
	--   height
	-- )

	local win = vim.api.nvim_open_win(buf, false, {
		relative = "editor",
		width = width,
		height = height,
		row = 3,
		col = math.floor((ui.width - width) / 2),
		style = "minimal",
		border = "rounded",
		zindex = 50,
	})

	if not win or win == 0 then
		-- print("[DEBUG] Failed to open window")
		return
	end
	-- print(
	--   "[DEBUG] Window opened successfully:",
	--   win
	-- )

	vim.api.nvim_buf_set_option(buf, "modifiable", false)
	-- print("[DEBUG] Buffer made unmodifiable")

	vim.defer_fn(function()
		-- print("[DEBUG] Auto-close timer triggered")
		if vim.api.nvim_win_is_valid(win) then
			-- print("[DEBUG] Closing window:", win)
			vim.api.nvim_win_close(win, true)
		else
			-- print(
			--   "[DEBUG] Window already invalid — not closing"
			-- )
		end
	end, 2000)
end

local function show_centered_error(msg)
	local buf = vim.api.nvim_create_buf(false, true)
	local lines = vim.split(msg, "\n")
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(msg, "\n"))

	vim.api.nvim_set_hl(0, "CenteredError", { fg = "#FF5555", bold = true })

	-- Apply highlight to all lines
	for i = 0, #lines - 1 do
		vim.api.nvim_buf_add_highlight(buf, -1, "CenteredError", i, 0, -1)
	end

	local width = 60
	local height = #lines
	local ui = vim.api.nvim_list_uis()[1]

	local win = vim.api.nvim_open_win(buf, false, {
		relative = "editor",
		width = width,
		height = height,
		row = 2,
		col = math.floor((ui.width - width) / 2),
		style = "minimal",
		border = "rounded",
		zindex = 50,
	})

	vim.api.nvim_buf_set_option(buf, "modifiable", false)
	-- Auto close after 3 seconds
	vim.defer_fn(function()
		if vim.api.nvim_win_is_valid(win) then
			vim.api.nvim_win_close(win, true)
		end
	end, 2000)
end

-- Checkout the selected branch
local function checkout_branch()
	if Ui.mode ~= "branches" then
		return
	end

	local branch = Ui.branches[Ui.selected_index]
	if not branch then
		return
	end

	-- Check for uncommitted changes
	local status = vim.fn.systemlist("git status --porcelain")
	if #status > 0 then
		show_centered_error(
			"🚨 You have uncommitted changes!\nCommit, stash, or discard them before switching branches."
		)
		return
	end

	-- Switch branch using 'git switch'
	local cmd = "git switch " .. vim.fn.shellescape(branch)
	local result = vim.fn.system(cmd)

	if vim.v.shell_error ~= 0 then
		show_centered_message("Failed to switch branch:\n" .. result, "❌")
		return
	end

	-- Update internal state
	Ui.branch_selected = branch
	show_centered_message("Switched to branch: " .. branch, "✅")

	-- Reload branch list (this automatically sorts the new current branch to the top)
	load_branches()

	-- Reset selection to the top since the checked-out branch is now at index 1
	Ui.selected_index = 1

	-- Redraw all panes
	refresh_ui()
end

-- Delete the selected branch
local function delete_branch()
	-- only relevant in branches mode
	if Ui.mode ~= "branches" then
		return
	end

	-- get currently selected branch
	local branch = Ui.branches[Ui.selected_index]
	if not branch then
		return
	end

	-- confirm deletion
	local ok_confirm = vim.fn.confirm("Delete branch " .. branch .. "?", "Yes\nNo", 2)
	if ok_confirm ~= 1 then
		return
	end

	-- run git delete branch
	local out = vim.fn.system("git branch -D " .. vim.fn.shellescape(branch))
	if vim.v.shell_error ~= 0 then
		show_centered_message("Failed to delete branch: " .. out, vim.log.levels.ERROR)
	else
		show_centered_message("Deleted branch: " .. branch, vim.log.levels.INFO)
	end

	-- reload branch list and refresh UI
	load_branches()
	refresh_ui()
end

-- Open UI
function M.toggle(opts)
	-- 1. Buffer Initialization
	Ui = Ui or {}

	if not Ui.diff_buf or not vim.api.nvim_buf_is_valid(Ui.diff_buf) then
		Ui.diff_buf = vim.api.nvim_create_buf(false, true)
	end
	if not Ui.right_buf or not vim.api.nvim_buf_is_valid(Ui.right_buf) then
		Ui.right_buf = vim.api.nvim_create_buf(false, true)
	end
	if not Ui.left_buf or not vim.api.nvim_buf_is_valid(Ui.left_buf) then
		Ui.left_buf = vim.api.nvim_create_buf(false, true)
	end
	if not Ui.help_buf or not vim.api.nvim_buf_is_valid(Ui.help_buf) then
		Ui.help_buf = vim.api.nvim_create_buf(false, true)
	end

	for _, buf in ipairs({ Ui.left_buf, Ui.right_buf, Ui.diff_buf, Ui.help_buf }) do
		vim.api.nvim_buf_set_option(buf, "buftype", "nofile")
		vim.api.nvim_buf_set_option(buf, "bufhidden", "wipe")
		vim.api.nvim_buf_set_option(buf, "modifiable", true)
	end

	-- 2. Screen Dimensions & Row Offsets
	local ui = vim.api.nvim_list_uis()[1]
	local editor_w = ui and ui.width or vim.o.columns
	local editor_h = ui and ui.height or vim.o.lines

	local statusline_h = (vim.o.laststatus > 0) and 1 or 0
	local available_h = editor_h - vim.o.cmdheight - statusline_h

	local w = math.floor(editor_w * 0.9)
	local col = math.floor((editor_w - w) / 2)

	local help_h = 1
	local branch_h = 4
	local log_h = 8
	local lower_h = 8

	local help_row = available_h - help_h - 2
	local branch_row = help_row - branch_h - 2
	local log_row = branch_row - log_h - 2
	local lower_row = help_row - lower_h - 2

	local diff_row = 2
	local diff_h
	if Ui.mode == "branches" then
		diff_h = math.max(log_row - diff_row - 2, 1)
	else
		diff_h = math.max(lower_row - diff_row - 2, 1)
	end

	vim.notify(
		string.format(
			"[GitCompanion Toggle] Mode: %s | editor_h: %d | available_h: %d | help_row: %d | diff_h: %d",
			tostring(Ui.mode),
			editor_h,
			available_h,
			help_row,
			diff_h
		),
		vim.log.levels.WARN
	)

	-- 3. Open Floating Windows
	Ui.diff_win = vim.api.nvim_open_win(Ui.diff_buf, false, {
		relative = "editor",
		width = w,
		height = diff_h,
		row = diff_row,
		col = col,
		style = "minimal",
		border = "rounded",
		title = " Code Changes ",
		title_pos = "center",
		zindex = 10,
	})

	if Ui.mode == "branches" then
		Ui.right_win = vim.api.nvim_open_win(Ui.right_buf, false, {
			relative = "editor",
			width = w,
			height = log_h,
			row = log_row,
			col = col,
			style = "minimal",
			border = "rounded",
			title = " Commit Log ",
			title_pos = "center",
			zindex = 10,
		})

		Ui.left_win = vim.api.nvim_open_win(Ui.left_buf, true, {
			relative = "editor",
			width = w,
			height = branch_h,
			row = branch_row,
			col = col,
			style = "minimal",
			border = "rounded",
			title = " Git Branches ",
			title_pos = "center",
			zindex = 10,
		})
	else
		Ui.left_win = vim.api.nvim_open_win(Ui.left_buf, true, {
			relative = "editor",
			width = w,
			height = lower_h,
			row = lower_row,
			col = col,
			style = "minimal",
			border = "rounded",
			title = (Ui.mode == "stashes") and " Stashes " or " Files Changed ",
			title_pos = "center",
			zindex = 10,
		})
	end

	Ui.help_win = vim.api.nvim_open_win(Ui.help_buf, false, {
		relative = "editor",
		width = w,
		height = help_h,
		row = help_row,
		col = col,
		style = "minimal",
		border = "rounded",
		zindex = 10,
	})

	local left_text = "[H] Branches ↔ Files Changed ↔ Stashes [L]"
	local right_text = "Press ? For Help"

	-- Calculate dynamic padding using visual display width, not raw bytes
	local left_width = vim.fn.strdisplaywidth(left_text)
	local right_width = vim.fn.strdisplaywidth(right_text)
	local pad_len = math.max(0, w - left_width - right_width)
	local pad = string.rep(" ", pad_len)

	vim.api.nvim_buf_set_lines(Ui.help_buf, 0, -1, false, { left_text .. pad .. right_text })
	vim.api.nvim_buf_set_option(Ui.help_buf, "modifiable", false)
	vim.api.nvim_buf_add_highlight(Ui.help_buf, -1, "GitMsg", 0, 0, -1)

	-- 4. Close Handler
	local function close_ui()
		for _, win in ipairs({ Ui.left_win, Ui.right_win, Ui.diff_win, Ui.help_win, Ui.full_win }) do
			if win and vim.api.nvim_win_is_valid(win) then
				vim.api.nvim_win_close(win, true)
			end
		end
		for _, buf in ipairs({ Ui.left_buf, Ui.right_buf, Ui.diff_buf, Ui.help_buf }) do
			if buf and vim.api.nvim_buf_is_valid(buf) then
				vim.api.nvim_buf_delete(buf, { force = true })
			end
		end
		Ui.left_win, Ui.right_win, Ui.diff_win, Ui.help_win = nil, nil, nil, nil
		Ui.left_buf, Ui.right_buf, Ui.diff_buf, Ui.help_buf = nil, nil, nil, nil
	end

	-- 5. Window Navigation Keymaps (J/K to move between windows vertically)
	local active_bufs = { Ui.left_buf, Ui.right_buf, Ui.diff_buf }

	for _, buf in ipairs(active_bufs) do
		-- Quit picker
		vim.keymap.set("n", "q", close_ui, { buffer = buf, silent = true, nowait = true })

		-- Trap horizontal split navigation so it doesn't break out of the UI
		vim.keymap.set("n", "sh", function() end, { buffer = buf, silent = true, nowait = true })
		vim.keymap.set("n", "sl", function() end, { buffer = buf, silent = true, nowait = true })

		-- Navigate Down visually (Diff -> [Log] -> Branch)
		vim.keymap.set("n", "sj", function()
			local cur = vim.api.nvim_get_current_win()
			if cur == Ui.diff_win then
				vim.api.nvim_set_current_win(Ui.mode == "branches" and Ui.right_win or Ui.left_win)
			elseif cur == Ui.right_win then
				vim.api.nvim_set_current_win(Ui.left_win)
			end
		end, { buffer = buf, silent = true })

		-- Navigate Up visually (Branch -> [Log] -> Diff)
		vim.keymap.set("n", "sk", function()
			local cur = vim.api.nvim_get_current_win()
			if cur == Ui.left_win then
				vim.api.nvim_set_current_win(Ui.mode == "branches" and Ui.right_win or Ui.diff_win)
			elseif cur == Ui.right_win then
				vim.api.nvim_set_current_win(Ui.diff_win)
			end
		end, { buffer = buf, silent = true })
	end

	-- Automatically update windows when natively moving the cursor
	local group = vim.api.nvim_create_augroup("GitPickerAutoCmds", { clear = true })

	local function show_help()
		local buf = vim.api.nvim_create_buf(false, true) -- <--- ADD THIS LINE
		local lines = {
			" Navigation",
			"  j / k       : Move selection up / down",
			"  h / l       : Focus left / right panels",
			"  sj / sk     : Jump up / down between panels",
			"  H / L       : Cycle views (Branches ↔ Files ↔ Stashes)",
			"",
			" Actions",
			"  <Space>     : Checkout Branch / Stage File / Pop Stash",
			"  d           : Delete Branch / Discard Changes / Drop Stash",
			"  c           : Commit (Files) / Checkout Remote (Branches)",
			"  n           : Create new branch from selected (Branches)",
			"  m           : Merge branch into current (Branches)",
			"  g           : Reset HEAD to commit (Commit Log)",
			"  p / P       : Pull / Push branch (Branches)",
			"  s           : Create new stash (Any view)",
			"",
			" General",
			"  ?           : Show this help modal",
			"  q / <Esc>   : Close picker or popup",
		}

		vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
		vim.api.nvim_buf_set_option(buf, "modifiable", false)

		local ui = vim.api.nvim_list_uis()[1]
		local width = 60
		local height = #lines
		local row = math.floor((ui.height - height) / 2)
		local col = math.floor((ui.width - width) / 2)

		local win = vim.api.nvim_open_win(buf, true, {
			relative = "editor",
			width = width,
			height = height,
			row = row,
			col = col,
			style = "minimal",
			border = "rounded",
			title = " Git Picker Help ",
			title_pos = "center",
			zindex = 1000,
		})

		-- Highlight headings and hotkeys
		vim.api.nvim_set_hl(0, "GitPickerHelpKey", { fg = "#00d7ff", bold = true })
		vim.api.nvim_set_hl(0, "GitPickerHelpHeading", { fg = "#a6e22e", bold = true, italic = true })

		for i, line in ipairs(lines) do
			if line:match("^ %a") then
				vim.api.nvim_buf_add_highlight(buf, -1, "GitPickerHelpHeading", i - 1, 0, -1)
			else
				local sep = line:find(":")
				if sep then
					vim.api.nvim_buf_add_highlight(buf, -1, "GitPickerHelpKey", i - 1, 0, sep - 1)
				end
			end
		end

		local function close_help()
			if vim.api.nvim_win_is_valid(win) then
				vim.api.nvim_win_close(win, true)
			end
		end

		vim.keymap.set("n", "q", close_help, { buffer = buf, silent = true, nowait = true })
		vim.keymap.set("n", "<Esc>", close_help, { buffer = buf, silent = true, nowait = true })
		vim.keymap.set("n", "?", close_help, { buffer = buf, silent = true, nowait = true })
	end

	vim.api.nvim_create_autocmd("CursorMoved", {
		group = group,
		buffer = Ui.right_buf,
		callback = function()
			if Ui.mode == "branches" then
				render_diff()
			end
		end,
	})

	vim.api.nvim_create_autocmd("CursorMoved", {
		group = group,
		buffer = Ui.left_buf,
		callback = function()
			-- Keep index perfectly in sync with the native cursor
			local cursor = vim.api.nvim_win_get_cursor(0)
			Ui.selected_index = cursor[1]

			if Ui.mode == "files" or Ui.mode == "stashes" then
				render_diff()
			elseif Ui.mode == "branches" then
				Ui.branch_selected = Ui.branches[Ui.selected_index]
				render_right()
				render_diff()
			end
		end,
	})

	-- 6. Populate Data & Render Contents
	Ui.mode = "files"
	Ui.selected_index = 1

	if type(load_branches) == "function" then
		load_branches()
	end
	if type(get_changed_files) == "function" then
		get_changed_files()
	end
	if type(refresh_ui) == "function" then
		refresh_ui()
	end

	if type(update_window_layout) == "function" then
		update_window_layout()
	end

	-- Keymaps
	local function set_keymaps(buf)
		-- Navigation & mode toggle
		vim.keymap.set("n", "H", function()
			toggle_mode("prev")
		end, {
			buffer = buf,
			noremap = true,
			silent = true,
		})
		vim.keymap.set("n", "L", function()
			toggle_mode("next")
		end, {
			buffer = buf,
			noremap = true,
			silent = true,
		})

		vim.keymap.set("n", "?", show_help, { buffer = buf, noremap = true, silent = true, desc = "Show help" })

		vim.keymap.set("n", "s", function()
			vim.ui.input({ prompt = "Stash Message (leave blank for WIP): " }, function(input)
				if input == nil then
					return
				end -- User cancelled
				local msg = input == "" and "WIP" or input
				vim.fn.system("git stash push -m " .. vim.fn.shellescape(msg))

				Ui.mode = "stashes"
				Ui.selected_index = 1
				load_stashes()
				update_window_layout()
				refresh_ui()
				focus_left()
				show_centered_message("Stash created: " .. msg, "📦")
			end)
		end, { buffer = buf, noremap = true, silent = true, desc = "Create new stash" })

		local function has_worktree_changes()
			-- returns >0 when there are changes
			return vim.fn.system("git status --porcelain") ~= ""
		end

		local function make_show_error(row, height, ui)
			return function(msg)
				local buf_err = vim.api.nvim_create_buf(false, true)
				vim.api.nvim_set_hl(0, "ResetError", {
					fg = "#ff4444",
					bg = "NONE",
					bold = true,
				})
				vim.api.nvim_buf_set_lines(buf_err, 0, -1, false, { msg })
				vim.api.nvim_buf_add_highlight(buf_err, -1, "ResetError", 0, 0, -1)

				local w = #msg + 4
				local error_row = row + height
				local error_col = math.floor((ui.width - w) / 2)

				local win_err = vim.api.nvim_open_win(buf_err, false, {
					relative = "editor",
					width = w,
					height = 1,
					row = error_row - 10,
					col = error_col,
					style = "minimal",
					border = "rounded",
					zindex = 600,
				})

				vim.defer_fn(function()
					if vim.api.nvim_win_is_valid(win_err) then
						vim.api.nvim_win_close(win_err, true)
					end
				end, 1800)
			end
		end

		-- G keymap for reset/rebase options on commits
		vim.keymap.set("n", "g", function()
			if Ui.mode ~= "branches" then
				return
			end

			local win = vim.api.nvim_get_current_win()
			if win ~= Ui.right_win then
				return
			end

			local cursor = vim.api.nvim_win_get_cursor(Ui.right_win)
			local line = vim.api.nvim_buf_get_lines(Ui.right_buf, cursor[1] - 1, cursor[1], false)[1] or ""
			local hash = line:match("^(%S+)")
			if not hash then
				return
			end

			---------------------------------------------------------------------------
			-- TEXT WRAPPING
			---------------------------------------------------------------------------
			local function wrap_text(text, max_width)
				local lines, current = {}, ""
				for word in text:gmatch("%S+") do
					if #current + #word + 1 > max_width then
						table.insert(lines, current)
						current = word
					else
						if current == "" then
							current = word
						else
							current = current .. " " .. word
						end
					end
				end
				if current ~= "" then
					table.insert(lines, current)
				end
				return lines
			end

			---------------------------------------------------------------------------
			-- OPTIONS
			---------------------------------------------------------------------------
			local options = {
				{
					key = "m",
					label = "Mixed reset",
					hl = "ResetBlue",
					desc = "Reset HEAD to this commit, keeping changes unstaged.",
					cmd = "git reset --mixed " .. hash,
				},

				{
					key = "s",
					label = "Soft reset",
					hl = "ResetGreen",
					desc = "Reset HEAD to this commit, keeping all changes staged.",
					cmd = "git reset --soft " .. hash,
				},

				{
					key = "h",
					label = "Hard reset",
					hl = "ResetRed",
					desc = "Fully reset working tree & index to this commit.",
					cmd = "git reset --hard " .. hash,
				},

				{
					key = "c",
					label = "Cancel",
					hl = "ResetWhite",
					desc = "Exit without doing anything.",
					cmd = nil,
				},
			}

			local selected = 1

			---------------------------------------------------------------------------
			-- POPUP WINDOWS
			---------------------------------------------------------------------------
			local ui = vim.api.nvim_list_uis()[1]
			local width = 52
			local height = #options + 2 -- FIX: removed the extra blank line

			local row = math.floor((ui.height - height) / 2)
			local col = math.floor((ui.width - width) / 2)

			local buf = vim.api.nvim_create_buf(false, true)
			local win = vim.api.nvim_open_win(buf, true, {
				relative = "editor",
				width = width,
				height = height,
				row = row,
				col = col,
				style = "minimal",
				border = "rounded",
				title = " Reset to " .. hash .. " ",
				title_pos = "center",
				zindex = 500,
			})

			local buf_desc = vim.api.nvim_create_buf(false, true)
			local win_desc = vim.api.nvim_open_win(buf_desc, false, {
				relative = "editor",
				width = width,
				height = 3,
				row = row + height + 2,
				col = col,
				style = "minimal",
				border = "rounded",
				title = " Info ",
				title_pos = "center",
				zindex = 500,
			})

			---------------------------------------------------------------------------
			-- RENDER
			---------------------------------------------------------------------------
			local function render()
				local lines = {}

				for i, opt in ipairs(options) do
					local prefix = (i == selected) and " " or "  "
					lines[#lines + 1] = prefix .. opt.label
				end

				vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
				vim.api.nvim_buf_clear_namespace(buf, -1, 0, -1)
				vim.api.nvim_buf_add_highlight(buf, -1, options[selected].hl, selected - 1, 0, -1)

				local wrapped = wrap_text(options[selected].desc, width - 4)
				vim.api.nvim_buf_set_lines(buf_desc, 0, -1, false, wrapped)
				vim.api.nvim_buf_clear_namespace(buf_desc, -1, 0, -1)
				for i = 1, #wrapped do
					vim.api.nvim_buf_add_highlight(buf_desc, -1, options[selected].hl, i - 1, 0, -1)
				end
			end

			render()

			---------------------------------------------------------------------------
			-- CLOSE POPUP
			---------------------------------------------------------------------------
			local function close_all()
				if vim.api.nvim_win_is_valid(win_desc) then
					vim.api.nvim_win_close(win_desc, true)
				end
				if vim.api.nvim_win_is_valid(win) then
					vim.api.nvim_win_close(win, true)
				end
				Ui.mode = "branches"
				refresh_ui()
			end

			---------------------------------------------------------------------------
			-- MOVEMENT
			---------------------------------------------------------------------------
			vim.keymap.set("n", "j", function()
				selected = math.min(#options, selected + 1)
				render()
			end, { buffer = buf })

			vim.keymap.set("n", "k", function()
				selected = math.max(1, selected - 1)
				render()
			end, { buffer = buf })

			---------------------------------------------------------------------------
			-- APPLY RESET FUNCTION
			---------------------------------------------------------------------------
			local function apply_selected_reset()
				local opt = options[selected]

				if not opt or not opt.cmd then
					close_all()
					return
				end

				if has_worktree_changes() then
					local show_error = make_show_error(row, height, ui)
					show_error("Cannot reset: work tree has uncommitted changes")
					return
				end

				vim.fn.system(opt.cmd)

				local msg = opt.label .. " → " .. hash
				vim.notify(msg, vim.log.levels.INFO)

				close_all()
			end

			---------------------------------------------------------------------------
			-- POPUP KEYMAPS
			---------------------------------------------------------------------------

			-- Confirm current selection
			vim.keymap.set("n", "<CR>", apply_selected_reset, { buffer = buf, noremap = true, silent = true })

			-- Close popup
			vim.keymap.set("n", "q", close_all, { buffer = buf, noremap = true, silent = true })
			vim.keymap.set("n", "<Esc>", close_all, { buffer = buf, noremap = true, silent = true })

			-- Direct hotkey selection for reset options
			for idx, opt in ipairs(options) do
				if opt.key then
					vim.keymap.set("n", opt.key, function()
						selected = idx
						apply_selected_reset()
					end, { buffer = buf, noremap = true, silent = true })
				end
			end

			---------------------------------------------------------------------------
			-- EXIT
			---------------------------------------------------------------------------
			vim.keymap.set("n", "q", close_all, { buffer = buf })
			vim.keymap.set("n", "<Esc>", close_all, { buffer = buf })
		end, { buffer = Ui.right_buf, noremap = true, silent = true })

		-- keymap for dropping commits
		vim.keymap.set("n", "d", function()
			-- Check if we're in the correct mode
			if Ui.mode ~= "branches" then
				return
			end

			-- Check if we're in the right window
			local win = vim.api.nvim_get_current_win()
			if win ~= Ui.right_win then
				return
			end

			-- Get the cursor position and the commit hash
			local cursor = vim.api.nvim_win_get_cursor(Ui.right_win)
			local line = vim.api.nvim_buf_get_lines(Ui.right_buf, cursor[1] - 1, cursor[1], false)[1] or ""

			-- Extract the commit hash from the line
			local hash = line:match("^(%S+)") -- Get the commit hash
			if not hash then
				return
			end

			-- Get the next commit hash
			local next_commit_hash = vim.fn.trim(vim.fn.system("git log --format='%H' --skip=1 " .. hash .. " -n 1"))
			if not next_commit_hash or next_commit_hash == "" then
				vim.notify("No next commit found", vim.log.levels.ERROR)
				return
			end

			-- Ask for user confirmation before discarding the commit
			local ui = vim.api.nvim_list_uis()[1]
			local width = 51
			local height = 1
			local row = 3
			local col = math.floor((ui.width - width) / 2)

			local buf = vim.api.nvim_create_buf(false, true)
			local win_confirm = vim.api.nvim_open_win(buf, true, {
				relative = "editor",
				width = width,
				height = height,
				row = row,
				col = col,
				style = "minimal",
				border = "rounded",
				title = " Confirmation ",
				title_pos = "center",
				zindex = 500,
			})

			local confirm_message = "Are you sure you want to discard this commit? (y/N)"
			vim.api.nvim_buf_set_lines(buf, 0, -1, false, { confirm_message })

			local function close_confirm_win()
				if vim.api.nvim_win_is_valid(win_confirm) then
					vim.api.nvim_win_close(win_confirm, true)
				end
			end

			-- Confirm keymap for 'y' and 'n'
			vim.keymap.set("n", "y", function()
				-- Perform the reset to the next commit
				local reset_command = "git reset --hard " .. next_commit_hash
				-- print("Running git reset command:", reset_command)
				vim.fn.system(reset_command)

				-- Show a success message
				local msg = "Reset to commit: " .. next_commit_hash
				local buf_ok = vim.api.nvim_create_buf(false, true)
				vim.api.nvim_buf_set_lines(buf_ok, 0, -1, false, { msg })
				vim.api.nvim_buf_add_highlight(buf_ok, -1, "ResetGreen", 0, 0, -1)

				local width = #msg + 4
				local ui = vim.api.nvim_list_uis()[1]
				local col = math.floor((ui.width - width) / 2)

				-- Position for the success message: Place it 2 rows below the confirmation

				local win_ok = vim.api.nvim_open_win(buf_ok, false, {
					relative = "editor",
					width = width,
					height = 1,
					row = row,
					col = col,
					style = "minimal",
					border = "rounded",
					zindex = 600,
				})

				vim.defer_fn(function()
					if vim.api.nvim_win_is_valid(win_ok) then
						vim.api.nvim_win_close(win_ok, true)
					end
				end, 1500)

				-- Refresh UI to reflect the reset state
				Ui.mode = "branches" -- Stay in branches mode after reset
				refresh_ui()

				close_confirm_win()
			end, { buffer = buf, noremap = true, silent = true })

			-- Cancel reset if user presses 'n' or Esc
			vim.keymap.set("n", "n", function()
				vim.notify("Drop Aborted", vim.log.levels.INFO)
				close_confirm_win()
			end, { buffer = buf, noremap = true, silent = true })

			vim.keymap.set("n", "q", function()
				vim.notify("Drop Aborted", vim.log.levels.INFO)
				close_confirm_win()
			end, { buffer = buf, noremap = true, silent = true })

			vim.keymap.set("n", "<Esc>", function()
				vim.notify("Drop Aborted", vim.log.levels.INFO)
				close_confirm_win()
			end, { buffer = buf, noremap = true, silent = true })
		end, { buffer = Ui.right_buf, noremap = true, silent = true })

		-- Apply Action (<Space>)
		vim.keymap.set("n", "<Space>", function()
			local win = vim.api.nvim_get_current_win()
			if win ~= Ui.left_win then
				return
			end

			if Ui.mode == "files" then
				stage_unstage_selected()
				render_left()
			elseif Ui.mode == "branches" then
				checkout_branch()
			elseif Ui.mode == "stashes" then
				local stash = Ui.stashes[Ui.selected_index]
				if stash then
					local ref = stash:match("(stash@{%d+})")
					if ref then
						local ok = vim.fn.confirm("Pop " .. ref .. "?", "Yes\nNo", 2)
						if ok == 1 then
							vim.fn.system("git stash pop " .. ref)
							if vim.v.shell_error == 0 then
								show_centered_message("Successfully popped " .. ref, "✅")
							else
								show_centered_message("Merge conflict or error popping stash", "⚠️")
							end
							load_stashes()
							Ui.selected_index = math.max(1, Ui.selected_index - 1)
							refresh_ui()
						end
					end
				end
			end
		end, { buffer = buf, noremap = true, silent = true })

		-- Delete Action (d)
		vim.keymap.set("n", "d", function()
			local win = vim.api.nvim_get_current_win()
			if win ~= Ui.left_win then
				return
			end

			if Ui.mode == "files" then
				discard_changes_selected()
			elseif Ui.mode == "stashes" then
				local stash = Ui.stashes[Ui.selected_index]
				if stash then
					local ref = stash:match("(stash@{%d+})")
					if ref then
						local ok = vim.fn.confirm("Drop " .. ref .. "?", "Yes\nNo", 2)
						if ok == 1 then
							vim.fn.system("git stash drop " .. ref)
							load_stashes()
							Ui.selected_index = math.max(1, Ui.selected_index - 1)
							refresh_ui()
							show_centered_message("Dropped " .. ref, "🗑️")
						end
					end
				end
			else
				delete_branch()
			end
		end, { buffer = Ui.left_buf, noremap = true, silent = true })

		-- Commit Keymap
		vim.keymap.set("n", "c", function()
			if Ui.mode == "branches" then
				local remotes = vim.fn.systemlist("git branch -r --format='%(refname:short)'")
				local missing = {}
				local local_set = {}
				for _, b in ipairs(Ui.branches) do
					local_set[b] = true
				end

				for _, r in ipairs(remotes) do
					local _, branch_name = r:match("^([^/]+)/(.*)$")
					if branch_name and branch_name ~= "HEAD" and not local_set[branch_name] then
						if not vim.tbl_contains(missing, branch_name) then
							table.insert(missing, branch_name)
						end
					end
				end

				if #missing == 0 then
					show_centered_message("No remote branches available to checkout.", "❄️")
					return
				end

				local ui_info = vim.api.nvim_list_uis()[1]
				local width = math.floor(ui_info.width * 0.6) -- Adjust width here (0.6 = 60% of screen)
				local max_height = math.floor(ui_info.height * 0.6) -- Adjust max vertical height here
				local height = math.max(10, math.min(max_height, #missing + 3))

				local row = math.floor((ui_info.height - height) / 2)
				local col = math.floor((ui_info.width - width) / 2)

				local buf = vim.api.nvim_create_buf(false, true)
				local win = vim.api.nvim_open_win(buf, true, {
					relative = "editor",
					width = width,
					height = height,
					row = row,
					col = col,
					style = "minimal",
					border = "rounded",
					title = " Checkout Remote Branch ",
					title_pos = "center",
					zindex = 500,
				})

				-- Initial setup
				vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "> " })

				local query = ""
				local filtered = vim.deepcopy(missing)
				local selected = 1

				local function render()
					local lines = { string.rep("─", width) }
					for i, b in ipairs(filtered) do
						local prefix = (i == selected) and "  " or "   "
						table.insert(lines, prefix .. b)
					end
					vim.api.nvim_buf_set_lines(buf, 1, -1, false, lines)
					vim.api.nvim_buf_clear_namespace(buf, -1, 1, -1)
					if #filtered > 0 then
						vim.api.nvim_buf_add_highlight(buf, -1, "MergeBlue", selected + 1, 0, -1)
					end
				end

				render()

				-- Live filtering
				vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
					buffer = buf,
					callback = function()
						local line = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] or ""
						local q = line
						if q:sub(1, 2) == "> " then
							q = q:sub(3)
						else
							-- Prevent user from deleting the prompt prefix
							vim.api.nvim_buf_set_lines(buf, 0, 1, false, { "> " .. q })
							vim.api.nvim_win_set_cursor(win, { 1, #q + 2 })
						end

						if q == query then
							return
						end
						query = q

						filtered = {}
						for _, b in ipairs(missing) do
							if b:lower():find(query:lower(), 1, true) then
								table.insert(filtered, b)
							end
						end
						selected = math.min(selected, math.max(1, #filtered))
						render()
					end,
				})

				local function close_popup()
					if vim.api.nvim_win_is_valid(win) then
						vim.api.nvim_win_close(win, true)
					end
					vim.cmd("stopinsert")
				end

				local function confirm_selection()
					if #filtered == 0 then
						return
					end
					local choice = filtered[selected]
					close_popup()

					local cmd = "git switch " .. vim.fn.shellescape(choice)
					local result = vim.fn.system(cmd)
					if vim.v.shell_error ~= 0 then
						show_centered_message("Failed to switch branch:\n" .. result, "❌")
						return
					end
					Ui.branch_selected = choice
					show_centered_message("Switched to branch: " .. choice, "✅")
					load_branches()
					Ui.selected_index = 1
					refresh_ui()
				end

				local opts = { buffer = buf, noremap = true, silent = true }

				local function move_down()
					selected = math.min(#filtered, selected + 1)
					render()
				end

				local function move_up()
					selected = math.max(1, selected - 1)
					render()
				end

				-- Insert mode navigation
				vim.keymap.set("i", "<C-j>", move_down, opts)
				vim.keymap.set("i", "<C-n>", move_down, opts)
				vim.keymap.set("i", "<Down>", move_down, opts)

				vim.keymap.set("i", "<C-k>", move_up, opts)
				vim.keymap.set("i", "<C-p>", move_up, opts)
				vim.keymap.set("i", "<Up>", move_up, opts)

				vim.keymap.set("i", "<CR>", confirm_selection, opts)
				vim.keymap.set("i", "<Esc>", close_popup, opts)
				vim.keymap.set("i", "<C-c>", close_popup, opts)

				-- Normal mode fallbacks
				vim.keymap.set("n", "j", move_down, opts)
				vim.keymap.set("n", "k", move_up, opts)
				vim.keymap.set("n", "<CR>", confirm_selection, opts)
				vim.keymap.set("n", "q", close_popup, opts)
				vim.keymap.set("n", "<Esc>", close_popup, opts)

				-- Start in insert mode at the end of the prompt
				vim.cmd("startinsert!")
				vim.api.nvim_win_set_cursor(win, { 1, 2 })

				return
			end

			if Ui.mode ~= "files" then
				return
			end

			local branch = Ui.branches[Ui.selected_index]
			if not branch or branch == "" then
				branch = Ui.branch_selected or "HEAD"
			end

			local width = math.floor(vim.o.columns * 0.9)
			local height_title = 1
			local height_desc = 4
			local height_diff = math.floor(vim.o.lines * 0.72) -- taller diff
			local spacing = 1
			local col = math.floor((vim.o.columns - width) / 2)

			-- =========================
			-- Background overlay
			-- =========================
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

			-- =========================
			-- Buffers
			-- =========================
			local buf_diff = vim.api.nvim_create_buf(false, true)
			vim.api.nvim_buf_set_option(buf_diff, "buftype", "nofile")
			vim.api.nvim_buf_set_option(buf_diff, "bufhidden", "wipe")
			vim.api.nvim_buf_set_option(buf_diff, "filetype", "diff")

			local diff_cmd = "git diff --cached " .. vim.fn.shellescape(branch)
			local diff_lines = vim.fn.systemlist(diff_cmd)
			if vim.v.shell_error ~= 0 or #diff_lines == 0 then
				diff_lines = { "[No staged changes]" }
			end
			vim.api.nvim_buf_set_lines(buf_diff, 0, -1, false, diff_lines)
			vim.api.nvim_buf_set_option(buf_diff, "modifiable", false)

			-- Buffers for title and description
			local buf_title = vim.api.nvim_create_buf(false, true)
			vim.api.nvim_buf_set_option(buf_title, "buftype", "acwrite")
			vim.api.nvim_buf_set_option(buf_title, "bufhidden", "wipe")
			vim.api.nvim_buf_set_lines(buf_title, 0, -1, false, { "" })

			local buf_desc = vim.api.nvim_create_buf(false, true)
			vim.api.nvim_buf_set_option(buf_desc, "buftype", "acwrite")
			vim.api.nvim_buf_set_option(buf_desc, "bufhidden", "wipe")
			vim.api.nvim_buf_set_lines(buf_desc, 0, -1, false, { "", "", "" })

			-- =========================
			-- Windows (diff top, commit bottom)
			-- =========================
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

			-- =========================
			-- Close popup helper
			-- =========================
			local function close_commit_popup()
				for _, w in ipairs({ win_title, win_desc, win_diff, win_overlay }) do
					if vim.api.nvim_win_is_valid(w) then
						vim.api.nvim_win_close(w, true)
					end
				end

				-- Restore focus to the main UI
				if Ui.left_win and vim.api.nvim_win_is_valid(Ui.left_win) then
					vim.api.nvim_set_current_win(Ui.left_win)
				end
			end

			-- ====================================
			-- Start commit title in insert mode
			-- ====================================
			-- Clear the title buffer and enter insert mode
			local function prepare_title_buffer()
				vim.api.nvim_buf_set_lines(buf_title, 0, -1, false, { "" })
				vim.cmd("startinsert")
			end

			prepare_title_buffer()
			-- =========================
			-- Commit logic
			-- =========================
			local function commit_changes()
				vim.cmd("stopinsert") -- ensure we exit insert mode

				local title = vim.api.nvim_buf_get_lines(buf_title, 0, -1, false)[1] or ""
				local body = table.concat(vim.api.nvim_buf_get_lines(buf_desc, 0, -1, false), "\n")

				vim.fn.system("git add -A")
				local cmd = "git commit -m " .. vim.fn.shellescape(title)

				if body:match("%S") then
					cmd = cmd .. " -m " .. vim.fn.shellescape(body)
				end
				vim.fn.system(cmd)

				show_centered_message("Committed changes on branch: " .. branch, "🌸")
				close_commit_popup()

				-- Refresh git status and UI
				load_branches()
				get_changed_files(Ui.branch_selected)

				-- If no changed files remain, return to branches view
				if #Ui.changed_files == 0 and Ui.mode == "files" then
					Ui.mode = "branches"
					Ui.selected_index = 1
					if type(update_window_layout) == "function" then
						update_window_layout()
					end
				end

				refresh_ui()
			end

			-- =========================
			-- Keymaps
			-- =========================
			for _, b in ipairs({ buf_title, buf_desc, buf_diff }) do
				vim.keymap.set("n", "q", close_commit_popup, { buffer = b, noremap = true, silent = true })
				vim.keymap.set("n", "<Esc>", close_commit_popup, { buffer = b, noremap = true, silent = true })
				vim.keymap.set("n", "<Tab>", function()
					vim.api.nvim_set_current_win(win_desc)
				end, { buffer = b })
				vim.keymap.set("n", "<S-Tab>", function()
					vim.api.nvim_set_current_win(win_title)
				end, { buffer = b })

				vim.keymap.set("n", "<C-d>", function()
					vim.api.nvim_win_call(win_diff, function()
						vim.cmd("normal! <C-d>")
					end)
				end, { buffer = buf_diff, noremap = true, silent = false })

				vim.keymap.set("n", "<C-b>", function()
					vim.api.nvim_win_call(win_diff, function()
						vim.cmd("normal! <C-b>")
					end)
				end, { buffer = buf_diff, noremap = true, silent = false })
			end

			vim.keymap.set("n", "<CR>", commit_changes, { buffer = buf_title, noremap = true, silent = true })
			vim.keymap.set("n", "<CR>", commit_changes, { buffer = buf_desc, noremap = true, silent = true })

			-- Start typing in title (but don't go into insert mode)
			vim.api.nvim_set_current_win(win_title)
		end)

		-- Pull latest changes
		vim.keymap.set("n", "p", function()
			if Ui.mode ~= "branches" then
				return
			end
			local branch = Ui.branches[Ui.selected_index]
			if not branch or branch == "" then
				show_centered_message("No branch selected", vim.log.levels.WARN)
				return
			end

			local cmd = "git pull origin " .. branch
			local stdout_lines = {}
			local stderr_lines = {}

			-- Run the pull command asynchronously
			vim.fn.jobstart(cmd, {
				stdout_buffered = true,
				stderr_buffered = true,
				on_stdout = function(_, data)
					stdout_lines = data or {}
				end,
				on_stderr = function(_, data)
					stderr_lines = data or {}
				end,
				on_exit = function(_, exit_code)
					-- Show floating windows with the output and error messages
					show_floating_pair(stdout_lines or {}, stderr_lines or {})

					-- After pulling, handle success or failure
					if exit_code == 0 then
						show_centered_message("✅ Pulled latest changes for branch: " .. branch, vim.log.levels.INFO)
					else
						show_centered_message("❌ Failed to pull for branch: " .. branch, vim.log.levels.ERROR)
					end
					refresh_ui()
				end,
			})

			-- Show spinner or any other loading feedback while pull is running
			show_centered_message("Pulling latest changes for branch: " .. branch, vim.log.levels.INFO)
		end, { buffer = buf, noremap = true, silent = true })

		-- Push branch
		vim.keymap.set("n", "P", function()
			local current_branch = branch or Ui.branch_selected or "HEAD"
			local remote = "origin"
			-- print("DEBUG: Starting push for branch:", current_branch)

			local spinner_chars = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
			local spinner_idx = 1

			-- Spinner window
			local buf = vim.api.nvim_create_buf(false, true)
			vim.api.nvim_buf_set_lines(
				buf,
				0,
				-1,
				false,
				{ "Pushing to " .. current_branch .. " " .. spinner_chars[spinner_idx] }
			)
			local ui = vim.api.nvim_list_uis()[1]
			local win = vim.api.nvim_open_win(buf, false, {
				relative = "editor",
				width = 50,
				height = 1,
				row = 3,
				col = math.floor((ui.width - 50) / 2),
				style = "minimal",
				border = "rounded",
				zindex = 50,
			})

			local spinner_timer = vim.loop.new_timer()
			spinner_timer:start(
				100,
				100,
				vim.schedule_wrap(function()
					if not vim.api.nvim_win_is_valid(win) then
						spinner_timer:stop()
						spinner_timer:close()
						return
					end
					spinner_idx = spinner_idx % #spinner_chars + 1
					vim.api.nvim_buf_set_lines(
						buf,
						0,
						-1,
						false,
						{ "✨ Pushing To " .. current_branch .. " " .. spinner_chars[spinner_idx] }
					)
				end)
			)

			local function do_push(force)
				local args = { "git", "push", "-u", remote, current_branch }
				if force then
					table.insert(args, 3, "--force")
				end

				vim.fn.jobstart(args, {
					stdout_buffered = true,
					stderr_buffered = true,
					on_exit = function(_, exit_code, _)
						spinner_timer:stop()
						spinner_timer:close()
						vim.schedule(function()
							if vim.api.nvim_win_is_valid(win) then
								vim.api.nvim_win_close(win, true)
							end
							if exit_code == 0 then
								show_centered_message("✅ Successfully pushed branch: " .. current_branch)
								Ui.mode = "branches"
								refresh_ui()

							-- show_floating_pair({ "Push to " .. current_branch .. " succeeded!" }, {})
							else
								show_centered_message(" Failed to push branch: " .. current_branch)
								-- show_floating_pair({}, { "Failed to push to " .. current_branch })
							end
						end)
					end,
				})
			end

			-- Run a dry-run push first to detect divergence
			local dry_output = vim.fn.system("git push --dry-run -u " .. remote .. " " .. current_branch .. " 2>&1")
			-- print("DEBUG: dry-run output:\n" .. dry_output)
			if dry_output:match("rejected") or dry_output:match("non-fast-forward") then
				local answer = vim.fn.input("Branch has diverged. Force push? (y/N): ")
				if answer:lower() == "y" then
					do_push(true)
				else
					-- print("DEBUG: user declined force push")
					show_centered_message("Push aborted.")
				end
			else
				do_push(false)
			end

			refresh_ui()
		end)

		-- n keymap to create new branches off of selected branch
		vim.keymap.set("n", "n", function()
			local buf = Ui.left_buf
			if not buf or not vim.api.nvim_buf_is_valid(buf) then
				return
			end
			if vim.api.nvim_get_current_buf() ~= buf then
				return
			end

			local current_branch = Ui.branch_selected
			if not current_branch or current_branch == "" then
				vim.notify("No branch selected!", vim.log.levels.ERROR)
				return
			end

			local function show_centered_error(msg)
				local buf = vim.api.nvim_create_buf(false, true)
				local lines = vim.split(msg, "\n")
				vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(msg, "\n"))

				vim.api.nvim_set_hl(0, "CenteredError", { fg = "#FF5555", bold = true })

				-- Apply highlight to all lines
				for i = 0, #lines - 1 do
					vim.api.nvim_buf_add_highlight(buf, -1, "CenteredError", i, 0, -1)
				end

				local width = 60
				local height = #lines
				local ui = vim.api.nvim_list_uis()[1]

				local win = vim.api.nvim_open_win(buf, false, {
					relative = "editor",
					width = width,
					height = height,
					row = 2,
					col = math.floor((ui.width - width) / 2),
					style = "minimal",
					border = "rounded",
					zindex = 50,
				})

				vim.api.nvim_buf_set_option(buf, "modifiable", false)
				-- Auto close after 3 seconds
				vim.defer_fn(function()
					if vim.api.nvim_win_is_valid(win) then
						vim.api.nvim_win_close(win, true)
					end
				end, 2000)
			end

			-- Check for uncommitted changes using systemlist
			local status = vim.fn.systemlist("git status --porcelain")
			if #status > 0 then
				show_centered_error(
					"🚨 You have uncommitted changes!\nCommit, stash, or discard them before switching branches."
				)
				return
			end

			-- Window size
			local width, height = 50, 1
			local ui = vim.api.nvim_list_uis()[1]
			local buf = vim.api.nvim_create_buf(false, true)

			-- Open floating window with a title
			local win = vim.api.nvim_open_win(buf, true, {
				relative = "editor",
				width = width,
				height = height,
				row = 3,
				col = math.floor((ui.width - width) / 2),
				style = "minimal",
				border = "rounded",
				title = " Create New Branch: " .. current_branch .. " ",
				title_pos = "center",
				zindex = 50,
			})

			-- Start insert mode at second line
			vim.api.nvim_win_set_cursor(win, { 1, 0 })
			vim.cmd("startinsert")

			-- Keymap for Enter to create branch
			-- Normal mode mapping inside the buffer
			-- after creating `buf` and `win`
			-- set normal mode mapping for Enter
			vim.keymap.set("n", "<CR>", function()
				local new_branch = vim.api.nvim_get_current_line()
				vim.api.nvim_win_close(win, true)

				if new_branch == "" then
					print("Aborted: no branch name entered")
					return
				end

				-- Spinner
				local spinner_chars = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
				local spinner_idx = 1
				local spin_buf = vim.api.nvim_create_buf(false, true)
				local spin_win = vim.api.nvim_open_win(spin_buf, false, {
					relative = "editor",
					width = 50,
					height = 1,
					row = 2,
					col = math.floor((vim.api.nvim_list_uis()[1].width - 50) / 2),
					style = "minimal",
					border = "rounded",
					zindex = 50,
				})

				local spinner_timer = vim.loop.new_timer()
				spinner_timer:start(
					100,
					100,
					vim.schedule_wrap(function()
						if not vim.api.nvim_win_is_valid(spin_win) then
							spinner_timer:stop()
							spinner_timer:close()
							return
						end
						spinner_idx = spinner_idx % #spinner_chars + 1
						vim.api.nvim_buf_set_lines(
							spin_buf,
							0,
							-1,
							false,
							{ "✨ Creating new branch " .. new_branch .. " " .. spinner_chars[spinner_idx] }
						)
					end)
				)

				vim.fn.jobstart({ "git", "checkout", "-b", new_branch, current_branch }, {
					on_exit = function(_, exit_code)
						spinner_timer:stop()
						spinner_timer:close()
						vim.schedule(function()
							if vim.api.nvim_win_is_valid(spin_win) then
								vim.api.nvim_win_close(spin_win, true)
							end

							if exit_code == 0 then
								print("✅ Created new branch '" .. new_branch .. "' from '" .. current_branch .. "'")

								-- 1. Update internal selected branch state
								Ui.branch_selected = new_branch

								-- 2. Trigger the refresh/re-render function for GitCompanion
								if type(M.refresh_branches) == "function" then
									M.refresh_branches()
								elseif type(M.render_branches) == "function" then
									M.render_branches()
								elseif type(M.refresh) == "function" then
									M.refresh()
								end
							else
								print(" Failed to create branch '" .. new_branch .. "'")
							end

							-- 3. Refocus back to the branches floating window
							if Ui.left_win and vim.api.nvim_win_is_valid(Ui.left_win) then
								vim.api.nvim_set_current_win(Ui.left_win)
							end
						end)
					end,
				})
			end, { buffer = buf, noremap = true, silent = true })

			-- Keymap to quit the floating window with 'q' in normal mode
			vim.api.nvim_buf_set_keymap(
				buf,
				"n",
				"q",
				[[<Cmd>lua vim.api.nvim_win_close(0, true)<CR>]],
				{ noremap = true, silent = true }
			)
		end, {
			buffer = Ui.left_buf,
			noremap = true,
			silent = true,
			desc = "Create new branch from selected",
		})

		-- m keymap for merge options
		vim.keymap.set("n", "m", function()
			if Ui.mode ~= "branches" then
				return
			end

			local function wrap_text(text, max_width)
				local lines, current_line = {}, ""
				for word in text:gmatch("%S+") do
					if #current_line + #word + 1 > max_width then
						table.insert(lines, current_line)
						current_line = word
					else
						if current_line == "" then
							current_line = word
						else
							current_line = current_line .. " " .. word
						end
					end
				end
				if current_line ~= "" then
					table.insert(lines, current_line)
				end
				return lines
			end

			local target_branch = Ui.branch_selected
			if not target_branch or target_branch == "" then
				vim.notify("No branch selected!", vim.log.levels.ERROR)
				return
			end

			local current_branch = vim.fn.trim(vim.fn.system("git branch --show-current"))
			if current_branch == target_branch then
				vim.notify("Cannot merge a branch into itself!", vim.log.levels.ERROR)
				return
			end

			-- OPTIONS
			local options = {
				{
					key = "m",
					label = "Regular merge",
					hl = "MergeBlue",
					desc = "Merge '"
						.. target_branch
						.. "' into '"
						.. current_branch
						.. "'. Creates a merge commit if needed.",
					cmd = "git merge " .. target_branch,
				},
				{
					key = "s",
					label = "Squash merge, leave uncommitted",
					hl = "MergeGreen",
					desc = "Squash commits from '"
						.. target_branch
						.. "' into working tree, do not commit automatically.",
					cmd = "git merge --squash " .. target_branch,
				},
				{
					key = "S",
					label = "Squash merge and commit",
					hl = "MergeRed",
					desc = "Squash commits from '" .. target_branch .. "' and commit automatically.",
					cmd = string.format(
						"git merge --squash %s && git commit -m 'Merge %s into %s'",
						target_branch,
						target_branch,
						current_branch
					),
				},
				{
					key = "q",
					label = "Cancel",
					hl = "MergeWhite",
					desc = "Exit without merging.",
					cmd = nil,
				},
			}

			local selected = 1
			local ui = vim.api.nvim_list_uis()[1]
			local width, height = 52, #options + 3
			local row, col = math.floor((ui.height - height) / 2), math.floor((ui.width - width) / 2)

			-- POPUP WINDOW
			local buf_win = vim.api.nvim_create_buf(false, true)
			local win = vim.api.nvim_open_win(buf_win, true, {
				relative = "editor",
				width = width,
				height = height,
				row = row - 1,
				col = col,
				style = "minimal",
				border = "rounded",
				title = " Merge " .. target_branch .. " → " .. current_branch .. " ",
				title_pos = "center",
				zindex = 500,
			})

			local buf_desc = vim.api.nvim_create_buf(false, true)
			local win_desc = vim.api.nvim_open_win(buf_desc, false, {
				relative = "editor",
				width = width,
				height = 2,
				row = row + height + 1,
				col = col,
				style = "minimal",
				border = "rounded",
				title = " Info ",
				title_pos = "center",
				zindex = 500,
			})

			vim.api.nvim_win_set_option(win, "cursorline", false)
			vim.api.nvim_win_set_cursor(win, { 1, 0 })
			vim.api.nvim_win_set_option(win_desc, "cursorline", false)
			vim.api.nvim_win_set_cursor(win_desc, { 1, 0 })

			-- test
			-- RENDER FUNCTION
			local function render()
				local lines = {}
				for i, opt in ipairs(options) do
					lines[#lines + 1] = (i == selected and " " or "  ") .. opt.label
				end
				vim.api.nvim_buf_set_lines(buf_win, 0, -1, false, lines)
				vim.api.nvim_buf_clear_namespace(buf_win, -1, 0, -1)
				vim.api.nvim_buf_add_highlight(buf_win, -1, options[selected].hl, selected - 1, 0, -1)

				local desc_lines = wrap_text(options[selected].desc, width - 4)
				vim.api.nvim_buf_set_lines(buf_desc, 0, -1, false, desc_lines)
				vim.api.nvim_buf_clear_namespace(buf_desc, -1, 0, -1)
				for i = 1, #desc_lines do
					vim.api.nvim_buf_add_highlight(buf_desc, -1, options[selected].hl, i - 1, 0, -1)
				end
			end
			render()

			-- MOVEMENT
			vim.keymap.set("n", "j", function()
				selected = math.min(#options, selected + 1)
				render()
			end, { buffer = buf_win })
			vim.keymap.set("n", "k", function()
				selected = math.max(1, selected - 1)
				render()
			end, { buffer = buf_win })

			-- Close the merge popup completely (if 'q' or 'Esc' pressed)
			local function close_all()
				if vim.api.nvim_win_is_valid(win_desc) then
					vim.api.nvim_win_close(win_desc, true)
				end
				if vim.api.nvim_win_is_valid(win) then
					vim.api.nvim_win_close(win, true)
				end
				Ui.mode = "branches"
				refresh_ui()
			end

			-- test

			local function apply_selected()
				local opt = options[selected]
				if not opt.cmd then
					close_all()
					return
				end

				close_all() -- close main popup first

				local stdout_lines = nil
				local stderr_lines = nil

				-- run merge asynchronously
				vim.fn.jobstart(opt.cmd, {
					stdout_buffered = true,
					stderr_buffered = true,
					on_stdout = function(_, data)
						stdout_lines = data or {}
					end,
					on_stderr = function(_, data)
						stderr_lines = data or {}
					end,
					on_exit = function()
						-- Use the floating window function here
						show_floating_pair(stdout_lines or {}, stderr_lines or {})
					end,
				})
			end

			vim.keymap.set("n", "<CR>", apply_selected, { buffer = buf_win })
			for _, opt in ipairs(options) do
				vim.keymap.set("n", opt.key, function()
					selected = _
					apply_selected()
				end, { buffer = buf_win })
			end

			vim.keymap.set("n", "q", close_all, { buffer = buf_win })
			vim.keymap.set("n", "<Esc>", close_all, { buffer = buf_win })
		end, { buffer = buf, noremap = true, silent = true })

		-- Close UI
		vim.keymap.set("n", "q", function()
			close_ui()
			reload_file_buffer()
		end, {
			buffer = buf,
			noremap = true,
			silent = true,
		})
	end

	-- comment
	--
	-- Apply keymaps to both buffers
	set_keymaps(Ui.left_buf)
	set_keymaps(Ui.right_buf)
	set_keymaps(Ui.diff_buf)
	refresh_ui()
	init_ui()
end

M.setup = function(opts)
	-- Define your plugin's default settings
	local default_opts = {
		-- Add any user-configurable options here in the future
	}

	-- Merge default options with user-provided options
	M.options = vim.tbl_deep_extend("force", default_opts, opts or {})

	-- Expose a Neovim user command
	vim.api.nvim_create_user_command("GitCompanion", function()
		M.toggle()
	end, { desc = "Open GitCompanion UI" })
end

return M
