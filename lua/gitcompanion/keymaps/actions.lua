-- lua/gitcompanion/keymaps/actions.lua
local git_actions = require("gitcompanion.git.actions")

local M = {}

function M.attach(buf, state)
	local Ui = state.Ui or state

	-- local function debug_log(msg)
	-- 	vim.schedule(function()
	-- 		vim.notify("[GitCompanion Keymaps] " .. msg, vim.log.levels.DEBUG)
	-- 	end)
	-- end

	for _, b in ipairs({ Ui.left_buf, Ui.right_buf, Ui.diff_buf }) do
		if b and vim.api.nvim_buf_is_valid(b) then
			-- vim.notify(
			--    string.format("[Keymap] Executing Space | Mode: %s | Index: %s", Ui.mode, tostring(Ui.selected_index)),
			--    vim.log.levels.DEBUG
			-- )
			vim.keymap.set("n", "<Space>", function()
				local current_win = vim.api.nvim_get_current_win()
				local expected_win = Ui and Ui.left_win or nil

				-- Check window match
				if current_win ~= expected_win then
					return
				end

				if Ui.mode == "files" then
					if type(git_actions.stage_unstage_selected) == "function" then
						git_actions.stage_unstage_selected()
					end
				elseif Ui.mode == "branches" then
					-- 1. Grab the branch name directly under the cursor line
					local cursor_line = vim.api.nvim_get_current_line()
					-- Strip git markers (*, +, leading whitespace, glyphs)
					local target_branch = cursor_line:gsub("^[%*%+%s]*", ""):match("^%S+")

					if not target_branch or target_branch == "" then
						vim.notify("No valid branch under cursor", vim.log.levels.WARN)
						return
					end

					-- Instead of blocking with vim.fn.system, check against cached state or run async
					local current_branch = Ui.current_branch
					if not current_branch or current_branch == "" then
						current_branch = vim.fn.trim(Ui.branch_selected or "")
					end

					if target_branch == current_branch then
						vim.notify("Already on branch '" .. target_branch .. "'", vim.log.levels.INFO)
						return
					end

					-- 2. Execute git checkout asynchronously via jobstart
					vim.fn.jobstart({ "git", "checkout", target_branch }, {
						on_exit = function(_, exit_code)
							vim.schedule(function()
								if exit_code == 0 then
									Ui.branch_selected = target_branch
									Ui.current_branch = target_branch

									-- Find and update selected_index for the new branch in the list
									if Ui.branches then
										for idx, b in ipairs(Ui.branches) do
											local clean_b = b:gsub("^%*%s*", ""):gsub("%s+$", "")
											if clean_b == target_branch then
												Ui.selected_index = idx
												break
											end
										end
									end

									-- Snap cursor directly to the newly checked-out branch line
									if Ui.left_win and vim.api.nvim_win_is_valid(Ui.left_win) and Ui.selected_index then
										pcall(vim.api.nvim_win_set_cursor, Ui.left_win, { Ui.selected_index, 0 })
									end

									-- Immediately fetch and render commit log data for the new branch
									local data_mod = package.loaded["gitcompanion.git.data"]
										or require("gitcompanion.git.data")
									if data_mod and type(data_mod.load_commits_async) == "function" then
										data_mod.load_commits_async(target_branch, function(commits)
											Ui.commit_data_cache = Ui.commit_data_cache or {}
											Ui.commit_data_cache[target_branch] = commits

											-- Refresh right pane (commit log) view
											local layout_mod = package.loaded["gitcompanion.ui.layout"]
												or require("gitcompanion.ui.layout")
											if layout_mod and type(layout_mod.render_right) == "function" then
												layout_mod.render_right()
											end
										end)
									end

									-- Trigger layout refresh
									local layout_mod = package.loaded["gitcompanion.ui.layout"]
										or require("gitcompanion.ui.layout")
									if layout_mod and type(layout_mod.refresh_ui) == "function" then
										layout_mod.refresh_ui()
									end

									-- Trigger background reload safely
									local state_mod = require("gitcompanion.state")
									if type(state_mod.reload_with_fetch) == "function" then
										state_mod.reload_with_fetch(target_branch, function()
											if type(sync_selected_index) == "function" then
												sync_selected_index()
											end
										end)
									end

									vim.notify("Switched to branch '" .. target_branch .. "'", vim.log.levels.INFO)
								else
									vim.notify(
										"Failed to checkout branch '" .. target_branch .. "'",
										vim.log.levels.ERROR
									)
								end
							end)
						end,
					})
				elseif Ui.mode == "stashes" then
					local stash = Ui.stashes and Ui.stashes[Ui.selected_index]
					if stash then
						local ref = stash:match("(stash@{%d+})")
						if ref then
							local ok = vim.fn.confirm("Pop " .. ref .. "?", "Yes\nNo", 2)
							if ok == 1 then
								local out = vim.fn.system("git stash pop " .. vim.fn.shellescape(ref))
								if vim.v.shell_error == 0 then
									if state.show_centered_message then
										state.show_centered_message("Successfully popped " .. ref, "✅")
									end
								else
									if state.show_centered_message then
										state.show_centered_message("Merge conflict or error popping stash", "⚠️")
									end
								end

								if type(state.load_stashes) == "function" then
									state.load_stashes()
								end
								Ui.selected_index = math.max(1, (Ui.selected_index or 1) - 1)
								if type(state.refresh_ui) == "function" then
									state.refresh_ui()
								end
							end
						end
					end
				end
			end, { buffer = b, noremap = true, silent = true, desc = "Toggle stage/checkout/pop stash" })
		end
	end
end

return M
