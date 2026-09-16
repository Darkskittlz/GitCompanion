local M = {}
local status = require("gitcompanion.git.status")
local diff = require("gitcompanion.git.diff")
local graph = require("gitcompanion.git.graph")

-- Module-scoped state
local refresh_timer = nil
local floating_windows = {}
local current_win = nil
local current_buf = nil

-- Highlight namespaces
local ns_left = vim.api.nvim_create_namespace("gitcompanion_left_hl")
local ns_right = vim.api.nvim_create_namespace("gitcompanion_right_hl")
local ns_diff = vim.api.nvim_create_namespace("gitcompanion_diff_hl")

local function get_ui()
   local ok, state = pcall(require, "gitcompanion.state")
   return ok and state and state.Ui or _G.Ui
end

-------------------------------------------------------------------------------
-- 1. INITIALIZATION & WINDOW LAYOUT MANAGEMENT
-------------------------------------------------------------------------------
-- 1. Custom Purple Border Highlight
vim.api.nvim_set_hl(0, "GitCompanionActiveBorder", { fg = "#CA3A36", default = true })

-- 2. Define Border Styles
local active_border = {
   { "╭", "GitCompanionActiveBorder" },
   { "─", "GitCompanionActiveBorder" },
   { "╮", "GitCompanionActiveBorder" },
   { "│", "GitCompanionActiveBorder" },
   { "╯", "GitCompanionActiveBorder" },
   { "─", "GitCompanionActiveBorder" },
   { "╰", "GitCompanionActiveBorder" },
   { "│", "GitCompanionActiveBorder" },
}

local inactive_border = {
   { "╭", "FloatBorder" },
   { "─", "FloatBorder" },
   { "╮", "FloatBorder" },
   { "│", "FloatBorder" },
   { "╯", "FloatBorder" },
   { "─", "FloatBorder" },
   { "╰", "FloatBorder" },
   { "│", "FloatBorder" },
}

-- 3. Dynamic Border Refresh
local function update_active_borders()
   local Ui = get_ui()
   if not Ui then
      return
   end

   local cur_win = vim.api.nvim_get_current_win()
   local wins = { Ui.diff_win, Ui.left_win, Ui.right_win }

   for _, win in ipairs(wins) do
      if win and vim.api.nvim_win_is_valid(win) then
         local border_style = (win == cur_win) and active_border or inactive_border
         vim.api.nvim_win_set_config(win, { border = border_style })
      end
   end
end

-- 4. Autocmd for Focus Switching
vim.api.nvim_create_autocmd({ "WinEnter", "BufEnter" }, {
   group = vim.api.nvim_create_augroup("GitCompanionBorders", { clear = true }),
   callback = function()
      update_active_borders()
   end,
})

-- 2. HIGHLIGHT GROUP SETUP
local function setup_border_highlights()
   local colors = {
      "#e06c75", -- Red
      "#d19a66", -- Orange
      "#e5c07b", -- Yellow
      "#98c379", -- Green
      "#56b6c2", -- Cyan
      "#61afef", -- Blue
      "#c678dd", -- Purple
      "#be5046", -- Dark Red
   }
   for i, color in ipairs(colors) do
      vim.api.nvim_set_hl(0, "RainbowBorder" .. i, { fg = color, default = true })
   end

   -- Commit Log & UI Highlights
   vim.api.nvim_set_hl(0, "GitHash", { fg = "#00d7ff", bold = true, default = true })
   vim.api.nvim_set_hl(0, "GitDate", { fg = "#db302d", italic = true, default = true })
   vim.api.nvim_set_hl(0, "GitAuthor", { fg = "#00a77d", italic = true, default = true })
   vim.api.nvim_set_hl(0, "GitOutput", { fg = "#40a02b", bold = false, italic = false, default = true })
   vim.api.nvim_set_hl(0, "GitError", { fg = "#FF6F69", bold = false, italic = false, default = true })
   vim.api.nvim_set_hl(0, "GitMsg", { fg = "#777777", bold = false, italic = false, default = true })
end

-------------------------------------------------------------------------------
-- UI INITIALIZATION & LAYOUT
-------------------------------------------------------------------------------
function M.init_ui()
   -- Initialize highlight groups on start
   setup_border_highlights()

   local Ui = get_ui()

   status.get_changed_files_async(function()
      if Ui and Ui.changed_files and #Ui.changed_files > 0 then
         Ui.mode = "files"
      elseif Ui then
         Ui.mode = "branches"
      end
      if Ui then
         Ui.selected_index = 1
      end

      M.update_window_layout()

      local load_branches = status.load_branches_async or (Ui and Ui.load_branches_async)
      if type(load_branches) == "function" then
         load_branches(function()
            M.refresh_ui({ skip_fetch = true })
         end)
      end
   end)
end

function M.update_window_layout()
   local Ui = get_ui()
   if not Ui then
      return
   end

   local ui_info = vim.api.nvim_list_uis()[1]
   local editor_w = ui_info and ui_info.width or vim.o.columns
   local editor_h = ui_info and ui_info.height or vim.o.lines

   local statusline_h = (vim.o.laststatus > 0) and 1 or 0
   local available_h = editor_h - vim.o.cmdheight - statusline_h

   local w = math.floor(editor_w * 0.9)
   local col = math.floor((editor_w - w) / 2)

   local help_h = 1
   local branch_h = 4
   local lower_h = 8
   local log_h = 8

   local help_row = available_h - help_h - 2
   local branch_row = help_row - branch_h - 2
   local log_row = branch_row - log_h - 2
   local lower_row = help_row - lower_h - 2
   local diff_row = 2

   local target_lower_row = (Ui.mode == "branches") and log_row or lower_row
   local diff_h = math.max(target_lower_row - diff_row - 2, 1)

   -- 1. Top Diff Window
   if not Ui.diff_buf or not vim.api.nvim_buf_is_valid(Ui.diff_buf) then
      Ui.diff_buf = vim.api.nvim_create_buf(false, true)
      vim.bo[Ui.diff_buf].filetype = "diff"
      vim.bo[Ui.diff_buf].syntax = "diff"
      vim.bo[Ui.diff_buf].bufhidden = "hide"
   end

   local diff_cfg = {
      relative = "editor",
      width = w,
      height = diff_h,
      row = diff_row,
      col = col,
      style = "minimal",
      border = inactive_border,
      title = " Code Changes ",
      title_pos = "center",
   }

   if not Ui.diff_win or not vim.api.nvim_win_is_valid(Ui.diff_win) then
      Ui.diff_win = vim.api.nvim_open_win(Ui.diff_buf, false, diff_cfg)
   else
      vim.api.nvim_win_set_config(Ui.diff_win, diff_cfg)
   end

   -- 2. Commit Log Window
   if Ui.mode == "branches" then
      if not Ui.right_buf or not vim.api.nvim_buf_is_valid(Ui.right_buf) then
         Ui.right_buf = vim.api.nvim_create_buf(false, true)
         vim.bo[Ui.right_buf].filetype = "git"
         vim.bo[Ui.right_buf].bufhidden = "hide"
      end

      local right_cfg = {
         relative = "editor",
         width = w,
         height = log_h,
         row = log_row,
         col = col,
         style = "minimal",
         border = inactive_border,
         title = " Commit Log ",
         title_pos = "center",
         zindex = 10,
      }

      if not Ui.right_win or not vim.api.nvim_win_is_valid(Ui.right_win) then
         Ui.right_win = vim.api.nvim_open_win(Ui.right_buf, false, right_cfg)
      else
         vim.api.nvim_win_set_config(Ui.right_win, right_cfg)
      end
   else
      if Ui.right_win and vim.api.nvim_win_is_valid(Ui.right_win) then
         pcall(vim.api.nvim_win_close, Ui.right_win, true)
         Ui.right_win = nil
      end
   end

   -- 3. Navigation / List Window
   local titles = {
      files = " Files ",
      branches = " Branches ",
      stashes = " Stashes ",
   }
   local left_title = titles[Ui.mode] or " Files "
   local left_h = (Ui.mode == "branches") and branch_h or lower_h
   local left_row = (Ui.mode == "branches") and branch_row or lower_row

   local left_cfg = {
      relative = "editor",
      width = w,
      height = left_h,
      row = left_row,
      col = col,
      border = inactive_border,
      title = left_title,
      title_pos = "center",
   }

   if not Ui.left_win or not vim.api.nvim_win_is_valid(Ui.left_win) then
      Ui.left_win = vim.api.nvim_open_win(Ui.left_buf, false, left_cfg)
   else
      vim.api.nvim_win_set_config(Ui.left_win, left_cfg)
   end

   -- Apply dynamic borders based on current focus
   update_active_borders()
end

function M.toggle_mode(direction)
   local Ui = get_ui()
   if not Ui then
      return
   end

   local modes = { "branches", "files", "stashes" }
   local current_idx = 1
   for i, m in ipairs(modes) do
      if m == Ui.mode then
         current_idx = i
         break
      end
   end

   if direction == "next" then
      current_idx = (current_idx % #modes) + 1
   elseif direction == "prev" then
      current_idx = (current_idx - 2 + #modes) % #modes + 1
   end

   Ui.mode = modes[current_idx]
   Ui.selected_index = 1
   Ui.user_navigated = true

   M.refresh_ui()

   -- 1. Switch active window focus first
   local active_win = (Ui.mode == "branches") and Ui.right_win or Ui.left_win
   if active_win and vim.api.nvim_win_is_valid(active_win) then
      vim.api.nvim_set_current_win(active_win)
      pcall(vim.api.nvim_win_set_cursor, active_win, { 1, 0 })
   end

   -- 2. Update layout and borders for focused window
   M.update_window_layout()

   -- 3. Trigger diff population
   M.render_diff()
end

-------------------------------------------------------------------------------
-- 2. BUFFER RENDERING LOGIC
-------------------------------------------------------------------------------
function M.render_left()
   local Ui = get_ui()
   if not Ui or not Ui.left_buf or not vim.api.nvim_buf_is_valid(Ui.left_buf) then
      return
   end

   local buf = Ui.left_buf
   local ns_left = vim.api.nvim_create_namespace("gitcompanion_left_hl")

   if Ui.left_win and vim.api.nvim_win_is_valid(Ui.left_win) then
      local titles = {
         files = " Files ",
         branches = " Branches ",
         stashes = " Stashes ",
      }
      vim.api.nvim_win_set_config(Ui.left_win, {
         title = titles[Ui.mode] or " Files ",
         title_pos = "center",
      })
      update_active_borders()
   end

   if Ui.mode == "files" then
      local ok, tree = pcall(require, "gitcompanion.ui.tree")
      if not ok then
         ok, tree = pcall(require, "gitcompanion.tree")
      end

      if ok and type(tree) == "table" and type(tree.render_files_tree) == "function" then
         tree.render_files_tree()
      end

      M.render_diff()
      return
   end

   local lines = {}
   local highlights = {}

   if Ui.mode == "branches" then
      local current = (Ui.current_branch and Ui.current_branch ~= "") and Ui.current_branch
          or Ui.branch_selected
          or "HEAD"
      local branches = Ui.branches or {}

      for i, b in ipairs(branches) do
         local marker = (b == current) and "*" or " "
         local status_text = (Ui.branch_statuses and Ui.branch_statuses[b]) or ""
         local ahead_behind = (Ui.branch_ahead_behind and Ui.branch_ahead_behind[b]) or ""
         table.insert(lines, string.format("%2s %s %s %s", marker, b, status_text, ahead_behind))

         if b == current then
            table.insert(highlights, { line = i, hl = "GitBranchCurrent" })
         end
      end
   elseif Ui.mode == "stashes" then
      if not Ui.stashes_loaded then
         Ui.stashes_loaded = true

         local ok_state, state_mod = pcall(require, "gitcompanion.state")
         if ok_state and type(state_mod.load_stashes_async) == "function" then
            state_mod.load_stashes_async(function(stashes)
               Ui.stashes = stashes or {}
               M.render_left()
            end)
         else
            Ui.stashes = vim.fn.systemlist("git stash list") or {}
            M.render_left()
         end
      end

      local stashes = Ui.stashes or {}
      local parsed_stashes = {}
      local max_branch_len = 0

      for _, s in ipairs(stashes) do
         local branch, msg = s:match("^stash@{%d+}:%s*On%s+([^:]+):%s*(.*)$")
         if not branch then
            msg = s:match("^stash@{%d+}:%s*(.*)$") or s
            branch = "stash"
         end
         if #branch > max_branch_len then
            max_branch_len = #branch
         end
         table.insert(parsed_stashes, { branch = branch, msg = msg })
      end

      for i, item in ipairs(parsed_stashes) do
         local prefix = string.format("  %d. ", i)
         local padded_branch = item.branch .. string.rep(" ", max_branch_len - #item.branch)
         local separator = " "
         local line_text = prefix .. padded_branch .. separator .. item.msg

         table.insert(lines, line_text)

         local prefix_bytes = #prefix
         local branch_bytes = #padded_branch

         table.insert(highlights, {
            line = i,
            hl = "GitStashNumber",
            col = 0,
            end_col = prefix_bytes,
         })

         table.insert(highlights, {
            line = i,
            hl = "GitStashBranch",
            col = prefix_bytes,
            end_col = prefix_bytes + branch_bytes,
         })

         table.insert(highlights, {
            line = i,
            hl = "GitStashText",
            col = prefix_bytes + branch_bytes,
            end_col = -1,
         })
      end
   end

   if #lines == 0 then
      local placeholder = (Ui.mode == "stashes" and not Ui.stashes) and "  (Loading stashes...)"
          or "  (No items available)"
      lines = { placeholder }
   end

   vim.bo[buf].modifiable = true
   vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
   vim.api.nvim_buf_clear_namespace(buf, ns_left, 0, -1)
   for _, h in ipairs(highlights) do
      vim.api.nvim_buf_add_highlight(buf, ns_left, h.hl, h.line - 1, h.col or 0, h.end_col or h.length or -1)
   end

   vim.bo[buf].modifiable = false
   vim.bo[buf].modified = false

   M.render_diff()
end

function M.render_right()
   local Ui = get_ui()
   if not Ui or not Ui.right_buf or not vim.api.nvim_buf_is_valid(Ui.right_buf) then
      return
   end

   vim.api.nvim_set_option_value("modifiable", true, { buf = Ui.right_buf })
   vim.api.nvim_buf_clear_namespace(Ui.right_buf, ns_right, 0, -1)

   local branch = Ui.branch_selected or "HEAD"
   local raw_out = Ui.commit_graph_cache and Ui.commit_graph_cache[branch]

   local out = {}
   if type(raw_out) == "string" then
      out = vim.split(raw_out, "\n", { trimempty = true })
   elseif type(raw_out) == "table" and #raw_out > 0 then
      out = raw_out
   else
      out = { "[Loading commit graph...]" }
      local fetch_graph = graph.fetch_git_graph_async or (Ui and Ui.fetch_git_graph_async)
      if type(fetch_graph) == "function" then
         fetch_graph(branch)
      end
   end

   if #out == 0 then
      out = { "[No commits]" }
   end

   vim.api.nvim_buf_set_lines(Ui.right_buf, 0, -1, false, out)

   local config = require("gitcompanion.config")
   local graph_chars_list = (config.options and config.options.graph_chars)
       or _G.graph_chars
       or { "*", "|", "/", "\\", "-", "o", "◯", "│", "╮", "╯", "─" }

   local graph_colors = (config.options and config.options.graph_colors)
       or _G.graph_colors
       or { "#5fff5f", "#5fd7ff", "#ffaf5f", "#ff5fff" }

   Ui.branch_colors = Ui.branch_colors or {}

   for line_idx, line in ipairs(out) do
      -- 1. Highlight Graph Symbols (* | / \ - o)
      local byte_pos = 1
      for char in line:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
         local char_bytes = #char
         if vim.tbl_contains(graph_chars_list, char) then
            if not Ui.branch_colors[byte_pos] and #graph_colors > 0 then
               local color = graph_colors[((byte_pos - 1) % #graph_colors) + 1]
               Ui.branch_colors[byte_pos] = color
               vim.api.nvim_set_hl(0, "GitGraphSymbol" .. byte_pos, { fg = color, default = true })
            end
            vim.api.nvim_buf_add_highlight(
               Ui.right_buf,
               ns_right,
               "GitGraphSymbol" .. byte_pos,
               line_idx - 1,
               byte_pos - 1,
               byte_pos - 1 + char_bytes
            )
         end
         byte_pos = byte_pos + char_bytes
      end

      -- 2. Token-based Highlight Matching (Resilient to extra spaces/formats)
      -- Find 7+ char hex hash
      local h_start, h_end = line:find("%x%x%x%x%x%x%x+")
      if h_start then
         vim.api.nvim_buf_add_highlight(Ui.right_buf, ns_right, "GitHash", line_idx - 1, h_start - 1, h_end)

         -- Find date mm/dd/yy after hash
         local d_start, d_end = line:find("%d%d/%d%d/%d%d", h_end + 1)
         if d_start then
            vim.api.nvim_buf_add_highlight(Ui.right_buf, ns_right, "GitDate", line_idx - 1, d_start - 1, d_end)

            -- Find author (first non-whitespace word after date)
            local a_start, a_end, author = line:find("(%S+)", d_end + 1)
            if a_start then
               vim.api.nvim_buf_add_highlight(
                  Ui.right_buf,
                  ns_right,
                  "GitAuthor",
                  line_idx - 1,
                  a_start - 1,
                  a_end
               )

               -- Rest of line is commit message
               local m_start = line:find("%S", a_end + 1)
               if m_start then
                  vim.api.nvim_buf_add_highlight(Ui.right_buf, ns_right, "GitMsg", line_idx - 1, m_start - 1, -1)
               end
            end
         end
      end
   end

   vim.api.nvim_set_option_value("modifiable", false, { buf = Ui.right_buf })
end

function M.fetch_diff_async(file_path, is_dir)
   return diff.fetch_diff_async(file_path, is_dir)
end

function M.get_current_selected_path()
   local Ui = require("gitcompanion.state").Ui
   if not Ui or not Ui.left_win or not vim.api.nvim_win_is_valid(Ui.left_win) then
      return nil, false
   end

   local cursor_line = vim.api.nvim_win_get_cursor(Ui.left_win)[1]
   local item = (Ui.flat_nodes or {})[cursor_line]

   if not item or not item.node then
      return nil, false
   end

   -- If a directory is highlighted, don't attempt to pull a file diff directly
   if item.node.is_dir then
      return item.node.path, true
   end

   return item.node.path, false
end

function M.get_selected_commit_hash()
   local State = require("gitcompanion.state")
   local ui = State.Ui
   if not ui or not ui.right_win or not vim.api.nvim_win_is_valid(ui.right_win) then
      return nil
   end

   local cursor_line = vim.api.nvim_win_get_cursor(ui.right_win)[1]
   local line_text = vim.api.nvim_buf_get_lines(ui.right_buf, cursor_line - 1, cursor_line, false)[1]

   if not line_text then
      return nil
   end

   -- Extract 7-40 character git hash (e.g., matching "01c7c24")
   local hash = line_text:match("(%x%x%x%x%x%x%x+)")
   return hash
end

function M.render_diff()
   local State = require("gitcompanion.state")
   local diff_mod = require("gitcompanion.git.diff")
   local ui = State.Ui
   if not ui or not ui.diff_buf or not vim.api.nvim_buf_is_valid(ui.diff_buf) then
      return
   end

   ui.diff_cache = ui.diff_cache or {}
   local lines = nil

   -- 1. MODE: Files / Working Tree
   if ui.mode == "files" then
      local path, is_dir = M.get_current_selected_path()

      if is_dir or not path then
         lines = {
            "--- Directory selected: " .. tostring(path or "root") .. " ---",
            "Select an individual file below to view diffs.",
         }
      elseif ui.diff_cache[path] then
         lines = ui.diff_cache[path]
      else
         lines = { "[Loading file diff...]" }
         if type(diff_mod.fetch_diff_async) == "function" then
            diff_mod.fetch_diff_async(path, is_dir)
         end
      end

      -- 2. MODE: Commits / Branches
   elseif ui.mode == "commits" or ui.mode == "branches" then
      local selected_commit = M.get_selected_commit_hash()

      if not selected_commit then
         lines = { "No commit selected." }
      elseif ui.diff_cache[selected_commit] then
         lines = ui.diff_cache[selected_commit]
      else
         lines = { "[Loading commit diff for " .. selected_commit .. "...]" }
         if type(diff_mod.fetch_commit_diff_async) == "function" then
            diff_mod.fetch_commit_diff_async(selected_commit)
         end
      end

      -- 3. MODE: Stashes
   elseif ui.mode == "stashes" then
      local cursor_line = 1
      if ui.left_win and vim.api.nvim_win_is_valid(ui.left_win) then
         cursor_line = vim.api.nvim_win_get_cursor(ui.left_win)[1]
      else
         cursor_line = ui.selected_index or 1
      end

      local stashes = ui.stashes or {}
      if #stashes == 0 then
         lines = { "No stashes available." }
      else
         -- Calculate zero-indexed stash reference from line position
         local stash_index = math.max(0, cursor_line - 1)
         local stash_ref = string.format("stash@{%d}", stash_index)

         if ui.diff_cache[stash_ref] then
            lines = ui.diff_cache[stash_ref]
         else
            lines = { "[Loading stash diff for " .. stash_ref .. "...]" }
            if type(diff_mod.fetch_stash_diff_async) == "function" then
               diff_mod.fetch_stash_diff_async(stash_ref)
            else
               -- Fallback if async loader isn't attached yet
               local out = vim.fn.systemlist("git stash show -p " .. stash_ref)
               lines = (#out > 0) and out or { "  (Empty stash diff)" }
               ui.diff_cache[stash_ref] = lines
            end
         end
      end
   end

   if lines then
      vim.bo[ui.diff_buf].modifiable = true
      vim.api.nvim_buf_set_lines(ui.diff_buf, 0, -1, false, lines)
      vim.bo[ui.diff_buf].modifiable = false
      vim.bo[ui.diff_buf].modified = false

      -- Activate syntax highlighting
      vim.bo[ui.diff_buf].filetype = "diff"
      vim.bo[ui.diff_buf].syntax = "diff"
   end
end

-------------------------------------------------------------------------------
-- 3. UI REFRESH DEBOUNCER
-------------------------------------------------------------------------------
function M.refresh_ui(opts)
   opts = opts or {}
   local Ui = get_ui()
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

         M.update_window_layout()

         if Ui.mode == "branches" and Ui.branches and #Ui.branches > 0 then
            Ui.selected_index = math.min(Ui.selected_index or 1, #Ui.branches)
            Ui.branch_selected = Ui.branches[Ui.selected_index]
         end

         local total = (Ui.mode == "branches") and #(Ui.branches or {})
             or (Ui.mode == "stashes" and #(Ui.stashes or {}) or #(Ui.changed_files or {}))
         Ui.selected_index = math.max(1, math.min(Ui.selected_index or 1, math.max(1, total)))

         M.render_left()
         M.render_right()
         M.render_diff()

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
                  M.render_left()
               end)
            end

            if Ui.mode == "stashes" then
               local ok_stashes, stashes_mod = pcall(require, "gitcompanion.stashes")
               local stash_fn = (ok_stashes and stashes_mod and stashes_mod.load_stashes_async)
                   or (status and status.get_stashes_async)

               if type(stash_fn) == "function" then
                  stash_fn(function(stashes)
                     if stashes then
                        Ui.stashes = stashes
                        local stash_total = #Ui.stashes
                        Ui.selected_index =
                            math.max(1, math.min(Ui.selected_index or 1, math.max(1, stash_total)))
                     end
                     M.render_left()
                  end)
               end
            end

            -- Call status module directly
            if status and type(status.get_changed_files_async) == "function" then
               status.get_changed_files_async(function()
                  M.render_left()
               end)
            end
         end
      end)
   )
end

function M.save_active_window()
   current_win = vim.api.nvim_get_current_win()
   current_buf = vim.api.nvim_get_current_buf()
end

function M.restore_active_window()
   if current_win and vim.api.nvim_win_is_valid(current_win) then
      pcall(vim.api.nvim_set_current_win, current_win)
   end
end

-------------------------------------------------------------------------------
-- 4. UTILITY & POPUP WINDOW FUNCTIONS
-------------------------------------------------------------------------------
function M.close_floating()
   for _, w in pairs(floating_windows) do
      if vim.api.nvim_win_is_valid(w) then
         pcall(vim.api.nvim_win_close, w, true)
      end
   end
   floating_windows = {}

   local Ui = get_ui()
   if Ui then
      Ui.mode = "branches"
   end
   M.refresh_ui()
   M.restore_active_window()
end

function M.show_floating_pair(stdout_lines, stderr_lines)
   -- Combine stdout and stderr into a single list of lines
   local combined_lines = {}
   for _, line in ipairs(stdout_lines or {}) do
      table.insert(combined_lines, line)
   end
   for _, line in ipairs(stderr_lines or {}) do
      table.insert(combined_lines, line)
   end

   local full_text = table.concat(combined_lines, "\n")
   if string.find(full_text, "CONFLICT") then
      return
   end

   M.save_active_window()

   local ui = vim.api.nvim_list_uis()[1]
   local width = math.min(80, ui.width - 4)
   local height = math.max(#combined_lines + 2, 3)
   local top = math.floor((ui.height - height) / 2)
   local col = math.floor((ui.width - width) / 2)

   local buf = vim.api.nvim_create_buf(false, true)
   vim.api.nvim_buf_set_lines(buf, 0, -1, false, combined_lines)
   vim.bo[buf].modifiable = false

   local win = vim.api.nvim_open_win(buf, true, {
      relative = "editor",
      width = width,
      height = height,
      row = top,
      col = col,
      style = "minimal",
      border = "rounded",
      title = " Git Output ",
      title_pos = "center",
      zindex = 600,
   })

   floating_windows.output = win

   local opts = { buffer = buf, nowait = true, silent = true }
   vim.keymap.set("n", "q", M.close_floating, opts)
end

function M.close()
   local Ui = get_ui()
   if not Ui then
      return
   end

   for _, buf_key in ipairs({ "diff_buf", "right_buf", "left_buf", "help_buf" }) do
      if Ui[buf_key] and vim.api.nvim_buf_is_valid(Ui[buf_key]) then
         pcall(vim.api.nvim_buf_delete, Ui[buf_key], { force = true })
         Ui[buf_key] = nil
      end
   end

   for _, win_key in ipairs({ "diff_win", "left_win", "right_win", "help_win" }) do
      if Ui[win_key] and vim.api.nvim_win_is_valid(Ui[win_key]) then
         pcall(vim.api.nvim_win_close, Ui[win_key], true)
         Ui[win_key] = nil
      end
   end
end

local ok, state = pcall(require, "gitcompanion.state")
if ok and type(state.register_refresh_ui) == "function" then
   state.register_refresh_ui(M.refresh_ui)
end

return M
