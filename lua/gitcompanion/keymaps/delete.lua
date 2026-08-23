-- lua/gitcompanion/keymaps/delete.lua
local M = {}
local git_actions = require("gitcompanion.git.actions")

function M.attach(buf, state)
	if not buf or not vim.api.nvim_buf_is_valid(buf) then
		return
	end

	local state_mod = state or _G.State or {}

	-- Helper to trigger UI refresh reliably
	local function trigger_refresh()
		vim.schedule(function()
			if type(state_mod.reload_with_fetch) == "function" then
				state_mod.reload_with_fetch()
			elseif type(state_mod.refresh_ui) == "function" then
				state_mod.refresh_ui()
			end
		end)
	end

	vim.keymap.set("n", "x", function()
		vim.schedule(function()
			-- vim.notify("[GitCompanion Keymaps] 'x' pressed in buffer: " .. tostring(buf), vim.log.levels.DEBUG)
		end)

		local active_ui = state_mod.Ui or _G.Ui or {}
		local current_win = vim.api.nvim_get_current_win()
		local current_buf = vim.api.nvim_get_current_buf()

		-- Determine if the active window/buffer belongs to the left or right pane
		local is_right_pane = (current_win == active_ui.right_win)
			or (current_buf == active_ui.right_buf)
			or (active_ui.mode == "commits")

		local is_left_pane = not is_right_pane
			and ((current_win == active_ui.left_win) or (current_buf == active_ui.left_buf) or (current_buf == buf))

		if is_left_pane then
			local cursor_line = vim.api.nvim_win_get_cursor(0)[1]
			active_ui.selected_index = cursor_line

			if active_ui.mode == "files" then
				if type(git_actions.discard_changes_selected) == "function" then
					git_actions.discard_changes_selected()
					trigger_refresh()
				else
					-- vim.notify("[GitCompanion Error] discard_changes_selected not found", vim.log.levels.ERROR)
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
						trigger_refresh()
					end
				end
			elseif active_ui.mode == "branches" then
				local delete_fn = git_actions.delete_branch or state_mod.delete_branch
				if type(delete_fn) == "function" then
					delete_fn()
					trigger_refresh()
				else
					-- vim.notify("[GitCompanion Error] delete_branch function not found", vim.log.levels.ERROR)
				end
			end
		elseif is_right_pane then
			local cursor = vim.api.nvim_win_get_cursor(0)
			local line = vim.api.nvim_buf_get_lines(current_buf, cursor[1] - 1, cursor[1], false)[1] or ""
			local hash = line:match("([0-9a-fA-F]+)")

			if not hash or #hash < 4 then
				vim.notify("No valid commit selected to drop!", vim.log.levels.WARN)
				return
			end

			local short_hash = hash:sub(1, 7)
			if vim.fn.confirm("Drop commit " .. short_hash .. "?", "Yes\nNo", 2) == 1 then
				-- Pass --autostash so git automatically stashes local changes before rebasing and restores them after
				local safe_hash = vim.fn.shellescape(hash)
				local cmd = string.format("git rebase --autostash --onto %s~1 %s", safe_hash, safe_hash)
				local out = vim.fn.system(cmd)

				if vim.v.shell_error == 0 then
					vim.notify("Successfully dropped commit " .. short_hash, vim.log.levels.INFO)
					trigger_refresh()
				else
					if out:find("CONFLICT") then
						vim.notify(
							"Conflict while dropping commit "
								.. short_hash
								.. "!\nResolve conflicts or run 'git rebase --abort'.",
							vim.log.levels.ERROR
						)
					else
						vim.notify("Failed to drop commit: " .. out, vim.log.levels.ERROR)
					end
				end
			end
		end
	end, {
		buffer = buf,
		noremap = true,
		silent = true,
		nowait = true,
		desc = "Discard changes, drop stash, delete branch, or drop commit",
	})
end

return M
