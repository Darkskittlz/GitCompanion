local M = {}

-- Translate raw git ASCII graph characters into smooth box-drawing unicode characters
local function smooth_graph(graph_str)
	-- Replace standard straight connectors and nodes
	graph_str = graph_str:gsub("%*", "○")
	graph_str = graph_str:gsub("%|", "│")
	graph_str = graph_str:gsub("%_", "─")
	graph_str = graph_str:gsub("%-", "─")

	-- Replace directional slashes with smooth corners based on surrounding context
	-- Merge / branch curve translations
	graph_str = graph_str:gsub("/_", "╭─")
	graph_str = graph_str:gsub("\\_", "╰─")
	graph_str = graph_str:gsub("/%s", "╭ ")
	graph_str = graph_str:gsub("\\%s", "╰ ")

	-- General slash cleanups to smooth out diagonals into curved arcs
	graph_str = graph_str:gsub("/", "╭")
	graph_str = graph_str:gsub("\\", "╮")

	return graph_str
end

function M.process_line(line)
	-- Match pattern: captures leading graph symbols/spaces, hash, date, author, and message
	local graph_prefix, hash, date, author, msg =
		line:match("^(%s*[%*\\/|_%.%-%+%:%w%s]*)(%x%x%x%x%x%x%x+)%s+(%S+)%s+(%S+)%s+(.*)$")

	if not hash then
		-- If it's a pure graph line (no commit hash on this row), smooth it directly
		return smooth_graph(line)
	end

	-- Smooth the graph prefix
	graph_prefix = smooth_graph(graph_prefix)
	graph_prefix = graph_prefix:gsub("%s+$", "")
	if graph_prefix == "" then
		graph_prefix = " "
	end

	-- Reorder into: Hash | Date | Author | Smoothed Graph | Message
	return string.format("%s  %s  %s  %s  %s", hash, date, author, graph_prefix, msg)
end

function M.transform_output(raw_output)
	local lines = {}
	for line in raw_output:gmatch("[^\r\n]+") do
		table.insert(lines, M.process_line(line))
	end
	return lines
end

return M
