local M = {}

M.conflict_ns = vim.api.nvim_create_namespace("gitcompanion_conflicts")

local function debug_log(msg, level)
	level = level or vim.log.levels.INFO
	vim.notify("[GitCompanion Debug] " .. msg, level)
end

--------------------------------------------------------------------------------
-- HELPER FUNCTIONS
--------------------------------------------------------------------------------

local function get_safe_ui()
	local uis = vim.api.nvim_list_uis()
	return #uis > 0 and uis[1] or { width = 80, height = 24 }
end

local function safe_set_cursor(win, line, col)
	if not win or not vim.api.nvim_win_is_valid(win) then
		return
	end
	local buf = vim.api.nvim_win_get_buf(win)
	local line_count = vim.api.nvim_buf_line_count(buf)
	local target_line = math.max(1, math.min(line, line_count))
	pcall(vim.api.nvim_win_set_cursor, win, { target_line, col or 0 })
end

-- Strip ANSI color escape codes from string outputs
local function strip_ansi(str)
	return str:gsub("\27%[[0-9;]*[mK]", ""):gsub("\r", "")
end

--------------------------------------------------------------------------------
-- CONFLICT RESOLUTION ENGINE
--------------------------------------------------------------------------------

function M.sync_to_target_file(float_bufnr, target_path)
	if not vim.api.nvim_buf_is_valid(float_bufnr) then
		debug_log("sync_to_target_file: Invalid float buffer handle", vim.log.levels.ERROR)
		return
	end

	local lines = vim.api.nvim_buf_get_lines(float_bufnr, 0, -1, false)
	local abs_path = vim.fn.fnamemodify(target_path, ":p")

	-- Write directly to disk
	local ok, err = pcall(vim.fn.writefile, lines, abs_path)
	if ok then
		debug_log("Successfully written directly to disk: " .. abs_path)
	else
		debug_log("Failed to write target file: " .. tostring(err), vim.log.levels.ERROR)
	end

	-- Sync open buffer if loaded in Neovim session
	local target_bufnr = vim.fn.bufnr(abs_path)
	if target_bufnr ~= -1 and vim.api.nvim_buf_is_loaded(target_bufnr) then
		vim.bo[target_bufnr].modifiable = true
		vim.api.nvim_buf_set_lines(target_bufnr, 0, -1, false, lines)
		vim.bo[target_bufnr].modified = false
	end
end

function M.resolve_conflict_at_cursor(float_bufnr, target_path, mode)
	mode = mode or "auto"
	local cur_win = vim.api.nvim_get_current_win()
	local cursor_line = vim.api.nvim_win_get_cursor(cur_win)[1]
	local lines = vim.api.nvim_buf_get_lines(float_bufnr, 0, -1, false)

	local start_line, separator_line, end_line = nil, nil, nil

	for i = cursor_line, 1, -1 do
		if lines[i] and lines[i]:match("^<<<<<<<") then
			start_line = i
			break
		end
	end

	if not start_line then
		vim.notify("Cursor is not inside a valid conflict block", vim.log.levels.WARN)
		return
	end

	for i = start_line, #lines do
		if lines[i]:match("^=======") and not separator_line then
			separator_line = i
		elseif lines[i]:match("^>>>>>>>") then
			end_line = i
			break
		end
	end

	if not (separator_line and end_line and cursor_line <= end_line) then
		vim.notify("Cursor is not inside a valid conflict block", vim.log.levels.WARN)
		return
	end

	local keep_lines = {}
	if mode == "both" then
		for i = start_line + 1, end_line - 1 do
			if i ~= separator_line then
				table.insert(keep_lines, lines[i])
			end
		end
	else
		if cursor_line < separator_line then
			for i = start_line + 1, separator_line - 1 do
				table.insert(keep_lines, lines[i])
			end
		else
			for i = separator_line + 1, end_line - 1 do
				table.insert(keep_lines, lines[i])
			end
		end
	end

	vim.api.nvim_buf_set_lines(float_bufnr, start_line - 1, end_line, false, keep_lines)
	M.sync_to_target_file(float_bufnr, target_path)

	local remaining = vim.api.nvim_buf_get_lines(float_bufnr, 0, -1, false)
	local has_more = false
	local next_conflict_line = nil

	for idx, l in ipairs(remaining) do
		if l:match("^<<<<<<<") then
			has_more = true
			if not next_conflict_line and idx >= start_line then
				next_conflict_line = idx
			end
		end
	end

	if not has_more then
		vim.notify("All conflicts resolved in file!", vim.log.levels.INFO)
		if cur_win and vim.api.nvim_win_is_valid(cur_win) and vim.api.nvim_win_get_config(cur_win).relative ~= "" then
			vim.api.nvim_win_close(cur_win, true)
		end
	else
		if next_conflict_line then
			safe_set_cursor(cur_win, next_conflict_line, 0)
		else
			for idx, l in ipairs(remaining) do
				if l:match("^<<<<<<<") then
					safe_set_cursor(cur_win, idx, 0)
					break
				end
			end
		end
	end
end

function M.open_merge_conflict_resolver(file_path)
	-- Clean path input thoroughly
	local clean_path = strip_ansi(file_path):match("^%s*(.-)%s*$")
	local full_path = vim.fn.fnamemodify(clean_path, ":p")

	debug_log("Opening conflict resolver for: " .. full_path)

	if vim.fn.filereadable(full_path) == 0 then
		debug_log("File does not exist or cannot be read at path: " .. full_path, vim.log.levels.ERROR)
		vim.notify("Error: File not found -> " .. full_path, vim.log.levels.ERROR)
		return
	end

	local file_lines = vim.fn.readfile(full_path)

	local float_bufnr = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(float_bufnr, 0, -1, false, file_lines)

	-- Set filetype by extension manually to avoid relying on unlinked buffers
	local ft = nil
	if vim.filetype.match then
		ft = vim.filetype.match({ filename = full_path })
	elseif vim.filetype.detect then
		ft = vim.filetype.detect({ filename = full_path })
	end

	if ft then
		vim.bo[float_bufnr].filetype = ft
	end

	local ui = get_safe_ui()
	local width = math.max(10, ui.width - 6)
	local height = math.max(10, ui.height - 3)
	local col = math.floor((ui.width - width) / 2)
	local row = math.floor((ui.height - height) / 2)

	local winnr = vim.api.nvim_open_win(float_bufnr, true, {
		relative = "editor",
		width = width,
		height = height,
		col = col,
		row = row,
		style = "minimal",
		border = "rounded",
		title = " Merge Conflict Resolver: " .. vim.fn.fnamemodify(full_path, ":t") .. " ",
		title_pos = "center",
		zindex = 700,
	})

	M.setup_keymaps(float_bufnr, full_path, winnr)
	M.highlight_conflicts(float_bufnr)

	for i, line in ipairs(file_lines) do
		if line:match("^<<<<<<<") then
			safe_set_cursor(winnr, i, 0)
			break
		end
	end
end

function M.setup_keymaps(float_bufnr, target_path, winnr)
	local opts = { buffer = float_bufnr, silent = true, noremap = true, nowait = true }

	local keys_to_disable = {
		"i",
		"I",
		"a",
		"A",
		"o",
		"O",
		"r",
		"R",
		"c",
		"C",
		"s",
		"S",
		"d",
		"x",
		"X",
		"p",
		"P",
		"u",
		"<C-r>",
		"v",
		"V",
		"<C-v>",
		"w",
		"e",
		"ge",
		"0",
		"$",
		"^",
		"G",
		"gg",
		"<CR>",
		"H",
		"L",
	}
	for _, key in ipairs(keys_to_disable) do
		vim.keymap.set("n", key, "<Nop>", opts)
	end

	vim.keymap.set("n", "<Space>", function()
		M.resolve_conflict_at_cursor(float_bufnr, target_path, "auto")
		M.highlight_conflicts(float_bufnr)
	end, opts)

	vim.keymap.set("n", "b", function()
		M.resolve_conflict_at_cursor(float_bufnr, target_path, "both")
		M.highlight_conflicts(float_bufnr)
	end, opts)

	vim.keymap.set("n", "q", function()
		if vim.api.nvim_win_is_valid(winnr) then
			vim.api.nvim_win_close(winnr, true)
		end
	end, opts)

	vim.keymap.set("n", "j", function()
		local cur_line = vim.api.nvim_win_get_cursor(winnr)[1]
		local lines = vim.api.nvim_buf_get_lines(float_bufnr, 0, -1, false)

		if cur_line < #lines then
			safe_set_cursor(winnr, cur_line + 1, 0)
		else
			for i = 1, #lines do
				if lines[i]:match("^<<<<<<<") then
					safe_set_cursor(winnr, i, 0)
					break
				end
			end
		end
		M.highlight_conflicts(float_bufnr)
	end, opts)

	vim.keymap.set("n", "k", function()
		local cur_line = vim.api.nvim_win_get_cursor(winnr)[1]
		local lines = vim.api.nvim_buf_get_lines(float_bufnr, 0, -1, false)

		if cur_line > 1 then
			safe_set_cursor(winnr, cur_line - 1, 0)
		else
			for i = #lines, 1, -1 do
				if lines[i]:match("^<<<<<<<") then
					safe_set_cursor(winnr, i, 0)
					break
				end
			end
		end
		M.highlight_conflicts(float_bufnr)
	end, opts)
end

function M.highlight_conflicts(bufnr)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	vim.api.nvim_buf_clear_namespace(bufnr, M.conflict_ns, 0, -1)

	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	local state = "none"
	local ours_start, theirs_start = nil, nil

	for idx, line in ipairs(lines) do
		local line_idx = idx - 1

		if line:match("^<<<<<<<") then
			state = "ours"
			ours_start = line_idx
			vim.api.nvim_buf_set_extmark(bufnr, M.conflict_ns, line_idx, 0, {
				line_hl_group = "GitCompanionMarker",
			})
		elseif line:match("^=======") and state == "ours" then
			state = "theirs"
			theirs_start = line_idx
			vim.api.nvim_buf_set_extmark(bufnr, M.conflict_ns, line_idx, 0, {
				line_hl_group = "GitCompanionMarker",
			})

			if ours_start then
				for l = ours_start + 1, line_idx - 1 do
					vim.api.nvim_buf_set_extmark(bufnr, M.conflict_ns, l, 0, {
						line_hl_group = "GitCompanionOurs",
					})
				end
			end
		elseif line:match("^>>>>>>>") and state == "theirs" then
			state = "none"
			vim.api.nvim_buf_set_extmark(bufnr, M.conflict_ns, line_idx, 0, {
				line_hl_group = "GitCompanionMarker",
			})

			if theirs_start then
				for l = theirs_start + 1, line_idx - 1 do
					vim.api.nvim_buf_set_extmark(bufnr, M.conflict_ns, l, 0, {
						line_hl_group = "GitCompanionTheirs",
					})
				end
			end
		end
	end
end

--------------------------------------------------------------------------------
-- PROMPT & HANDLERS
--------------------------------------------------------------------------------

function M.prompt_resolve_conflicts(filename, on_choice)
	local clean_name = strip_ansi(filename)
	local buf = vim.api.nvim_create_buf(false, true)

	local lines = {
		" Merge Conflict Detected in: " .. clean_name,
		" Do you want to resolve conflicts now?",
		"",
		" [y] Yes, jump to conflicts   [n] No, skip",
	}

	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].modifiable = false
	vim.bo[buf].buftype = "nofile"

	local ui = get_safe_ui()
	local w, h = 50, 6
	local row = math.floor((ui.height - h) / 2)
	local col = math.floor((ui.width - w) / 2)

	local win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		width = w,
		height = h,
		row = row,
		col = col,
		style = "minimal",
		border = "rounded",
		title = " Merge Conflict ",
		title_pos = "center",
		zindex = 800,
	})

	vim.api.nvim_set_hl(0, "GitCompanionPromptKey", { fg = "#00d7ff", bold = true })
	vim.api.nvim_buf_add_highlight(buf, -1, "GitCompanionPromptKey", 3, 2, 5)
	vim.api.nvim_buf_add_highlight(buf, -1, "GitCompanionPromptKey", 3, 31, 34)

	local function close()
		if vim.api.nvim_win_is_valid(win) then
			vim.api.nvim_win_close(win, true)
		end
	end

	vim.keymap.set("n", "y", function()
		close()
		on_choice(true)
	end, { buffer = buf, silent = true, nowait = true })

	vim.keymap.set("n", "n", function()
		close()
		on_choice(false)
	end, { buffer = buf, silent = true, nowait = true })

	vim.keymap.set("n", "<Esc>", function()
		close()
		on_choice(false)
	end, { buffer = buf, silent = true, nowait = true })

	vim.keymap.set("n", "q", function()
		close()
		on_choice(false)
	end, { buffer = buf, silent = true, nowait = true })
end

function M.handle_merge_result(cmd_output, exit_code)
	local clean_output = strip_ansi(cmd_output)
	if exit_code ~= 0 and string.find(clean_output, "CONFLICT") then
		local conflicted_file = clean_output:match("CONFLICT.-in%s+([%w_%.%-%/]+)")

		if type(close_floating) == "function" then
			close_floating()
		end

		if conflicted_file then
			M.prompt_resolve_conflicts(conflicted_file, function(should_resolve)
				if should_resolve then
					M.open_merge_conflict_resolver(conflicted_file)
				end
			end)
		end
	end
end

--------------------------------------------------------------------------------
-- AUTOCMDS
--------------------------------------------------------------------------------

vim.api.nvim_create_autocmd({ "BufEnter", "BufWinEnter", "BufWritePost" }, {
	group = vim.api.nvim_create_augroup("GitCompanionConflictHL", { clear = true }),
	callback = function(args)
		local bufnr = args.buf
		if not vim.api.nvim_buf_is_valid(bufnr) or vim.bo[bufnr].buftype == "nofile" then
			return
		end

		local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
		local has_conflict = false
		for _, line in ipairs(lines) do
			if line:match("^<<<<<<<") then
				has_conflict = true
				break
			end
		end

		if has_conflict then
			M.highlight_conflicts(bufnr)
		else
			vim.api.nvim_buf_clear_namespace(bufnr, M.conflict_ns, 0, -1)
		end
	end,
})

return M
