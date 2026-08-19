local M = {}

M.conflict_ns = vim.api.nvim_create_namespace("gitcompanion_conflicts")

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

--------------------------------------------------------------------------------
-- CONFLICT RESOLUTION ENGINE
--------------------------------------------------------------------------------

function M.parse_conflict_blocks(bufnr)
   bufnr = bufnr or 0
   local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
   local conflicts = {}
   local current = nil

   for idx, line in ipairs(lines) do
      if line:match("^<<<<<<<") then
         current = { start_line = idx, ours_start = idx + 1 }
      elseif line:match("^=======") and current then
         current.ours_end = idx - 1
         current.theirs_start = idx + 1
      elseif line:match("^>>>>>>>") and current then
         current.theirs_end = idx - 1
         current.end_line = idx
         table.insert(conflicts, current)
         current = nil
      end
   end
   return conflicts
end

function M.resolve_conflict_at_cursor(target_bufnr, mode)
   target_bufnr = (not target_bufnr or target_bufnr == 0) and vim.api.nvim_get_current_buf() or target_bufnr
   mode = mode or "auto"

   local cur_win = vim.api.nvim_get_current_win()
   local cursor_line = vim.api.nvim_win_get_cursor(cur_win)[1]
   local lines = vim.api.nvim_buf_get_lines(target_bufnr, 0, -1, false)

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

   vim.api.nvim_buf_set_lines(target_bufnr, start_line - 1, end_line, false, keep_lines)

   vim.api.nvim_buf_call(target_bufnr, function()
      vim.cmd("silent write")
   end)

   local remaining = vim.api.nvim_buf_get_lines(target_bufnr, 0, -1, false)
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
      vim.api.nvim_buf_clear_namespace(target_bufnr, M.conflict_ns, 0, -1)
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
   local target_bufnr = vim.fn.bufadd(file_path)
   vim.fn.bufload(target_bufnr)

   vim.bo[target_bufnr].modifiable = true

   local ui = get_safe_ui()
   local width = math.max(10, ui.width - 6)
   local height = math.max(10, ui.height - 2)
   local col = math.floor((ui.width - width) / 2)
   local row = math.floor((ui.height - height) / 2)

   local winnr = vim.api.nvim_open_win(target_bufnr, true, {
      relative = "editor",
      width = width,
      height = height,
      col = col,
      row = row,
      style = "minimal",
      border = "rounded",
      title = " Merge Conflict Resolver: " .. vim.fn.fnamemodify(file_path, ":t") .. " ",
      title_pos = "center",
      zindex = 700,
   })

   M.setup_keymaps(target_bufnr, winnr)
   M.highlight_conflicts(target_bufnr)

   local lines = vim.api.nvim_buf_get_lines(target_bufnr, 0, -1, false)
   for i, line in ipairs(lines) do
      if line:match("^<<<<<<<") then
         safe_set_cursor(winnr, i, 0)
         break
      end
   end
end

function M.setup_keymaps(bufnr, winnr)
   bufnr = bufnr or vim.api.nvim_get_current_buf()
   local opts = { buffer = bufnr, silent = true, noremap = true }

   -- Re-bind keymaps to update current floating window reference
   vim.b[bufnr].gitcompanion_active_win = winnr

   if vim.b[bufnr].gitcompanion_conflicts_mapped then
      return
   end

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
      "b",
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

   local function get_target_win()
      local active_win = vim.b[bufnr].gitcompanion_active_win
      if active_win and vim.api.nvim_win_is_valid(active_win) then
         return active_win
      end
      local wins = vim.fn.win_findbuf(bufnr)
      return #wins > 0 and wins[1] or vim.api.nvim_get_current_win()
   end

   vim.keymap.set("n", "<Space>", function()
      M.resolve_conflict_at_cursor(bufnr, "auto")
      M.highlight_conflicts(bufnr)
   end, opts)

   vim.keymap.set("n", "b", function()
      M.resolve_conflict_at_cursor(bufnr, "both")
      M.highlight_conflicts(bufnr)
   end, opts)

   vim.keymap.set("n", "q", function()
      local win = get_target_win()
      if vim.api.nvim_win_get_config(win).relative ~= "" then
         vim.api.nvim_win_close(win, true)
      end
   end, opts)

   -- Jump to NEXT conflict block
   vim.keymap.set("n", "j", function()
      local win = get_target_win()
      local cur_line = vim.api.nvim_win_get_cursor(win)[1]
      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

      for i = cur_line + 1, #lines do
         if lines[i]:match("^<<<<<<<") then
            safe_set_cursor(win, i, 0)
            M.highlight_conflicts(bufnr)
            return
         end
      end

      -- Wrap around
      for i = 1, cur_line - 1 do
         if lines[i]:match("^<<<<<<<") then
            safe_set_cursor(win, i, 0)
            M.highlight_conflicts(bufnr)
            return
         end
      end
   end, opts)

   -- Jump to PREVIOUS conflict block
   vim.keymap.set("n", "k", function()
      local win = get_target_win()
      local cur_line = vim.api.nvim_win_get_cursor(win)[1]
      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

      for i = cur_line - 1, 1, -1 do
         if lines[i]:match("^<<<<<<<") then
            safe_set_cursor(win, i, 0)
            M.highlight_conflicts(bufnr)
            return
         end
      end

      -- Wrap around
      for i = #lines, cur_line + 1, -1 do
         if lines[i]:match("^<<<<<<<") then
            safe_set_cursor(win, i, 0)
            M.highlight_conflicts(bufnr)
            return
         end
      end
   end, opts)

   vim.b[bufnr].gitcompanion_conflicts_mapped = true
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
   local buf = vim.api.nvim_create_buf(false, true)

   local lines = {
      " Merge Conflict Detected in: " .. filename,
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
   if exit_code ~= 0 and string.find(cmd_output, "CONFLICT") then
      local conflicted_file = cmd_output:match("CONFLICT.-in%s+([%w_%.%-%/]+)")

      if type(close_floating) == "function" then
         close_floating()
      end

      M.prompt_resolve_conflicts(conflicted_file, function(should_resolve)
         if should_resolve and conflicted_file then
            M.open_merge_conflict_resolver(conflicted_file)
         end
      end)
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
