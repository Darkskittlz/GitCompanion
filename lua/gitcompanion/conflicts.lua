local M = {}

M.conflict_ns = vim.api.nvim_create_namespace("gitcompanion_conflicts")

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

function M.resolve_conflict_at_cursor(choice)
   local bufnr = vim.api.nvim_get_current_buf()
   local cursor_line = vim.api.nvim_win_get_cursor(0)[1]
   local conflicts = M.parse_conflict_blocks(bufnr)

   local target = nil
   for _, c in ipairs(conflicts) do
      if cursor_line >= c.start_line and cursor_line <= c.end_line then
         target = c
         break
      end
   end

   if not target then
      vim.notify("[GitCompanion] Cursor is not inside a merge conflict block", vim.log.levels.WARN)
      return
   end

   if choice == "auto" then
      choice = (cursor_line <= (target.ours_end or target.start_line)) and "ours" or "theirs"
   end

   local replacement = {}
   local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

   if choice == "ours" then
      for i = target.ours_start, target.ours_end do
         table.insert(replacement, lines[i])
      end
   elseif choice == "theirs" then
      for i = target.theirs_start, target.theirs_end do
         table.insert(replacement, lines[i])
      end
   elseif choice == "both" then
      for i = target.ours_start, target.ours_end do
         table.insert(replacement, lines[i])
      end
      for i = target.theirs_start, target.theirs_end do
         table.insert(replacement, lines[i])
      end
   end

   local is_modifiable = vim.api.nvim_get_option_value("modifiable", { buf = bufnr })
   if not is_modifiable then
      vim.api.nvim_set_option_value("modifiable", true, { buf = bufnr })
   end

   vim.api.nvim_buf_set_lines(bufnr, target.start_line - 1, target.end_line, false, replacement)

   if not is_modifiable then
      vim.api.nvim_set_option_value("modifiable", false, { buf = bufnr })
   end

   M.highlight_conflicts(bufnr)
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

function M.setup_keymaps(bufnr)
   bufnr = bufnr or vim.api.nvim_get_current_buf()
   if vim.b[bufnr].gitcompanion_conflicts_mapped then
      return
   end

   local opts = { buffer = bufnr, silent = true, noremap = true }

   vim.keymap.set("n", "<Space>", function()
      M.resolve_conflict_at_cursor("auto")
   end, opts)

   vim.keymap.set("n", "b", function()
      M.resolve_conflict_at_cursor("both")
   end, opts)

   vim.keymap.set("n", "j", function()
      local found = vim.fn.search("^<<<<<<<", "W")
      if found == 0 then
         vim.fn.cursor(1, 1)
         vim.fn.search("^<<<<<<<", "W")
      end
   end, opts)

   vim.keymap.set("n", "k", function()
      local found = vim.fn.search("^<<<<<<<", "bW")
      if found == 0 then
         vim.fn.cursor(vim.api.nvim_buf_line_count(bufnr), 1)
         vim.fn.search("^<<<<<<<", "bW")
      end
   end, opts)

   vim.b[bufnr].gitcompanion_conflicts_mapped = true
end

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
         M.setup_keymaps(bufnr)
      else
         vim.api.nvim_buf_clear_namespace(bufnr, M.conflict_ns, 0, -1)
      end
   end,
})

return M
