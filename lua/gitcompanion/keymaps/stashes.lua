local M = {}

local function debug_log(msg)
	vim.schedule(function()
		vim.notify("[GitCompanion Stashes Debug] " .. msg, vim.log.levels.DEBUG)
	end)
end

function M.attach(buf, state)
	local state_mod = require("gitcompanion.state")
	state = vim.tbl_extend("keep", state or {}, state_mod)

	local Ui = state.Ui or state
	local left_buf = Ui.left_buf

	if not left_buf or not vim.api.nvim_buf_is_valid(left_buf) then
		debug_log("Attach skipped: Invalid left_buf (" .. tostring(left_buf) .. ")")
		return
	end

	debug_log("Attaching stash keymaps to left_buf: " .. tostring(left_buf))
	local opts = { buffer = left_buf, noremap = true, silent = true }

	-- Parse stash reference OR fallback to index format "stash@{idx}"
	local function get_selected_stash()
		if Ui.mode ~= "stashes" then
			return nil
		end

		local idx = Ui.selected_index or 1
		local stash_line = Ui.stashes and Ui.stashes[idx]
		if not stash_line or stash_line == "" then
			return nil
		end

		local stash_ref = stash_line:match("^(stash@{%d+})")
		if not stash_ref then
			stash_ref = string.format("stash@{%d}", idx - 1)
		end
		return stash_ref
	end

	-- 's' - Interactive Floating Modal Create Stash
	vim.keymap.set("n", "s", function()
		local lines = {
			"  1. Staged changes only (--staged)",
			"  2. Unstaged changes only (--keep-index)",
			"  3. All changes",
		}

		local buf = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

		-- Calculate position for centered float modal
		local width = 46
		local height = #lines
		local win_width = vim.api.nvim_get_option("columns")
		local win_height = vim.api.nvim_get_option("lines")
		local row = math.floor((win_height - height) / 2)
		local col = math.floor((win_width - width) / 2)

		local win = vim.api.nvim_open_win(buf, true, {
			relative = "editor",
			width = width,
			height = height,
			row = row,
			col = col,
			style = "minimal",
			border = "rounded",
			title = " Create Stash ",
			title_pos = "center",
		})

		local function close_modal()
			if vim.api.nvim_win_is_valid(win) then
				vim.api.nvim_win_close(win, true)
			end
		end

		local function execute_stash(stash_type)
			close_modal()
			vim.ui.input({ prompt = "Stash message (optional): " }, function(msg)
				local msg_arg = (msg and #msg > 0) and string.format(" -m %s", vim.fn.shellescape(msg)) or ""
				local cmd

				if stash_type == 1 then
					cmd = "git stash push --staged" .. msg_arg
				elseif stash_type == 2 then
					cmd = "git stash push --keep-index" .. msg_arg
				else
					cmd = "git stash push" .. msg_arg
				end

				debug_log("Executing CLI command: " .. cmd)
				local out = vim.fn.system(cmd)
				debug_log("CLI Result (code " .. tostring(vim.v.shell_error) .. "): " .. tostring(out))

				if vim.v.shell_error == 0 then
					if state.show_centered_message then
						state.show_centered_message("Stashed changes", "📦")
					end

					vim.defer_fn(function()
						-- Switch active tab mode to stashes explicitly
						Ui.mode = "stashes"
						state_mod.reload_stashes(function()
							if type(state_mod.refresh_ui) == "function" then
								state_mod.refresh_ui()
							end
						end)
					end, 100)
				else
					vim.notify("Stash failed: " .. out, vim.log.levels.ERROR)
				end
			end)
		end

		local map_opts = { buffer = buf, noremap = true, silent = true }

		vim.keymap.set("n", "1", function()
			execute_stash(1)
		end, map_opts)
		vim.keymap.set("n", "2", function()
			execute_stash(2)
		end, map_opts)
		vim.keymap.set("n", "3", function()
			execute_stash(3)
		end, map_opts)

		vim.keymap.set("n", "q", close_modal, map_opts)
		vim.keymap.set("n", "<Esc>", close_modal, map_opts)
	end, vim.tbl_extend("force", opts, { desc = "Create stash menu" }))

	-- 'a' - Apply Stash
	vim.keymap.set("n", "a", function()
		local stash = get_selected_stash()
		if not stash then
			return
		end

		local out = vim.fn.system("git stash apply " .. stash)
		if vim.v.shell_error == 0 then
			if state.show_centered_message then
				state.show_centered_message("Applied " .. stash, "📦")
			end
			vim.defer_fn(function()
				state_mod.reload_stashes()
			end, 80)
		else
			vim.notify("Failed to apply stash: " .. out, vim.log.levels.ERROR)
		end
	end, vim.tbl_extend("force", opts, { desc = "Apply selected stash" }))

	-- 'p' - Pop Stash
	vim.keymap.set("n", "p", function()
		local stash = get_selected_stash()
		if not stash then
			return
		end

		local out = vim.fn.system("git stash pop " .. stash)
		if vim.v.shell_error == 0 then
			if state.show_centered_message then
				state.show_centered_message("Popped " .. stash, "💥")
			end
			vim.defer_fn(function()
				state_mod.reload_stashes()
			end, 80)
		else
			vim.notify("Failed to pop stash: " .. out, vim.log.levels.ERROR)
		end
	end, vim.tbl_extend("force", opts, { desc = "Pop selected stash" }))

	-- 'd' - Drop Stash
	vim.keymap.set("n", "d", function()
		local stash = get_selected_stash()
		if not stash then
			return
		end

		vim.ui.input({ prompt = "Type 'y' to drop " .. stash .. ": " }, function(confirm)
			if confirm ~= "y" then
				return
			end
			local out = vim.fn.system("git stash drop " .. stash)
			if vim.v.shell_error == 0 then
				if state.show_centered_message then
					state.show_centered_message("Dropped " .. stash, "🗑️")
				end
				state_mod.reload_stashes()
			else
				vim.notify("Failed to drop stash: " .. out, vim.log.levels.ERROR)
			end
		end)
	end, vim.tbl_extend("force", opts, { desc = "Drop selected stash" }))

	-- 'y' - Yank Reference
	vim.keymap.set("n", "y", function()
		local stash = get_selected_stash()
		if not stash then
			return
		end
		vim.fn.setreg('"', stash)
		vim.fn.setreg("+", stash)
		if state.show_centered_message then
			state.show_centered_message("Yanked: " .. stash, "📋")
		end
	end, vim.tbl_extend("force", opts, { desc = "Yank stash reference" }))
end

return M
