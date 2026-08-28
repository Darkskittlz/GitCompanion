local graph = require("gitcompanion.git.graph")

local M = {}

-- 1. Require shared state
local State = require("gitcompanion.state")

-- 2. Local references to functions imported from other modules
local build_tree_from_files
local flatten_tree

--- Initialize external UI tree dependencies to avoid circular require loops
function M.setup_dependencies(tree_module)
   build_tree_from_files = tree_module.build_tree_from_files
   flatten_tree = tree_module.flatten_tree
end

---------------------------------------------------------------------------
-- Functions
---------------------------------------------------------------------------

function M.git_root()
   local root = vim.fn.systemlist("git rev-parse --show-toplevel")[1]
   return root ~= "" and root or "."
end

function M.run_git(cmd)
   if type(cmd) == "table" then
      return vim.fn.systemlist(cmd)
   end
   return vim.fn.systemlist(cmd)
end

--- Asynchronously loads branch details, tracking information, and statuses.
function M.load_branches_async(opts, cb)
   if type(opts) == "function" then
      cb = opts
      opts = {}
   end
   opts = opts or {}

   local Ui = State.Ui

   local function fetch_and_load()
      local branches_raw, current_raw, tracking_raw, status_raw
      local pending = 4

      local function check_done()
         pending = pending - 1
         if pending > 0 then
            return
         end

         vim.schedule(function()
            local branches = vim.split(branches_raw or "", "\n", { trimempty = true })
            local cleaned = {}
            for _, b in ipairs(branches) do
               if b and b:match("%S") then
                  table.insert(cleaned, b)
               end
            end

            local current = (vim.split(current_raw or "", "\n", { trimempty = true }))[1] or ""

            Ui.branch_ahead_behind = {}
            local tracking_info = vim.split(tracking_raw or "", "\n", { trimempty = true })
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

            local branch_statuses = {}
            local status_lines = vim.split(status_raw or "", "\n", { trimempty = true })
            for _, branch in ipairs(cleaned) do
               if branch == current then
                  local staged, unstaged = false, false
                  for _, line in ipairs(status_lines) do
                     local x = line:sub(1, 1)
                     local y = line:sub(2, 2)
                     if x ~= " " then
                        staged = true
                     end
                     if y ~= " " then
                        unstaged = true
                     end
                  end

                  if unstaged then
                     branch_statuses[branch] = "💣"
                  elseif staged then
                     branch_statuses[branch] = "✅"
                  else
                     branch_statuses[branch] = ""
                  end
               else
                  branch_statuses[branch] = ""
               end
            end

            table.sort(cleaned, function(a, b)
               if a == current then
                  return true
               end
               if b == current then
                  return false
               end
               return a < b
            end)

            Ui.branches = cleaned
            Ui.branch_statuses = branch_statuses
            Ui.branch_selected = Ui.branch_selected or Ui.branches[1]

            if Ui.commit_graph_cache and Ui.branch_selected then
               Ui.commit_graph_cache[Ui.branch_selected] = nil
            end

            if cb then
               cb(cleaned)
            end
         end)
      end

      vim.system({ "git", "branch", "--list", "--format=%(refname:short)" }, { text = true }, function(obj)
         branches_raw = obj.stdout
         check_done()
      end)

      vim.system({ "git", "rev-parse", "--abbrev-ref", "HEAD" }, { text = true }, function(obj)
         current_raw = obj.stdout
         check_done()
      end)

      vim.system(
         { "git", "for-each-ref", "--format=%(refname:short)|%(upstream:track)", "refs/heads/" },
         { text = true },
         function(obj)
            tracking_raw = obj.stdout
            check_done()
         end
      )

      vim.system({ "git", "status", "--porcelain" }, { text = true }, function(obj)
         status_raw = obj.stdout
         check_done()
      end)
   end

   -- Perform git fetch if explicitly requested (e.g. after push)
   if opts.fetch then
      vim.system({ "git", "fetch" }, { text = true }, function()
         fetch_and_load()
      end)
   else
      fetch_and_load()
   end
end

--- Asynchronously loads commit history for a branch
function M.load_commits_async(branch, cb)
   if type(branch) == "function" then
      cb = branch
      branch = nil
   end

   local State = require("gitcompanion.state")
   local target_branch = branch or State.Ui.branch_selected or State.Ui.current_branch

   if not target_branch or target_branch == "" then
      if type(cb) == "function" then
         cb({})
      end
      return
   end

   local cmd = {
      "git",
      "log",
      target_branch,
      "--graph",
      "--format=%h|%p|%an|%cr|%s",
      "--format=%h|%p|%an|%cr|%sD|%s",
   }

   vim.system(cmd, { text = true }, function(obj)
      vim.schedule(function()
         local raw_output = obj.stdout or ""
         -- Split string by line breaks into a table of lines expected by nvim_buf_set_lines
         local lines = vim.split(raw_output, "\n", { trimempty = true })

         State.Ui.commit_graph_cache[target_branch] = lines

         if type(cb) == "function" then
            cb(lines)
         end
      end)
   end)
end

function M.load_stashes()
   local Ui = State.Ui
   local raw = M.run_git("git stash list --pretty='%gd: %s'") or {}
   Ui.stashes = vim.tbl_filter(function(s)
      return s and #s > 0
   end, raw)
end

function M.parse_file_status(line)
   if #line < 4 then
      return nil
   end

   local staged_char = line:sub(1, 1)
   local unstaged_char = line:sub(2, 2)
   local path_info = line:sub(4):gsub("^%s+", ""):gsub('^"', ""):gsub('"$', "")

   if staged_char == "?" and unstaged_char == "?" then
      return {
         status = "?",
         staged = false,
         path = path_info,
         display = path_info,
      }
   end

   local is_staged = staged_char ~= " " and staged_char ~= "?"
   local status_code = is_staged and staged_char or unstaged_char

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

function M.get_changed_files_async(cb)
   local Ui = State.Ui
   Ui.diff_cache = Ui.diff_cache or {}
   for key in pairs(Ui.diff_cache) do
      if not key:match("^%x%x%x%x%x%x%x+") and not key:match("^stash@") then
         Ui.diff_cache[key] = nil
      end
   end

   vim.system({ "git", "status", "--porcelain", "-uall" }, { text = true }, function(obj)
      vim.schedule(function()
         local status_lines = vim.split(obj.stdout or "", "\n", { trimempty = true })
         local files = {}
         Ui.has_conflicts = false

         for _, line in ipairs(status_lines) do
            local code = line:sub(1, 2)
            local parsed = M.parse_file_status(line)
            if parsed then
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
         if build_tree_from_files and flatten_tree then
            Ui.tree_root = build_tree_from_files(files)
            Ui.visible_tree_lines = flatten_tree(Ui.tree_root)
         end

         if type(cb) == "function" then
            cb(files)
         end
      end)
   end)
end

return M
