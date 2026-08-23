local M = {}

function M.attach(buf, state)
	local Ui = state.Ui or state
	local target_buf = buf or Ui.left_buf

	if not target_buf or not vim.api.nvim_buf_is_valid(target_buf) then
		return
	end

	local base_opts = { buffer = target_buf, noremap = true, silent = true }

	local function map(mode, lhs, rhs, desc)
		vim.keymap.set(mode, lhs, rhs, vim.tbl_extend("force", base_opts, { desc = desc }))
	end

	-- Helper: Sync selected index with branch_selected name
	local function sync_selected_index()
		if not Ui.branches or not Ui.branch_selected then
			-- vim.notify("[Debug] sync_selected_index skipped: missing branches or branch_selected", vim.log.levels.WARN)
			return
		end
		for idx, b in ipairs(Ui.branches) do
			local clean_b = (b:gsub("^%*%s*", ""):gsub("%s+$", ""))
			if clean_b == Ui.branch_selected then
				Ui.selected_index = idx
				-- vim.notify(
				--    string.format("[Debug] Synced index to %d for branch '%s'", idx, clean_b),
				--    vim.log.levels.INFO
				-- )
				break
			end
		end
	end

	-- Helper: Get Selected Branch
	local function get_selected_branch()
		if Ui.mode ~= "branches" then
			return Ui.branch_selected or nil
		end

		local branch = nil
		if Ui.branches and Ui.selected_index and Ui.branches[Ui.selected_index] then
			branch = Ui.branches[Ui.selected_index]
		end

		if not branch or branch == "" then
			branch = Ui.branch_selected
		end

		if not branch or branch == "" then
			return nil
		end

		return branch:gsub("^%*%s*", ""):gsub("%s+$", "")
	end

	-- 'r' - Rename Selected Branch
	map("n", "r", function()
		local branch = get_selected_branch()
		if not branch then
			return
		end

		vim.ui.input({
			prompt = "Rename branch '" .. branch .. "': ",
			default = branch,
		}, function(new_branch)
			if not new_branch or new_branch == "" or new_branch == branch then
				return
			end

			local cmd = string.format("git branch -m %s %s", vim.fn.shellescape(branch), vim.fn.shellescape(new_branch))
			local out = vim.fn.system(cmd)

			if vim.v.shell_error == 0 then
				local state_mod = require("gitcompanion.state")

				-- Update internal references
				if Ui.branch_selected == branch then
					Ui.branch_selected = new_branch
				end
				if Ui.current_branch == branch then
					Ui.current_branch = new_branch
				end

				if type(state.show_centered_message) == "function" then
					state.show_centered_message("Renamed branch: " .. branch .. " ➔ " .. new_branch, "🌿")
				end

				-- Direct call: invalidates cache & triggers async fetch/reload pipeline
				state_mod.reload_with_fetch(new_branch, function()
					if type(sync_selected_index) == "function" then
						sync_selected_index()
					end
				end)
			else
				vim.notify("Failed to rename branch: " .. out, vim.log.levels.ERROR)
			end
		end)
	end, "Rename selected branch")

	-- 'y' - Yank Selected Branch Name
	map("n", "y", function()
		local branch = get_selected_branch()
		if not branch then
			return
		end

		vim.fn.setreg('"', branch)
		vim.fn.setreg("+", branch)
		if type(state.show_centered_message) == "function" then
			state.show_centered_message("Yanked branch: " .. branch, "🌿")
		end
	end, "Yank branch name")

	-- 'p' - Pull Branch
	map("n", "p", function()
		local branch = get_selected_branch()

		if not branch then
			if type(state.show_centered_message) == "function" then
				state.show_centered_message("No branch selected", "⚠️")
			end
			return
		end

		if type(state.show_centered_message) == "function" then
			state.show_centered_message("Pulling latest changes for branch: " .. branch, "⬇️")
		end

		-- Pass command arguments as an array to avoid shell escape issues
		vim.system({ "git", "pull", "origin", branch }, { text = true }, function(obj)
			vim.schedule(function()
				local exit_code = obj.code or 0
				local stdout_str = obj.stdout or ""
				local stderr_str = obj.stderr or ""
				local full_output = stdout_str .. "\n" .. stderr_str

				local stdout_lines = vim.split(stdout_str, "\n", { trimempty = true })
				local stderr_lines = vim.split(stderr_str, "\n", { trimempty = true })

				-- 1. Handle Merge Conflicts or Show Output Modal
				local has_conflict = exit_code ~= 0 and string.find(full_output, "CONFLICT")

				if has_conflict and state.conflicts and type(state.conflicts.handle_merge_result) == "function" then
					state.conflicts.handle_merge_result(full_output, exit_code)
				else
					-- Call show_floating_pair from layout/UI module or fallback to state
					local show_pair = state.show_floating_pair
						or (
							package.loaded["gitcompanion.ui.layout"]
							and package.loaded["gitcompanion.ui.layout"].show_floating_pair
						)

					if type(show_pair) == "function" then
						show_pair(stdout_lines, stderr_lines)
					end
				end

				-- 2. Clear commit graph and diff caches to force UI re-render
				if Ui then
					Ui.commit_graph_cache = {}
					Ui.diff_cache = {}
				end

				-- 3. Reload branches & trigger full re-render via state
				local refresh_fn = state.refresh_ui
					or (
						package.loaded["gitcompanion.ui.layout"] and package.loaded["gitcompanion.ui.layout"].refresh_ui
					)
				local load_branches_fn = state.load_branches_async
					or (state.status and state.status.load_branches_async)

				if type(load_branches_fn) == "function" then
					load_branches_fn(function(updated_branches)
						if updated_branches and Ui then
							Ui.branches = updated_branches
						end
						if type(sync_selected_index) == "function" then
							sync_selected_index()
						end
						if type(refresh_fn) == "function" then
							refresh_fn({ skip_fetch = true })
						end
					end)
				elseif type(refresh_fn) == "function" then
					if type(sync_selected_index) == "function" then
						sync_selected_index()
					end
					refresh_fn()
				end
			end)
		end)
	end, "Pull latest changes for branch")

	-- 'P' - Push Branch
	map("n", "P", function()
		local current_branch = get_selected_branch() or Ui.branch_selected or "HEAD"
		local remote = "origin"

		-- vim.notify(
		--    string.format(
		--       "[Push Init] Target branch: '%s' | Ui.branch_selected: '%s'",
		--       current_branch,
		--       tostring(Ui.branch_selected)
		--    ),
		--    vim.log.levels.INFO
		-- )

		local spinner_chars = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
		local spinner_idx = 1

		local spin_buf = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_buf_set_lines(
			spin_buf,
			0,
			-1,
			false,
			{ "Pushing to " .. current_branch .. " " .. spinner_chars[spinner_idx] }
		)

		local uis = vim.api.nvim_list_uis()
		local ui_width = uis[1] and uis[1].width or 80

		local win = vim.api.nvim_open_win(spin_buf, false, {
			relative = "editor",
			width = 50,
			height = 1,
			row = 3,
			col = math.floor((ui_width - 50) / 2),
			style = "minimal",
			border = "rounded",
			zindex = 50,
		})

		local uv = vim.uv or vim.loop
		local spinner_timer = uv.new_timer()

		local function stop_spinner()
			if spinner_timer and not spinner_timer:is_closing() then
				spinner_timer:stop()
				spinner_timer:close()
			end
			if vim.api.nvim_win_is_valid(win) then
				vim.api.nvim_win_close(win, true)
			end
		end

		spinner_timer:start(
			100,
			100,
			vim.schedule_wrap(function()
				if not vim.api.nvim_win_is_valid(win) then
					stop_spinner()
					return
				end
				spinner_idx = spinner_idx % #spinner_chars + 1
				vim.api.nvim_buf_set_lines(
					spin_buf,
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

			-- vim.notify("[Push Job] Running: " .. table.concat(args, " "), vim.log.levels.INFO)

			vim.fn.jobstart(args, {
				stdout_buffered = true,
				stderr_buffered = true,
				on_exit = function(_, exit_code, _)
					stop_spinner()
					vim.schedule(function()
						-- vim.notify(
						--    string.format("[Push Exit] Exit Code: %d", exit_code),
						--    exit_code == 0 and vim.log.levels.INFO or vim.log.levels.ERROR
						-- )

						if exit_code == 0 then
							if type(state.show_centered_message) == "function" then
								state.show_centered_message("✅ Successfully pushed branch: " .. current_branch)
							end

							if Ui.commit_graph_cache and Ui.branch_selected then
								Ui.commit_graph_cache[Ui.branch_selected] = nil
							end

							-- vim.notify(
							--    "[Reload] Directly calling data.load_branches_async with fetch...",
							--    vim.log.levels.INFO
							-- )

							-- Require data directly here to guarantee it exists
							local data = require("gitcompanion.git.data")

							data.load_branches_async({ fetch = true }, function()
								-- vim.notify("[Reload Callback] load_branches_async finished.", vim.log.levels.INFO)

								if type(sync_selected_index) == "function" then
									sync_selected_index()
								end

								if type(state.refresh_ui) == "function" then
									state.refresh_ui({ skip_fetch = true })
								end
							end)
						else
							if type(state.show_centered_message) == "function" then
								state.show_centered_message("⚠️ Failed to push branch: " .. current_branch)
							end
						end

						if Ui.commit_graph_cache and Ui.branch_selected then
							-- vim.notify(
							--    "[Cache Clear] Invalidated graph cache for: " .. tostring(Ui.branch_selected),
							--    vim.log.levels.INFO
							-- )
							Ui.commit_graph_cache[Ui.branch_selected] = nil
						end

						if type(state.load_branches_async) == "function" then
							-- vim.notify("[Reload] Triggering state.load_branches_async...", vim.log.levels.INFO)
							state.load_branches_async({ fetch = true }, function()
								-- vim.notify("[Reload Callback] load_branches_async finished.", vim.log.levels.INFO)
								sync_selected_index()
								if type(state.refresh_ui) == "function" then
									-- vim.notify("[UI] Invoking refresh_ui({ skip_fetch = true })", vim.log.levels.WARN)
									state.refresh_ui({ skip_fetch = true })
								else
									-- vim.notify("[UI Error] state.refresh_ui is not a function", vim.log.levels.ERROR)
								end
							end)
						elseif type(state.refresh_ui) == "function" then
							-- vim.notify("[Reload] Fallback triggering state.refresh_ui()...", vim.log.levels.INFO)
							sync_selected_index()
							state.refresh_ui()
						else
							-- vim.notify(
							--    "[Reload Error] Neither load_branches_async nor refresh_ui exist on state!",
							--    vim.log.levels.ERROR
							-- )
							if type(state.show_centered_message) == "function" then
								state.show_centered_message("⚠️ Failed to push branch: " .. current_branch)
							end
						end
					end)
				end,
			})
		end

		local dry_cmd = string.format("git push --dry-run -u %s %s 2>&1", remote, vim.fn.shellescape(current_branch))
		local dry_output = vim.fn.system(dry_cmd)

		if dry_output:match("rejected") or dry_output:match("non-fast-forward") then
			stop_spinner()
			vim.ui.input({
				prompt = "Branch has diverged. Force push? (y/N): ",
			}, function(answer)
				if answer and answer:lower() == "y" then
					do_push(true)
				else
					if type(state.show_centered_message) == "function" then
						state.show_centered_message("Push aborted.")
					end
				end
			end)
		else
			do_push(false)
		end
	end, "Push selected branch")

	-- 'n' - Create New Branch
	-- 'n' - Create New Branch
	map("n", "n", function()
		if vim.api.nvim_get_current_buf() ~= target_buf then
			return
		end

		local current_branch = get_selected_branch() or Ui.branch_selected or "HEAD"
		if not current_branch or current_branch == "" then
			vim.notify("No branch selected!", vim.log.levels.ERROR)
			return
		end

		local status = vim.fn.systemlist("git status --porcelain")
		if #status > 0 then
			if type(state.show_centered_message) == "function" then
				state.show_centered_message(
					"🚨 You have uncommitted changes!\nCommit or stash before branching.",
					"⚠️"
				)
			end
			return
		end

		local width, height = 50, 1
		local uis = vim.api.nvim_list_uis()
		local ui_width = uis[1] and uis[1].width or 80
		local input_buf = vim.api.nvim_create_buf(false, true)

		local input_win = vim.api.nvim_open_win(input_buf, true, {
			relative = "editor",
			width = width,
			height = height,
			row = 3,
			col = math.floor((ui_width - width) / 2),
			style = "minimal",
			border = "rounded",
			title = " Create New Branch: " .. current_branch .. " ",
			title_pos = "center",
			zindex = 50,
		})

		vim.cmd("startinsert")

		local function confirm_new_branch()
			vim.cmd("stopinsert")
			local lines = vim.api.nvim_buf_get_lines(input_buf, 0, 1, false)
			local new_branch = vim.trim(lines[1] or "")

			if vim.api.nvim_win_is_valid(input_win) then
				vim.api.nvim_win_close(input_win, true)
			end

			if new_branch == "" then
				return
			end

			local args = { "git", "checkout", "-b", new_branch, current_branch }

			vim.fn.jobstart(args, {
				stdout_buffered = true,
				stderr_buffered = true,
				on_exit = function(_, exit_code, _)
					vim.schedule(function()
						if exit_code == 0 then
							if type(state.show_centered_message) == "function" then
								state.show_centered_message("✅ Created and checked out branch: " .. new_branch)
							end

							Ui.branch_selected = new_branch
							Ui.current_branch = new_branch

							if Ui.commit_graph_cache then
								Ui.commit_graph_cache[new_branch] = nil
							end

							local data = require("gitcompanion.git.data")
							data.load_branches_async({ fetch = true }, function()
								if type(sync_selected_index) == "function" then
									sync_selected_index()
								end

								if type(state.refresh_ui) == "function" then
									state.refresh_ui({ skip_fetch = true })
								end
							end)
						else
							if type(state.show_centered_message) == "function" then
								state.show_centered_message("⚠️ Failed to create branch: " .. new_branch)
							else
								vim.notify("Failed to create branch '" .. new_branch .. "'", vim.log.levels.ERROR)
							end
						end
					end)
				end,
			})
		end

		vim.keymap.set({ "i", "n" }, "<CR>", confirm_new_branch, { buffer = input_buf, noremap = true, silent = true })

		vim.keymap.set({ "i", "n" }, "<Esc>", function()
			vim.cmd("stopinsert")
			if vim.api.nvim_win_is_valid(input_win) then
				vim.api.nvim_win_close(input_win, true)
			end
		end, { buffer = input_buf, noremap = true, silent = true })
	end, "Create new branch from selected")

	-- 'm' - Merge Menu
	map("n", "m", function()
		if Ui.mode ~= "branches" then
			return
		end

		local orig_win = vim.api.nvim_get_current_win()
		local target_branch = get_selected_branch()

		if not target_branch or target_branch == "" then
			vim.notify("No branch selected!", vim.log.levels.ERROR)
			return
		end

		local current_branch = vim.fn.trim(vim.fn.system("git branch --show-current"))
		if current_branch == target_branch then
			vim.notify("Cannot merge a branch into itself!", vim.log.levels.ERROR)
			return
		end

		local safe_target = vim.fn.shellescape(target_branch)
		local safe_current = vim.fn.shellescape(current_branch)

		local options = {
			{
				key = "m",
				label = "Regular merge",
				hl = "MergeBlue",
				desc = "Merge '" .. target_branch .. "' into '" .. current_branch .. "'.",
				cmd = "git merge " .. safe_target,
			},
			{
				key = "s",
				label = "Squash merge, leave uncommitted",
				hl = "MergeGreen",
				desc = "Squash commits without auto-committing.",
				cmd = "git merge --squash " .. safe_target,
			},
			{
				key = "S",
				label = "Squash merge and commit",
				hl = "MergeRed",
				desc = "Squash and commit automatically.",
				cmd = string.format(
					"git merge --squash %s && git commit -m 'Merge %s into %s'",
					safe_target,
					safe_target,
					safe_current
				),
			},
			{ key = "q", label = "Cancel", hl = "MergeWhite", desc = "Exit without merging.", cmd = nil },
		}

		local selected = 1
		local uis = vim.api.nvim_list_uis()
		local ui = uis[1] or { width = 80, height = 24 }
		local width, height = 52, #options + 3
		local row, col = math.floor((ui.height - height) / 2), math.floor((ui.width - width) / 2)

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

		local function render()
			local lines = {}
			for i, opt in ipairs(options) do
				lines[#lines + 1] = (i == selected and " " or "  ") .. opt.label
			end
			vim.api.nvim_buf_set_lines(buf_win, 0, -1, false, lines)
			vim.api.nvim_buf_clear_namespace(buf_win, -1, 0, -1)
			vim.api.nvim_buf_add_highlight(buf_win, -1, options[selected].hl, selected - 1, 0, -1)

			vim.api.nvim_buf_set_lines(buf_desc, 0, -1, false, { options[selected].desc })
			vim.api.nvim_buf_clear_namespace(buf_desc, -1, 0, -1)
			vim.api.nvim_buf_add_highlight(buf_desc, -1, options[selected].hl, 0, 0, -1)
		end
		render()

		vim.keymap.set("n", "j", function()
			selected = math.min(#options, selected + 1)
			render()
		end, { buffer = buf_win, noremap = true, silent = true })

		vim.keymap.set("n", "k", function()
			selected = math.max(1, selected - 1)
			render()
		end, { buffer = buf_win, noremap = true, silent = true })

		local function close_all()
			if vim.api.nvim_win_is_valid(win_desc) then
				vim.api.nvim_win_close(win_desc, true)
			end
			if vim.api.nvim_win_is_valid(win) then
				vim.api.nvim_win_close(win, true)
			end
			Ui.mode = "branches"
		end

		local function apply_selected()
			local opt = options[selected]
			close_all()

			if not opt or not opt.cmd then
				return
			end

			local stdout_lines, stderr_lines = {}, {}
			local state_mod = require("gitcompanion.state")

			vim.fn.jobstart(opt.cmd, {
				stdout_buffered = true,
				stderr_buffered = true,
				on_stdout = function(_, data)
					if data then
						for _, line in ipairs(data) do
							if line ~= "" then
								table.insert(stdout_lines, line)
							end
						end
					end
				end,
				on_stderr = function(_, data)
					if data then
						for _, line in ipairs(data) do
							if line ~= "" then
								table.insert(stderr_lines, line)
							end
						end
					end
				end,
				on_exit = function(_, exit_code)
					vim.schedule(function()
						local full_output = table.concat(stdout_lines, "\n") .. "\n" .. table.concat(stderr_lines, "\n")
						local has_conflict = exit_code ~= 0 and string.find(full_output, "CONFLICT")

						if has_conflict and state.conflicts and state.conflicts.handle_merge_result then
							state.conflicts.handle_merge_result(full_output, exit_code, orig_win)
						elseif type(state.show_floating_pair) == "function" then
							state.show_floating_pair(stdout_lines, stderr_lines)
						end

						-- Trigger full refresh pipeline after merge completes
						state_mod.reload_with_fetch(current_branch, function()
							if type(sync_selected_index) == "function" then
								sync_selected_index()
							end
						end)
					end)
				end,
			})
		end

		vim.keymap.set("n", "<CR>", apply_selected, { buffer = buf_win, noremap = true, silent = true })

		for idx, opt in ipairs(options) do
			vim.keymap.set("n", opt.key, function()
				selected = idx
				apply_selected()
			end, { buffer = buf_win, noremap = true, silent = true })
		end

		vim.keymap.set("n", "q", close_all, { buffer = buf_win, noremap = true, silent = true })
		vim.keymap.set("n", "<Esc>", close_all, { buffer = buf_win, noremap = true, silent = true })
	end, "Merge options")

	map("n", "x", function()
		-- Adjust the require path if your plugin name is different
		require("gitcompanion.git.actions").delete_branch()
	end, "Delete selected branch")
end

return M
