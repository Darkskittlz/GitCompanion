local M = {}

-- Internal Helper: Fetch diff for a single file (handles untracked files)
local function get_diff_for_target(path)
   if not path or path == "" then
      return { "[No file selected]" }
   end

   local is_tracked = (vim.fn.system({ "git", "ls-files", "--error-unmatch", path }) and vim.v.shell_error == 0)

   local cmd
   if is_tracked then
      cmd = { "git", "--no-pager", "diff", "HEAD", "--", path }
   else
      cmd = { "git", "--no-pager", "diff", "--no-index", "--", "/dev/null", path }
   end

   local obj = vim.system(cmd, { text = true }):wait()
   local stdout = obj.stdout or ""

   if stdout ~= "" then
      return vim.split(stdout, "\n", { plain = true })
   end

   -- Manual fallback for untracked single files
   if vim.fn.filereadable(path) == 1 then
      local file_content = vim.fn.readfile(path)
      local diff_lines = { "@@ -0,0 +1," .. #file_content .. " @@" }
      for _, line in ipairs(file_content) do
         table.insert(diff_lines, "+" .. line)
      end
      return diff_lines
   end

   return { "[No changes for " .. path .. "]" }
end

function M.get_diff_for_target(path)
   return get_diff_for_target(path)
end

function M.fetch_diff_async(path, is_dir)
   if not path or path == "" then
      return
   end
   local target_path = path

   vim.system({ "git", "ls-files", "--error-unmatch", target_path }, { text = true }, function(check_obj)
      local is_tracked = (check_obj.code == 0)
      local cmd

      if is_tracked then
         cmd = { "git", "--no-pager", "diff", "--color=never", "HEAD", "--", target_path }
      else
         cmd = { "git", "--no-pager", "diff", "--color=never", "--no-index", "--", "/dev/null", target_path }
      end

      vim.system(cmd, { text = true }, function(obj)
         vim.schedule(function()
            local stdout = obj.stdout or ""
            local lines = {}

            if stdout ~= "" then
               lines = vim.split(stdout, "\n", { plain = true })
            elseif not is_tracked and vim.fn.filereadable(target_path) == 1 then
               local file_content = vim.fn.readfile(target_path)
               lines = { "@@ -0,0 +1," .. #file_content .. " @@" }
               for _, line in ipairs(file_content) do
                  table.insert(lines, "+" .. line)
               end
            end

            local Ui = require("gitcompanion.state").Ui or _G.Ui
            if Ui then
               Ui.diff_cache = Ui.diff_cache or {}
               Ui.diff_cache[target_path] = #lines > 0 and lines or { "[No changes]" }
            end

            local ok, layout = pcall(require, "gitcompanion.ui.layout")
            if ok and type(layout.render_diff) == "function" then
               layout.render_diff()
            end
         end)
      end)
   end)
end

function M.fetch_stash_diff_async(stash_ref)
   if not stash_ref or stash_ref == "" then
      return
   end
   local target_ref = stash_ref

   vim.system({ "git", "--no-pager", "stash", "show", "-p", target_ref }, { text = true }, function(obj)
      vim.schedule(function()
         local Ui = require("gitcompanion.state").Ui or _G.Ui
         if obj.code == 0 and obj.stdout then
            local lines = vim.split(obj.stdout, "\n", { plain = true })
            if Ui then
               Ui.diff_cache = Ui.diff_cache or {}
               Ui.diff_cache[target_ref] = #lines > 0 and lines or { "[No changes in stash]" }
            end
         else
            if Ui then
               Ui.diff_cache = Ui.diff_cache or {}
               Ui.diff_cache[target_ref] = { "[Error fetching stash diff for " .. target_ref .. "]" }
            end
         end

         local ok, layout = pcall(require, "gitcompanion.ui.layout")
         if ok and type(layout.render_diff) == "function" then
            layout.render_diff()
         end
      end)
   end)
end

function M.fetch_commit_diff_async(hash)
   if not hash or hash == "" then
      return
   end
   local target_hash = hash

   local cmd = { "git", "--no-pager", "show", "-m", "--stat", "-p", target_hash }

   vim.system(cmd, { text = true }, function(obj)
      vim.schedule(function()
         local Ui = require("gitcompanion.state").Ui or _G.Ui
         if obj.code == 0 and obj.stdout and obj.stdout ~= "" then
            local lines = vim.split(obj.stdout, "\n", { plain = true })
            if lines[#lines] == "" then
               table.remove(lines)
            end

            if Ui then
               Ui.diff_cache = Ui.diff_cache or {}
               Ui.diff_cache[target_hash] = #lines > 0 and lines or { "[No diff output]" }
            end
         else
            if Ui then
               Ui.diff_cache = Ui.diff_cache or {}
               Ui.diff_cache[target_hash] = { "[Error fetching commit diff for " .. target_hash .. "]" }
            end
         end

         local ok, layout = pcall(require, "gitcompanion.ui.layout")
         if ok and type(layout.render_diff) == "function" then
            layout.render_diff()
         end
      end)
   end)
end

function M.file_differs_from_disk(bufnr)
   bufnr = bufnr or vim.api.nvim_get_current_buf()
   local path = vim.api.nvim_buf_get_name(bufnr)
   if path == "" or vim.fn.filereadable(path) == 0 then
      return false
   end

   local ok, disk = pcall(vim.fn.readfile, path)
   if not ok then
      return false
   end

   local buf = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

   if #disk ~= #buf then
      return true
   end

   for i = 1, #disk do
      if disk[i] ~= buf[i] then
         return true
      end
   end

   return false
end

return M
