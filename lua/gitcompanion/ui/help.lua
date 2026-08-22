-- lua/gitcompanion/ui/help.lua
local M = {}

function M.show_help()
	local buf = vim.api.nvim_create_buf(false, true)

	local lines = {
		"  Navigation",
		"    j / k         : Move selection up / down",
		"    sj / sk       : Jump up / down between panels",
		"    H / L         : Cycle views (Branches ↔ Files ↔ Stashes)",
		"",
		"  Actions",
		"    <Space>       : Checkout Branch / Stage File / Pop Stash",
		"    d             : Delete Branch / Discard Changes / Drop Stash / Revert Commit",
		"    s             : Create new stash (Any view)",
		"    ?             : Show this help modal",
		"    q / <Esc>     : Close picker or popup",
	}

	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

	-- Buffer options
	vim.bo[buf].modifiable = false
	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].filetype = "gitcompanionhelp"

	-- Dynamic dimensions calculation
	local max_line_len = 0
	for _, line in ipairs(lines) do
		max_line_len = math.max(max_line_len, #line)
	end

	local width = max_line_len + 4
	local height = #lines + 2

	local ui = vim.api.nvim_list_uis()[1]
	local row = math.floor((ui.height - height) / 2)
	local col = math.floor((ui.width - width) / 2)

	-- Create floating window centered on screen
	local win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		width = width,
		height = height,
		row = row,
		col = col,
		style = "minimal",
		border = "rounded",
		title = " Keybindings Help ",
		title_pos = "center",
		zindex = 300,
	})

	-- Optional: Basic syntax highlights for headers and key shortcuts
	vim.api.nvim_win_set_option(win, "winhl", "Normal:NormalFloat,FloatBorder:FloatBorder")

	-- Add inline visual highlights for section headers
	for idx, line in ipairs(lines) do
		if line:match("^%s%s%a+") then
			vim.api.nvim_buf_add_highlight(buf, -1, "Title", idx - 1, 0, -1)
		end
	end

	-- Close window handler
	local function close_help()
		if vim.api.nvim_win_is_valid(win) then
			vim.api.nvim_win_close(win, true)
		end
	end

	-- Buffer-local keymaps to dismiss window
	local opts = { buffer = buf, noremap = true, silent = true }
	vim.keymap.set("n", "q", close_help, opts)
	vim.keymap.set("n", "<Esc>", close_help, opts)
	vim.keymap.set("n", "?", close_help, opts)
end

return M
