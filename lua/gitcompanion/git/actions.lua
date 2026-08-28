local M = {}

---------------------------------------------------------------------------
-- Internal Dependencies (Injected via setup_dependencies)
---------------------------------------------------------------------------
local Status
local Layout
local Dialogs
local Tree

function M.setup_dependencies(deps)
	deps = deps or {}
	Status = deps.status
	Layout = deps.layout
	Dialogs = deps.dialogs
	Tree = deps.tree
end

---------------------------------------------------------------------------
-- Helper Functions
---------------------------------------------------------------------------

-- Recursive gather leaf nodes under a directory/root node
local function collect_child_files(node, files)
	files = files or {}
	if not node then
		return files
	end

	if not node.is_dir then
		table.insert(files, node)
	else
		for _, child in pairs(node.children or {}) do
			collect_child_files(child, files)
		end
	end
	return files
end

---------------------------------------------------------------------------
-- Action Functions
---------------------------------------------------------------------------

function M.stage_unstage_selected(state)
	-- vim.notify("[GitActions] stage_unstage_selected ENTERED", vim.log.levels.DEBUG)

	-- Fallback sequence: passed state -> global State -> state module
	local State = state or _G.State or require("gitcompanion.state")
	local Ui = State and State.Ui

	if not Ui then
		-- vim.notify("[GitActions ERROR] State or State.Ui is nil!", vim.log.levels.ERROR)
		return
	end

	local item = Ui.visible_tree_lines and Ui.selected_index and Ui.visible_tree_lines[Ui.selected_index]
	local node = item and item.node
	if not node then
		-- vim.notify(
		-- 	string.format("[GitActions ERROR] No node found at index: %s", tostring(Ui.selected_index)),
		-- 	vim.log.levels.ERROR
		-- )
		return
	end

	-- Perform git add / restore logic
	if node.is_dir then
		local leaf_nodes = collect_child_files(node)
		local should_stage = false
		for _, child in ipairs(leaf_nodes) do
			if not child.staged then
				should_stage = true
				break
			end
		end

		for _, child in ipairs(leaf_nodes) do
			child.staged = should_stage
			if should_stage then
				vim.fn.system({ "git", "add", child.path })
			else
				vim.fn.system({ "git", "restore", "--staged", child.path })
			end
		end
	else
		node.staged = not node.staged
		if node.staged then
			vim.fn.system({ "git", "add", node.path })
		else
			vim.fn.system({ "git", "restore", "--staged", node.path })
		end
	end

	-- Refresh UI
	local layout = require("gitcompanion.ui.layout")
	if layout and type(layout.render_left) == "function" then
		layout.render_left(State)
	end
end

function M.discard_changes_selected()
	local state_mod = require("gitcompanion.state")
	local State = state_mod or _G.State or {}
	local Ui = State.Ui or {}

	vim.notify("[GitCompanion Debug] discard_changes_selected invoked", vim.log.levels.DEBUG)

	if Ui.mode ~= "files" then
		vim.notify("[GitCompanion Discard] Cancelled: Mode is " .. tostring(Ui.mode), vim.log.levels.WARN)
		return
	end

	local sel_file = nil

	if Ui.flat_nodes and Ui.selected_index and Ui.flat_nodes[Ui.selected_index] then
		local node = Ui.flat_nodes[Ui.selected_index]
		sel_file = node.path or node.value or node.file
		vim.notify(
			string.format(
				"[GitCompanion Debug] Selected from flat_nodes index %s: path=%s",
				tostring(Ui.selected_index),
				tostring(sel_file)
			),
			vim.log.levels.DEBUG
		)
		if node.is_dir then
			vim.notify("[GitCompanion Discard] Cannot discard changes on a directory node.", vim.log.levels.WARN)
			return
		end
	end

	if not sel_file and Ui.changed_files then
		local raw = Ui.changed_files[Ui.selected_index]
		vim.notify(
			string.format(
				"[GitCompanion Debug] Fallback lookup in changed_files at index %s, raw type: %s",
				tostring(Ui.selected_index),
				type(raw)
			),
			vim.log.levels.DEBUG
		)
		if type(raw) == "table" then
			sel_file = raw.value or raw.path or raw.file
		elseif type(raw) == "string" then
			sel_file = raw
		end
	end

	if not sel_file then
		vim.notify(
			string.format("[GitCompanion Discard] No valid file found at row %s", tostring(Ui.selected_index)),
			vim.log.levels.WARN
		)
		return
	end

	local confirm_result = vim.fn.confirm("Discard changes to " .. sel_file .. "?", "&Yes\n&No", 2)
	if confirm_result ~= 1 then
		vim.notify("[GitCompanion Discard] Discard cancelled by user", vim.log.levels.INFO)
		return
	end

	local status_mod = require("gitcompanion.git.status")
	local root = (status_mod and status_mod.git_root and status_mod.git_root()) or "."

	local status_output = vim.fn.system({ "git", "-C", root, "status", "--porcelain", "--", sel_file })
	status_output = vim.trim(status_output)
	vim.notify(
		string.format("[GitCompanion Debug] git status porcelain for %s: '%s'", sel_file, status_output),
		vim.log.levels.DEBUG
	)

	local cmd
	if vim.startswith(status_output, "??") then
		vim.notify("[GitCompanion Debug] File is untracked. Using git clean", vim.log.levels.DEBUG)
		cmd = { "git", "-C", root, "clean", "-f", "--", sel_file }
	else
		vim.notify("[GitCompanion Debug] File is tracked/modified. Using git restore", vim.log.levels.DEBUG)
		cmd = { "git", "-C", root, "restore", "--staged", "--worktree", "--", sel_file }
	end

	local result = vim.fn.system(cmd)
	local err = vim.v.shell_error
	vim.notify(
		string.format("[GitCompanion Debug] Command exit code: %s, output: %s", tostring(err), tostring(result)),
		vim.log.levels.DEBUG
	)

	if err ~= 0 and not vim.startswith(status_output, "??") then
		local fallback_cmd = { "git", "-C", root, "checkout", "HEAD", "--", sel_file }
		vim.notify("[GitCompanion Debug] Restore failed, attempting checkout HEAD fallback", vim.log.levels.DEBUG)
		result = vim.fn.system(fallback_cmd)
		err = vim.v.shell_error
	end

	if err ~= 0 then
		vim.notify("Failed to discard " .. sel_file .. ": " .. result, vim.log.levels.ERROR)
		return
	else
		vim.notify("Discarded changes in " .. sel_file, vim.log.levels.INFO)
	end

	vim.defer_fn(function()
		vim.notify("[GitCompanion Debug] Executing status refresh via get_changed_files_async...", vim.log.levels.DEBUG)

		if status_mod and type(status_mod.get_changed_files_async) == "function" then
			status_mod.get_changed_files_async(function(files)
				vim.notify(
					string.format(
						"[GitCompanion Debug] Async files callback returned count: %s",
						tostring(files and #files or 0)
					),
					vim.log.levels.DEBUG
				)

				-- Force cache invalidation and redraw
				Ui._last_rendered_files = nil
				Ui._last_files_len = nil

				local tree_ok, tree_mod = pcall(require, "gitcompanion.ui.tree")
				if tree_ok then
					if type(tree_mod.build_tree) == "function" then
						tree_mod.build_tree()
					end
					if type(tree_mod.render_files_tree) == "function" then
						tree_mod.render_files_tree()
					end
				end

				local layout_ok, layout_mod = pcall(require, "gitcompanion.ui.layout")
				if layout_ok and type(layout_mod.render_diff) == "function" then
					layout_mod.render_diff()
				end
			end)
		else
			vim.notify("[GitCompanion Error] get_changed_files_async is not a function", vim.log.levels.ERROR)
		end
	end, 150)
end

function M.checkout_branch()
	local Ui = State.Ui
	if Ui.mode ~= "branches" then
		return
	end

	local branch = Ui.branches[Ui.selected_index]
	if not branch then
		return
	end

	-- Check for uncommitted changes
	local status = vim.fn.systemlist("git status --porcelain -uall")
	if #status > 0 then
		if Dialogs and Dialogs.show_centered_error then
			Dialogs.show_centered_error(
				"🚨 You have uncommitted changes!\nCommit, stash, or discard them before switching branches."
			)
		end
		return
	end

	-- Switch branch using 'git switch'
	local cmd = "git switch " .. vim.fn.shellescape(branch)
	local result = vim.fn.system(cmd)

	if vim.v.shell_error ~= 0 then
		if Dialogs and Dialogs.show_centered_message then
			Dialogs.show_centered_message("Failed to switch branch:\n" .. result, "❌")
		end
		return
	end

	-- Update internal state
	Ui.branch_selected = branch

	-- Reload branch list
	if Status and Status.load_branches_async then
		Status.load_branches_async()
	end

	-- Reset selection index
	Ui.selected_index = 1

	-- 1. Refresh UI first
	if Layout and Layout.refresh_ui then
		Layout.refresh_ui()
	end

	-- 2. Display completion message
	if Dialogs and Dialogs.show_centered_message then
		Dialogs.show_centered_message("Switched to branch: " .. branch, "✅")
	end
end

-- Inside lua/gitcompanion/git/actions.lua
function M.delete_branch()
	local Ui = require("gitcompanion.state").Ui
	local branch = Ui.branches[Ui.selected_index]
	if not branch then
		return
	end

	-- Strip leading asterisk/spaces and trailing emojis (like 💣)
	local clean_branch = branch:gsub("^%*%s*", ""):gsub("%s*💣%s*$", ""):gsub("%s+", "")

	if vim.fn.confirm("Delete branch '" .. clean_branch .. "'?", "Yes\nNo", 2) == 1 then
		local out = vim.fn.system("git branch -D " .. vim.fn.shellescape(clean_branch))
		if vim.v.shell_error == 0 then
			vim.notify("Deleted branch: " .. clean_branch, vim.log.levels.INFO)
			-- Refresh branch view instead of closing UI
			require("gitcompanion.state").reload_with_fetch()
		else
			vim.notify("Failed to delete branch: " .. out, vim.log.levels.ERROR)
		end
	end
end

function M.open_commit_or_checkout_popup()
	local Ui = State.Ui

	if Ui.mode == "branches" then
		local remotes = vim.fn.systemlist("git branch -r --format='%(refname:short)'")
		local missing = {}
		local local_set = {}
		for _, b in ipairs(Ui.branches or {}) do
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
			if Dialogs and Dialogs.show_centered_message then
				Dialogs.show_centered_message("No remote branches available to checkout.", "❄️")
			end
			return
		end

		local ui_info = vim.api.nvim_list_uis()[1]
		local width = math.floor(ui_info.width * 0.6)
		local max_height = math.floor(ui_info.height * 0.6)
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

		vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
			buffer = buf,
			callback = function()
				local line = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] or ""
				local q = line
				if q:sub(1, 2) == "> " then
					q = q:sub(3)
				else
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
			vim.cmd("stopinsert")
			if vim.api.nvim_win_is_valid(win) then
				vim.api.nvim_win_close(win, true)
			end
			if vim.api.nvim_buf_is_valid(buf) then
				vim.api.nvim_buf_delete(buf, { force = true })
			end
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
				if Dialogs and Dialogs.show_centered_message then
					Dialogs.show_centered_message("Failed to switch branch:\n" .. result, "❌")
				end
				return
			end
			Ui.branch_selected = choice
			if Dialogs and Dialogs.show_centered_message then
				Dialogs.show_centered_message("Switched to branch: " .. choice, "✅")
			end
			if Status and Status.load_branches_async then
				Status.load_branches_async()
			end
			Ui.selected_index = 1
			if Layout and Layout.refresh_ui then
				Layout.refresh_ui()
			end
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

		vim.keymap.set("i", "<C-j>", move_down, opts)
		vim.keymap.set("i", "<C-n>", move_down, opts)
		vim.keymap.set("i", "<Down>", move_down, opts)

		vim.keymap.set("i", "<C-k>", move_up, opts)
		vim.keymap.set("i", "<C-p>", move_up, opts)
		vim.keymap.set("i", "<Up>", move_up, opts)

		vim.keymap.set("i", "<CR>", confirm_selection, opts)
		vim.keymap.set("i", "<Esc>", close_popup, opts)
		vim.keymap.set("i", "<C-c>", close_popup, opts)

		vim.keymap.set("n", "j", move_down, opts)
		vim.keymap.set("n", "k", move_up, opts)
		vim.keymap.set("n", "<CR>", confirm_selection, opts)
		vim.keymap.set("n", "q", close_popup, opts)
		vim.keymap.set("n", "<Esc>", close_popup, opts)

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
	local height_diff = math.floor(vim.o.lines * 0.72)
	local spacing = 1
	local col = math.floor((vim.o.columns - width) / 2)

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

	local buf_diff = vim.api.nvim_create_buf(false, true)
	vim.bo[buf_diff].buftype = "nofile"
	vim.bo[buf_diff].bufhidden = "wipe"
	vim.bo[buf_diff].filetype = "diff"

	local diff_cmd = "git diff --cached"
	local diff_lines = vim.fn.systemlist(diff_cmd)
	if vim.v.shell_error ~= 0 or #diff_lines == 0 then
		diff_lines = { "[No staged changes]" }
	end
	vim.api.nvim_buf_set_lines(buf_diff, 0, -1, false, diff_lines)
	vim.bo[buf_diff].modifiable = false

	local buf_title = vim.api.nvim_create_buf(false, true)
	vim.bo[buf_title].buftype = "acwrite"
	vim.bo[buf_title].bufhidden = "wipe"
	vim.api.nvim_buf_set_lines(buf_title, 0, -1, false, { "" })

	local buf_desc = vim.api.nvim_create_buf(false, true)
	vim.bo[buf_desc].buftype = "acwrite"
	vim.bo[buf_desc].bufhidden = "wipe"
	vim.api.nvim_buf_set_lines(buf_desc, 0, -1, false, { "", "", "" })

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

	local function close_commit_popup()
		vim.cmd("stopinsert")

		for _, w in ipairs({ win_title, win_desc, win_diff, win_overlay }) do
			if vim.api.nvim_win_is_valid(w) then
				vim.api.nvim_win_close(w, true)
			end
		end

		for _, b in ipairs({ buf_title, buf_desc, buf_diff, buf_overlay }) do
			if vim.api.nvim_buf_is_valid(b) then
				vim.api.nvim_buf_delete(b, { force = true })
			end
		end

		if Ui.left_win and vim.api.nvim_win_is_valid(Ui.left_win) then
			vim.api.nvim_set_current_win(Ui.left_win)
		end
	end

	vim.api.nvim_buf_set_lines(buf_title, 0, -1, false, { "" })
	vim.cmd("startinsert")

	local function commit_changes()
		vim.cmd("stopinsert")

		local title = vim.api.nvim_buf_get_lines(buf_title, 0, -1, false)[1] or ""
		local body = table.concat(vim.api.nvim_buf_get_lines(buf_desc, 0, -1, false), "\n")

		local cmd = "git commit -m " .. vim.fn.shellescape(title)
		if body:match("%S") then
			cmd = cmd .. " -m " .. vim.fn.shellescape(body)
		end
		vim.fn.system(cmd)

		if Dialogs and Dialogs.show_centered_message then
			Dialogs.show_centered_message("Committed changes on branch: " .. branch, "🌸")
		end
		close_commit_popup()

		if Status and Status.load_branches_async then
			Status.load_branches_async()
		end
		if Status and Status.get_changed_files_async then
			Status.get_changed_files_async(Ui.branch_selected)
		end

		if #Ui.changed_files == 0 and Ui.mode == "files" then
			Ui.mode = "branches"
			Ui.selected_index = 1
			if Layout and Layout.update_window_layout then
				Layout.update_window_layout()
			end
		end

		if Layout and Layout.refresh_ui then
			Layout.refresh_ui()
		end
	end

	for _, b in ipairs({ buf_title, buf_desc, buf_diff }) do
		vim.keymap.set("n", "q", close_commit_popup, { buffer = b, noremap = true, silent = true })
		vim.keymap.set("n", "<Esc>", close_commit_popup, { buffer = b, noremap = true, silent = true })
		vim.keymap.set("i", "<Esc>", close_commit_popup, { buffer = b, noremap = true, silent = true })
		vim.keymap.set("i", "<C-c>", close_commit_popup, { buffer = b, noremap = true, silent = true })

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

	vim.api.nvim_set_current_win(win_title)
end

return M
