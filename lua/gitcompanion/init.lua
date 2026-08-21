---@diagnostic disable: undefined-global
local conflicts = require("gitcompanion.git.conflicts")
local config = require("gitcompanion.config")
local git_diff = require("gitcompanion.git.diff")

-- Require keymap submodules
local global_keymaps = require("gitcompanion.keymaps.global")
local branch_keymaps = require("gitcompanion.keymaps.branches")
local file_keymaps = require("gitcompanion.keymaps.files")
local stash_keymaps = require("gitcompanion.keymaps.stashes")

-- UI & Git modules
local ui_module = require("gitcompanion.ui")
local git_data = require("gitcompanion.git.data")
local graph = require("gitcompanion.git.graph")

local load_branches_async = git_data.load_branches_async
local get_changed_files_async = git_data.get_changed_files_async
local load_stashes = git_data.load_stashes

local refresh_ui = ui_module.refresh_ui
local render_right = ui_module.render_right
local render_diff = ui_module.render_diff
local update_window_layout = ui_module.update_window_layout
local reload_file_buffer = ui_module.reload_file_buffer
local toggle_mode = ui_module.toggle_mode
local show_help = ui_module.show_help
local toggle_tree_node = ui_module.toggle_tree_node
local show_centered_message = ui_module.show_centered_message
local init_ui = ui_module.init_ui

local M = {}

local function debug_log(msg, level)
	level = level or vim.log.levels.INFO
	vim.schedule(function()
		vim.notify("[GitCompanion Main] " .. msg, level)
	end)
end

local function get_ui()
	local current_state = require("gitcompanion.state")
	if not current_state.Ui then
		current_state.Ui = {}
	end
	return current_state.Ui
end

local function apply_highlights()
	for i, c in ipairs(config.options.graph_colors or {}) do
		vim.api.nvim_set_hl(0, "GitGraphSymbol" .. i, { fg = c })
	end

	vim.cmd([[
    highlight GitStaged guifg=green
    highlight GitStagedFile guifg=green
    highlight GitUnstaged guifg=orange
    highlight GitUnstagedFile guifg=orange
    highlight GitBranchCurrent guifg=#00BFFF

    highlight GitCompanionMarker guifg=#E5C07B gui=bold
    highlight GitCompanionOurs guibg=#2C323D guifg=#E06C75
    highlight GitCompanionTheirs guibg=#2C323D guifg=#98C379
   ]])
end

function M.close()
	debug_log("Closing UI and cleaning up windows/buffers")
	local Ui = get_ui()
	for _, buf_key in ipairs({ "diff_buf", "right_buf", "left_buf", "help_buf" }) do
		if Ui and Ui[buf_key] and vim.api.nvim_buf_is_valid(Ui[buf_key]) then
			pcall(vim.api.nvim_buf_delete, Ui[buf_key], { force = true })
			Ui[buf_key] = nil
		end
	end

	for _, win_key in ipairs({ "diff_win", "left_win", "right_win", "help_win" }) do
		if Ui and Ui[win_key] and vim.api.nvim_win_is_valid(Ui[win_key]) then
			pcall(vim.api.nvim_win_close, Ui[win_key], true)
			Ui[win_key] = nil
		end
	end
end

function M.apply_all_keymaps()
	local Ui = get_ui()
	local active_bufs = { Ui.left_buf, Ui.right_buf, Ui.diff_buf }

	local state = {
		Ui = Ui,
		conflicts = conflicts,
		close_ui = M.close,
		reload_file_buffer = reload_file_buffer,
		toggle_mode = toggle_mode,
		show_help = show_help,
		toggle_tree_node = toggle_tree_node,
		refresh_ui = refresh_ui,
		load_stashes = load_stashes,
		update_window_layout = update_window_layout,
		show_centered_message = show_centered_message,
	}

	for _, buf in ipairs(active_bufs) do
		if buf and vim.api.nvim_buf_is_valid(buf) then
			global_keymaps.attach(buf, state)
		end
	end

	if Ui.left_buf and vim.api.nvim_buf_is_valid(Ui.left_buf) then
		if Ui.mode == "branches" then
			branch_keymaps.attach(Ui.left_buf, state)
		elseif Ui.mode == "files" then
			file_keymaps.attach(Ui.left_buf, state)
		elseif Ui.mode == "stashes" then
			stash_keymaps.attach(Ui.left_buf, state)
		end
	end
end

function M.toggle(opts)
	local Ui = get_ui()

	if Ui and Ui.diff_win and vim.api.nvim_win_is_valid(Ui.diff_win) then
		debug_log("Toggle triggered: UI open -> closing")
		M.close()
		return
	end

	debug_log("Toggle triggered: Opening UI windows")

	-- Attach async graph loader to UI state
	Ui.fetch_git_graph_async = graph.fetch_git_graph_async

	-- Initialize Buffers
	for _, buf_key in ipairs({ "diff_buf", "right_buf", "left_buf", "help_buf" }) do
		if not Ui[buf_key] or not vim.api.nvim_buf_is_valid(Ui[buf_key]) then
			local buf = vim.api.nvim_create_buf(false, true)
			Ui[buf_key] = buf
			vim.bo[buf].buftype = "nofile"
			vim.bo[buf].bufhidden = "hide"
			vim.bo[buf].modifiable = true
		end
	end

	-- Initial Mode Selection
	if not Ui.mode then
		local changed = vim.fn.systemlist("git status --porcelain -uall")
		Ui.mode = (#changed > 0) and "files" or "branches"
		debug_log("Initial mode chosen: " .. tostring(Ui.mode) .. " (changed count: " .. #changed .. ")")
	end
	Ui.selected_index = Ui.selected_index or 1

	-- Screen Dimensions
	local active_ui = vim.api.nvim_list_uis()[1]
	local editor_w = active_ui and active_ui.width or vim.o.columns
	local editor_h = active_ui and active_ui.height or vim.o.lines

	local statusline_h = (vim.o.laststatus > 0) and 1 or 0
	local available_h = editor_h - vim.o.cmdheight - statusline_h

	local w = math.floor(editor_w * 0.9)
	local col = math.floor((editor_w - w) / 2)

	local help_h, branch_h, log_h, lower_h = 1, 4, 8, 8
	local help_row = available_h - help_h - 2
	local branch_row = help_row - branch_h - 2
	local log_row = branch_row - log_h - 2
	local lower_row = help_row - lower_h - 2

	local diff_row = 2
	local diff_h = (Ui.mode == "branches") and math.max(log_row - diff_row - 2, 1)
		or math.max(lower_row - diff_row - 2, 1)

	for _, win_key in ipairs({ "left_win", "right_win", "help_win" }) do
		if Ui[win_key] and vim.api.nvim_win_is_valid(Ui[win_key]) then
			pcall(vim.api.nvim_win_close, Ui[win_key], true)
			Ui[win_key] = nil
		end
	end

	-- Open Floating Windows
	Ui.diff_win = vim.api.nvim_open_win(Ui.diff_buf, true, {
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
		local left_title = " Files Changed "
		if Ui.mode == "stashes" then
			left_title = " Stashes "
		elseif Ui.has_conflicts then
			left_title = " ⚠️ Merge Conflicts Detected ⚠️ "
		end

		Ui.left_win = vim.api.nvim_open_win(Ui.left_buf, true, {
			relative = "editor",
			width = w,
			height = lower_h,
			row = lower_row,
			col = col,
			style = "minimal",
			border = "rounded",
			title = left_title,
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

	-- Render Help Footer
	local left_text = "[H] Branches ↔ Files Changed ↔ Stashes [L]"
	local right_text = "Press ? For Help"
	local pad_len = math.max(0, w - vim.fn.strdisplaywidth(left_text) - vim.fn.strdisplaywidth(right_text))

	vim.bo[Ui.help_buf].modifiable = true
	vim.api.nvim_buf_set_lines(Ui.help_buf, 0, -1, false, { left_text .. string.rep(" ", pad_len) .. right_text })
	vim.api.nvim_buf_add_highlight(Ui.help_buf, -1, "GitMsg", 0, 0, -1)
	vim.bo[Ui.help_buf].modifiable = false

	M.apply_all_keymaps()

	-- Window Navigation Controls
	for _, buf in ipairs({ Ui.left_buf, Ui.right_buf, Ui.diff_buf }) do
		vim.keymap.set("n", "sj", function()
			local current_ui = get_ui()
			local cur = vim.api.nvim_get_current_win()
			if cur == current_ui.diff_win then
				vim.api.nvim_set_current_win(
					current_ui.mode == "branches" and current_ui.right_win or current_ui.left_win
				)
			elseif cur == current_ui.right_win then
				vim.api.nvim_set_current_win(current_ui.left_win)
			end
		end, { buffer = buf, silent = true })

		vim.keymap.set("n", "sk", function()
			local current_ui = get_ui()
			local cur = vim.api.nvim_get_current_win()
			if cur == current_ui.left_win then
				vim.api.nvim_set_current_win(
					current_ui.mode == "branches" and current_ui.right_win or current_ui.diff_win
				)
			elseif cur == current_ui.right_win then
				vim.api.nvim_set_current_win(current_ui.diff_win)
			end
		end, { buffer = buf, silent = true })
	end

	-- Autocmds for Navigation
	local group = vim.api.nvim_create_augroup("GitPickerAutoCmds", { clear = true })

	vim.api.nvim_create_autocmd("CursorMoved", {
		group = group,
		buffer = Ui.right_buf,
		callback = function()
			if get_ui().mode == "branches" and type(render_diff) == "function" then
				render_diff()
			end
		end,
	})

	vim.api.nvim_create_autocmd("CursorMoved", {
		group = group,
		buffer = Ui.left_buf,
		callback = function()
			local current_ui = get_ui()
			if not current_ui.left_win or not vim.api.nvim_win_is_valid(current_ui.left_win) then
				return
			end

			local cursor = vim.api.nvim_win_get_cursor(current_ui.left_win)
			current_ui.selected_index = cursor[1]

			if current_ui.mode == "files" or current_ui.mode == "stashes" then
				if type(render_diff) == "function" then
					render_diff()
				end
			elseif current_ui.mode == "branches" then
				current_ui.branch_selected = current_ui.branches and current_ui.branches[current_ui.selected_index]
				if type(render_right) == "function" then
					render_right()
				end
				if type(render_diff) == "function" then
					render_diff()
				end
			end
		end,
	})

	-- Data Fetching
	if type(get_changed_files_async) == "function" then
		debug_log("Fetching changed files asynchronously...")
		get_changed_files_async(function(files)
			local current_ui = get_ui()
			debug_log("Async files callback received. File count: " .. tostring(files and #files or 0))

			current_ui.changed_files = files or {}

			if not current_ui.user_navigated then
				if #current_ui.changed_files > 0 then
					current_ui.mode = "files"
				else
					current_ui.mode = current_ui.mode or "branches"
				end
			end
			current_ui.selected_index = 1

			if type(update_window_layout) == "function" then
				update_window_layout()
			end
			if type(refresh_ui) == "function" then
				refresh_ui({ skip_fetch = true })
			end

			M.apply_all_keymaps()
		end)
	end

	if type(load_branches_async) == "function" then
		debug_log("Fetching branches asynchronously...")
		load_branches_async(function(branches)
			local current_ui = get_ui()
			debug_log("Async branches callback received. Branch count: " .. tostring(branches and #branches or 0))
			if branches then
				current_ui.branches = branches
			end
			if type(refresh_ui) == "function" then
				refresh_ui({ skip_fetch = true })
			end
		end)
	else
		debug_log("Falling back to synchronous git branch retrieval")
		get_ui().branches = vim.fn.systemlist("git branch --format='%(refname:short)'")
		if type(refresh_ui) == "function" then
			refresh_ui()
		end
	end

	if type(init_ui) == "function" then
		init_ui()
	end
end

M.setup = function(opts)
	opts = opts or {}
	config.options = vim.tbl_deep_extend("force", config.options or {}, opts)
	M.options = config.options

	-- Setup graph render callback dependency
	graph.setup_dependencies({
		render_right = render_right,
	})

	apply_highlights()

	vim.api.nvim_create_user_command("GitCompanion", function()
		M.toggle()
	end, { desc = "Open GitCompanion UI" })

	debug_log("GitCompanion setup complete")
end

return M
