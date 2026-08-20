---@diagnostic disable: undefined-global
---
local conflicts = require("gitcompanion.conflicts")

local M = {}
local render_diff
local toggle_tree_node
local render_files_tree
local flatten_tree
local get_changed_files
local ns_id
local refresh_ui

-- Highlights
vim.api.nvim_set_hl(0, "GitBranchCurrent", { fg = "#549afc" })
vim.api.nvim_set_hl(0, "GitUnstaged", { fg = "#f99c67", bold = true, italic = true })
vim.api.nvim_set_hl(0, "GitStaged", { fg = "#a6e22e", bold = true })
vim.api.nvim_set_hl(0, "GitPickerTitle", { fg = "#268bd3", bold = true })

vim.api.nvim_set_hl(0, "DiffAdd", { fg = "#00aa00", bg = "", bold = false })    -- green
vim.api.nvim_set_hl(0, "DiffDelete", { fg = "#f92672", bg = "", bold = false }) -- red/pink
vim.api.nvim_set_hl(0, "DiffChange", { fg = "#fd971f", bg = "", bold = false }) -- orange/yellow

vim.api.nvim_set_hl(0, "MergeBlue", { fg = "#4da3ff", bold = true })
vim.api.nvim_set_hl(0, "MergeGreen", { fg = "#32cd32", bold = true })
vim.api.nvim_set_hl(0, "MergeRed", { fg = "#ff4444", bold = true })
vim.api.nvim_set_hl(0, "MergeWhite", { fg = "#bbbbbb", bold = true })

vim.api.nvim_set_hl(0, "ResetBlue", { fg = "#4da3ff", bold = true })
vim.api.nvim_set_hl(0, "ResetGreen", { fg = "#32cd32", bold = true })
vim.api.nvim_set_hl(0, "ResetRed", { fg = "#ff4444", bold = true })
vim.api.nvim_set_hl(0, "ResetWhite", { fg = "#bbbbbb", bold = true })

vim.api.nvim_set_hl(0, "GitGraphSymbol", { fg = "#5f87ff" })

-- Light Mode Colors
vim.api.nvim_set_hl(0, "GitHash", { fg = "#00d7ff", bold = true })
vim.api.nvim_set_hl(0, "GitDate", { fg = "#db302d", italic = true })
vim.api.nvim_set_hl(0, "GitAuthor", { fg = "#00a77d", italic = true })
vim.api.nvim_set_hl(0, "GitOutput", { fg = "#40a02b", bold = false, italic = false }) -- Light green for stdout (success)
vim.api.nvim_set_hl(0, "GitError", { fg = "#FF6F69", bold = false, italic = false })  -- Red for stderr (error)
vim.api.nvim_set_hl(0, "GitMsg", { fg = "#777777", bold = false, italic = false })

vim.api.nvim_set_hl(0, "GitCompanionOurs", { bg = "#2e3f33", default = true })
vim.api.nvim_set_hl(0, "GitCompanionTheirs", { bg = "#23374d", default = true })
vim.api.nvim_set_hl(0, "GitCompanionMarker", { bg = "#444444", bold = true, default = true })

-- Dark Mode Colors
-- vim.api.nvim_set_hl(0, "GitHash", { fg = "#11518c", bold = true, italic = false })
-- vim.api.nvim_set_hl(0, "GitDate", { fg = "#006400", bold = false, italic = true })
-- vim.api.nvim_set_hl(0, "GitMsg", { fg = "#ffffff" })

-- Git Graph Colors
local graph_chars = { "◯", "│", "╮", "╯", "─" }

-- branch colors
local graph_colors = {
   "#5fff5f", -- green
   "#5fd7ff", -- cyan
   "#ffaf5f", -- orange
   "#ff5fff", -- magenta
   "#ffff5f", -- yellow
   "#5f5fff", -- blue
   "#5fffff", -- light cyan
   "#ff5f5f", -- red
}

for i, c in ipairs(graph_colors) do
   vim.api.nvim_set_hl(0, "GitGraphSymbol" .. i, { fg = c })
end

vim.cmd([[
highlight GitStaged guifg=green
highlight GitStagedFile guifg=green
highlight GitUnstaged guifg=orange
highlight GitUnstagedFile guifg=orange
highlight GitBranchCurrent guifg=#00BFFF
]])

local Ui = {
   left_buf = nil,
   left_win = nil,
   right_buf = nil,
   right_win = nil,
   mode = "branches",
   branches = {},
   stashes = {},
   changed_files = {},
   selected_index = 1,
   branch_selected = nil,
}

local function git_root()
   local root = vim.fn.systemlist("git rev-parse --show-toplevel")[1]
   return root ~= "" and root or "."
end

local function run_git(cmd)
   if type(cmd) == "table" then
      return vim.fn.systemlist(cmd)
   end
   return vim.fn.systemlist(cmd)
end

---------------------------------------------------------------------------
-- 🔄 Load list of Git branches
---------------------------------------------------------------------------
local function load_branches()
   local branches = run_git("git branch --list --format='%(refname:short)'") or {}

   -- Filter out empty/whitespace-only lines
   local cleaned = {}
   for _, b in ipairs(branches) do
      if b and b:match("%S") then
         table.insert(cleaned, b)
      end
   end

   -- Get the current branch
   local current = run_git("git rev-parse --abbrev-ref HEAD")[1] or ""

   -- Get ahead/behind info
   Ui.branch_ahead_behind = {}
   local tracking_info = run_git("git for-each-ref --format='%(refname:short)|%(upstream:track)' refs/heads/") or {}
   for _, line in ipairs(tracking_info) do
      local b, track = line:match("^(.-)|(.*)$")
      if b and b ~= "" then
         local ah = track:match("ahead (%d+)")
         local bh = track:match("behind (%d+)")
         local track_str = ""
         if ah then
            track_str = track_str .. "↑" .. ah
         end
         if bh then
            track_str = track_str .. "↓" .. bh
         end
         Ui.branch_ahead_behind[b] = track_str
      end
   end

   -- Store branch statuses separately
   local branch_statuses = {}
   local status = run_git("git status --porcelain")
   for _, branch in ipairs(cleaned) do
      if branch == current then
         local staged = false
         local unstaged = false
         for _, line in ipairs(status) do
            local x = line:sub(1, 1) -- staged
            local y = line:sub(2, 2) -- unstaged

            if x ~= " " then
               staged = true
            end
            if y ~= " " then
               unstaged = true
            end
         end

         if unstaged then
            branch_statuses[branch] = "💣" -- unstaged changes exist
         elseif staged then
            branch_statuses[branch] = "✅" -- staged changes ready to commit
         else
            branch_statuses[branch] = "" -- clean
         end
      else
         branch_statuses[branch] = "" -- other branches just blank
      end
   end

   -- Reorder so current branch is first
   table.sort(cleaned, function(a, b)
      if a == current then
         return true
      end
      if b == current then
         return false
      end
      return a < b
   end)

   -- Save pure branch names
   Ui.branches = cleaned
   Ui.branch_statuses = branch_statuses

   -- Default selected branch
   Ui.branch_selected = Ui.branch_selected or Ui.branches[1]
end

---------------------------------------------------------------------------
-- 🕵️ Load list of Git stashes
---------------------------------------------------------------------------
local function load_stashes()
   local raw = run_git("git stash list --pretty='%gd: %s'") or {}
   Ui.stashes = vim.tbl_filter(function(s)
      return s and #s > 0
   end, raw)
end

local function format_node_text(node, indent_level)
   local indent = string.rep("  ", indent_level)
   if node.is_dir then
      local icon = node.expanded and "📂 " or "📁 "
      return indent .. icon .. node.name .. "/"
   else
      -- Visual indicator for staged vs unstaged
      local icon = node.staged and "✓ " or "• "
      return indent .. icon .. node.name
   end
end

-- 2. Flatten tree into line entries based on expansion states
flatten_tree = function(node, depth, result)
   depth = depth or 0
   result = result or {}

   local keys = {}
   for k in pairs(node.children or {}) do
      table.insert(keys, k)
   end
   table.sort(keys, function(a, b)
      local ca, cb = node.children[a], node.children[b]
      if ca.is_dir ~= cb.is_dir then
         return ca.is_dir
      end
      return ca.name < cb.name
   end)

   for _, k in ipairs(keys) do
      local child = node.children[k]

      -- CALL format_node_text HERE
      table.insert(result, {
         text = format_node_text(child, depth),
         node = child,
      })

      if child.is_dir and child.expanded then
         flatten_tree(child, depth + 1, result)
      end
   end
   return result
end

local function get_tree_ns()
   if not ns_id then
      ns_id = vim.api.nvim_create_namespace("gitcompanion_tree_hl")
   end
   return ns_id
end

render_files_tree = function()
   if not Ui.left_buf or not vim.api.nvim_buf_is_valid(Ui.left_buf) then
      return
   end

   local ns = get_tree_ns()

   vim.api.nvim_set_option_value("modifiable", true, { buf = Ui.left_buf })
   -- Clear previous highlights using safe namespace ID
   vim.api.nvim_buf_clear_namespace(Ui.left_buf, ns, 0, -1)

   local lines = {}
   for _, item in ipairs(Ui.visible_tree_lines or {}) do
      table.insert(lines, item.text)
   end

   vim.api.nvim_buf_set_lines(Ui.left_buf, 0, -1, false, lines)

   -- Apply file status highlights
   for line_idx, item in ipairs(Ui.visible_tree_lines or {}) do
      local node = item.node
      if node and not node.is_dir then
         local hl_group = node.staged and "Added" or "Changed"
         if vim.fn.hlexists("GitSignsAdd") == 1 and node.staged then
            hl_group = "GitSignsAdd"
         elseif vim.fn.hlexists("GitSignsChange") == 1 and not node.staged then
            hl_group = "GitSignsChange"
         end

         vim.api.nvim_buf_add_highlight(Ui.left_buf, ns, hl_group, line_idx - 1, 0, -1)
      elseif node and node.is_dir then
         vim.api.nvim_buf_add_highlight(Ui.left_buf, ns, "Directory", line_idx - 1, 0, -1)
      end
   end

   vim.api.nvim_set_option_value("modifiable", false, { buf = Ui.left_buf })
end

toggle_tree_node = function()
   if Ui.mode ~= "files" or not Ui.left_win or not vim.api.nvim_win_is_valid(Ui.left_win) then
      return
   end

   -- 1. Sync cursor position
   local cursor = vim.api.nvim_win_get_cursor(Ui.left_win)
   Ui.selected_index = cursor[1]

   -- 2. Fetch active node
   local item = Ui.visible_tree_lines and Ui.visible_tree_lines[Ui.selected_index]
   local node = item and item.node

   -- 3. Toggle expansion if node is a directory
   if node and node.is_dir then
      node.expanded = not node.expanded

      -- 4. Re-flatten tree and update buffer lines
      Ui.visible_tree_lines = flatten_tree(Ui.tree_root)
      render_files_tree()

      -- 5. Restore cursor position
      local max_line = #Ui.visible_tree_lines
      local safe_idx = math.min(math.max(1, Ui.selected_index), max_line)
      if safe_idx > 0 then
         pcall(vim.api.nvim_win_set_cursor, Ui.left_win, { safe_idx, 0 })
      end

      -- Update code preview for new selection focus
      render_diff()
   end
end

-- Helper to parse rename paths from git status or diff
local function parse_file_status(line)
   if #line < 4 then
      return nil
   end

   local staged_char = line:sub(1, 1)
   local unstaged_char = line:sub(2, 2)
   local path_info = line:sub(4):gsub("^%s+", ""):gsub('^"', ""):gsub('"$', "")

   local is_staged = staged_char ~= " " and staged_char ~= "?"
   local status_code = is_staged and staged_char or unstaged_char

   -- Handle git rename syntax ("R  old_path -> new_path")
   if status_code == "R" then
      local old_path, new_path = path_info:match("^(.-)%s*%->%s*(.+)$")
      local target_path = new_path or path_info
      return {
         status = "R",
         staged = is_staged,
         path = target_path,
         old_path = old_path,
         display = string.format("%s (renamed from %s)", target_path, old_path or "?"),
      }
   end

   return {
      status = status_code,
      staged = is_staged,
      path = path_info,
      display = path_info,
   }
end

---------------------------------------------------------------------------
-- 🧩 Load list of changed files (staged + unstaged)
---------------------------------------------------------------------------
get_changed_files = function(branch)
   local status_lines = vim.fn.systemlist("git status --porcelain")
   local files = {}
   Ui.has_conflicts = false

   for _, line in ipairs(status_lines) do
      local code = line:sub(1, 2)
      local parsed = parse_file_status(line)
      if parsed then
         -- Check if git marks file as unmerged
         if code:match("U") or code == "AA" or code == "DD" then
            parsed.is_conflict = true
            Ui.has_conflicts = true
         end

         table.insert(files, {
            path = parsed.path,
            old_path = parsed.old_path,
            value = parsed.path,
            staged = parsed.staged,
            status = parsed.status,
            display = parsed.display,
            is_conflict = parsed.is_conflict,
         })
      end
   end

   Ui.changed_files = files
   Ui.tree_root = build_tree_from_files(files)
   Ui.visible_tree_lines = flatten_tree(Ui.tree_root)

   return files
end

local function get_diff_for_target(path)
   if not path or path == "" then
      return { "[No file selected]" }
   end
   local cmd = "git --no-pager diff HEAD -- " .. vim.fn.shellescape(path)
   local diff_lines = vim.fn.systemlist(cmd)
   if vim.v.shell_error == 0 and #diff_lines > 0 then
      return diff_lines
   end
   return { "[No changes for " .. path .. "]" }
end

render_diff = function()
   if not Ui or not Ui.diff_buf or not vim.api.nvim_buf_is_valid(Ui.diff_buf) then
      return
   end

   vim.api.nvim_set_option_value("modifiable", true, { buf = Ui.diff_buf })
   vim.api.nvim_buf_clear_namespace(Ui.diff_buf, -1, 0, -1)

   local out = { "" }

   if Ui.mode == "files" then
      if Ui.left_win and vim.api.nvim_win_is_valid(Ui.left_win) then
         local cursor = vim.api.nvim_win_get_cursor(Ui.left_win)
         Ui.selected_index = cursor[1]
      end

      local item = Ui.visible_tree_lines and Ui.visible_tree_lines[Ui.selected_index]
      local node = item and item.node

      if node then
         if node.is_dir then
            local child_paths = get_all_child_paths(node)
            out = get_diff_for_paths(child_paths)
         else
            out = get_diff_for_target(node.path or node.value or node.name)
         end
      else
         out = { "[No file selected]" }
      end
   elseif Ui.mode == "branches" then
      -- Show branch diff against active HEAD
      local branch = Ui.branches and Ui.branches[Ui.selected_index]
      if branch then
         local clean_branch = branch:gsub("^%*%s*", ""):gsub("%s+", "")
         out = vim.fn.systemlist("git --no-pager diff " .. vim.fn.shellescape(clean_branch))
      else
         out = { "[No branch selected]" }
      end
   end

   vim.api.nvim_buf_set_lines(Ui.diff_buf, 0, -1, false, out)
   vim.api.nvim_set_option_value("filetype", "diff", { buf = Ui.diff_buf })

   for i, line in ipairs(out) do
      if line:match("^%+.*") then
         vim.api.nvim_buf_add_highlight(Ui.diff_buf, -1, "DiffAdd", i - 1, 0, -1)
      elseif line:match("^%-.*") then
         vim.api.nvim_buf_add_highlight(Ui.diff_buf, -1, "DiffDelete", i - 1, 0, -1)
      elseif line:match("^@@") then
         vim.api.nvim_buf_add_highlight(Ui.diff_buf, -1, "DiffHeader", i - 1, 0, -1)
      end
   end

   vim.api.nvim_set_option_value("modifiable", false, { buf = Ui.diff_buf })
end

build_tree_from_files = function(files)
   local root = { name = "", is_dir = true, children = {}, expanded = true }

   for _, item in ipairs(files) do
      local path = item.value or item.path or item
      local parts = {}
      for part in path:gmatch("[^/]+") do
         table.insert(parts, part)
      end

      local current = root
      for i, part in ipairs(parts) do
         if i == #parts then
            current.children[part] = current.children[part]
                or {
                   name = part,
                   is_dir = false,
                   path = path,
                   old_path = item.old_path,
                   status = item.status or "M",
                   staged = item.staged or false,
                }
         else
            if not current.children[part] then
               current.children[part] = {
                  name = part,
                  is_dir = true,
                  children = {},
                  expanded = true,
               }
            end
            current = current.children[part]
         end
      end
   end
   return root
end

---------------------------------------------------------------------------
-- Render the left panel (branches or changed files)
---------------------------------------------------------------------------
local function render_left()
   if not Ui or not Ui.left_buf then
      return
   end

   -- Delegate directly to tree renderer for files mode
   if Ui.mode == "files" or not (Ui.mode == "branches" or Ui.mode == "stashes") then
      render_files_tree()
      return -- Critical: stop execution so we don't wipe the buffer below!
   end

   vim.api.nvim_set_option_value("modifiable", true, { buf = Ui.left_buf })

   local lines = {}
   local highlights = {}

   if Ui.mode == "branches" then
      load_branches()
      local current = run_git("git rev-parse --abbrev-ref HEAD")[1] or ""
      for i, b in ipairs(Ui.branches) do
         local marker = (b == current) and "*" or " "
         local status = Ui.branch_statuses[b] or ""
         local ahead_behind = Ui.branch_ahead_behind[b] or ""
         local line = string.format("%2s %s %s %s", marker, b, status, ahead_behind)
         table.insert(lines, line)

         if b == current then
            table.insert(highlights, { line = i, hl = "GitBranchCurrent" })
         end
      end
   elseif Ui.mode == "stashes" then
      load_stashes()
      for i, s in ipairs(Ui.stashes) do
         table.insert(lines, "  " .. s)
         table.insert(highlights, { line = i, hl = "GitMsg", col = 0, length = -1 })
      end
   end

   vim.api.nvim_buf_set_lines(Ui.left_buf, 0, -1, false, lines)

   -- Apply highlights
   vim.api.nvim_buf_clear_namespace(Ui.left_buf, -1, 0, -1)
   for _, h in ipairs(highlights) do
      vim.api.nvim_buf_add_highlight(Ui.left_buf, -1, h.hl, h.line - 1, h.col or 0, h.length or -1)
   end

   vim.api.nvim_set_option_value("modifiable", false, { buf = Ui.left_buf })
end

---------------------------------------------------------------------------
-- Git Graph Functions
---------------------------------------------------------------------------
local function convert_graph(line)
   line = line:gsub("%*%-", "*-") -- star + horizontal
   line = line:gsub("|\\", "|\\") -- merge down-right
   line = line:gsub("|/", "|/") -- merge down-left
   return line
end

-- Fetch git log and convert graph symbols
local function git_graph(limit, branch)
   limit = limit or 20
   branch = branch or "HEAD"
   local cmd = string.format(
      [[git --no-pager log --graph --pretty=format:'%%h %%cd %%an %%s' --date=format:'%%I:%%M%%p' -n %d %s]],
      limit,
      branch
   )
   local lines = vim.fn.systemlist(cmd)
   if vim.v.shell_error ~= 0 then
      return { "Not a git repo or branch does not exist" }
   end
   for i, line in ipairs(lines) do
      lines[i] = convert_graph(line)
   end
   return lines
end

---------------------------------------------------------------------------

-- Render the right panel (commit log or diff preview)
---------------------------------------------------------------------------
local graph_chars = { "*", "|", "/", "\\", "-" }

-- Git Graph Colors (per column)
local graph_colors = {
   "#5fff5f", -- green
   "#5fd7ff", -- cyan
   "#ffaf5f", -- orange
   "#ff5fff", -- magenta
   "#ffff5f", -- yellow
   "#5f5fff", -- blue
   "#5fffff", -- light cyan
   "#ff5f5f", -- red
}

-- Set highlight groups for graph columns
for i, c in ipairs(graph_colors) do
   vim.api.nvim_set_hl(0, "GitGraphSymbol" .. i, { fg = c })
end

-- Convert git --graph lines (ASCII identity)
local function convert_graph(line)
   line = line:gsub("%*%-", "*-")
   line = line:gsub("|\\", "|\\")
   line = line:gsub("|/", "|/")
   return line
end

local function git_graph(limit, branch)
   limit = limit or 20
   branch = branch or "HEAD"
   local cmd = string.format(
      [[git --no-pager log --graph --pretty=format:'%%h %%cd %%an %%s' --date=format:'%%I:%%M%%p' -n %d %s]],
      limit,
      branch
   )
   local lines = vim.fn.systemlist(cmd)
   if vim.v.shell_error ~= 0 then
      return { "Not a git repo or branch does not exist" }
   end
   for i, line in ipairs(lines) do
      lines[i] = convert_graph(line)
   end
   return lines
end

-- Render right panel (commit log)
local function render_right()
   if not Ui or not Ui.right_buf then
      return
   end
   vim.api.nvim_buf_set_option(Ui.right_buf, "modifiable", true)
   vim.api.nvim_buf_clear_namespace(Ui.right_buf, -1, 0, -1)

   local branch = Ui.branch_selected or "HEAD"
   local out = git_graph(40, branch)
   if #out == 0 then
      out = { "[No commits]" }
   end
   vim.api.nvim_buf_set_lines(Ui.right_buf, 0, -1, false, out)

   Ui.branch_colors = Ui.branch_colors or {}

   for i, line in ipairs(out) do
      -- highlight graph per column
      for pos = 1, #line do
         local char = line:sub(pos, pos)
         if vim.tbl_contains(graph_chars, char) then
            if not Ui.branch_colors[pos] then
               local color = graph_colors[((pos - 1) % #graph_colors) + 1]
               Ui.branch_colors[pos] = color
               vim.api.nvim_set_hl(0, "GitGraphSymbol" .. pos, { fg = color })
            end
            vim.api.nvim_buf_add_highlight(Ui.right_buf, -1, "GitGraphSymbol" .. pos, i - 1, pos - 1, pos)
         end
      end

      -- highlight commit hash/date/author/message
      local hash, date, author, msg = line:match("([0-9a-f]+)%s+([0-9:APM]+)%s+(%S+)%s+(.+)")
      if hash then
         local s = line:find(hash, 1, true)
         if s then
            vim.api.nvim_buf_add_highlight(Ui.right_buf, -1, "GitHash", i - 1, s - 1, s - 1 + #hash)
         end
      end
      if date then
         local s = line:find(date, 1, true)
         if s then
            vim.api.nvim_buf_add_highlight(Ui.right_buf, -1, "GitDate", i - 1, s - 1, s - 1 + #date)
         end
      end
      if author then
         local s = line:find(author, 1, true)
         if s then
            vim.api.nvim_buf_add_highlight(Ui.right_buf, -1, "GitAuthor", i - 1, s - 1, s - 1 + #author)
         end
      end
      if msg then
         local s = line:find(msg, 1, true)
         if s then
            vim.api.nvim_buf_add_highlight(Ui.right_buf, -1, "GitMsg", i - 1, s - 1, -1)
         end
      end
   end

   vim.api.nvim_buf_set_option(Ui.right_buf, "modifiable", false)
end

-- Render diff panel (Code Changes)
-- Helper 1: Recursively collect all file paths under a directory node
local function get_all_child_paths(node)
   local paths = {}
   local function collect(n)
      if not n then
         return
      end
      if n.is_dir then
         for _, child in pairs(n.children or {}) do
            collect(child)
         end
      elseif n.path then
         table.insert(paths, n.path)
      end
   end
   collect(node)
   return paths
end

-- Helper 2: Fetch combined git diff for multiple file paths
local function get_diff_for_paths(paths)
   if #paths == 0 then
      return { "[Empty directory or no changes]" }
   end
   local escaped = {}
   for _, p in ipairs(paths) do
      table.insert(escaped, vim.fn.shellescape(p))
   end
   local cmd = "git --no-pager diff HEAD -- " .. table.concat(escaped, " ")
   local diff_lines = vim.fn.systemlist(cmd)
   return (vim.v.shell_error == 0 and #diff_lines > 0) and diff_lines or { "[No changes in folder]" }
end

render_diff = function()
   if not Ui or not Ui.diff_buf or not vim.api.nvim_buf_is_valid(Ui.diff_buf) then
      return
   end

   -- Updated API calls replacing deprecated nvim_buf_set_option
   vim.api.nvim_set_option_value("modifiable", true, { buf = Ui.diff_buf })
   vim.api.nvim_buf_clear_namespace(Ui.diff_buf, -1, 0, -1)

   local out = { "" }

   if Ui.mode == "files" then
      if Ui.left_win and vim.api.nvim_win_is_valid(Ui.left_win) then
         local cursor = vim.api.nvim_win_get_cursor(Ui.left_win)
         Ui.selected_index = cursor[1]
      end

      -- Access the active node directly from the flattened visible tree list
      local item = Ui.visible_tree_lines and Ui.visible_tree_lines[Ui.selected_index]
      local node = item and item.node

      if node then
         if node.is_dir then
            -- Directory selected: aggregate diffs for all child files
            local child_paths = get_all_child_paths(node)
            out = get_diff_for_paths(child_paths)
         else
            -- Single file selected
            out = get_diff_for_target(node.path)
         end
      else
         out = { "[No file selected]" }
      end
   elseif Ui.mode == "stashes" then
      if Ui.left_win and vim.api.nvim_win_is_valid(Ui.left_win) then
         local cursor = vim.api.nvim_win_get_cursor(Ui.left_win)
         Ui.selected_index = cursor[1]
      end
      local entry = Ui.stashes and Ui.stashes[Ui.selected_index]
      if entry then
         local ref = entry:match("(stash@{%d+})")
         if ref then
            local diff_lines = vim.fn.systemlist("git --no-pager stash show -p " .. ref)
            if vim.v.shell_error == 0 and #diff_lines > 0 then
               out = diff_lines
            end
         end
      else
         out = { "[No stash selected]" }
      end
   elseif Ui.mode == "branches" then
      if Ui.right_win and vim.api.nvim_win_is_valid(Ui.right_win) then
         local cursor = vim.api.nvim_win_get_cursor(Ui.right_win)
         local line = vim.api.nvim_buf_get_lines(Ui.right_buf, cursor[1] - 1, cursor[1], false)[1] or ""

         -- Extract hash correctly, skipping graph symbols
         local hash = line:match("([0-9a-f]+)%s+[0-9:APM]+%s+")
         if hash then
            local diff_lines = vim.fn.systemlist("git --no-pager show " .. hash)
            if vim.v.shell_error == 0 then
               out = diff_lines
            end
         else
            out = { "[No commit selected]" }
         end
      end
   end

   vim.api.nvim_buf_set_lines(Ui.diff_buf, 0, -1, false, out)
   vim.api.nvim_set_option_value("filetype", "diff", { buf = Ui.diff_buf })

   for i, line in ipairs(out) do
      if line:match("^%+.*") then
         vim.api.nvim_buf_add_highlight(Ui.diff_buf, -1, "DiffAdd", i - 1, 0, -1)
      elseif line:match("^%-.*") then
         vim.api.nvim_buf_add_highlight(Ui.diff_buf, -1, "DiffDelete", i - 1, 0, -1)
      elseif line:match("^\\+\\-") or line:match("^!.*") then
         vim.api.nvim_buf_add_highlight(Ui.diff_buf, -1, "DiffChange", i - 1, 0, -1)
      elseif line:match("^diff ") then
         vim.api.nvim_buf_add_highlight(Ui.diff_buf, -1, "DiffFile", i - 1, 0, -1)
      elseif line:match("^@@") then
         vim.api.nvim_buf_add_highlight(Ui.diff_buf, -1, "DiffHeader", i - 1, 0, -1)
      end
   end

   vim.api.nvim_set_option_value("modifiable", false, { buf = Ui.diff_buf })
end

---------------------------------------------------------------------------
-- Refresh UI on close
---------------------------------------------------------------------------
refresh_ui = function()
   -- 0. Re-fetch git state and rebuild file tree from disk
   if type(get_changed_files) == "function" then
      get_changed_files()
   end
   if type(load_branches) == "function" and Ui.mode == "branches" then
      load_branches()
   end

   -- 1. Sync window visibility & dimensions with current Ui.mode
   if type(update_window_layout) == "function" then
      update_window_layout()
   end

   -- Ensure Ui.selected_index is valid after switching to branches view
   if Ui.mode == "branches" then
      local total_branches = #Ui.branches
      Ui.selected_index = math.min(Ui.selected_index, total_branches)
      Ui.branch_selected = Ui.branches[Ui.selected_index]
   end

   -- Clamp selected index BEFORE rendering so bounds are accurate
   local total = (Ui.mode == "branches") and #Ui.branches
       or (Ui.mode == "stashes" and #Ui.stashes or #Ui.changed_files)
   Ui.selected_index = math.max(1, math.min(Ui.selected_index or 1, math.max(1, total)))

   -- Render the panes
   render_left()
   render_right()
   render_diff()

   -- Update left window title and cursor
   if Ui.left_win and vim.api.nvim_win_is_valid(Ui.left_win) then
      local title_str = " Files Changed "
      if Ui.mode == "branches" then
         title_str = " Git Branches "
      end
      if Ui.mode == "stashes" then
         title_str = " Stashes "
      end

      vim.api.nvim_win_set_config(Ui.left_win, { title = title_str })
      pcall(vim.api.nvim_win_set_cursor, Ui.left_win, { Ui.selected_index, 0 })
   end

   -- Update the right window title
   if Ui.right_win and vim.api.nvim_win_is_valid(Ui.right_win) then
      vim.api.nvim_win_set_config(Ui.right_win, { title = " Commit Log " })
   end
end

---------------------------------------------------------------------------
-- 🌸 Floating window functions to display git output after an operation
---------------------------------------------------------------------------
local floating_windows = {}

-- Store the current active window
local current_win = nil
local current_buf = nil

-- Function to save the current active window
local function save_active_window()
   current_win = vim.api.nvim_get_current_win()
   current_buf = vim.api.nvim_win_get_buf(current_win)
end

-- Function to restore the active window after closing floating windows
local function restore_active_window()
   if current_win and vim.api.nvim_win_is_valid(current_win) then
      vim.api.nvim_set_current_win(current_win) -- Restore the previously active window
   elseif current_buf and vim.api.nvim_buf_is_valid(current_buf) then
      -- If the previous window is no longer valid, set the buffer in the current window
      vim.api.nvim_win_set_buf(vim.api.nvim_get_current_win(), current_buf)
   end
end

-- Function to close floating windows and return to branches view
local function close_floating()
   print("Closing floating windows...")
   for _, w in pairs(floating_windows) do
      if vim.api.nvim_win_is_valid(w) then
         print("Closing window:", w)
         vim.api.nvim_win_close(w, true)
      else
         print("Window is not valid:", w)
      end
   end
   floating_windows = {} -- Reset floating windows table

   -- After closing floating windows, restore the active window and return to branches view
   Ui.mode = "branches"
   refresh_ui()
   restore_active_window() -- Restore the last active window
end

-- Keybinding to close floating windows and go back to branches view
vim.keymap.set("n", "q", function()
   close_floating()
end, { buffer = buf_out, nowait = true, silent = true })

-- Keybinding to close error window as well
vim.keymap.set("n", "q", function()
   close_floating()
end, { buffer = buf_err, nowait = true, silent = true })

-- Show output and error windows in floating style
local function show_floating_pair(stdout_lines, stderr_lines)
   -- Check if either output stream contains a merge conflict
   local full_text = table.concat(stdout_lines or {}, "\n") .. "\n" .. table.concat(stderr_lines or {}, "\n")
   if string.find(full_text, "CONFLICT") then
      return -- Skip rendering Git Output/Errors windows completely
   end

   save_active_window()

   local ui = vim.api.nvim_list_uis()[1]
   local editor_h = ui.height
   local width = math.min(80, ui.width - 4)

   -- Calculate window heights
   local h_out = math.max(#stdout_lines + 2, 3)
   local h_err = math.max(#stderr_lines + 2, 3)
   local total_h = math.floor(editor_h * 0.95)

   -- Calculate top row and column for centering
   local top = math.floor((ui.height - total_h) / 2)
   local col = math.floor((ui.width - width) / 2)

   -- Create and show the output window (stdout)
   local buf_out = vim.api.nvim_create_buf(false, true)
   vim.api.nvim_buf_set_lines(buf_out, 0, -1, false, stdout_lines)
   vim.api.nvim_set_option_value("modifiable", false, { buf = buf_out })

   -- Apply a highlight group to colorize the output window (stdout)
   vim.api.nvim_buf_add_highlight(buf_out, -1, "GitOutput", 0, 0, -1)

   local win_out = vim.api.nvim_open_win(buf_out, true, {
      relative = "editor",
      width = width,
      height = h_out,
      row = top,
      col = col,
      style = "minimal",
      border = "rounded",
      title = " Git Output ",
      title_pos = "center",
      zindex = 600,
   })

   floating_windows.stdout = win_out -- Store reference to output window

   -- Create and show the error window (stderr)
   local buf_err = vim.api.nvim_create_buf(false, true)
   vim.api.nvim_buf_set_lines(buf_err, 0, -1, false, stderr_lines)
   vim.api.nvim_set_option_value("modifiable", false, { buf = buf_err })

   vim.api.nvim_buf_add_highlight(buf_err, -1, "GitError", 0, 0, -1)

   local win_err = vim.api.nvim_open_win(buf_err, false, {
      relative = "editor",
      width = width,
      height = h_err,
      row = top + h_out + 2, -- Right below output window
      col = col,
      style = "minimal",
      border = "rounded",
      title = " Git Errors ",
      title_pos = "center",
      zindex = 600,
   })

   floating_windows.stderr = win_err -- Store reference to error window

   -- H/L navigation between floating windows
   vim.keymap.set("n", "H", function()
      if floating_windows.stdout and vim.api.nvim_win_is_valid(floating_windows.stdout) then
         vim.api.nvim_set_current_win(floating_windows.stdout)
      elseif floating_windows.stderr and vim.api.nvim_win_is_valid(floating_windows.stderr) then
         vim.api.nvim_set_current_win(floating_windows.stderr)
      end
   end, { buffer = buf_out, nowait = true, silent = true })

   vim.keymap.set("n", "L", function()
      if floating_windows.stderr and vim.api.nvim_win_is_valid(floating_windows.stderr) then
         vim.api.nvim_set_current_win(floating_windows.stderr)
      elseif floating_windows.stdout and vim.api.nvim_win_is_valid(floating_windows.stdout) then
         vim.api.nvim_set_current_win(floating_windows.stdout)
      end
   end, { buffer = buf_out, nowait = true, silent = true })

   -- Bind 'q' to close floating windows and return to branches view
   vim.keymap.set("n", "q", function()
      close_floating()
      Ui.mode = "branches" -- Return to branches view after closing
      refresh_ui()
   end, { buffer = buf_out, nowait = true, silent = true })
end

---------------------------------------------------------------------------
-- Function to reload the current file buffer after exiting git picker
---------------------------------------------------------------------------
local function file_differs_from_disk(bufnr)
   local path = vim.api.nvim_buf_get_name(bufnr)
   if path == "" then
      return false
   end

   local ok, disk = pcall(vim.fn.readfile, path)
   if not ok then
      return false
   end

   local buf = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

   return table.concat(disk, "\n") ~= table.concat(buf, "\n")
end

local function reload_file_buffer()
   local bufnr = vim.api.nvim_get_current_buf()
   if not vim.api.nvim_buf_is_valid(bufnr) then
      return
   end

   if vim.api.nvim_buf_get_option(bufnr, "modified") then
      return
   end

   if file_differs_from_disk(bufnr) then
      -- This creates a true Yes/No prompt in the cmdline (always focused)
      local choice = vim.fn.confirm("File changed on disk. Reload?", "&Yes\n&No", 2)

      if choice == 1 then
         vim.cmd("e!")
      end
   end
end

-- Focus helpers
---------------------------------------------------------------------------
local function focus_left()
   if Ui.left_win and vim.api.nvim_win_is_valid(Ui.left_win) then
      vim.api.nvim_set_current_win(Ui.left_win)
   end
end

-- When initializing your UI
local function init_ui()
   -- Load branches and changed files
   load_branches()
   get_changed_files(Ui.branch_selected)

   -- Determine initial mode based on whether there are changes
   if #Ui.changed_files > 0 then
      Ui.mode = "files"
   else
      Ui.mode = "branches"
   end

   Ui.selected_index = 1

   -- Create buffers / windows here if needed
   refresh_ui()
   focus_left()
end

function update_window_layout()
   if not Ui or not Ui.diff_win or not vim.api.nvim_win_is_valid(Ui.diff_win) then
      return
   end

   -- 1. Recalculate layout rows & heights
   local ui = vim.api.nvim_list_uis()[1]
   local editor_w = ui and ui.width or vim.o.columns
   local editor_h = ui and ui.height or vim.o.lines

   local statusline_h = (vim.o.laststatus > 0) and 1 or 0
   local available_h = editor_h - vim.o.cmdheight - statusline_h

   local w = math.floor(editor_w * 0.9)
   local col = math.floor((editor_w - w) / 2)

   local help_h = 1
   local branch_h = 4
   local log_h = 8
   local lower_h = 8

   local help_row = available_h - help_h - 2
   local branch_row = help_row - branch_h - 2
   local log_row = branch_row - log_h - 2
   local lower_row = help_row - lower_h - 2
   local diff_row = 2

   local diff_h
   if Ui.mode == "branches" then
      diff_h = math.max(log_row - diff_row - 2, 1)
   else
      diff_h = math.max(lower_row - diff_row - 2, 1)
   end

   -- 2. Update Diff Window Size
   vim.api.nvim_win_set_config(Ui.diff_win, {
      relative = "editor",
      width = w,
      height = diff_h,
      row = diff_row,
      col = col,
   })

   -- 3. Handle Right Win (Commit Log) Visibility Based on Mode
   if Ui.mode == "branches" then
      if not Ui.right_win or not vim.api.nvim_win_is_valid(Ui.right_win) then
         Ui.right_win = vim.api.nvim_open_win(Ui.right_buf, false, {
            relative = "editor",
            width = w,
            height = log_h,
            row = log_row,
            col = col,
            style = "minimal",
            border = "rounded",
            title = " Commit Log ",
            title_pos = "center",
            zindex = 10,
         })
      else
         vim.api.nvim_win_set_config(Ui.right_win, {
            relative = "editor",
            width = w,
            height = log_h,
            row = log_row,
            col = col,
         })
      end
   else
      -- CRITICAL FIX: Close right_win when NOT in branches mode
      if Ui.right_win and vim.api.nvim_win_is_valid(Ui.right_win) then
         pcall(vim.api.nvim_win_close, Ui.right_win, true)
         Ui.right_win = nil
      end
   end

   -- 4. Update Left Window (Navigation / List)
   local left_title = " Files Changed "
   local left_h = lower_h
   local left_row = lower_row

   if Ui.mode == "branches" then
      left_title = " Git Branches "
      left_h = branch_h
      left_row = branch_row
   elseif Ui.mode == "stashes" then
      left_title = " Stashes "
   end

   if Ui.left_win and vim.api.nvim_win_is_valid(Ui.left_win) then
      vim.api.nvim_win_set_config(Ui.left_win, {
         relative = "editor",
         width = w,
         height = left_h,
         row = left_row,
         col = col,
         title = left_title,
         title_pos = "center",
      })
   end
end

local function toggle_mode(dir)
   if not Ui then
      return
   end

   Ui.mode = Ui.mode or "files"

   local modes = { "branches", "files", "stashes" }
   local current_idx = 1
   for i, m in ipairs(modes) do
      if m == Ui.mode then
         current_idx = i
         break
      end
   end

   if dir == "prev" then
      current_idx = (current_idx == 1) and #modes or (current_idx - 1)
   else
      current_idx = (current_idx == #modes) and 1 or (current_idx + 1)
   end

   Ui.mode = modes[current_idx]
   Ui.selected_index = 1

   if Ui.mode == "files" then
      get_changed_files()
   elseif Ui.mode == "stashes" then
      load_stashes()
   end

   refresh_ui()
   focus_left()
end

-- Helper to gather all leaf file paths under a node recursively
local function get_all_child_paths(node)
   local paths = {}
   if not node then
      return paths
   end

   if not node.is_dir then
      if node.path then
         table.insert(paths, node.path)
      end
      return paths
   end

   for _, child in pairs(node.children or {}) do
      if child.is_dir then
         local sub_paths = get_all_child_paths(child)
         for _, p in ipairs(sub_paths) do
            table.insert(paths, p)
         end
      else
         if child.path then
            table.insert(paths, child.path)
         end
      end
   end
   return paths
end

-- Staging/Unstaging Function with Debugging
local function stage_unstage_selected()
   if Ui.mode ~= "files" or not Ui.left_win or not vim.api.nvim_win_is_valid(Ui.left_win) then
      return
   end

   local cursor = vim.api.nvim_win_get_cursor(Ui.left_win)
   Ui.selected_index = cursor[1]

   local item = Ui.visible_tree_lines and Ui.visible_tree_lines[Ui.selected_index]
   local node = item and item.node
   if not node then
      return
   end

   local target_paths = node.is_dir and get_all_child_paths(node) or { node.path or node.value or node.name }
   if #target_paths == 0 then
      return
   end

   -- Check current staged status
   local status_lines = vim.fn.systemlist("git status --porcelain")
   local staged_set = {}
   for _, line in ipairs(status_lines) do
      if #line >= 4 then
         local staged_char = line:sub(1, 1)
         local path = line:sub(4):gsub("^%s+", ""):gsub('^"', ""):gsub('"$', "")
         if staged_char ~= " " and staged_char ~= "?" then
            staged_set[path] = true
         end
      end
   end

   local all_staged = true
   for _, path in ipairs(target_paths) do
      if not staged_set[path] then
         all_staged = false
         break
      end
   end

   -- Execute git action
   local action = all_staged and "restore --staged -- " or "add -- "
   local cmd = "git " .. action
   for _, path in ipairs(target_paths) do
      cmd = cmd .. " " .. vim.fn.shellescape(path)
   end

   vim.fn.system(cmd)

   -- 1. Refresh changed files list
   get_changed_files(Ui.branch_selected)

   -- 2. Re-flatten tree from newly updated tree_root
   if Ui.tree_root then
      Ui.visible_tree_lines = flatten_tree(Ui.tree_root)
   end

   -- 3. Render tree buffer
   render_files_tree()

   -- 4. Preserve cursor
   local max_line = #(Ui.visible_tree_lines or {})
   local safe_idx = math.min(math.max(1, Ui.selected_index), max_line)
   if safe_idx > 0 then
      pcall(vim.api.nvim_win_set_cursor, Ui.left_win, { safe_idx, 0 })
   end

   -- 5. Refresh diff pane
   render_diff()
end

-- Discard changes for the selected file
local function discard_changes_selected()
   if Ui.mode ~= "files" then
      print("Exiting: Ui.mode is not 'files', current mode:", Ui.mode)
      return
   end

   local sel = Ui.changed_files[Ui.selected_index]
   if not sel then
      print("Exiting: No selected file at index", Ui.selected_index)
      return
   end

   print("Selected file to discard:", sel.value)

   local confirm_result = vim.fn.confirm("Discard changes to " .. sel.value .. "?", "Yes\nNo", 2)
   print("Confirm result:", confirm_result)

   if confirm_result ~= 1 then
      print("Discard canceled by user")
      return
   end

   local root = git_root()
   print("Git root detected:", root)

   local cmd = { "git", "restore", root .. "/" .. sel.value }
   print("Running command:", table.concat(cmd, " "))

   local result = vim.fn.system(cmd)
   local err = vim.v.shell_error
   print("Command output:", result)
   print("Shell error code:", err)

   if err ~= 0 then
      print("Error discarding changes!")
   else
      print("Successfully discarded changes")
   end

   refresh_ui()
   print("UI refreshed")
end

local function show_centered_message(msg, icon)
   -- print(
   --   "[DEBUG] show_centered_message called with msg:",
   --   msg or "nil",
   --   "icon:",
   --   icon or "nil"
   -- )

   icon = icon or "❄️" -- default icon
   local buf = vim.api.nvim_create_buf(false, true)
   if not buf or buf == 0 then
      -- print("[DEBUG] Failed to create buffer")
      return
   end
   -- print("[DEBUG] Created buffer:", buf)

   local lines = vim.split(msg or "", "\n")
   if #lines > 0 then
      lines[1] = icon .. " " .. lines[1]
   else
      lines = { icon }
   end
   -- print(
   --   "[DEBUG] Lines prepared:",
   --   table.concat(lines, " | ")
   -- )

   -- Set lines
   vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
   -- print("[DEBUG] Lines set in buffer")

   -- Create highlight
   vim.api.nvim_set_hl(0, "CenteredMessage", { fg = "#FFFFFF", bold = true })
   -- print(
   --   "[DEBUG] Highlight defined: CenteredMessage"
   -- )

   for i = 0, #lines - 1 do
      vim.api.nvim_buf_add_highlight(buf, -1, "CenteredMessage", i, 0, -1)
   end
   -- print("[DEBUG] Highlights applied")

   -- Get UI info
   local ui_list = vim.api.nvim_list_uis()
   if not ui_list or #ui_list == 0 then
      -- print(
      --   "[DEBUG] No UI available — skipping window creation"
      -- )
      return
   end
   local ui = ui_list[1]
   -- print(
   --   "[DEBUG] UI info — width:",
   --   ui.width,
   --   "height:",
   --   ui.height
   -- )

   local width = math.max(60, math.min(80, #lines[1] + 4))
   local height = #lines
   -- print(
   --   "[DEBUG] Calculated window size:",
   --   width,
   --   "x",
   --   height
   -- )

   local win = vim.api.nvim_open_win(buf, false, {
      relative = "editor",
      width = width,
      height = height,
      row = 3,
      col = math.floor((ui.width - width) / 2),
      style = "minimal",
      border = "rounded",
      zindex = 50,
   })

   if not win or win == 0 then
      -- print("[DEBUG] Failed to open window")
      return
   end
   -- print(
   --   "[DEBUG] Window opened successfully:",
   --   win
   -- )

   vim.api.nvim_buf_set_option(buf, "modifiable", false)
   -- print("[DEBUG] Buffer made unmodifiable")

   vim.defer_fn(function()
      -- print("[DEBUG] Auto-close timer triggered")
      if vim.api.nvim_win_is_valid(win) then
         -- print("[DEBUG] Closing window:", win)
         vim.api.nvim_win_close(win, true)
      else
         -- print(
         --   "[DEBUG] Window already invalid — not closing"
         -- )
      end
   end, 2000)
end

local function show_centered_error(msg)
   local buf = vim.api.nvim_create_buf(false, true)
   local lines = vim.split(msg, "\n")
   vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(msg, "\n"))

   vim.api.nvim_set_hl(0, "CenteredError", { fg = "#FF5555", bold = true })

   -- Apply highlight to all lines
   for i = 0, #lines - 1 do
      vim.api.nvim_buf_add_highlight(buf, -1, "CenteredError", i, 0, -1)
   end

   local width = 60
   local height = #lines
   local ui = vim.api.nvim_list_uis()[1]

   local win = vim.api.nvim_open_win(buf, false, {
      relative = "editor",
      width = width,
      height = height,
      row = 2,
      col = math.floor((ui.width - width) / 2),
      style = "minimal",
      border = "rounded",
      zindex = 50,
   })

   vim.api.nvim_buf_set_option(buf, "modifiable", false)
   -- Auto close after 3 seconds
   vim.defer_fn(function()
      if vim.api.nvim_win_is_valid(win) then
         vim.api.nvim_win_close(win, true)
      end
   end, 2000)
end

-- Checkout the selected branch
local function checkout_branch()
   if Ui.mode ~= "branches" then
      return
   end

   local branch = Ui.branches[Ui.selected_index]
   if not branch then
      return
   end

   -- Check for uncommitted changes
   local status = vim.fn.systemlist("git status --porcelain")
   if #status > 0 then
      show_centered_error(
         "🚨 You have uncommitted changes!\nCommit, stash, or discard them before switching branches."
      )
      return
   end

   -- Switch branch using 'git switch'
   local cmd = "git switch " .. vim.fn.shellescape(branch)
   local result = vim.fn.system(cmd)

   if vim.v.shell_error ~= 0 then
      show_centered_message("Failed to switch branch:\n" .. result, "❌")
      return
   end

   -- Update internal state
   Ui.branch_selected = branch

   -- Reload branch list (sorts active branch to top)
   if type(load_branches) == "function" then
      load_branches()
   end

   -- Reset selection index to top active branch
   Ui.selected_index = 1

   -- 1. Refresh UI first while main window retains focus
   refresh_ui()

   -- 2. Display completion message on top of refreshed UI
   show_centered_message("Switched to branch: " .. branch, "✅")
end

-- Delete the selected branch
local function delete_branch()
   -- only relevant in branches mode
   if Ui.mode ~= "branches" then
      return
   end

   -- get currently selected branch
   local branch = Ui.branches[Ui.selected_index]
   if not branch then
      return
   end

   -- confirm deletion
   local ok_confirm = vim.fn.confirm("Delete branch " .. branch .. "?", "Yes\nNo", 2)
   if ok_confirm ~= 1 then
      return
   end

   -- run git delete branch
   local out = vim.fn.system("git branch -D " .. vim.fn.shellescape(branch))
   if vim.v.shell_error ~= 0 then
      show_centered_message("Failed to delete branch: " .. out, vim.log.levels.ERROR)
   else
      show_centered_message("Deleted branch: " .. branch, vim.log.levels.INFO)
   end

   -- reload branch list and refresh UI
   load_branches()
   refresh_ui()
end

M.close = function()
   for _, win_key in ipairs({ "diff_win", "left_win", "right_win", "help_win" }) do
      if Ui and Ui[win_key] and vim.api.nvim_win_is_valid(Ui[win_key]) then
         pcall(vim.api.nvim_win_close, Ui[win_key], true)
         Ui[win_key] = nil
      end
   end
end

-- Open UI
function M.toggle(opts)
   -- 1. If windows are already open, close them (Toggle Off)
   if Ui and Ui.diff_win and vim.api.nvim_win_is_valid(Ui.diff_win) then
      M.close()
      return
   end

   Ui = Ui or {}

   if type(get_changed_files) == "function" then
      get_changed_files()
   end
   if type(load_branches) == "function" then
      load_branches()
   end

   -- Set default mode based on changed files count
   if Ui.changed_files and #Ui.changed_files > 0 then
      Ui.mode = "files"
   else
      Ui.mode = "branches"
   end

   Ui.selected_index = 1

   -- 2. Ensure Buffers Exist and are Valid
   if not Ui.diff_buf or not vim.api.nvim_buf_is_valid(Ui.diff_buf) then
      Ui.diff_buf = vim.api.nvim_create_buf(false, true)
   end
   if not Ui.right_buf or not vim.api.nvim_buf_is_valid(Ui.right_buf) then
      Ui.right_buf = vim.api.nvim_create_buf(false, true)
   end
   if not Ui.left_buf or not vim.api.nvim_buf_is_valid(Ui.left_buf) then
      Ui.left_buf = vim.api.nvim_create_buf(false, true)
   end
   if not Ui.help_buf or not vim.api.nvim_buf_is_valid(Ui.help_buf) then
      Ui.help_buf = vim.api.nvim_create_buf(false, true)
   end

   for _, buf in ipairs({ Ui.left_buf, Ui.right_buf, Ui.diff_buf, Ui.help_buf }) do
      vim.bo[buf].buftype = "nofile"
      vim.bo[buf].bufhidden = "hide" -- Keep buffers alive across toggles
      vim.bo[buf].modifiable = true
   end

   vim.notify(
      string.format(
         "[DEBUG Toggle Init] Mode: %s | Changed files: %d",
         tostring(Ui.mode),
         Ui.changed_files and #Ui.changed_files or 0
      ),
      vim.log.levels.INFO
   )

   -- 2. Screen Dimensions & Row Offsets
   local ui = vim.api.nvim_list_uis()[1]
   local editor_w = ui and ui.width or vim.o.columns
   local editor_h = ui and ui.height or vim.o.lines

   local statusline_h = (vim.o.laststatus > 0) and 1 or 0
   local available_h = editor_h - vim.o.cmdheight - statusline_h

   local w = math.floor(editor_w * 0.9)
   local col = math.floor((editor_w - w) / 2)

   local help_h = 1
   local branch_h = 4
   local log_h = 8
   local lower_h = 8

   local help_row = available_h - help_h - 2
   local branch_row = help_row - branch_h - 2
   local log_row = branch_row - log_h - 2
   local lower_row = help_row - lower_h - 2

   local diff_row = 2
   local diff_h
   if Ui.mode == "branches" then
      diff_h = math.max(log_row - diff_row - 2, 1)
   else
      diff_h = math.max(lower_row - diff_row - 2, 1)
   end

   -- 4. Clean up stale window references before opening
   for _, win_key in ipairs({ "left_win", "right_win", "help_win" }) do
      if Ui[win_key] and vim.api.nvim_win_is_valid(Ui[win_key]) then
         pcall(vim.api.nvim_win_close, Ui[win_key], true)
         Ui[win_key] = nil
      end
   end

   vim.notify(
      string.format(
         "[GitCompanion Toggle] Mode: %s | editor_h: %d | available_h: %d | help_row: %d | diff_h: %d",
         tostring(Ui.mode),
         editor_h,
         available_h,
         help_row,
         diff_h
      ),
      vim.log.levels.WARN
   )

   -- 3. Open Floating Windows
   Ui.diff_win = vim.api.nvim_open_win(Ui.diff_buf, false, {
      relative = "editor",
      width = w,
      height = diff_h,
      row = diff_row,
      col = col,
      style = "minimal",
      border = "rounded",
      title = " Code Changes ",
      title_pos = "center",
      zindex = 10,
   })

   if Ui.mode == "branches" then
      vim.notify(
         string.format(
            "[DEBUG Creating Right Win] Mode: %s | right_buf Valid: %s | log_row: %d | log_h: %d",
            tostring(Ui.mode),
            tostring(Ui.right_buf and vim.api.nvim_buf_is_valid(Ui.right_buf)),
            log_row,
            log_h
         ),
         vim.log.levels.WARN
      )

      Ui.right_win = vim.api.nvim_open_win(Ui.right_buf, false, {
         relative = "editor",
         width = w,
         height = log_h,
         row = log_row,
         col = col,
         style = "minimal",
         border = "rounded",
         title = " Commit Log ",
         title_pos = "center",
         zindex = 10,
      })

      vim.notify(
         string.format(
            "[DEBUG Right Win Result] right_win ID: %s | Is Valid: %s",
            tostring(Ui.right_win),
            tostring(Ui.right_win and vim.api.nvim_win_is_valid(Ui.right_win))
         ),
         vim.log.levels.WARN
      )

      Ui.left_win = vim.api.nvim_open_win(Ui.left_buf, true, {
         relative = "editor",
         width = w,
         height = branch_h,
         row = branch_row,
         col = col,
         style = "minimal",
         border = "rounded",
         title = " Git Branches ",
         title_pos = "center",
         zindex = 10,
      })
   else
      Ui.left_win = vim.api.nvim_open_win(Ui.left_buf, true, {
         relative = "editor",
         width = w,
         height = lower_h,
         row = lower_row,
         col = col,
         style = "minimal",
         border = "rounded",
         title = (Ui.mode == "stashes") and " Stashes " or " Files Changed ",
         title_pos = "center",
         zindex = 10,
      })
   end

   Ui.help_win = vim.api.nvim_open_win(Ui.help_buf, false, {
      relative = "editor",
      width = w,
      height = help_h,
      row = help_row,
      col = col,
      style = "minimal",
      border = "rounded",
      zindex = 10,
   })

   local left_text = "[H] Branches ↔ Files Changed ↔ Stashes [L]"
   local right_text = "Press ? For Help"

   -- Calculate dynamic padding using visual display width, not raw bytes
   local left_width = vim.fn.strdisplaywidth(left_text)
   local right_width = vim.fn.strdisplaywidth(right_text)
   local pad_len = math.max(0, w - left_width - right_width)
   local pad = string.rep(" ", pad_len)

   vim.api.nvim_set_option_value("modifiable", true, { buf = Ui.help_buf })
   vim.api.nvim_buf_set_lines(Ui.help_buf, 0, -1, false, { left_text .. pad .. right_text })
   vim.api.nvim_buf_add_highlight(Ui.help_buf, -1, "GitMsg", 0, 0, -1)
   vim.api.nvim_set_option_value("modifiable", false, { buf = Ui.help_buf })

   -- 6. Render UI Contents AFTER layout & windows exist
   if type(refresh_ui) == "function" then
      refresh_ui()
   end

   -- 4. Close Handler
   local function close_ui()
      for _, win in ipairs({ Ui.left_win, Ui.right_win, Ui.diff_win, Ui.help_win, Ui.full_win }) do
         if win and vim.api.nvim_win_is_valid(win) then
            vim.api.nvim_win_close(win, true)
         end
      end
      for _, buf in ipairs({ Ui.left_buf, Ui.right_buf, Ui.diff_buf, Ui.help_buf }) do
         if buf and vim.api.nvim_buf_is_valid(buf) then
            vim.api.nvim_buf_delete(buf, { force = true })
         end
      end
      Ui.left_win, Ui.right_win, Ui.diff_win, Ui.help_win = nil, nil, nil, nil
      Ui.left_buf, Ui.right_buf, Ui.diff_buf, Ui.help_buf = nil, nil, nil, nil
   end

   -- 5. Window Navigation Keymaps (J/K to move between windows vertically)
   local active_bufs = { Ui.left_buf, Ui.right_buf, Ui.diff_buf }

   for _, buf in ipairs(active_bufs) do
      -- Quit picker
      vim.keymap.set("n", "q", close_ui, { buffer = buf, silent = true, nowait = true })

      -- Trap horizontal split navigation so it doesn't break out of the UI
      vim.keymap.set("n", "sh", function() end, { buffer = buf, silent = true, nowait = true })
      vim.keymap.set("n", "sl", function() end, { buffer = buf, silent = true, nowait = true })

      -- Navigate Down visually (Diff -> [Log] -> Branch)
      vim.keymap.set("n", "sj", function()
         local cur = vim.api.nvim_get_current_win()
         if cur == Ui.diff_win then
            vim.api.nvim_set_current_win(Ui.mode == "branches" and Ui.right_win or Ui.left_win)
         elseif cur == Ui.right_win then
            vim.api.nvim_set_current_win(Ui.left_win)
         end
      end, { buffer = buf, silent = true })

      -- Navigate Up visually (Branch -> [Log] -> Diff)
      vim.keymap.set("n", "sk", function()
         local cur = vim.api.nvim_get_current_win()
         if cur == Ui.left_win then
            vim.api.nvim_set_current_win(Ui.mode == "branches" and Ui.right_win or Ui.diff_win)
         elseif cur == Ui.right_win then
            vim.api.nvim_set_current_win(Ui.diff_win)
         end
      end, { buffer = buf, silent = true })
   end

   -- Automatically update windows when natively moving the cursor
   local group = vim.api.nvim_create_augroup("GitPickerAutoCmds", { clear = true })

   local function show_help()
      local buf = vim.api.nvim_create_buf(false, true)
      local lines = {
         " Navigation",
         "  j / k       : Move selection up / down",
         "  sj / sk     : Jump up / down between panels",
         "  H / L       : Cycle views (Branches ↔ Files ↔ Stashes)",
         "",
         " Actions",
         "  <Space>     : Checkout Branch / Stage File / Pop Stash",
         "  d           : Delete Branch / Discard Changes / Drop Stash / Revert Commit",
         "  r           : Rename Branch (Branches) / Reword Commit (Commit Log)",
         "  y           : Copy Branch name (Branches) / Copy Commit metadata (Commit Log)",
         "  c           : Commit (Files) / Checkout Remote (Branches)",
         "  n           : Create new branch from selected (Branches)",
         "  m           : Merge branch into current (Branches)",
         "  g           : Reset HEAD to commit (Commit Log)",
         "  p / P       : Pull / Push branch (Branches)",
         "  s           : Create new stash (Any view)",
         "",
         " Merge Conflict Resolver",
         "  <Space>     : Resolve conflict under cursor (keeps current section)",
         "  b           : Keep both ours & theirs conflict sections",
         "  j / k       : Jump to next / previous conflict marker",
         "  q           : Exit resolver window",
         "",
         " General",
         "  ?           : Show this help modal",
         "  q / <Esc>   : Close picker or popup",
      }

      vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
      vim.bo[buf].modifiable = false

      local ui = vim.api.nvim_list_uis()[1]
      local width = 81
      local height = #lines + 2
      local row = math.floor((ui.height - height) / 2)
      local col = math.floor((ui.width - width) / 2)

      local win = vim.api.nvim_open_win(buf, true, {
         relative = "editor",
         width = width,
         height = height,
         row = row,
         col = col,
         style = "minimal",
         border = "rounded",
         title = " Git Picker Help ",
         title_pos = "center",
         zindex = 1000,
      })

      -- Highlight headings and hotkeys
      vim.api.nvim_set_hl(0, "GitPickerHelpKey", { fg = "#00d7ff", bold = true })
      vim.api.nvim_set_hl(0, "GitPickerHelpHeading", { fg = "#a6e22e", bold = true, italic = true })

      for i, line in ipairs(lines) do
         if line:match("^ %a") then
            vim.api.nvim_buf_add_highlight(buf, -1, "GitPickerHelpHeading", i - 1, 0, -1)
         else
            local sep = line:find(":")
            if sep then
               vim.api.nvim_buf_add_highlight(buf, -1, "GitPickerHelpKey", i - 1, 0, sep - 1)
            end
         end
      end

      local function close_help()
         if vim.api.nvim_win_is_valid(win) then
            vim.api.nvim_win_close(win, true)
         end
      end

      vim.keymap.set("n", "q", close_help, { buffer = buf, silent = true, nowait = true })
      vim.keymap.set("n", "<Esc>", close_help, { buffer = buf, silent = true, nowait = true })
      vim.keymap.set("n", "?", close_help, { buffer = buf, silent = true, nowait = true })
   end

   vim.api.nvim_create_autocmd("CursorMoved", {
      group = group,
      buffer = Ui.right_buf,
      callback = function()
         if Ui.mode == "branches" then
            render_diff()
         end
      end,
   })

   vim.api.nvim_create_autocmd("CursorMoved", {
      group = group,
      buffer = Ui.left_buf,
      callback = function()
         -- Keep index perfectly in sync with the native cursor
         local cursor = vim.api.nvim_win_get_cursor(0)
         Ui.selected_index = cursor[1]

         if Ui.mode == "files" or Ui.mode == "stashes" then
            render_diff()
         elseif Ui.mode == "branches" then
            Ui.branch_selected = Ui.branches[Ui.selected_index]
            render_right()
            render_diff()
         end
      end,
   })

   -- 6. Populate Data & Render Contents
   if type(get_changed_files) == "function" then
      get_changed_files()
   end
   if type(load_branches) == "function" then
      load_branches()
   end

   vim.notify(
      string.format(
         "[DEBUG Sec 6 Pre-Check] Ui.mode: %s | changed_files count: %d",
         tostring(Ui.mode),
         Ui.changed_files and #Ui.changed_files or 0
      ),
      vim.log.levels.WARN
   )

   -- Dynamically pick default mode based on freshly populated changed files
   if Ui.changed_files and #Ui.changed_files > 0 then
      Ui.mode = "files"
   else
      Ui.mode = "branches"
   end
   Ui.selected_index = 1

   vim.notify(
      string.format("[DEBUG Sec 6 Post-Check] Ui.mode evaluated to: %s", tostring(Ui.mode)),
      vim.log.levels.WARN
   )

   if type(refresh_ui) == "function" then
      refresh_ui()
   end

   -- Keymaps
   local function set_keymaps(buf)
      -- Navigation & mode toggle
      vim.keymap.set("n", "H", function()
         toggle_mode("prev")
      end, {
         buffer = buf,
         noremap = true,
         silent = true,
      })

      vim.keymap.set("n", "L", function()
         toggle_mode("next")
      end, {
         buffer = buf,
         noremap = true,
         silent = true,
      })

      vim.keymap.set("n", "?", show_help, { buffer = buf, noremap = true, silent = true, desc = "Show help" })

      vim.keymap.set("n", "s", function()
         vim.ui.input({ prompt = "Stash Message (leave blank for WIP): " }, function(input)
            if input == nil then
               return
            end -- User cancelled
            local msg = input == "" and "WIP" or input
            vim.fn.system("git stash push -m " .. vim.fn.shellescape(msg))

            Ui.mode = "stashes"
            Ui.selected_index = 1
            load_stashes()
            update_window_layout()
            refresh_ui()
            focus_left()
            show_centered_message("Stash created: " .. msg, "📦")
         end)
      end, { buffer = buf, noremap = true, silent = true, desc = "Create new stash" })

      -- G keymap for reset/rebase options on commits
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

         -- Extract hex commit hash anywhere on line (handles bullet points, tree characters, icons)
         local hash = line:match("(%x%x%x%x%x%x%x+)")
         if not hash then
            return
         end

         ---------------------------------------------------------------------------
         -- TEXT WRAPPING
         ---------------------------------------------------------------------------
         local function wrap_text(text, max_width)
            local lines, current = {}, ""
            for word in text:gmatch("%S+") do
               if #current + #word + 1 > max_width then
                  table.insert(lines, current)
                  current = word
               else
                  if current == "" then
                     current = word
                  else
                     current = current .. " " .. word
                  end
               end
            end
            if current ~= "" then
               table.insert(lines, current)
            end
            return lines
         end

         ---------------------------------------------------------------------------
         -- OPTIONS
         ---------------------------------------------------------------------------
         local options = {
            {
               key = "m",
               label = "Mixed reset",
               hl = "ResetBlue",
               desc = "Reset HEAD to this commit, keeping changes unstaged.",
               cmd = "git reset --mixed " .. hash,
            },
            {
               key = "s",
               label = "Soft reset",
               hl = "ResetGreen",
               desc = "Reset HEAD to this commit, keeping all changes staged.",
               cmd = "git reset --soft " .. hash,
            },
            {
               key = "h",
               label = "Hard reset",
               hl = "ResetRed",
               desc = "Fully reset working tree & index to this commit.",
               cmd = "git reset --hard " .. hash,
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

         ---------------------------------------------------------------------------
         -- POPUP WINDOWS
         ---------------------------------------------------------------------------
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
            title = " Reset to " .. hash .. " ",
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

         ---------------------------------------------------------------------------
         -- RENDER
         ---------------------------------------------------------------------------
         local function render()
            local lines = {}

            for i, opt in ipairs(options) do
               local prefix = (i == selected) and " " or "  "
               lines[#lines + 1] = prefix .. opt.label
            end

            vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
            vim.api.nvim_buf_clear_namespace(buf, -1, 0, -1)
            vim.api.nvim_buf_add_highlight(buf, -1, options[selected].hl, selected - 1, 0, -1)

            local wrapped = wrap_text(options[selected].desc, width - 4)
            vim.api.nvim_buf_set_lines(buf_desc, 0, -1, false, wrapped)
            vim.api.nvim_buf_clear_namespace(buf_desc, -1, 0, -1)
            for i = 1, #wrapped do
               vim.api.nvim_buf_add_highlight(buf_desc, -1, options[selected].hl, i - 1, 0, -1)
            end
         end

         render()

         ---------------------------------------------------------------------------
         -- CLOSE POPUP
         ---------------------------------------------------------------------------
         local function close_all()
            if vim.api.nvim_win_is_valid(win_desc) then
               vim.api.nvim_win_close(win_desc, true)
            end
            if vim.api.nvim_win_is_valid(win) then
               vim.api.nvim_win_close(win, true)
            end
            Ui.mode = "branches"
            refresh_ui()
         end

         ---------------------------------------------------------------------------
         -- MOVEMENT
         ---------------------------------------------------------------------------
         vim.keymap.set("n", "j", function()
            selected = math.min(#options, selected + 1)
            render()
         end, { buffer = buf })

         vim.keymap.set("n", "k", function()
            selected = math.max(1, selected - 1)
            render()
         end, { buffer = buf })

         ---------------------------------------------------------------------------
         -- APPLY RESET FUNCTION
         ---------------------------------------------------------------------------
         local function apply_selected_reset()
            local opt = options[selected]

            if not opt or not opt.cmd then
               close_all()
               return
            end

            -- Execute git command directly without worktree check blockage
            local out = vim.fn.system(opt.cmd)

            if vim.v.shell_error ~= 0 then
               vim.notify("Git error: " .. out, vim.log.levels.ERROR)
            else
               local msg = opt.label .. " → " .. hash
               vim.notify(msg, vim.log.levels.INFO)
            end

            close_all()
         end

         ---------------------------------------------------------------------------
         -- POPUP KEYMAPS
         ---------------------------------------------------------------------------

         -- Confirm current selection
         vim.keymap.set("n", "<CR>", apply_selected_reset, { buffer = buf, noremap = true, silent = true })

         -- Close popup
         vim.keymap.set("n", "q", close_all, { buffer = buf, noremap = true, silent = true })
         vim.keymap.set("n", "<Esc>", close_all, { buffer = buf, noremap = true, silent = true })

         -- Direct hotkey selection for reset options
         for idx, opt in ipairs(options) do
            if opt.key then
               vim.keymap.set("n", opt.key, function()
                  selected = idx
                  apply_selected_reset()
               end, { buffer = buf, noremap = true, silent = true })
            end
         end
      end, { buffer = Ui.right_buf, noremap = true, silent = true })

      -- keymap for dropping commits
      vim.keymap.set("n", "d", function()
         local win = vim.api.nvim_get_current_win()

         -- Handlers when focus is on left navigation pane
         if win == Ui.left_win then
            if Ui.mode == "files" then
               discard_changes_selected()
            elseif Ui.mode == "stashes" then
               local stash = Ui.stashes and Ui.stashes[Ui.selected_index]
               if stash then
                  local ref = stash:match("(stash@{%d+})")
                  if ref then
                     local ok = vim.fn.confirm("Drop " .. ref .. "?", "Yes\nNo", 2)
                     if ok == 1 then
                        vim.fn.system("git stash drop " .. ref)
                        load_stashes()
                        Ui.selected_index = math.max(1, Ui.selected_index - 1)
                        refresh_ui()
                        show_centered_message("Dropped " .. ref, "🗑️")
                     end
                  end
               end
            elseif Ui.mode == "branches" then
               delete_branch()
            end

            -- Handlers when focus is on Commit Log window (Ui.right_win)
         elseif win == Ui.right_win then
            local cursor = vim.api.nvim_win_get_cursor(Ui.right_win)
            local line = vim.api.nvim_buf_get_lines(Ui.right_buf, cursor[1] - 1, cursor[1], false)[1]
            local hash = line and line:match("([0-9a-f]+)")

            if hash then
               local confirm = vim.fn.confirm("Revert commit " .. hash:sub(1, 7) .. "?", "Yes\nNo", 2)
               if confirm == 1 then
                  local out = vim.fn.system("git revert --no-edit " .. hash)
                  if vim.v.shell_error == 0 then
                     show_centered_message("Reverted " .. hash:sub(1, 7), "🔄")
                     refresh_ui()
                  else
                     vim.notify("Failed to revert commit: " .. out, vim.log.levels.ERROR)
                  end
               end
            end
         end
      end, { buffer = buf, noremap = true, silent = true })

      -- Apply Action (<Space>)
      vim.keymap.set("n", "<Space>", function()
         local win = vim.api.nvim_get_current_win()
         if win ~= Ui.left_win then
            -- vim.notify(
            --    "[Space Debug] Current window ("
            --    .. tostring(win)
            --    .. ") != Ui.left_win ("
            --    .. tostring(Ui.left_win)
            --    .. ")",
            --    vim.log.levels.WARN
            -- )
            return
         end

         -- vim.notify("[Space Debug] Key pressed in left_win. Mode: " .. tostring(Ui.mode), vim.log.levels.INFO)

         if Ui.mode == "files" then
            stage_unstage_selected()
         elseif Ui.mode == "branches" then
            checkout_branch()
         elseif Ui.mode == "stashes" then
            local stash = Ui.stashes[Ui.selected_index]
            if stash then
               local ref = stash:match("(stash@{%d+})")
               if ref then
                  local ok = vim.fn.confirm("Pop " .. ref .. "?", "Yes\nNo", 2)
                  if ok == 1 then
                     vim.fn.system("git stash pop " .. ref)
                     if vim.v.shell_error == 0 then
                        show_centered_message("Successfully popped " .. ref, "✅")
                     else
                        show_centered_message("Merge conflict or error popping stash", "⚠️")
                     end
                     load_stashes()
                     Ui.selected_index = math.max(1, Ui.selected_index - 1)
                     refresh_ui()
                  end
               end
            end
         end
      end, { buffer = buf, noremap = true, silent = true })

      -- Add Enter keymap to toggle fold expansion on directory nodes
      vim.keymap.set("n", "<CR>", function()
         local win = vim.api.nvim_get_current_win()
         if win ~= Ui.left_win or Ui.mode ~= "files" then
            return
         end

         toggle_tree_node()
      end, { buffer = buf, noremap = true, silent = true })

      -- Delete Action (d)
      vim.keymap.set("n", "d", function()
         local win = vim.api.nvim_get_current_win()
         if win ~= Ui.left_win then
            return
         end

         if Ui.mode == "files" then
            discard_changes_selected()
         elseif Ui.mode == "stashes" then
            local stash = Ui.stashes[Ui.selected_index]
            if stash then
               local ref = stash:match("(stash@{%d+})")
               if ref then
                  local ok = vim.fn.confirm("Drop " .. ref .. "?", "Yes\nNo", 2)
                  if ok == 1 then
                     vim.fn.system("git stash drop " .. ref)
                     load_stashes()
                     Ui.selected_index = math.max(1, Ui.selected_index - 1)
                     refresh_ui()
                     show_centered_message("Dropped " .. ref, "🗑️")
                  end
               end
            end
         else
            delete_branch()
         end
      end, { buffer = Ui.left_buf, noremap = true, silent = true })

      -- Commit Keymap
      vim.keymap.set("n", "c", function()
         if Ui.mode == "branches" then
            local remotes = vim.fn.systemlist("git branch -r --format='%(refname:short)'")
            local missing = {}
            local local_set = {}
            for _, b in ipairs(Ui.branches) do
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
               show_centered_message("No remote branches available to checkout.", "❄️")
               return
            end

            local ui_info = vim.api.nvim_list_uis()[1]
            local width = math.floor(ui_info.width * 0.6) -- Adjust width here (0.6 = 60% of screen)
            local max_height = math.floor(ui_info.height * 0.6) -- Adjust max vertical height here
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

            -- Initial setup
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

            -- Live filtering
            vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
               buffer = buf,
               callback = function()
                  local line = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] or ""
                  local q = line
                  if q:sub(1, 2) == "> " then
                     q = q:sub(3)
                  else
                     -- Prevent user from deleting the prompt prefix
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
               if vim.api.nvim_win_is_valid(win) then
                  vim.api.nvim_win_close(win, true)
               end
               vim.cmd("stopinsert")
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
                  show_centered_message("Failed to switch branch:\n" .. result, "❌")
                  return
               end
               Ui.branch_selected = choice
               show_centered_message("Switched to branch: " .. choice, "✅")
               load_branches()
               Ui.selected_index = 1
               refresh_ui()
            end

            local opts = { buffer = buf, noremap = true, silent = true }

            local function move_down()
               selected = math.min(#filtered, selected + 1)
               render()
            end

            local function move_up()
               selected = math.max(1, selected - 1)
               render()
            end

            -- Insert mode navigation
            vim.keymap.set("i", "<C-j>", move_down, opts)
            vim.keymap.set("i", "<C-n>", move_down, opts)
            vim.keymap.set("i", "<Down>", move_down, opts)

            vim.keymap.set("i", "<C-k>", move_up, opts)
            vim.keymap.set("i", "<C-p>", move_up, opts)
            vim.keymap.set("i", "<Up>", move_up, opts)

            vim.keymap.set("i", "<CR>", confirm_selection, opts)
            vim.keymap.set("i", "<Esc>", close_popup, opts)
            vim.keymap.set("i", "<C-c>", close_popup, opts)

            -- Normal mode fallbacks
            vim.keymap.set("n", "j", move_down, opts)
            vim.keymap.set("n", "k", move_up, opts)
            vim.keymap.set("n", "<CR>", confirm_selection, opts)
            vim.keymap.set("n", "q", close_popup, opts)
            vim.keymap.set("n", "<Esc>", close_popup, opts)

            -- Start in insert mode at the end of the prompt
            vim.cmd("startinsert!")
            vim.api.nvim_win_set_cursor(win, { 1, 2 })

            return
         end

         if Ui.mode ~= "files" then
            return
         end

         local branch = Ui.branches[Ui.selected_index]
         if not branch or branch == "" then
            branch = Ui.branch_selected or "HEAD"
         end

         local width = math.floor(vim.o.columns * 0.9)
         local height_title = 1
         local height_desc = 4
         local height_diff = math.floor(vim.o.lines * 0.72) -- taller diff
         local spacing = 1
         local col = math.floor((vim.o.columns - width) / 2)

         -- =========================
         -- Background overlay
         -- =========================
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

         -- =========================
         -- Buffers
         -- =========================
         local buf_diff = vim.api.nvim_create_buf(false, true)
         vim.api.nvim_buf_set_option(buf_diff, "buftype", "nofile")
         vim.api.nvim_buf_set_option(buf_diff, "bufhidden", "wipe")
         vim.api.nvim_buf_set_option(buf_diff, "filetype", "diff")

         local diff_cmd = "git diff --cached"
         local diff_lines = vim.fn.systemlist(diff_cmd)
         if vim.v.shell_error ~= 0 or #diff_lines == 0 then
            diff_lines = { "[No staged changes]" }
         end
         vim.api.nvim_buf_set_lines(buf_diff, 0, -1, false, diff_lines)
         vim.api.nvim_buf_set_option(buf_diff, "modifiable", false)

         -- Buffers for title and description
         local buf_title = vim.api.nvim_create_buf(false, true)
         vim.api.nvim_buf_set_option(buf_title, "buftype", "acwrite")
         vim.api.nvim_buf_set_option(buf_title, "bufhidden", "wipe")
         vim.api.nvim_buf_set_lines(buf_title, 0, -1, false, { "" })

         local buf_desc = vim.api.nvim_create_buf(false, true)
         vim.api.nvim_buf_set_option(buf_desc, "buftype", "acwrite")
         vim.api.nvim_buf_set_option(buf_desc, "bufhidden", "wipe")
         vim.api.nvim_buf_set_lines(buf_desc, 0, -1, false, { "", "", "" })

         -- =========================
         -- Windows (diff top, commit bottom)
         -- =========================
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

         -- =========================
         -- Close popup helper
         -- =========================
         local function close_commit_popup()
            for _, w in ipairs({ win_title, win_desc, win_diff, win_overlay }) do
               if vim.api.nvim_win_is_valid(w) then
                  vim.api.nvim_win_close(w, true)
               end
            end

            -- Restore focus to the main UI
            if Ui.left_win and vim.api.nvim_win_is_valid(Ui.left_win) then
               vim.api.nvim_set_current_win(Ui.left_win)
            end
         end

         -- ====================================
         -- Start commit title in insert mode
         -- ====================================
         -- Clear the title buffer and enter insert mode
         local function prepare_title_buffer()
            vim.api.nvim_buf_set_lines(buf_title, 0, -1, false, { "" })
            vim.cmd("startinsert")
         end

         prepare_title_buffer()
         -- =========================
         -- Commit logic
         -- =========================
         local function commit_changes()
            vim.cmd("stopinsert") -- ensure we exit insert mode

            local title = vim.api.nvim_buf_get_lines(buf_title, 0, -1, false)[1] or ""
            local body = table.concat(vim.api.nvim_buf_get_lines(buf_desc, 0, -1, false), "\n")

            local cmd = "git commit -m " .. vim.fn.shellescape(title)

            if body:match("%S") then
               cmd = cmd .. " -m " .. vim.fn.shellescape(body)
            end
            vim.fn.system(cmd)

            show_centered_message("Committed changes on branch: " .. branch, "🌸")
            close_commit_popup()

            -- Refresh git status and UI
            load_branches()
            get_changed_files(Ui.branch_selected)

            -- If no changed files remain, return to branches view
            if #Ui.changed_files == 0 and Ui.mode == "files" then
               Ui.mode = "branches"
               Ui.selected_index = 1
               if type(update_window_layout) == "function" then
                  update_window_layout()
               end
            end

            refresh_ui()
         end

         -- =========================
         -- Keymaps
         -- =========================
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

         -- Start typing in title (but don't go into insert mode)
         vim.api.nvim_set_current_win(win_title)
      end)

      -- Pull latest changes
      vim.keymap.set("n", "p", function()
         if Ui.mode ~= "branches" then
            return
         end
         local branch = Ui.branches[Ui.selected_index]
         if not branch or branch == "" then
            show_centered_message("No branch selected", vim.log.levels.WARN)
            return
         end

         local cmd = "git pull origin " .. branch
         local stdout_lines = {}
         local stderr_lines = {}

         -- Run the pull command asynchronously
         vim.fn.jobstart(cmd, {
            stdout_buffered = true,
            stderr_buffered = true,
            on_stdout = function(_, data)
               stdout_lines = data or {}
            end,
            on_stderr = function(_, data)
               stderr_lines = data or {}
            end,
            on_exit = function(_, exit_code)
               vim.schedule(function()
                  local stdout_str = table.concat(stdout_lines or {}, "\n")
                  local stderr_str = table.concat(stderr_lines or {}, "\n")
                  local full_output = stdout_str .. "\n" .. stderr_str

                  local has_conflict = exit_code ~= 0 and string.find(full_output, "CONFLICT")

                  if has_conflict then
                     -- 1. Route strictly to conflict prompt
                     conflicts.handle_merge_result(full_output, exit_code)
                  else
                     -- 2. Route strictly to standard output floats
                     show_floating_pair(stdout_lines, stderr_lines)
                  end
               end)
            end,
         })

         -- Show spinner or any other loading feedback while pull is running
         show_centered_message("Pulling latest changes for branch: " .. branch, vim.log.levels.INFO)
      end, { buffer = buf, noremap = true, silent = true })

      -- Push branch
      vim.keymap.set("n", "P", function()
         local current_branch = branch or Ui.branch_selected or "HEAD"
         local remote = "origin"
         -- print("DEBUG: Starting push for branch:", current_branch)

         local spinner_chars = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
         local spinner_idx = 1

         -- Spinner window
         local buf = vim.api.nvim_create_buf(false, true)
         vim.api.nvim_buf_set_lines(
            buf,
            0,
            -1,
            false,
            { "Pushing to " .. current_branch .. " " .. spinner_chars[spinner_idx] }
         )
         local ui = vim.api.nvim_list_uis()[1]
         local win = vim.api.nvim_open_win(buf, false, {
            relative = "editor",
            width = 50,
            height = 1,
            row = 3,
            col = math.floor((ui.width - 50) / 2),
            style = "minimal",
            border = "rounded",
            zindex = 50,
         })

         local spinner_timer = vim.loop.new_timer()
         spinner_timer:start(
            100,
            100,
            vim.schedule_wrap(function()
               if not vim.api.nvim_win_is_valid(win) then
                  spinner_timer:stop()
                  spinner_timer:close()
                  return
               end
               spinner_idx = spinner_idx % #spinner_chars + 1
               vim.api.nvim_buf_set_lines(
                  buf,
                  0,
                  -1,
                  false,
                  { "✨ Pushing To " .. current_branch .. " " .. spinner_chars[spinner_idx] }
               )
            end)
         )

         local function do_push(force)
            local args = { "git", "push", "-u", remote, current_branch }
            if force then
               table.insert(args, 3, "--force")
            end

            vim.fn.jobstart(args, {
               stdout_buffered = true,
               stderr_buffered = true,
               on_exit = function(_, exit_code, _)
                  spinner_timer:stop()
                  spinner_timer:close()
                  vim.schedule(function()
                     if vim.api.nvim_win_is_valid(win) then
                        vim.api.nvim_win_close(win, true)
                     end
                     if exit_code == 0 then
                        show_centered_message("✅ Successfully pushed branch: " .. current_branch)
                        Ui.mode = "branches"
                        refresh_ui()

                        -- show_floating_pair({ "Push to " .. current_branch .. " succeeded!" }, {})
                     else
                        show_centered_message(" Failed to push branch: " .. current_branch)
                        -- show_floating_pair({}, { "Failed to push to " .. current_branch })
                     end
                  end)
               end,
            })
         end

         -- Run a dry-run push first to detect divergence
         local dry_output = vim.fn.system("git push --dry-run -u " .. remote .. " " .. current_branch .. " 2>&1")
         -- print("DEBUG: dry-run output:\n" .. dry_output)
         if dry_output:match("rejected") or dry_output:match("non-fast-forward") then
            local answer = vim.fn.input("Branch has diverged. Force push? (y/N): ")
            if answer:lower() == "y" then
               do_push(true)
            else
               -- print("DEBUG: user declined force push")
               show_centered_message("Push aborted.")
            end
         else
            do_push(false)
         end

         refresh_ui()
      end, { buffer = buf, noremap = true, silent = true })

      -- Rename commits (in commit float/log) or Rename branches (in branches mode)
      vim.keymap.set("n", "r", function()
         local win = vim.api.nvim_get_current_win()

         -- 1. Rename Commit when inside the Right Window (Commit Log)
         if win == Ui.right_win then
            local cursor = vim.api.nvim_win_get_cursor(Ui.right_win)
            local line = vim.api.nvim_buf_get_lines(Ui.right_buf, cursor[1] - 1, cursor[1], false)[1] or ""
            local hash = line:match("^(%S+)")

            if not hash then
               vim.notify("Git: No valid commit hash found on current line.", vim.log.levels.WARN)
               return
            end

            -- Check if selected commit is HEAD
            local head_hash = vim.fn.system("git rev-parse --short HEAD"):gsub("%s+", "")
            local is_head = hash:find("^" .. head_hash) or head_hash:find("^" .. head_hash)

            local current_msg = vim.fn.system("git log -1 --format=%s " .. hash):gsub("%s+$", "")

            vim.ui.input({
               prompt = "Rename commit (" .. hash:sub(1, 7) .. "): ",
               default = current_msg,
            }, function(new_msg)
               if not new_msg or new_msg == "" or new_msg == current_msg then
                  return
               end

               if is_head then
                  -- Simple amend for HEAD
                  local cmd = "git commit --amend -m " .. vim.fn.shellescape(new_msg)
                  local out = vim.fn.system(cmd)
                  if vim.v.shell_error == 0 then
                     show_centered_message("Renamed HEAD commit", "✏️")
                     refresh_ui()
                  else
                     vim.notify("Failed to rename HEAD commit: " .. out, vim.log.levels.ERROR)
                  end
               else
                  -- Autostash uncommitted worktree changes before rebasing
                  local stashed = false
                  local status = vim.fn.system("git status --porcelain"):gsub("%s+$", "")
                  if #status > 0 then
                     vim.fn.system("git stash push -m 'temp_reword_stash'")
                     stashed = true
                  end

                  -- Non-interactive Git rebase with custom sequence editor
                  local sequence_cmd = string.format(
                     "GIT_SEQUENCE_EDITOR=\"sed -i '' 's/^pick %s/reword %s/'\" GIT_EDITOR=\"echo %s >\" git rebase -i %s^",
                     hash,
                     hash,
                     vim.fn.shellescape(new_msg),
                     hash
                  )

                  -- Fallback using git-filter-repo / parent reset if rebase fails
                  local rebase_cmd = string.format("git rebase -i --onto %s %s^", hash, hash)

                  -- Execute reword via exec during rebase
                  local exec_cmd = string.format(
                     'git rebase -i %s^ --exec "git commit --amend -m %s"',
                     hash,
                     vim.fn.shellescape(new_msg)
                  )

                  -- Simple head check & reword exec
                  local out = vim.fn.system(
                     string.format(
                        "git filter-branch --msg-filter 'if [ $GIT_COMMIT = %s ]; then echo %s; else cat; fi' %s~1..HEAD",
                        hash,
                        vim.fn.shellescape(new_msg),
                        hash
                     )
                  )

                  -- If filter-branch is blocked/slow, fallback to git commit-tree plumbing safely:
                  if vim.v.shell_error ~= 0 then
                     local parent = vim.fn.system("git rev-parse " .. hash .. "^"):gsub("%s+", "")
                     local tree = vim.fn.system("git rev-parse " .. hash .. "^{tree}"):gsub("%s+", "")
                     local new_commit = vim.fn
                         .system(
                            string.format(
                               "git commit-tree %s -p %s -m %s",
                               tree,
                               parent,
                               vim.fn.shellescape(new_msg)
                            )
                         )
                         :gsub("%s+", "")

                     if #new_commit > 0 then
                        out = vim.fn.system(string.format("git rebase --onto %s %s HEAD", new_commit, hash))
                     end
                  end

                  -- Restore stashed changes if any were saved
                  if stashed then
                     vim.fn.system("git stash pop")
                  end

                  if vim.v.shell_error == 0 then
                     show_centered_message("Renamed commit " .. hash:sub(1, 7), "✏️")
                     refresh_ui()
                  else
                     vim.notify("Failed to reword commit: " .. out, vim.log.levels.ERROR)
                  end
               end
            end)

            -- 2. Rename Branch when inside Left Window in 'branches' mode
         elseif win == Ui.left_win and Ui.mode == "branches" then
            local branch = Ui.branches[Ui.selected_index]
            if not branch or branch == "" then
               branch = Ui.branch_selected or "HEAD"
            end

            vim.ui.input({
               prompt = "Rename branch '" .. branch .. "'",
               default = branch,
            }, function(new_branch)
               if not new_branch or new_branch == "" or new_branch == branch then
                  return
               end

               local cmd =
                   string.format("git branch -m %s %s", vim.fn.shellescape(branch), vim.fn.shellescape(new_branch))
               local out = vim.fn.system(cmd)

               if vim.v.shell_error == 0 then
                  if Ui.branch_selected == branch then
                     Ui.branch_selected = new_branch
                  end
                  show_centered_message("Renamed branch: " .. branch .. " ➔ " .. new_branch, "🌿")
                  load_branches()
                  refresh_ui()
               else
                  vim.notify("Failed to rename branch: " .. out, vim.log.levels.ERROR)
               end
            end)
         end
      end, { buffer = buf, noremap = true, silent = true, desc = "Rename commit or branch" })

      -- Yank branch (in branch view) or commit details (in commit view)
      vim.keymap.set("n", "y", function()
         local win = vim.api.nvim_get_current_win()

         -- 1. Commit View: Open custom floating modal
         if win == Ui.right_win then
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

            -- Create scratch buffer for floating menu
            local buf = vim.api.nvim_create_buf(false, true)
            vim.api.nvim_buf_set_lines(buf, 0, -1, false, options)

            -- Window dimensions and centering
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

            -- Buffer local options
            vim.bo[buf].modifiable = false
            vim.bo[buf].bufhidden = "wipe"
            vim.wo[float_win].cursorline = true

            -- Sanitized commit hash extraction (strictly hex)
            local raw_hash = line:match("([a-f0-9]+)") or hash
            local clean_hash = vim.fn.shellescape(raw_hash)

            -- Helper function to yank based on index (1..5)
            local function perform_yank(choice_num)
               if vim.api.nvim_win_is_valid(float_win) then
                  vim.api.nvim_win_close(float_win, true)
               end

               local text_to_yank = ""
               local choice_name = ""

               if choice_num == 1 then
                  choice_name = "ID"
                  -- Returns full 40-character commit SHA safely
                  text_to_yank = vim.fn.system("git rev-parse " .. clean_hash):gsub("%s+", "")
               elseif choice_num == 2 then
                  choice_name = "Title"
                  text_to_yank = vim.fn.system("git log -1 --format=%s " .. clean_hash):gsub("%s+$", "")
               elseif choice_num == 3 then
                  choice_name = "Description"
                  text_to_yank = vim.fn.system("git log -1 --format=%b " .. clean_hash):gsub("%s+$", "")
               elseif choice_num == 4 then
                  choice_name = "Author"
                  -- Fixed shell redirection: quoted placeholder format string
                  text_to_yank = vim.fn.system("git log -1 --format='%an <%ae>' " .. clean_hash):gsub("%s+$", "")
               elseif choice_num == 5 then
                  choice_name = "Time"
                  text_to_yank = vim.fn.system("git log -1 --format=%cd " .. clean_hash):gsub("%s+$", "")
               end

               if text_to_yank ~= "" then
                  vim.fn.setreg('"', text_to_yank)
                  vim.fn.setreg("+", text_to_yank)
                  show_centered_message("Yanked " .. choice_name .. ": " .. text_to_yank:sub(1, 35), "📋")
               else
                  vim.notify(
                     "Git: Selected field is empty for commit " .. raw_hash:sub(1, 7),
                     vim.log.levels.INFO
                  )
               end
            end
            -- Keymaps for selecting via 1-5 number keys
            for i = 1, 5 do
               vim.keymap.set("n", tostring(i), function()
                  perform_yank(i)
               end, { buffer = buf, nowait = true, noremap = true, silent = true })
            end

            -- Keymap for selecting current cursor line with <CR>
            vim.keymap.set("n", "<CR>", function()
               local line_num = vim.api.nvim_win_get_cursor(float_win)[1]
               perform_yank(line_num)
            end, { buffer = buf, noremap = true, silent = true })

            -- Keymaps to close floating menu with <Esc> or q
            local close_keys = { "<Esc>", "q" }
            for _, key in ipairs(close_keys) do
               vim.keymap.set("n", key, function()
                  if vim.api.nvim_win_is_valid(float_win) then
                     vim.api.nvim_win_close(float_win, true)
                  end
               end, { buffer = buf, noremap = true, silent = true })
            end

            -- 2. Branch View: Yank selected branch name directly
         elseif win == Ui.left_win and Ui.mode == "branches" then
            local branch = Ui.branches[Ui.selected_index]
            if not branch or branch == "" then
               branch = Ui.branch_selected or "HEAD"
            end

            -- Clean up active branch markers (e.g., stripping '* ')
            branch = branch:gsub("^%*%s*", ""):gsub("%s+$", "")

            vim.fn.setreg('"', branch)
            vim.fn.setreg("+", branch)
            show_centered_message("Yanked branch: " .. branch, "🌿")
         end
      end, { noremap = true, silent = true, desc = "Yank branch or commit metadata" })

      -- n keymap to create new branches off of selected branch
      vim.keymap.set("n", "n", function()
         local buf = Ui.left_buf
         if not buf or not vim.api.nvim_buf_is_valid(buf) then
            return
         end
         if vim.api.nvim_get_current_buf() ~= buf then
            return
         end

         local current_branch = Ui.branch_selected
         if not current_branch or current_branch == "" then
            vim.notify("No branch selected!", vim.log.levels.ERROR)
            return
         end

         local function show_centered_error(msg)
            local buf = vim.api.nvim_create_buf(false, true)
            local lines = vim.split(msg, "\n")
            vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(msg, "\n"))

            vim.api.nvim_set_hl(0, "CenteredError", { fg = "#FF5555", bold = true })

            -- Apply highlight to all lines
            for i = 0, #lines - 1 do
               vim.api.nvim_buf_add_highlight(buf, -1, "CenteredError", i, 0, -1)
            end

            local width = 60
            local height = #lines
            local ui = vim.api.nvim_list_uis()[1]

            local win = vim.api.nvim_open_win(buf, false, {
               relative = "editor",
               width = width,
               height = height,
               row = 2,
               col = math.floor((ui.width - width) / 2),
               style = "minimal",
               border = "rounded",
               zindex = 50,
            })

            vim.api.nvim_buf_set_option(buf, "modifiable", false)
            -- Auto close after 3 seconds
            vim.defer_fn(function()
               if vim.api.nvim_win_is_valid(win) then
                  vim.api.nvim_win_close(win, true)
               end
            end, 2000)
         end

         -- Check for uncommitted changes using systemlist
         local status = vim.fn.systemlist("git status --porcelain")
         if #status > 0 then
            show_centered_error(
               "🚨 You have uncommitted changes!\nCommit, stash, or discard them before switching branches."
            )
            return
         end

         -- Window size
         local width, height = 50, 1
         local ui = vim.api.nvim_list_uis()[1]
         local buf = vim.api.nvim_create_buf(false, true)

         -- Open floating window with a title
         local win = vim.api.nvim_open_win(buf, true, {
            relative = "editor",
            width = width,
            height = height,
            row = 3,
            col = math.floor((ui.width - width) / 2),
            style = "minimal",
            border = "rounded",
            title = " Create New Branch: " .. current_branch .. " ",
            title_pos = "center",
            zindex = 50,
         })

         -- Start insert mode at second line
         vim.api.nvim_win_set_cursor(win, { 1, 0 })
         vim.cmd("startinsert")

         -- Keymap for Enter to create branch
         -- Normal mode mapping inside the buffer
         -- after creating `buf` and `win`
         -- set normal mode mapping for Enter
         vim.keymap.set("n", "<CR>", function()
            local new_branch = vim.api.nvim_get_current_line()
            vim.api.nvim_win_close(win, true)

            if new_branch == "" then
               print("Aborted: no branch name entered")
               return
            end

            -- Spinner
            local spinner_chars = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
            local spinner_idx = 1
            local spin_buf = vim.api.nvim_create_buf(false, true)
            local spin_win = vim.api.nvim_open_win(spin_buf, false, {
               relative = "editor",
               width = 50,
               height = 1,
               row = 2,
               col = math.floor((vim.api.nvim_list_uis()[1].width - 50) / 2),
               style = "minimal",
               border = "rounded",
               zindex = 50,
            })

            local spinner_timer = vim.loop.new_timer()
            spinner_timer:start(
               100,
               100,
               vim.schedule_wrap(function()
                  if not vim.api.nvim_win_is_valid(spin_win) then
                     spinner_timer:stop()
                     spinner_timer:close()
                     return
                  end
                  spinner_idx = spinner_idx % #spinner_chars + 1
                  vim.api.nvim_buf_set_lines(
                     spin_buf,
                     0,
                     -1,
                     false,
                     { "✨ Creating new branch " .. new_branch .. " " .. spinner_chars[spinner_idx] }
                  )
               end)
            )

            vim.fn.jobstart({ "git", "checkout", "-b", new_branch, current_branch }, {
               on_exit = function(_, exit_code)
                  spinner_timer:stop()
                  spinner_timer:close()
                  vim.schedule(function()
                     if vim.api.nvim_win_is_valid(spin_win) then
                        vim.api.nvim_win_close(spin_win, true)
                     end

                     if exit_code == 0 then
                        print("✅ Created new branch '" .. new_branch .. "' from '" .. current_branch .. "'")

                        -- 1. Re-query local branches so Ui.branches array updates
                        Ui.branches = vim.fn.systemlist("git branch --format='%(refname:short)'")

                        -- 2. Set index to point to the newly created branch
                        for idx, b in ipairs(Ui.branches) do
                           if b == new_branch then
                              Ui.selected_index = idx
                              break
                           end
                        end

                        -- 3. Trigger UI re-render
                        refresh_ui()
                     else
                        print(" Failed to create branch '" .. new_branch .. "'")
                     end

                     -- 4. Refocus back to the branches window
                     if Ui.left_win and vim.api.nvim_win_is_valid(Ui.left_win) then
                        vim.api.nvim_set_current_win(Ui.left_win)
                     end
                  end)
               end,
            })
         end, { buffer = buf, noremap = true, silent = true })

         -- Keymap to quit the floating window with 'q' in normal mode
         vim.api.nvim_buf_set_keymap(
            buf,
            "n",
            "q",
            [[<Cmd>lua vim.api.nvim_win_close(0, true)<CR>]],
            { noremap = true, silent = true }
         )
      end, {
         buffer = Ui.left_buf,
         noremap = true,
         silent = true,
         desc = "Create new branch from selected",
      })

      -- m keymap for merge options
      vim.keymap.set("n", "m", function()
         if Ui.mode ~= "branches" then
            return
         end

         local function wrap_text(text, max_width)
            local lines, current_line = {}, ""
            for word in text:gmatch("%S+") do
               if #current_line + #word + 1 > max_width then
                  table.insert(lines, current_line)
                  current_line = word
               else
                  if current_line == "" then
                     current_line = word
                  else
                     current_line = current_line .. " " .. word
                  end
               end
            end
            if current_line ~= "" then
               table.insert(lines, current_line)
            end
            return lines
         end

         local target_branch = Ui.branch_selected
         if not target_branch or target_branch == "" then
            vim.notify("No branch selected!", vim.log.levels.ERROR)
            return
         end

         local current_branch = vim.fn.trim(vim.fn.system("git branch --show-current"))
         if current_branch == target_branch then
            vim.notify("Cannot merge a branch into itself!", vim.log.levels.ERROR)
            return
         end

         -- OPTIONS
         local options = {
            {
               key = "m",
               label = "Regular merge",
               hl = "MergeBlue",
               desc = "Merge '"
                   .. target_branch
                   .. "' into '"
                   .. current_branch
                   .. "'. Creates a merge commit if needed.",
               cmd = "git merge " .. target_branch,
            },
            {
               key = "s",
               label = "Squash merge, leave uncommitted",
               hl = "MergeGreen",
               desc = "Squash commits from '"
                   .. target_branch
                   .. "' into working tree, do not commit automatically.",
               cmd = "git merge --squash " .. target_branch,
            },
            {
               key = "S",
               label = "Squash merge and commit",
               hl = "MergeRed",
               desc = "Squash commits from '" .. target_branch .. "' and commit automatically.",
               cmd = string.format(
                  "git merge --squash %s && git commit -m 'Merge %s into %s'",
                  target_branch,
                  target_branch,
                  current_branch
               ),
            },
            {
               key = "q",
               label = "Cancel",
               hl = "MergeWhite",
               desc = "Exit without merging.",
               cmd = nil,
            },
         }

         local selected = 1
         local ui = vim.api.nvim_list_uis()[1]
         local width, height = 52, #options + 3
         local row, col = math.floor((ui.height - height) / 2), math.floor((ui.width - width) / 2)

         -- POPUP WINDOW
         local buf_win = vim.api.nvim_create_buf(false, true)
         local win = vim.api.nvim_open_win(buf_win, true, {
            relative = "editor",
            width = width,
            height = height,
            row = row - 1,
            col = col,
            style = "minimal",
            border = "rounded",
            title = " Merge " .. target_branch .. " → " .. current_branch .. " ",
            title_pos = "center",
            zindex = 500,
         })

         local buf_desc = vim.api.nvim_create_buf(false, true)
         local win_desc = vim.api.nvim_open_win(buf_desc, false, {
            relative = "editor",
            width = width,
            height = 2,
            row = row + height + 1,
            col = col,
            style = "minimal",
            border = "rounded",
            title = " Info ",
            title_pos = "center",
            zindex = 500,
         })

         vim.api.nvim_win_set_option(win, "cursorline", false)
         vim.api.nvim_win_set_cursor(win, { 1, 0 })
         vim.api.nvim_win_set_option(win_desc, "cursorline", false)
         vim.api.nvim_win_set_cursor(win_desc, { 1, 0 })

         -- RENDER FUNCTION
         local function render()
            local lines = {}
            for i, opt in ipairs(options) do
               lines[#lines + 1] = (i == selected and " " or "  ") .. opt.label
            end
            vim.api.nvim_buf_set_lines(buf_win, 0, -1, false, lines)
            vim.api.nvim_buf_clear_namespace(buf_win, -1, 0, -1)
            vim.api.nvim_buf_add_highlight(buf_win, -1, options[selected].hl, selected - 1, 0, -1)

            local desc_lines = wrap_text(options[selected].desc, width - 4)
            vim.api.nvim_buf_set_lines(buf_desc, 0, -1, false, desc_lines)
            vim.api.nvim_buf_clear_namespace(buf_desc, -1, 0, -1)
            for i = 1, #desc_lines do
               vim.api.nvim_buf_add_highlight(buf_desc, -1, options[selected].hl, i - 1, 0, -1)
            end
         end
         render()

         -- MOVEMENT
         vim.keymap.set("n", "j", function()
            selected = math.min(#options, selected + 1)
            render()
         end, { buffer = buf_win })
         vim.keymap.set("n", "k", function()
            selected = math.max(1, selected - 1)
            render()
         end, { buffer = buf_win })

         -- Close the merge popup completely (if 'q' or 'Esc' pressed)
         local function close_all()
            if vim.api.nvim_win_is_valid(win_desc) then
               vim.api.nvim_win_close(win_desc, true)
            end
            if vim.api.nvim_win_is_valid(win) then
               vim.api.nvim_win_close(win, true)
            end
            Ui.mode = "branches"
            refresh_ui()
         end

         local function apply_selected()
            local opt = options[selected]
            if not opt.cmd then
               close_all()
               return
            end

            close_all() -- close main popup first

            -- 1. Ensure tables are explicitly instantiated outside callbacks
            local stdout_lines = {}
            local stderr_lines = {}

            -- run merge asynchronously
            vim.fn.jobstart(opt.cmd, {
               stdout_buffered = true,
               stderr_buffered = true,
               on_stdout = function(_, data)
                  if data and #data > 0 then
                     for _, line in ipairs(data) do
                        if line ~= "" then
                           table.insert(stdout_lines, line)
                        end
                     end
                  end
               end,
               on_stderr = function(_, data)
                  if data and #data > 0 then
                     for _, line in ipairs(data) do
                        if line ~= "" then
                           table.insert(stderr_lines, line)
                        end
                     end
                  end
               end,
               on_exit = function(_, exit_code)
                  vim.schedule(function()
                     -- Safe fallback concatenation
                     local stdout_str = table.concat(stdout_lines or {}, "\n")
                     local stderr_str = table.concat(stderr_lines or {}, "\n")
                     local full_output = stdout_str .. "\n" .. stderr_str

                     local has_conflict = exit_code ~= 0 and string.find(full_output, "CONFLICT")

                     if has_conflict then
                        -- Trigger conflict resolution UI directly
                        conflicts.handle_merge_result(full_output, exit_code)
                     else
                        -- Only show output/error floats if there are NO conflicts
                        if type(show_floating_pair) == "function" then
                           show_floating_pair(stdout_lines, stderr_lines)
                        end
                     end
                  end)
               end,
            })
         end

         vim.keymap.set("n", "<CR>", apply_selected, { buffer = buf_win })
         for idx, opt in ipairs(options) do
            vim.keymap.set("n", opt.key, function()
               selected = idx
               apply_selected()
            end, { buffer = buf_win })
         end

         vim.keymap.set("n", "q", close_all, { buffer = buf_win })
         vim.keymap.set("n", "<Esc>", close_all, { buffer = buf_win })
      end, { buffer = buf, noremap = true, silent = true })

      -- Close UI
      vim.keymap.set("n", "q", function()
         close_ui()
         reload_file_buffer()
      end, {
         buffer = buf,
         noremap = true,
         silent = true,
      })
   end

   -- Apply keymaps to both buffers
   set_keymaps(Ui.left_buf)
   set_keymaps(Ui.right_buf)
   set_keymaps(Ui.diff_buf)
   refresh_ui()
   init_ui()
end

M.setup = function(opts)
   -- Define your plugin's default settings
   local default_opts = {
      -- Add any user-configurable options here in the future
   }

   -- Merge default options with user-provided options
   M.options = vim.tbl_deep_extend("force", default_opts, opts or {})

   -- Expose a Neovim user command
   vim.api.nvim_create_user_command("GitCompanion", function()
      M.toggle()
   end, { desc = "Open GitCompanion UI" })
end

return M
