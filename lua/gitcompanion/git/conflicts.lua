local M = {}

-- Enable debug notifications
M.debug = true

M.conflict_ns = vim.api.nvim_create_namespace("gitcompanion_conflicts")

M.session_state = {
   total_conflicts = 0,
   resolved_conflicts = 0,
}

local function debug_log(msg, level)
   if M.debug then
      level = level or vim.log.levels.INFO
      -- vim.notify("[GitCompanion Debug] " .. msg, level)
   end
end

--------------------------------------------------------------------------------
-- HELPER FUNCTIONS
--------------------------------------------------------------------------------

local function get_active_merge_cmd(target_path)
   local dir = vim.fn.fnamemodify(target_path, ":h")
   local git_dir =
       vim.fn.trim(vim.fn.system(string.format("git -C %s rev-parse --git-dir 2>/dev/null", vim.fn.shellescape(dir))))
   if vim.v.shell_error ~= 0 or git_dir == "" then
      return nil
   end

   -- Convert relative git_dir to absolute if needed
   if not git_dir:match("^/") then
      git_dir = dir .. "/" .. git_dir
   end

   if vim.fn.filereadable(git_dir .. "/MERGE_HEAD") == 1 then
      return { "git", "-C", dir, "merge", "--continue" }
   elseif
       vim.fn.isdirectory(git_dir .. "/rebase-apply") == 1 or vim.fn.isdirectory(git_dir .. "/rebase-merge") == 1
   then
      return { "git", "-C", dir, "rebase", "--continue" }
   elseif vim.fn.filereadable(git_dir .. "/CHERRY_PICK_HEAD") == 1 then
      return { "git", "-C", dir, "cherry-pick", "--continue" }
   end

   return nil
end

local function get_safe_ui()
   local uis = vim.api.nvim_list_uis()
   return #uis > 0 and uis[1] or { width = 80, height = 24 }
end

local function safe_set_cursor(win, line, col)
   if not win or not vim.api.nvim_win_is_valid(win) then
      debug_log("safe_set_cursor: Invalid target window handle", vim.log.levels.WARN)
      return
   end
   local buf = vim.api.nvim_win_get_buf(win)
   local line_count = vim.api.nvim_buf_line_count(buf)
   local target_line = math.max(1, math.min(line, line_count))
   pcall(vim.api.nvim_win_set_cursor, win, { target_line, col or 0 })
   debug_log(string.format("Cursor set to line %d in window %d", target_line, win))
end

local function strip_ansi(str)
   return str:gsub("\27%[[0-9;]*[mK]", ""):gsub("\r", "")
end

local function count_conflict_blocks(lines)
   if not lines or type(lines) ~= "table" then
      return 0
   end
   local count = 0
   for _, line in ipairs(lines) do
      if type(line) == "string" and line:match("^<<<<<<<") then
         count = count + 1
      end
   end
   return count
end

--------------------------------------------------------------------------------
-- UI EXTENSIONS
--------------------------------------------------------------------------------

--- Updates top-right status on the floating window header
function M.update_top_right_counter(winnr)
   if not winnr or not vim.api.nvim_win_is_valid(winnr) then
      return
   end

   local buf = vim.api.nvim_win_get_buf(winnr)
   local raw_name = vim.api.nvim_buf_get_name(buf)
   local file_name = vim.fn.fnamemodify(raw_name, ":t"):gsub(" %[%s*Conflict Resolver%s*%]", "")
   if file_name == "" then
      file_name = "Resolver"
   end

   local total = M.session_state.total_conflicts
   local resolved = M.session_state.resolved_conflicts

   vim.api.nvim_win_set_config(winnr, {
      title = string.format(" Merge Conflict Resolver: %s ", file_name),
      title_pos = "center",
   })

   -- Set right-aligned winbar 1 line below border
   local status_text = string.format(" %d/%d conflicts resolved ", resolved, total)
   vim.wo[winnr].winbar = "%=" .. status_text
end

function M.prompt_proceed_with_merge(cur_win, target_path, orig_win)
   debug_log("Prompting user to finalize merge after resolving all conflicts")
   local buf = vim.api.nvim_create_buf(false, true)

   local lines = {
      " All merge conflicts resolved. Continue the merge?",
      "",
      " [y] Confirm   [n] Close/Cancel",
   }

   vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
   vim.bo[buf].modifiable = false
   vim.bo[buf].buftype = "nofile"

   local ui = get_safe_ui()
   local w, h = 54, 5
   local row = math.max(0, math.floor((ui.height - h) / 2) - 1)
   local col = math.floor((ui.width - w) / 2)

   local win = vim.api.nvim_open_win(buf, true, {
      relative = "editor",
      width = w,
      height = h,
      row = row,
      col = col,
      style = "minimal",
      border = "rounded",
      title = " Continue ",
      title_pos = "left",
      zindex = 850,
   })

   vim.api.nvim_set_hl(0, "GitCompanionPromptKey", { fg = "#00d7ff", bold = true })
   vim.api.nvim_buf_set_extmark(buf, M.conflict_ns, 2, 2, { end_col = 5, hl_group = "GitCompanionPromptKey" })
   vim.api.nvim_buf_set_extmark(buf, M.conflict_ns, 2, 17, { end_col = 20, hl_group = "GitCompanionPromptKey" })

   -- Cancels prompt and focuses back on the conflict resolver window
   local function cancel()
      if vim.api.nvim_win_is_valid(win) then
         vim.api.nvim_win_close(win, true)
      end

      if cur_win and vim.api.nvim_win_is_valid(cur_win) then
         local float_bufnr = vim.api.nvim_win_get_buf(cur_win)
         local orig_lines = vim.b[float_bufnr].original_lines

         if orig_lines and type(orig_lines) == "table" then
            -- 1. Restore buffer contents
            vim.bo[float_bufnr].modifiable = true
            vim.api.nvim_buf_set_lines(float_bufnr, 0, -1, false, orig_lines)

            -- 2. Sync back to disk and open buffers
            M.sync_to_target_file(float_bufnr, target_path)

            -- 3. Reset counter state
            local total = count_conflict_blocks(orig_lines)
            M.session_state.total_conflicts = total
            M.session_state.resolved_conflicts = 0

            -- 4. Re-apply conflict highlights and update UI top counter
            if type(M.highlight_conflicts) == "function" then
               M.highlight_conflicts(float_bufnr)
            end
            if type(M.update_top_right_counter) == "function" then
               M.update_top_right_counter(cur_win)
            end

            -- 5. Move cursor back to first conflict marker
            for i, line in ipairs(orig_lines) do
               if type(line) == "string" and line:match("^<<<<<<<") then
                  safe_set_cursor(cur_win, i, 0)
                  break
               end
            end
         end

         vim.api.nvim_set_current_win(cur_win)
      end
   end

   local function finish_merge()
      debug_log("Executing finish_merge()")
      if vim.api.nvim_win_is_valid(win) then
         vim.api.nvim_win_close(win, true)
      end

      local abs_path = vim.fn.fnamemodify(target_path, ":p")
      local dir = vim.fn.fnamemodify(abs_path, ":h")

      -- 1. Stage the resolved file
      vim.fn.system({ "git", "-C", dir, "add", abs_path })

      -- 2. Continue operation or commit
      local continue_cmd = get_active_merge_cmd(abs_path) or { "git", "-C", dir, "commit", "--no-edit" }
      local commit_out = vim.fn.system(continue_cmd)
      debug_log("Merge output: " .. commit_out)

      -- 3. Close conflict window and return focus to original buffer/UI
      if cur_win and vim.api.nvim_win_is_valid(cur_win) then
         vim.api.nvim_win_close(cur_win, true)
      end

      if orig_win and vim.api.nvim_win_is_valid(orig_win) then
         vim.api.nvim_set_current_win(orig_win)
      end

      local ui_obj = _G.Ui or _G["GitCompanionUi"] or (type(Ui) ~= "nil" and Ui or nil)
      if ui_obj then
         ui_obj.mode = "branches"
      end

      local refresh_fn = _G.refresh_ui
          or (ui_obj and ui_obj.refresh)
          or (type(refresh_fn) == "function" and refresh_fn or nil)
      if type(refresh_fn) == "function" then
         refresh_fn()
      end
   end

   vim.keymap.set("n", "y", finish_merge, { buffer = buf, silent = true, nowait = true })
   vim.keymap.set("n", "<CR>", finish_merge, { buffer = buf, silent = true, nowait = true })
   vim.keymap.set("n", "n", cancel, { buffer = buf, silent = true, nowait = true })
   vim.keymap.set("n", "<Esc>", cancel, { buffer = buf, silent = true, nowait = true })
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

   local ok, err = pcall(vim.fn.writefile, lines, abs_path)
   if ok then
      debug_log("Successfully written directly to disk: " .. abs_path)
   else
      debug_log("Failed to write target file: " .. tostring(err), vim.log.levels.ERROR)
   end

   local target_bufnr = vim.fn.bufnr(abs_path)
   if target_bufnr ~= -1 and vim.api.nvim_buf_is_loaded(target_bufnr) then
      vim.bo[target_bufnr].modifiable = true
      vim.api.nvim_buf_set_lines(target_bufnr, 0, -1, false, lines)
      vim.bo[target_bufnr].modified = false
      vim.cmd("checktime " .. target_bufnr)
   end
end

function M.resolve_conflict_at_cursor(float_bufnr, target_path, mode, orig_win)
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
      debug_log("No start marker ('<<<<<<<') found above line " .. cursor_line, vim.log.levels.WARN)
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

   if not (separator_line and end_line and cursor_line >= start_line and cursor_line <= end_line) then
      debug_log("Cursor position is outside valid conflict bounds", vim.log.levels.WARN)
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

   vim.bo[float_bufnr].modifiable = true
   vim.api.nvim_buf_set_lines(float_bufnr, start_line - 1, end_line, false, keep_lines)
   M.sync_to_target_file(float_bufnr, target_path)

   local remaining = vim.api.nvim_buf_get_lines(float_bufnr, 0, -1, false)
   local remaining_count = count_conflict_blocks(remaining)

   M.session_state.resolved_conflicts = M.session_state.total_conflicts - remaining_count
   M.update_top_right_counter(cur_win)

   if remaining_count == 0 then
      debug_log("All conflict blocks resolved. Triggering prompt.")
      M.prompt_proceed_with_merge(cur_win, target_path, orig_win)
   else
      local next_line = nil
      for idx, l in ipairs(remaining) do
         if l:match("^<<<<<<<") and idx >= start_line then
            next_line = idx
            break
         end
      end
      safe_set_cursor(cur_win, next_line or 1, 0)
   end
end

function M.open_merge_conflict_resolver(file_path, orig_win)
   orig_win = orig_win or vim.api.nvim_get_current_win()
   local clean_path = strip_ansi(file_path):match("^%s*(.-)%s*$")
   local full_path = vim.fn.fnamemodify(clean_path, ":p")

   debug_log("Opening conflict resolver for: " .. full_path .. " | orig_win: " .. tostring(orig_win))

   if vim.fn.filereadable(full_path) == 0 then
      debug_log("File does not exist or cannot be read at path: " .. full_path, vim.log.levels.ERROR)
      return
   end

   local file_lines = vim.fn.readfile(full_path)

   -- Create new floating scratch buffer FIRST so float_bufnr exists
   local float_bufnr = vim.api.nvim_create_buf(false, true)

   -- Store initial state on the buffer object for resets
   vim.b[float_bufnr].original_lines = vim.deepcopy(file_lines)
   vim.b[float_bufnr].original_path = full_path

   -- Define target scratch buffer name
   local target_buf_name = full_path .. " [Conflict Resolver]"

   -- Wipe out any existing stale buffer with the exact same name to prevent E95
   for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_valid(b) then
         local name = vim.api.nvim_buf_get_name(b)
         if name == target_buf_name then
            vim.api.nvim_buf_delete(b, { force = true })
         end
      end
   end

   -- Safely set buffer name
   pcall(function()
      vim.api.nvim_buf_set_name(float_bufnr, target_buf_name)
   end)

   vim.api.nvim_buf_set_lines(float_bufnr, 0, -1, false, file_lines)

   local initial_conflicts = count_conflict_blocks(file_lines)
   M.session_state.total_conflicts = initial_conflicts
   M.session_state.resolved_conflicts = 0

   local ft = nil
   if vim.filetype.match then
      ft = vim.filetype.match({ filename = full_path })
   end
   if ft then
      vim.bo[float_bufnr].filetype = ft
   end

   local ui = get_safe_ui()
   local width = math.max(10, ui.width - 6)
   local height = math.max(10, ui.height - 4)
   local col = math.floor((ui.width - width) / 2)
   local row = math.max(0, math.floor((ui.height - height) / 2) - 1)

   local winnr = vim.api.nvim_open_win(float_bufnr, true, {
      relative = "editor",
      width = width,
      height = height,
      col = col,
      row = row,
      title = " Merge Conflict Resolver ",
      style = "minimal",
      border = "rounded",
      title_pos = "left",
      zindex = 700,
   })

   M.setup_keymaps(float_bufnr, full_path, winnr, orig_win)
   M.highlight_conflicts(float_bufnr)
   M.update_top_right_counter(winnr)

   for i, line in ipairs(file_lines) do
      if line:match("^<<<<<<<") then
         safe_set_cursor(winnr, i, 0)
         break
      end
   end
end

function M.setup_keymaps(float_bufnr, target_path, winnr, orig_win)
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
      M.resolve_conflict_at_cursor(float_bufnr, target_path, "auto", orig_win)
      M.highlight_conflicts(float_bufnr)
   end, opts)

   vim.keymap.set("n", "b", function()
      M.resolve_conflict_at_cursor(float_bufnr, target_path, "both", orig_win)
      M.highlight_conflicts(float_bufnr)
   end, opts)

   vim.keymap.set("n", "q", function()
      if vim.api.nvim_win_is_valid(winnr) then
         vim.api.nvim_win_close(winnr, true)
      end
      if orig_win and vim.api.nvim_win_is_valid(orig_win) then
         vim.api.nvim_set_current_win(orig_win)
      end
   end, opts)

   vim.keymap.set("n", "j", function()
      local cur_line = vim.api.nvim_win_get_cursor(winnr)[1]
      local line_count = vim.api.nvim_buf_line_count(float_bufnr)
      local target = (cur_line >= line_count) and 1 or (cur_line + 1)
      safe_set_cursor(winnr, target, 0)
   end, opts)

   vim.keymap.set("n", "k", function()
      local cur_line = vim.api.nvim_win_get_cursor(winnr)[1]
      local line_count = vim.api.nvim_buf_line_count(float_bufnr)
      local target = (cur_line <= 1) and line_count or (cur_line - 1)
      safe_set_cursor(winnr, target, 0)
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
   local row = math.max(0, math.floor((ui.height - h) / 2) - 1)
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

   vim.api.nvim_buf_set_extmark(buf, M.conflict_ns, 3, 2, { end_col = 5, hl_group = "GitCompanionPromptKey" })
   vim.api.nvim_buf_set_extmark(buf, M.conflict_ns, 3, 31, { end_col = 34, hl_group = "GitCompanionPromptKey" })

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
end

function M.handle_merge_result(cmd_output, exit_code, orig_win)
   orig_win = orig_win or vim.api.nvim_get_current_win()
   local clean_output = strip_ansi(cmd_output)
   debug_log(string.format("handle_merge_result: exit_code=%d, orig_win=%s", exit_code, tostring(orig_win)))

   if exit_code ~= 0 and string.find(clean_output, "CONFLICT") then
      local conflicted_file = clean_output:match("Merge%s+conflict%s+in%s+([%w_%.%-%/]+)")
          or clean_output:match("CONFLICT%s*%(.-%):%s*Merge%s+conflict%s+in%s+([%w_%.%-%/]+)")
          or clean_output:match("CONFLICT.-in%s+([%w_%.%-%/]+)")

      if conflicted_file == "HEAD" then
         conflicted_file = nil
         for line in clean_output:gmatch("[^\r\n]+") do
            local file_match = line:match("Merge%s+conflict%s+in%s+([%w_%.%-%/]+)")
            if file_match and file_match ~= "HEAD" then
               conflicted_file = file_match
               break
            end
         end
      end

      if _G.close_floating and type(_G.close_floating) == "function" then
         _G.close_floating()
      end

      if conflicted_file then
         debug_log("Detected conflicted file path: " .. conflicted_file)
         M.prompt_resolve_conflicts(conflicted_file, function(should_resolve)
            if should_resolve then
               M.open_merge_conflict_resolver(conflicted_file, orig_win)
            end
         end)
      else
         debug_log("Failed to extract valid filename from conflict output", vim.log.levels.WARN)
      end
   end
end

local refresh_timer = nil

function M.refresh_ui(opts)
   opts = opts or {}
   local Ui = _G.Ui or _G["GitCompanionUi"] or (type(get_ui) == "function" and get_ui() or nil)
   if not Ui then
      return
   end

   if refresh_timer then
      vim.fn.timer_stop(refresh_timer)
      refresh_timer = nil
   end

   refresh_timer = vim.fn.timer_start(
      15,
      vim.schedule_wrap(function()
         refresh_timer = nil

         if type(M.update_window_layout) == "function" then
            M.update_window_layout()
         end

         if Ui.mode == "branches" and Ui.branches and #Ui.branches > 0 then
            Ui.selected_index = math.min(Ui.selected_index or 1, #Ui.branches)
            Ui.branch_selected = Ui.branches[Ui.selected_index]
         end

         local total = (Ui.mode == "branches") and #(Ui.branches or {})
             or (Ui.mode == "stashes" and #(Ui.stashes or {}) or #(Ui.changed_files or {}))
         Ui.selected_index = math.max(1, math.min(Ui.selected_index or 1, math.max(1, total)))

         if type(M.render_left) == "function" then
            M.render_left()
         end
         if type(M.render_right) == "function" then
            M.render_right()
         end
         if type(M.render_diff) == "function" then
            M.render_diff()
         end

         if Ui.left_win and vim.api.nvim_win_is_valid(Ui.left_win) then
            local line_count = (Ui.left_buf and vim.api.nvim_buf_is_valid(Ui.left_buf))
                and vim.api.nvim_buf_line_count(Ui.left_buf)
                or 0
            if line_count > 0 then
               local target_line = math.max(1, math.min(Ui.selected_index or 1, line_count))
               pcall(vim.api.nvim_win_set_cursor, Ui.left_win, { target_line, 0 })
            end
         end

         if not opts.skip_fetch then
            local ok_branches, branches_mod = pcall(require, "gitcompanion.branches")
            if
                ok_branches
                and branches_mod
                and Ui.mode == "branches"
                and type(branches_mod.load_branches_async) == "function"
            then
               branches_mod.load_branches_async(function(branches)
                  if branches then
                     Ui.branches = branches
                  end
                  if type(M.render_left) == "function" then
                     M.render_left()
                  end
               end)
            end

            if Ui.mode == "stashes" then
               local ok_stashes, stashes_mod = pcall(require, "gitcompanion.stashes")
               local status_mod = _G.status or (type(status) ~= "nil" and status or nil)
               local stash_fn = (ok_stashes and stashes_mod and stashes_mod.load_stashes_async)
                   or (status_mod and status_mod.get_stashes_async)

               if type(stash_fn) == "function" then
                  stash_fn(function(stashes)
                     if stashes then
                        Ui.stashes = stashes
                        local stash_total = #Ui.stashes
                        Ui.selected_index =
                            math.max(1, math.min(Ui.selected_index or 1, math.max(1, stash_total)))
                     end
                     if type(M.render_left) == "function" then
                        M.render_left()
                     end
                  end)
               end
            end

            local status_mod = _G.status or (type(status) ~= "nil" and status or nil)
            if status_mod and type(status_mod.get_changed_files_async) == "function" then
               status_mod.get_changed_files_async(function()
                  if type(M.render_left) == "function" then
                     M.render_left()
                  end
               end)
            end
         end
      end)
   )
end

vim.api.nvim_create_user_command("TC", function()
   -- 1. Create temporary directory for a test repo
   local repo_dir = vim.fn.tempname() .. "_git_test"
   vim.fn.mkdir(repo_dir, "p")

   -- Helper runner inside repo
   local function git(args)
      return vim.fn.system(string.format("git -C %s %s", vim.fn.shellescape(repo_dir), args))
   end

   -- 2. Setup git repo & base commit
   git("init -b main")
   git("config user.name 'Test'")
   git("config user.email 'test@test.com'")

   local test_file = repo_dir .. "/layout.lua"
   vim.fn.writefile({ "local M = {}", "print('initial')" }, test_file)
   git("add .")
   git("commit -m 'initial'")

   -- 3. Create feature branch & change file
   git("checkout -b feature")
   vim.fn.writefile({ "local M = {}", "print('feature branch change')" }, test_file)
   git("commit -am 'feature change'")

   -- 4. Change file on main branch
   git("checkout main")
   vim.fn.writefile({ "local M = {}", "print('main branch change')" }, test_file)
   git("commit -am 'main change'")

   -- 5. Trigger real merge conflict
   git("merge feature")

   -- 6. Launch your conflict resolver on the real conflicted file
   M.open_merge_conflict_resolver(test_file)
end, {})

return M
