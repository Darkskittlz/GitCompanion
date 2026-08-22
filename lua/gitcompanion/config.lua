local M = {}

-- Default Configuration Options
M.options = {
	-- Highlight definitions
	highlights = {
		GitBranchCurrent = { fg = "#549afc" },
		GitUnstaged = { fg = "#f99c67", bold = true, italic = true },
		GitStaged = { fg = "#57BE67", bold = true },
		GitPickerTitle = { fg = "#268bd3", bold = true },

		-- Stash View Highlights
		GitStashNumber = { fg = "#888888", bold = false }, -- Gray for numbers
		GitStashBranch = { fg = "#549afc", bold = true }, -- Blue for branch names
		GitStashText = { fg = "#00aa00", bold = false }, -- Green for stash message text

		-- Classic Vim Diff Highlights (Removed bg = "")
		DiffAdd = { fg = "#00aa00", bold = false },
		DiffDelete = { fg = "#f92672", bold = false },
		DiffChange = { fg = "#fd971f", bold = false },
		DiffText = { fg = "#fd971f", bold = true },

		-- Treesitter & Modern Diff Captures (Links to your custom defined groups)
		["@added"] = { link = "DiffAdd" },
		["@deleted"] = { link = "DiffDelete" },
		["@changed"] = { link = "DiffChange" },
		["@diff.plus"] = { link = "DiffAdd" },
		["@diff.minus"] = { link = "DiffDelete" },
		["@text.diff.add"] = { link = "DiffAdd" },
		["@text.diff.delete"] = { link = "DiffDelete" },

		MergeBlue = { fg = "#4da3ff", bold = true },
		MergeGreen = { fg = "#32cd32", bold = true },
		MergeRed = { fg = "#ff4444", bold = true },
		MergeWhite = { fg = "#bbbbbb", bold = true },

		ResetBlue = { fg = "#4da3ff", bold = true },
		ResetGreen = { fg = "#32cd32", bold = true },
		ResetRed = { fg = "#ff4444", bold = true },
		ResetWhite = { fg = "#bbbbbb", bold = true },

		GitGraphSymbol = { fg = "#5f87ff" },

		GitHash = { fg = "#00d7ff", bold = true },
		GitDate = { fg = "#db302d", italic = true },
		GitAuthor = { fg = "#00a77d", italic = true },
		GitOutput = { fg = "#40a02b", bold = false, italic = false },
		GitError = { fg = "#FF6F69", bold = false, italic = false },
		GitMsg = { fg = "#777777", bold = false, italic = false },

		GitCompanionOurs = { bg = "#2e3f33", default = true },
		GitCompanionTheirs = { bg = "#23374d", default = true },
		GitCompanionMarker = { bg = "#444444", bold = true, default = true },
	},

	-- Git Graph Rendering Settings
	graph_chars = { "◯", "│", "╮", "╯", "─" },
	graph_colors = {
		"#5fff5f", -- green
		"#5fd7ff", -- cyan
		"#ffaf5f", -- orange
		"#ff5fff", -- magenta
		"#ffff5f", -- yellow
		"#5f5fff", -- blue
		"#5fffff", -- light cyan
		"#ff5f5f", -- red
	},
}

--- Apply all configured highlight groups to Neovim
function M.apply_highlights()
	for hl_group, spec in pairs(M.options.highlights) do
		vim.api.nvim_set_hl(0, hl_group, spec)
	end
end

--- Initialize configuration and set up autocommands
---@param user_opts table|nil
function M.setup(user_opts)
	if user_opts and type(user_opts) == "table" then
		M.options = vim.tbl_deep_extend("force", M.options, user_opts)
	end

	-- Export variables globally for downstream layout/render module reliance
	_G.graph_chars = M.options.graph_chars
	_G.graph_colors = M.options.graph_colors
	M.graph_chars = M.options.graph_chars
	M.graph_colors = M.options.graph_colors

	-- Initial highlight application
	M.apply_highlights()

	-- Re-apply highlights whenever the user updates or changes colorschemes
	local augroup = vim.api.nvim_create_augroup("GitCompanionHighlights", { clear = true })
	vim.api.nvim_create_autocmd("ColorScheme", {
		group = augroup,
		callback = function()
			M.apply_highlights()
		end,
	})
end

-- Auto-initialize defaults upon file load
M.setup()

return M
