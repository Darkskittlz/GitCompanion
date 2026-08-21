-- lua/gitcompanion/keymaps/commits.lua
local reset = require("gitcompanion.git.reset")
local M = {}

--- Opens interactive fuzzy picker for checking out remote branches
local function checkout_remote_branch(state)
   local Ui = state.Ui or state
   local remotes = vim.fn.systemlist("git branch -r --format='%(refname:short)'")
   local missing = {}
   local local_set = {}

   for _, b in ipairs(Ui.branches or {}) do
      local_set[b] = true
   end

   for _, r in ipairs(remotes) do
      local _, branch_name = r:match("^([^/]+)/(.*)$")
      if branch_name and branch_name ~= "HEAD" and not local_set[branch_name] then
         if not vim.tbl_contains(missing, branch_name) then
            table.insert(missing, branch_name)
         end
      end
   end

   if #missing == 0 then
      if state.show_centered_message then
         state.show_centered_message("No remote branches available to checkout.", "❄️")
      end
      return
   end

   local ui_info = vim.api.nvim_list_uis()[1]
   local width = math.floor(ui_info.width * 0.6)
   local max_height = math.floor(ui_info.height * 0.6)
   local height = math.max(10, math.min(max_height, #missing + 3))

   local row = math.floor((ui_info.height - height) / 2)
   local col = math.floor((ui_info.width - width) / 2)

   local buf = vim.api.nvim_create_buf(false, true)
   local win = vim.api.nvim_open_win(buf, true, {
      relative = "editor",
      width = width,
      height = height,
      row = row,
      col = col,
      style = "minimal",
      border = "rounded",
      title = " Checkout Remote Branch ",
      title_pos = "center",
      zindex = 500,
   })

   vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "> " })

   local query = ""
   local filtered = vim.deepcopy(missing)
   local selected = 1

   local function render()
      local lines = { string.rep("─", width) }
      for i, b in ipairs(filtered) do
         local prefix = (i == selected) and "  " or "   "
         table.insert(lines, prefix .. b)
      end
      vim.api.nvim_buf_set_lines(buf, 1, -1, false, lines)
      vim.api.nvim_buf_clear_namespace(buf, -1, 1, -1)
      if #filtered > 0 then
         vim.api.nvim_buf_add_highlight(buf, -1, "MergeBlue", selected + 1, 0, -1)
      end
   end

   render()

   vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
      buffer = buf,
      callback = function()
         local line = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] or ""
         local q = line
         if q:sub(1, 2) == "> " then
            q = q:sub(3)
         else
            vim.api.nvim_buf_set_lines(buf, 0, 1, false, { "> " .. q })
            vim.api.nvim_win_set_cursor(win, { 1, #q + 2 })
         end

         if q == query then
            return
         end
         query = q

         filtered = {}
         for _, b in ipairs(missing) do
            if b:lower():find(query:lower(), 1, true) then
               table.insert(filtered, b)
            end
         end
         selected = math.min(selected, math.max(1, #filtered))
         render()
      end,
   })

   local function close_popup()
      vim.cmd("stopinsert")
      if vim.api.nvim_win_is_valid(win) then
         vim.api.nvim_win_close(win, true)
      end
      if vim.api.nvim_buf_is_valid(buf) then
         vim.api.nvim_buf_delete(buf, { force = true })
      end
   end

   local function confirm_selection()
      if #filtered == 0 then
         return
      end
      local choice = filtered[selected]
      close_popup()

      local cmd = "git switch " .. vim.fn.shellescape(choice)
      local result = vim.fn.system(cmd)
      if vim.v.shell_error ~= 0 then
         if state.show_centered_message then
            state.show_centered_message("Failed to switch branch:\n" .. result, "❌")
         end
         return
      end

      Ui.branch_selected = choice
      if state.show_centered_message then
         state.show_centered_message("Switched to branch: " .. choice, "✅")
      end

      if state.load_branches_async then
         state.load_branches_async()
      end
      Ui.selected_index = 1
      if state.refresh_ui then
         state.refresh_ui()
      end
   end

   local map_opts = { buffer = buf, noremap = true, silent = true }

   local function move_down()
      selected = math.min(#filtered, selected + 1)
      render()
   end

   local function move_up()
      selected = math.max(1, selected - 1)
      render()
   end

   vim.keymap.set("i", "<C-j>", move_down, map_opts)
   vim.keymap.set("i", "<C-n>", move_down, map_opts)
   vim.keymap.set("i", "<Down>", move_down, map_opts)
   vim.keymap.set("i", "<C-k>", move_up, map_opts)
   vim.keymap.set("i", "<C-p>", move_up, map_opts)
   vim.keymap.set("i", "<Up>", move_up, map_opts)
   vim.keymap.set("i", "<CR>", confirm_selection, map_opts)
   vim.keymap.set("i", "<Esc>", close_popup, map_opts)
   vim.keymap.set("i", "<C-c>", close_popup, map_opts)

   vim.keymap.set("n", "j", move_down, map_opts)
   vim.keymap.set("n", "k", move_up, map_opts)
   vim.keymap.set("n", "<CR>", confirm_selection, map_opts)
   vim.keymap.set("n", "q", close_popup, map_opts)
   vim.keymap.set("n", "<Esc>", close_popup, map_opts)

   vim.cmd("startinsert!")
   vim.api.nvim_win_set_cursor(win, { 1, 2 })
end

--- Opens commit creation overlay with staged diff preview
local function open_commit_modal(state)
   local Ui = state.Ui or state
   local branch = (Ui.branches and Ui.branches[Ui.selected_index]) or Ui.branch_selected or "HEAD"

   local width = math.floor(vim.o.columns * 0.9)
   local height_title = 1
   local height_desc = 4
   local height_diff = math.floor(vim.o.lines * 0.72)
   local spacing = 1
   local col = math.floor((vim.o.columns - width) / 2)

   local buf_overlay = vim.api.nvim_create_buf(false, true)
   vim.api.nvim_buf_set_lines(buf_overlay, 0, -1, false, { string.rep(" ", width) })
   local win_overlay = vim.api.nvim_open_win(buf_overlay, false, {
      relative = "editor",
      width = vim.o.columns,
      height = vim.o.lines,
      row = 0,
      col = 0,
      style = "minimal",
      border = "none",
      zindex = 200,
   })

   local buf_diff = vim.api.nvim_create_buf(false, true)
   vim.api.nvim_buf_set_option(buf_diff, "buftype", "nofile")
   vim.api.nvim_buf_set_option(buf_diff, "bufhidden", "wipe")
   vim.api.nvim_buf_set_option(buf_diff, "filetype", "diff")

   local diff_lines = vim.fn.systemlist("git diff --cached")
   if vim.v.shell_error ~= 0 or #diff_lines == 0 then
      diff_lines = { "[No staged changes]" }
   end
   vim.api.nvim_buf_set_lines(buf_diff, 0, -1, false, diff_lines)
   vim.api.nvim_buf_set_option(buf_diff, "modifiable", false)

   local buf_title = vim.api.nvim_create_buf(false, true)
   vim.api.nvim_buf_set_option(buf_title, "buftype", "acwrite")
   vim.api.nvim_buf_set_option(buf_title, "bufhidden", "wipe")

   local buf_desc = vim.api.nvim_create_buf(false, true)
   vim.api.nvim_buf_set_option(buf_desc, "buftype", "acwrite")
   vim.api.nvim_buf_set_option(buf_desc, "bufhidden", "wipe")
   vim.api.nvim_buf_set_lines(buf_desc, 0, -1, false, { "", "", "" })

   local win_diff = vim.api.nvim_open_win(buf_diff, false, {
      relative = "editor",
      width = width,
      height = height_diff - 3,
      row = 4,
      col = col,
      style = "minimal",
      border = "rounded",
      zindex = 300,
      focusable = true,
      title = " Commit ",
      title_pos = "center",
   })

   local win_title = vim.api.nvim_open_win(buf_title, true, {
      relative = "editor",
      width = width,
      height = height_title,
      row = 2 + height_diff + spacing,
      col = col,
      style = "minimal",
      border = "rounded",
      zindex = 300,
      title = " Title ",
      title_pos = "center",
   })

   local win_desc = vim.api.nvim_open_win(buf_desc, true, {
      relative = "editor",
      width = width,
      height = height_desc - 1,
      row = height_diff + height_title + 5,
      col = col,
      style = "minimal",
      border = "rounded",
      zindex = 300,
      title = " Description ",
      title_pos = "center",
   })

   local function close_commit_popup()
      for _, w in ipairs({ win_title, win_desc, win_diff, win_overlay }) do
         if vim.api.nvim_win_is_valid(w) then
            vim.api.nvim_win_close(w, true)
         end
      end

      if Ui.left_win and vim.api.nvim_win_is_valid(Ui.left_win) then
         vim.api.nvim_set_current_win(Ui.left_win)
      end
   end

   local function commit_changes()
      vim.cmd("stopinsert")
      local title = vim.api.nvim_buf_get_lines(buf_title, 0, -1, false)[1] or ""
      local body = table.concat(vim.api.nvim_buf_get_lines(buf_desc, 0, -1, false), "\n")

      local cmd = "git commit -m " .. vim.fn.shellescape(title)
      if body:match("%S") then
         cmd = cmd .. " -m " .. vim.fn.shellescape(body)
      end
      vim.fn.system(cmd)

      if state.show_centered_message then
         state.show_centered_message("Committed changes on branch: " .. branch, "🌸")
      end
      close_commit_popup()

      if state.get_changed_files_async then
         state.get_changed_files_async(function(files)
            Ui.changed_files = files or {}

            if #Ui.changed_files == 0 and Ui.mode == "files" then
               Ui.mode = "branches"
               Ui.selected_index = 1
               if type(state.update_window_layout) == "function" then
                  state.update_window_layout()
               end
            end

            if state.load_branches_async then
               state.load_branches_async(function()
                  if state.refresh_ui then
                     state.refresh_ui()
                  end
               end)
            end
         end)
      end
   end

   for _, b in ipairs({ buf_title, buf_desc, buf_diff }) do
      vim.keymap.set("n", "q", close_commit_popup, { buffer = b, noremap = true, silent = true })
      vim.keymap.set("n", "<Esc>", close_commit_popup, { buffer = b, noremap = true, silent = true })
      vim.keymap.set("n", "<Tab>", function()
         vim.api.nvim_set_current_win(win_desc)
      end, { buffer = b })
      vim.keymap.set("n", "<S-Tab>", function()
         vim.api.nvim_set_current_win(win_title)
      end, { buffer = b })

      vim.keymap.set("n", "<C-d>", function()
         vim.api.nvim_win_call(win_diff, function()
            vim.cmd("normal! <C-d>")
         end)
      end, { buffer = buf_diff, noremap = true, silent = false })

      vim.keymap.set("n", "<C-b>", function()
         vim.api.nvim_win_call(win_diff, function()
            vim.cmd("normal! <C-b>")
         end)
      end, { buffer = buf_diff, noremap = true, silent = false })
   end

   vim.keymap.set("n", "<CR>", commit_changes, { buffer = buf_title, noremap = true, silent = true })
   vim.keymap.set("n", "<CR>", commit_changes, { buffer = buf_desc, noremap = true, silent = true })

   vim.api.nvim_buf_set_lines(buf_title, 0, -1, false, { "" })
   vim.api.nvim_set_current_win(win_title)
   vim.cmd("startinsert")
end

function M.attach(buf, state)
   local Ui = state.Ui or state

   -- Bind 'c' globally across active context buffers
   for _, buf in ipairs({ Ui.left_buf, Ui.right_buf, Ui.diff_buf }) do
      if buf and vim.api.nvim_buf_is_valid(buf) then
         vim.keymap.set("n", "c", function()
            if Ui.mode == "branches" then
               checkout_remote_branch(state)
            elseif Ui.mode == "files" then
               open_commit_modal(state)
            end
         end, { buffer = buf, noremap = true, silent = true, desc = "Checkout remote or create commit" })
      end
   end

   local right_buf = Ui.right_buf
   if not right_buf or not vim.api.nvim_buf_is_valid(right_buf) then
      return
   end

   local right_opts = { buffer = right_buf, noremap = true, silent = true }

   -- Bind 'g' on right buffer for commit resets
   vim.keymap.set("n", "g", function()
      if Ui.mode ~= "branches" then
         return
      end

      local win = vim.api.nvim_get_current_win()
      if win ~= Ui.right_win then
         return
      end

      local cursor = vim.api.nvim_win_get_cursor(Ui.right_win)
      local line = vim.api.nvim_buf_get_lines(Ui.right_buf, cursor[1] - 1, cursor[1], false)[1] or ""

      local hash = line:match("(%x%x%x%x%x%x%x+)")
      if not hash then
         return
      end

      reset.open_reset_modal(hash, state)
   end, vim.tbl_extend("force", right_opts, { desc = "Reset/rebase options on commit" }))

   -- Bind 'r' on right buffer for renaming/reword commit
   vim.keymap.set("n", "r", function()
      local cursor = vim.api.nvim_win_get_cursor(Ui.right_win)
      local line = vim.api.nvim_buf_get_lines(Ui.right_buf, cursor[1] - 1, cursor[1], false)[1] or ""

      local hash = line:match("%f[%w](%x%x%x%x%x%x%x+)%f[%W]") or line:match("(%x%x%x%x%x%x%x+)")
      if not hash then
         vim.notify("Git: No valid commit hash found on current line.", vim.log.levels.WARN)
         return
      end

      local full_hash = vim.fn.system("git rev-parse " .. hash):gsub("%s+", "")
      local head_hash = vim.fn.system("git rev-parse HEAD"):gsub("%s+", "")
      local is_head = (full_hash == head_hash)

      local current_msg = vim.fn.system("git log -1 --format=%s " .. hash):gsub("%s+$", "")

      vim.ui.input({
         prompt = "Rename commit (" .. hash:sub(1, 7) .. "): ",
         default = current_msg,
      }, function(new_msg)
         if not new_msg or new_msg == "" or new_msg == current_msg then
            return
         end

         if is_head then
            local cmd = "git commit --amend -m " .. vim.fn.shellescape(new_msg)
            local out = vim.fn.system(cmd)
            if vim.v.shell_error == 0 then
               if state.show_centered_message then
                  state.show_centered_message("Renamed HEAD commit", "✏️")
               end
               if state.refresh_ui then
                  state.refresh_ui()
               end
            else
               vim.notify("Failed to rename HEAD commit: " .. out, vim.log.levels.ERROR)
            end
         else
            local stashed = false
            local status = vim.fn.system("git status --porcelain -uall"):gsub("%s+$", "")
            if #status > 0 then
               vim.fn.system("git stash push -m 'temp_reword_stash'")
               stashed = true
            end

            local tmp_msg_file = vim.fn.tempname()
            local f = io.open(tmp_msg_file, "w")
            if f then
               f:write(new_msg .. "\n")
               f:close()
            else
               vim.notify("Git: Failed to create temp file for commit message.", vim.log.levels.ERROR)
               return
            end

            local git_cmd = string.format(
               "GIT_SEQUENCE_EDITOR=\"sed -i '' 's/^pick %s/reword %s/' 2>/dev/null || sed -i 's/^pick %s/reword %s/'\" "
               .. "GIT_EDITOR=\"cp '%s'\" "
               .. "git rebase -i -r %s~1",
               hash:sub(1, 7),
               hash:sub(1, 7),
               hash:sub(1, 7),
               hash:sub(1, 7),
               tmp_msg_file,
               hash
            )

            local out = vim.fn.system(git_cmd)

            if vim.v.shell_error ~= 0 then
               vim.fn.system("git rebase --abort")
            end

            if stashed then
               vim.fn.system("git stash pop")
            end

            os.remove(tmp_msg_file)

            if vim.v.shell_error == 0 then
               if state.show_centered_message then
                  state.show_centered_message("Renamed commit " .. hash:sub(1, 7), "✏️")
               end
               if state.refresh_ui then
                  state.refresh_ui()
               end
            else
               vim.notify("Failed to reword commit: " .. out, vim.log.levels.ERROR)
            end
         end
      end)
   end, vim.tbl_extend("force", right_opts, { desc = "Rename commit under cursor" }))

   -- Bind 'y' on right buffer for yanking commit metadata
   vim.keymap.set("n", "y", function()
      local cursor = vim.api.nvim_win_get_cursor(Ui.right_win)
      local line = vim.api.nvim_buf_get_lines(Ui.right_buf, cursor[1] - 1, cursor[1], false)[1] or ""
      local hash = line:match("^(%S+)")

      if not hash then
         vim.notify("Git: No valid commit hash found on current line.", vim.log.levels.WARN)
         return
      end

      local options = {
         " 1. ID",
         " 2. Title",
         " 3. Description",
         " 4. Author",
         " 5. Time",
      }

      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, options)

      local width = 30
      local height = #options
      local ui = vim.api.nvim_list_uis()[1]
      local row = math.floor((ui.height - height) / 2)
      local col = math.floor((ui.width - width) / 2)

      local float_win = vim.api.nvim_open_win(buf, true, {
         relative = "editor",
         width = width,
         height = height,
         row = row,
         col = col,
         style = "minimal",
         border = "rounded",
         title = " Copy Commit ",
         title_pos = "center",
      })

      vim.bo[buf].modifiable = false
      vim.bo[buf].bufhidden = "wipe"
      vim.wo[float_win].cursorline = true

      local raw_hash = line:match("([a-f0-9]+)") or hash
      local clean_hash = vim.fn.shellescape(raw_hash)

      local function perform_yank(choice_num)
         if vim.api.nvim_win_is_valid(float_win) then
            vim.api.nvim_win_close(float_win, true)
         end

         local text_to_yank = ""
         local choice_name = ""

         if choice_num == 1 then
            choice_name = "ID"
            text_to_yank = vim.fn.system("git rev-parse " .. clean_hash):gsub("%s+", "")
         elseif choice_num == 2 then
            choice_name = "Title"
            text_to_yank = vim.fn.system("git log -1 --format=%s " .. clean_hash):gsub("%s+$", "")
         elseif choice_num == 3 then
            choice_name = "Description"
            text_to_yank = vim.fn.system("git log -1 --format=%b " .. clean_hash):gsub("%s+$", "")
         elseif choice_num == 4 then
            choice_name = "Author"
            text_to_yank = vim.fn.system("git log -1 --format='%an <%ae>' " .. clean_hash):gsub("%s+$", "")
         elseif choice_num == 5 then
            choice_name = "Time"
            text_to_yank = vim.fn.system("git log -1 --format=%cd " .. clean_hash):gsub("%s+$", "")
         end

         if text_to_yank ~= "" then
            vim.fn.setreg('"', text_to_yank)
            vim.fn.setreg("+", text_to_yank)
            if state.show_centered_message then
               state.show_centered_message("Yanked " .. choice_name .. ": " .. text_to_yank:sub(1, 35), "📋")
            end
         end
      end

      local m_opts = { buffer = buf, noremap = true, silent = true }
      for i = 1, 5 do
         vim.keymap.set("n", tostring(i), function()
            perform_yank(i)
         end, m_opts)
      end

      vim.keymap.set("n", "<CR>", function()
         local line_num = vim.api.nvim_win_get_cursor(float_win)[1]
         perform_yank(line_num)
      end, m_opts)

      for _, key in ipairs({ "<Esc>", "q" }) do
         vim.keymap.set("n", key, function()
            if vim.api.nvim_win_is_valid(float_win) then
               vim.api.nvim_win_close(float_win, true)
            end
         end, m_opts)
      end
   end, vim.tbl_extend("force", right_opts, { desc = "Yank commit metadata" }))
end

return M
