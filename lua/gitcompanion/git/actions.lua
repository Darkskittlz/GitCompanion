local M = {}

local State = require("gitcompanion.state")

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

function M.stage_unstage_selected()
	local Ui = State.Ui
	local item = Ui.visible_tree_lines and Ui.visible_tree_lines[Ui.selected_index]
	local node = item and item.node
	if not node then
		return
	end

	if node.is_dir then
		local leaf_nodes = collect_child_files(node)

		-- If any file under directory is unstaged, stage everything. Otherwise unstage all.
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
		-- Single file handler
		node.staged = not node.staged
		if node.staged then
			vim.fn.system({ "git", "add", node.path })
		else
			vim.fn.system({ "git", "restore", "--staged", node.path })
		end
	end

	if Layout and Layout.refresh_ui then
		Layout.refresh_ui()
	end
end

function M.discard_changes_selected()
	local Ui = State.Ui
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

	local root = Status and Status.git_root and Status.git_root() or "."
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

	if Layout and Layout.refresh_ui then
		Layout.refresh_ui()
	end
	print("UI refreshed")
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

function M.delete_branch()
	local Ui = State.Ui
	if Ui.mode ~= "branches" then
		return
	end

	local branch = Ui.branches[Ui.selected_index]
	if not branch then
		return
	end

	local ok_confirm = vim.fn.confirm("Delete branch " .. branch .. "?", "Yes\nNo", 2)
	if ok_confirm ~= 1 then
		return
	end

	local out = vim.fn.system("git branch -D " .. vim.fn.shellescape(branch))
	if vim.v.shell_error ~= 0 then
		if Dialogs and Dialogs.show_centered_message then
			Dialogs.show_centered_message("Failed to delete branch: " .. out, vim.log.levels.ERROR)
		end
	else
		if Dialogs and Dialogs.show_centered_message then
			Dialogs.show_centered_message("Deleted branch: " .. branch, vim.log.levels.INFO)
		end
	end

	if Status and Status.load_branches_async then
		Status.load_branches_async()
	end
	if Layout and Layout.refresh_ui then
		Layout.refresh_ui()
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
