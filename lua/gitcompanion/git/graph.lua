local M = {}
local State = require("gitcompanion.state")
local pipes = require("gitcompanion.git.pipes")

local render_right_fn

function M.setup_dependencies(opts)
	opts = opts or {}
	render_right_fn = opts.render_right
end

function M.convert_graph(line)
	return pipes.process_line(line)
end

-- Adjust format to place columns cleanly after the graph area
local GRAPH_FORMAT = "%h  %ad  %an  %s"

function M.git_graph(branch)
	branch = branch or "HEAD"
	local cmd = string.format(
		[[git --no-pager log --graph --date=format:'%%m/%%d/%%y' --pretty=format:'%s' %s]],
		GRAPH_FORMAT,
		branch
	)
	local raw_output = vim.fn.system(cmd)
	if vim.v.shell_error ~= 0 then
		return { "[No commits]" }
	end
	return pipes.transform_output(raw_output)
end

function M.fetch_git_graph_async(branch)
	local Ui = State.Ui
	branch = branch or "HEAD"

	vim.system({
		"git",
		"--no-pager",
		"log",
		"--graph",
		"--date=format:%m/%d/%y",
		"--pretty=format:" .. GRAPH_FORMAT,
		branch,
	}, { text = true }, function(obj)
		vim.schedule(function()
			-- DEBUG: Check raw exit code and output length
			vim.notify(
				string.format("[Graph Debug] code: %s, stdout len: %s", obj.code, obj.stdout and #obj.stdout or 0),
				vim.log.levels.INFO
			)

			if obj.code == 0 and obj.stdout then
				local lines = pipes.transform_output(obj.stdout)

				-- DEBUG: Print first converted line
				if #lines > 0 then
					vim.notify("[Graph Debug] Line 1: " .. lines[1], vim.log.levels.INFO)
				end

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
