local M = {}

local State = require("gitcompanion.state")

-- Holds external UI render callbacks to avoid circular dependencies
local render_right_fn

function M.setup_dependencies(opts)
   opts = opts or {}
   render_right_fn = opts.render_right
end

-- Convert git --graph lines (ASCII identity)
function M.convert_graph(line)
   line = line:gsub("%*%-", "*-")
   line = line:gsub("|\\", "|\\")
   line = line:gsub("|/", "|/")
   return line
end

function M.git_graph(limit, branch)
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
      lines[i] = M.convert_graph(line)
   end
   return lines
end

function M.fetch_git_graph_async(branch)
   local Ui = State.Ui
   branch = branch or "HEAD"

   -- Standard graph format: Hash | Date | Author | Message
   local format = "%h %ad %an %s"

   vim.system({
      "git",
      "--no-pager",
      "log",
      "--graph",
      "--date=format:%H:%M",
      "--pretty=format:" .. format,
      "-n",
      "40",
      branch,
   }, { text = true }, function(obj)
      vim.schedule(function()
         if obj.code == 0 and obj.stdout then
            local lines = vim.split(obj.stdout, "\n", { trimempty = true })

            -- Guard against nil cache table
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
