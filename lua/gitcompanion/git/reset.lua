-- lua/gitcompanion/git/reset.lua
local M = {}

--- Helper for wrapping string text to fit fixed modal widths
local function fallback_wrap_text(str, max_width)
   local lines = {}
   while #str > max_width do
      local part = str:sub(1, max_width)
      table.insert(lines, part)
      str = str:sub(max_width + 1)
   end
   if #str > 0 then
      table.insert(lines, str)
   end
   return lines
end

function M.open_reset_modal(hash, state)
   local safe_hash = vim.fn.shellescape(hash)

   local options = {
      {
         key = "m",
         label = "Mixed reset",
         hl = "ResetBlue",
         desc = "Reset HEAD to this commit, keeping changes unstaged.",
         cmd = "git reset --mixed " .. safe_hash,
      },
      {
         key = "s",
         label = "Soft reset",
         hl = "ResetGreen",
         desc = "Reset HEAD to this commit, keeping all changes staged.",
         cmd = "git reset --soft " .. safe_hash,
      },
      {
         key = "h",
         label = "Hard reset",
         hl = "ResetRed",
         desc = "Fully reset working tree & index to this commit.",
         cmd = "git reset --hard " .. safe_hash,
      },
      {
         key = "c",
         label = "Cancel",
         hl = "ResetWhite",
         desc = "Exit without doing anything.",
         cmd = nil,
      },
   }

	local selected = 1

	-- Popup window positioning
	local ui = vim.api.nvim_list_uis()[1]
	local width = 52
	local height = #options + 2

	local row = math.floor((ui.height - height) / 2)
	local col = math.floor((ui.width - width) / 2)

   local buf = vim.api.nvim_create_buf(false, true)
   local win = vim.api.nvim_open_win(buf, true, {
      relative = "editor",
      width = width,
      height = height,
      row = row,
      col = col,
      style = "minimal",
      border = "rounded",
      title = " Reset to " .. hash:sub(1, 7) .. " ",
      title_pos = "center",
      zindex = 500,
   })

	local buf_desc = vim.api.nvim_create_buf(false, true)
	local win_desc = vim.api.nvim_open_win(buf_desc, false, {
		relative = "editor",
		width = width,
		height = 3,
		row = row + height + 2,
		col = col,
		style = "minimal",
		border = "rounded",
		title = " Info ",
		title_pos = "center",
		zindex = 500,
	})

   local wrapper = type(wrap_text) == "function" and wrap_text or fallback_wrap_text

   local function render()
      local lines = {}
      for i, opt in ipairs(options) do
         local prefix = (i == selected) and " ❯ " or "   "
         lines[#lines + 1] = prefix .. opt.label
      end

		vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
		vim.api.nvim_buf_clear_namespace(buf, -1, 0, -1)
		vim.api.nvim_buf_add_highlight(buf, -1, options[selected].hl, selected - 1, 0, -1)

      local wrapped = wrapper(options[selected].desc, width - 4)
      vim.api.nvim_buf_set_lines(buf_desc, 0, -1, false, wrapped)
      vim.api.nvim_buf_clear_namespace(buf_desc, -1, 0, -1)
      for i = 1, #wrapped do
         vim.api.nvim_buf_add_highlight(buf_desc, -1, options[selected].hl, i - 1, 0, -1)
      end
   end

	render()

   local function close_all()
      if vim.api.nvim_win_is_valid(win_desc) then
         vim.api.nvim_win_close(win_desc, true)
      end
      if vim.api.nvim_win_is_valid(win) then
         vim.api.nvim_win_close(win, true)
      end
      if vim.api.nvim_buf_is_valid(buf_desc) then
         vim.api.nvim_buf_delete(buf_desc, { force = true })
      end
      if vim.api.nvim_buf_is_valid(buf) then
         vim.api.nvim_buf_delete(buf, { force = true })
      end

      if state.Ui then
         state.Ui.mode = "branches"
      end
      if state.refresh_ui then
         state.refresh_ui()
      end
   end

   -- Modal Navigation
   vim.keymap.set("n", "j", function()
      selected = math.min(#options, selected + 1)
      render()
   end, { buffer = buf, noremap = true, silent = true })

   vim.keymap.set("n", "k", function()
      selected = math.max(1, selected - 1)
      render()
   end, { buffer = buf, noremap = true, silent = true })

	local function apply_selected_reset()
		local opt = options[selected]
		if not opt or not opt.cmd then
			close_all()
			return
		end

      local out = vim.fn.system(opt.cmd)
      if vim.v.shell_error ~= 0 then
         vim.notify("Git error: " .. out, vim.log.levels.ERROR)
         close_all()
         return
      end

      vim.notify(opt.label .. " → " .. hash:sub(1, 7), vim.log.levels.INFO)

      if state.reload_with_fetch then
         state.reload_with_fetch(state.Ui and state.Ui.current_branch)
      elseif state.invalidate_cache then
         state.invalidate_cache()
      end

		vim.notify(opt.label .. " → " .. hash, vim.log.levels.INFO)

		-- 1. Invalidate cache and re-fetch commits/branches asynchronously
		if state.reload_with_fetch then
			state.reload_with_fetch(state.Ui and state.Ui.current_branch)
		elseif state.invalidate_cache then
			state.invalidate_cache()
		end

		-- 2. Close modal windows
		close_all()
	end

	-- Modal Bindings
	vim.keymap.set("n", "<CR>", apply_selected_reset, { buffer = buf, noremap = true, silent = true })
	vim.keymap.set("n", "q", close_all, { buffer = buf, noremap = true, silent = true })
	vim.keymap.set("n", "<Esc>", close_all, { buffer = buf, noremap = true, silent = true })

	for idx, opt in ipairs(options) do
		if opt.key then
			vim.keymap.set("n", opt.key, function()
				selected = idx
				apply_selected_reset()
			end, { buffer = buf, noremap = true, silent = true })
		end
	end
end

return M
