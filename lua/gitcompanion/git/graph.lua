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
      [[git --no-pager log --graph --date=format:'%%m/%%d/%%y' --pretty=format:'%s' %s]],
      GRAPH_FORMAT,
      branch
   )
   local lines = vim.fn.systemlist(cmd)
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
         if obj.code == 0 and obj.stdout then
            local lines = vim.split(obj.stdout, "\n", { trimempty = true })

            Ui.commit_graph_cache = Ui.commit_graph_cache or {}
            Ui.commit_graph_cache[branch] = #lines > 0 and lines or { "[No commits]" }

            if type(render_right_fn) == "function" then
               render_right_fn()
            end
         end
      end)
   end)
end

return M
