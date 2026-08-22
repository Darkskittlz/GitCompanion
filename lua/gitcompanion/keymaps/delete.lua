-- lua/gitcompanion/keymaps/delete.lua
local M = {}
local git_actions = require("gitcompanion.git.actions")

function M.attach(buf, state)
	local state_mod = state or _G.State or {}

	-- Target all active plugin buffers so the keymap isn't missed
	local buffers = { buf }
	local Ui = state_mod.Ui or _G.Ui or {}
	for _, b in ipairs({ Ui.left_buf, Ui.right_buf, Ui.diff_buf }) do
		if b and vim.api.nvim_buf_is_valid(b) and not vim.tbl_contains(buffers, b) then
			table.insert(buffers, b)
		end
	end

	for _, b in ipairs(buffers) do
		vim.keymap.set("n", "d", function()
			local active_ui = state_mod.Ui or _G.Ui or {}
			local current_win = vim.api.nvim_get_current_win()
			local current_buf = vim.api.nvim_get_current_buf()

			print(
				string.format(
					"[Debug 'd'] win: %s | left_win: %s | buf: %s | left_buf: %s",
					tostring(current_win),
					tostring(active_ui.left_win),
					tostring(current_buf),
					tostring(active_ui.left_buf)
				)
			)

			-- Match by Window Handle OR Buffer ID (if window handle shifted)
			local is_left_pane = (current_win == active_ui.left_win) or (current_buf == active_ui.left_buf)

			if is_left_pane then
				-- Sync selected index to current cursor line
				local cursor_line = vim.api.nvim_win_get_cursor(0)[1]
				active_ui.selected_index = cursor_line

				if active_ui.mode == "files" then
					print("[Debug 'd'] Executing git_actions.discard_changes_selected()")
					if type(git_actions.discard_changes_selected) == "function" then
						git_actions.discard_changes_selected()
					end
				elseif active_ui.mode == "stashes" then
					local stash = active_ui.stashes and active_ui.stashes[active_ui.selected_index]
					if stash then
						local ref = stash:match("(stash@{%d+})")
						if ref and vim.fn.confirm("Drop " .. ref .. "?", "Yes\nNo", 2) == 1 then
							vim.fn.system("git stash drop " .. vim.fn.shellescape(ref))
							if type(state_mod.load_stashes) == "function" then
								state_mod.load_stashes()
							end
							active_ui.selected_index = math.max(1, (active_ui.selected_index or 1) - 1)
							if type(state_mod.refresh_ui) == "function" then
								state_mod.refresh_ui()
							end
						end
					end
				elseif active_ui.mode == "branches" then
					if type(state_mod.delete_branch) == "function" then
						state_mod.delete_branch()
					end
				end

			-- Match Right Window
			elseif (current_win == active_ui.right_win) or (current_buf == active_ui.right_buf) then
				local cursor = vim.api.nvim_win_get_cursor(0)
				local line = vim.api.nvim_buf_get_lines(active_ui.right_buf or 0, cursor[1] - 1, cursor[1], false)[1]
				local hash = line and line:match("([0-9a-f]+)")

				if hash and vim.fn.confirm("Revert commit " .. hash:sub(1, 7) .. "?", "Yes\nNo", 2) == 1 then
					local out = vim.fn.system("git revert --no-edit " .. vim.fn.shellescape(hash))
					if vim.v.shell_error == 0 then
						if type(state_mod.refresh_ui) == "function" then
							state_mod.refresh_ui()
						end
					else
						vim.notify("Failed to revert commit: " .. out, vim.log.levels.ERROR)
					end
				end
			end
		end, {
			buffer = b,
			noremap = true,
			silent = false, -- Set to false to ensure print debug statements hit command line / :messages
			nowait = true,
			desc = "Discard changes, drop stash, delete branch, or revert commit",
		})
	end
end

return M
