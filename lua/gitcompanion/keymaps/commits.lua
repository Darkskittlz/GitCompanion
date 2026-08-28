-- lua/gitcompanion/keymaps/commits.lua
local reset = require("gitcompanion.git.reset")
local dialogs = require("gitcompanion.ui.dialogs")
local M = {}

--- Opens interactive fuzzy picker for checking out remote branches
local function checkout_remote_branch(state)
	local Ui = state.Ui or state
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
		if state.show_centered_message then
			state.show_centered_message("No remote branches available to checkout.", "❄️")
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
			if state.show_centered_message then
				state.show_centered_message("Failed to switch branch:\n" .. result, "❌")
			end
			return
		end

		Ui.branch_selected = choice
		if state.show_centered_message then
			state.show_centered_message("Switched to branch: " .. choice, "✅")
		end

		if state.load_branches_async then
			state.load_branches_async()
		end
		Ui.selected_index = 1
		if state.refresh_ui then
			state.refresh_ui()
		end
	end

	local map_opts = { buffer = buf, noremap = true, silent = true }

	local function move_down()
		selected = math.min(#filtered, selected + 1)
		render()
	end

	local function move_up()
		selected = math.max(1, selected - 1)
		render()
	end

	vim.keymap.set("i", "<C-j>", move_down, map_opts)
	vim.keymap.set("i", "<C-n>", move_down, map_opts)
	vim.keymap.set("i", "<Down>", move_down, map_opts)
	vim.keymap.set("i", "<C-k>", move_up, map_opts)
	vim.keymap.set("i", "<C-p>", move_up, map_opts)
	vim.keymap.set("i", "<Up>", move_up, map_opts)
	vim.keymap.set("i", "<CR>", confirm_selection, map_opts)
	vim.keymap.set("i", "<Esc>", close_popup, map_opts)
	vim.keymap.set("i", "<C-c>", close_popup, map_opts)

	vim.keymap.set("n", "j", move_down, map_opts)
	vim.keymap.set("n", "k", move_up, map_opts)
	vim.keymap.set("n", "<CR>", confirm_selection, map_opts)
	vim.keymap.set("n", "q", close_popup, map_opts)
	vim.keymap.set("n", "<Esc>", close_popup, map_opts)

	vim.cmd("startinsert!")
	vim.api.nvim_win_set_cursor(win, { 1, 2 })
end

function M.attach(buf, state)
	local Ui = state.Ui or state

	-- Bind 'c' globally across active context buffers
	for _, b in ipairs({ Ui.left_buf, Ui.right_buf, Ui.diff_buf }) do
		if b and vim.api.nvim_buf_is_valid(b) then
			vim.keymap.set("n", "c", function()
				if Ui.mode == "branches" then
					checkout_remote_branch(state)
				elseif Ui.mode == "files" then
					dialogs.open_commit_modal(state)
				end
			end, { buffer = b, noremap = true, silent = true, desc = "Checkout remote or create commit" })
		end
	end

	local right_buf = Ui.right_buf
	if not right_buf or not vim.api.nvim_buf_is_valid(right_buf) then
		return
	end

	local right_opts = { buffer = right_buf, noremap = true, silent = true }

	-- Bind 'g' on right buffer for commit resets
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

		-- Strip leading graph characters, spaces, and asterisks to isolate the hash
		local clean_line = line:gsub("[%*|\\/%_%-%s]+", " ")
		local hash = clean_line:match("(%x%x%x%x%x%x%x+)")
		if not hash then
			return
		end

		reset.open_reset_modal(hash, state)
	end, vim.tbl_extend("force", right_opts, { desc = "Reset/rebase options on commit" }))

	-- Bind 'r' on right buffer for renaming/reword commit
	vim.keymap.set("n", "r", function()
		local cursor = vim.api.nvim_win_get_cursor(Ui.right_win)
		local line = vim.api.nvim_buf_get_lines(Ui.right_buf, cursor[1] - 1, cursor[1], false)[1] or ""

		local hash = line:match("%f[%w](%x%x%x%x%x%x%x+)%f[%W]") or line:match("(%x%x%x%x%x%x%x+)")
		if not hash then
			vim.notify("Git: No valid commit hash found on current line.", vim.log.levels.WARN)
			return
		end

		local full_hash = vim.fn.system("git rev-parse " .. hash):gsub("%s+", "")
		local head_hash = vim.fn.system("git rev-parse HEAD"):gsub("%s+", "")
		local is_head = (full_hash == head_hash)

		local current_msg = vim.fn.system("git log -1 --format=%s " .. hash):gsub("%s+$", "")

		vim.ui.input({
			prompt = "Rename commit (" .. hash:sub(1, 7) .. "): ",
			default = current_msg,
		}, function(new_msg)
			if not new_msg or new_msg == "" or new_msg == current_msg then
				return
			end

			local success = false
			local out = ""

			if is_head then
				local cmd = "git commit --amend -m " .. vim.fn.shellescape(new_msg)
				out = vim.fn.system(cmd)
				success = (vim.v.shell_error == 0)
			else
				local stashed = false
				local status = vim.fn.system("git status --porcelain -uall"):gsub("%s+$", "")
				if #status > 0 then
					vim.fn.system("git stash push -m 'temp_reword_stash'")
					stashed = true
				end

				local tmp_msg_file = vim.fn.tempname()
				local f = io.open(tmp_msg_file, "w")
				if f then
					f:write(new_msg .. "\n")
					f:close()
				else
					vim.notify("Git: Failed to create temp file for commit message.", vim.log.levels.ERROR)
					return
				end

				local git_cmd = string.format(
					"GIT_SEQUENCE_EDITOR=\"sed -i '' 's/^pick %s/reword %s/' 2>/dev/null || sed -i 's/^pick %s/reword %s/'\" "
						.. "GIT_EDITOR=\"cp '%s'\" "
						.. "git rebase -i -r %s~1",
					hash:sub(1, 7),
					hash:sub(1, 7),
					hash:sub(1, 7),
					hash:sub(1, 7),
					tmp_msg_file,
					hash
				)

				out = vim.fn.system(git_cmd)
				success = (vim.v.shell_error == 0)

				if not success then
					vim.fn.system("git rebase --abort")
				end

				if stashed then
					vim.fn.system("git stash pop")
				end

				os.remove(tmp_msg_file)
			end

			if success then
				local state_mod = require("gitcompanion.state")

				if type(state.show_centered_message) == "function" then
					state.show_centered_message("Renamed commit " .. hash:sub(1, 7), "✏️")
				end

				-- Direct call: invalidates target branch cache & runs async reload
				state_mod.reload_with_fetch(Ui.current_branch or Ui.branch_selected)
			else
				vim.notify("Failed to reword commit: " .. out, vim.log.levels.ERROR)
			end
		end)
	end, vim.tbl_extend("force", right_opts, { desc = "Rename commit under cursor" }))

	-- Bind 'y' on right buffer for yanking commit metadata
	vim.keymap.set("n", "y", function()
		local cursor = vim.api.nvim_win_get_cursor(Ui.right_win)
		local line = vim.api.nvim_buf_get_lines(Ui.right_buf, cursor[1] - 1, cursor[1], false)[1] or ""
		local hash = line:match("^(%S+)")

		if not hash then
			vim.notify("Git: No valid commit hash found on current line.", vim.log.levels.WARN)
			return
		end

		local options = {
			" 1. ID",
			" 2. Title",
			" 3. Description",
			" 4. Author",
			" 5. Time",
		}

		local buf = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, options)

		local width = 30
		local height = #options
		local ui = vim.api.nvim_list_uis()[1]
		local row = math.floor((ui.height - height) / 2)
		local col = math.floor((ui.width - width) / 2)

		local float_win = vim.api.nvim_open_win(buf, true, {
			relative = "editor",
			width = width,
			height = height,
			row = row,
			col = col,
			style = "minimal",
			border = "rounded",
			title = " Copy Commit ",
			title_pos = "center",
		})

		vim.bo[buf].modifiable = false
		vim.bo[buf].bufhidden = "wipe"
		vim.wo[float_win].cursorline = true

		local raw_hash = line:match("([a-f0-9]+)") or hash
		local clean_hash = vim.fn.shellescape(raw_hash)

		local function perform_yank(choice_num)
			if vim.api.nvim_win_is_valid(float_win) then
				vim.api.nvim_win_close(float_win, true)
			end

			local text_to_yank = ""
			local choice_name = ""

			if choice_num == 1 then
				choice_name = "ID"
				text_to_yank = vim.fn.system("git rev-parse " .. clean_hash):gsub("%s+", "")
			elseif choice_num == 2 then
				choice_name = "Title"
				text_to_yank = vim.fn.system("git log -1 --format=%s " .. clean_hash):gsub("%s+$", "")
			elseif choice_num == 3 then
				choice_name = "Description"
				text_to_yank = vim.fn.system("git log -1 --format=%b " .. clean_hash):gsub("%s+$", "")
			elseif choice_num == 4 then
				choice_name = "Author"
				text_to_yank = vim.fn.system("git log -1 --format='%an <%ae>' " .. clean_hash):gsub("%s+$", "")
			elseif choice_num == 5 then
				choice_name = "Time"
				text_to_yank = vim.fn.system("git log -1 --format=%cd " .. clean_hash):gsub("%s+$", "")
			end

			if text_to_yank ~= "" then
				vim.fn.setreg('"', text_to_yank)
				vim.fn.setreg("+", text_to_yank)
				if state.show_centered_message then
					state.show_centered_message("Yanked " .. choice_name .. ": " .. text_to_yank:sub(1, 35), "📋")
				end
			end
		end

		local m_opts = { buffer = buf, noremap = true, silent = true }
		for i = 1, 5 do
			vim.keymap.set("n", tostring(i), function()
				perform_yank(i)
			end, m_opts)
		end

		vim.keymap.set("n", "<CR>", function()
			local line_num = vim.api.nvim_win_get_cursor(float_win)[1]
			perform_yank(line_num)
		end, m_opts)

		for _, key in ipairs({ "<Esc>", "q" }) do
			vim.keymap.set("n", key, function()
				if vim.api.nvim_win_is_valid(float_win) then
					vim.api.nvim_win_close(float_win, true)
				end
			end, m_opts)
		end
	end, vim.tbl_extend("force", right_opts, { desc = "Yank commit metadata" }))
end

return M
