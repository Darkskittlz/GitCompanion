local M = {}
local State = require("gitcompanion.state")

local render_right_fn

function M.setup_dependencies(opts)
   opts = opts or {}
   render_right_fn = opts.render_right
end

function M.convert_graph(line)
   line = line:gsub("%*%-", "*-")
   line = line:gsub("|\\", "|\\")
   line = line:gsub("|/", "|/")
   return line
end

-- Shared format for both sync and async graph fetchers
local GRAPH_FORMAT = "%h %ad %<(8,trunc)%an %s"

function M.git_graph(branch)
   branch = branch or "HEAD"
   local cmd = string.format(
      [[git --no-pager log --graph --color=always --date=format:'%%m/%%d/%%y' --pretty=format:'%s' %s]],
      GRAPH_FORMAT,
      branch
   )
   vim.notify("[GitGraph Debug] Sync command: " .. cmd, vim.log.levels.DEBUG)
   local lines = vim.fn.systemlist(cmd)
   vim.notify(
      string.format("[GitGraph Debug] Sync returned lines count: %s, exit code: %s", #lines, vim.v.shell_error),
      vim.log.levels.DEBUG
   )

   if vim.v.shell_error ~= 0 then
      return { "[No commits]" }
   end
   for i, line in ipairs(lines) do
      lines[i] = M.convert_graph(line)
   end
   return lines
end

function M.fetch_git_graph_async(branch)
   local Ui = State.Ui
   branch = branch or "HEAD"

   vim.notify(
      "[GitGraph Debug] fetch_git_graph_async triggered for branch: " .. tostring(branch),
      vim.log.levels.DEBUG
   )

   vim.system({
      "git",
      "--no-pager",
      "log",
      "--graph",
      "--color=always",
      "--date=format:%m/%d/%y",
      "--pretty=format:" .. GRAPH_FORMAT,
      branch,
   }, { text = true }, function(obj)
      vim.schedule(function()
         vim.notify(
            string.format(
               "[GitGraph Debug] Async finished. Exit code: %s, stdout length: %s",
               tostring(obj.code),
               tostring(obj.stdout and #obj.stdout or 0)
            ),
            vim.log.levels.DEBUG
         )

         if obj.code == 0 and obj.stdout then
            local lines = vim.split(obj.stdout, "\n", { trimempty = true })
            vim.notify(string.format("[GitGraph Debug] Parsed async lines count: %s", #lines), vim.log.levels.DEBUG)

            Ui.commit_graph_cache = Ui.commit_graph_cache or {}
            Ui.commit_graph_cache[branch] = #lines > 0 and lines or { "[No commits]" }

            if type(render_right_fn) == "function" then
               vim.notify("[GitGraph Debug] Invoking render_right_fn...", vim.log.levels.DEBUG)
               render_right_fn()
            else
               vim.notify("[GitGraph Debug] Warning: render_right_fn is not a function!", vim.log.levels.WARN)
            end
         else
            vim.notify(
               "[GitGraph Debug] Async command failed or empty output: " .. tostring(obj.stderr),
               vim.log.levels.ERROR
            )
         end
      end)
   end)
end

return M
