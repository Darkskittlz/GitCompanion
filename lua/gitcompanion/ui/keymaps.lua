local M = {}

local last_rendered_line = -1

function M.setup_tree_keymaps(bufnr)
	local opts = { noremap = true, silent = true, buffer = bufnr }

	-- Let standard motion run; CursorMoved autocmd will trigger render_diff smoothly
	vim.keymap.set("n", "j", "j", opts)
	vim.keymap.set("n", "k", "k", opts)

	-- Toggle expand/collapse directory
	vim.keymap.set("n", "<CR>", function()
		local tree = require("gitcompanion.tree")
		tree.toggle_tree_node()
	end, opts)
end

function M.attach_tree_listeners(bufnr)
	M.setup_tree_keymaps(bufnr)

	local group = vim.api.nvim_create_augroup("GitCompanionTreeEvents_" .. bufnr, { clear = true })

	vim.api.nvim_create_autocmd({ "CursorMoved", "BufEnter", "WinEnter" }, {
		group = group,
		buffer = bufnr,
		callback = function()
			local cur_win = vim.api.nvim_get_current_win()
			local cur_line = vim.api.nvim_win_get_cursor(cur_win)[1]

			-- Sync current line index to State UI
			local State = require("gitcompanion.state")
			if State and State.Ui then
				State.Ui.selected_index = cur_line
			end

			-- Force diff render on cursor change or focus change
			local layout = require("gitcompanion.ui.layout")
			if layout and type(layout.render_diff) == "function" then
				layout.render_diff()
			end
		end,
	})
end

return M
