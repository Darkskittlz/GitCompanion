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

-- Map standard ANSI 30-37 / 90-97 foreground codes to Neovim highlight groups
local ANSI_FG_MAP = {
	[30] = "Normal",
	[31] = "DiagnosticError",
	[32] = "String",
	[33] = "Constant",
	[34] = "Function",
	[35] = "Statement",
	[36] = "Identifier",
	[37] = "Normal",
	[90] = "Comment",
	[91] = "DiagnosticError",
	[92] = "String",
	[93] = "Constant",
	[94] = "Function",
	[95] = "Statement",
	[96] = "Identifier",
	[97] = "Normal",
}

--- Parse a single ANSI-colored line into plain text and byte-indexed highlight spans.
--- @param raw_line string
--- @return string text, table[] spans ({ start_col, end_col, hl_group })
function M.parse_ansi_line(raw_line)
	local out = {}
	local spans = {}
	local byte_pos = 0
	local current_fg = nil
	local is_bold = false

	local active_start = nil
	local active_hl = nil

	local function resolve_hl()
		if current_fg and ANSI_FG_MAP[current_fg] then
			return ANSI_FG_MAP[current_fg]
		end
		if is_bold then
			return "Title"
		end
		return nil
	end

	local function flush_span()
		if active_start ~= nil and active_hl ~= nil and byte_pos > active_start then
			table.insert(spans, { active_start, byte_pos, active_hl })
		end
		active_start = nil
		active_hl = nil
	end

	local function begin_span_if_needed()
		local next_hl = resolve_hl()
		if next_hl ~= active_hl then
			flush_span()
			active_hl = next_hl
			if active_hl ~= nil then
				active_start = byte_pos
			end
		end
	end

	local i = 1
	local len = #raw_line
	while i <= len do
		-- Match ESC [ <params> m
		local esc_start, esc_end, params = raw_line:find("\27%[([0-9;]*)m", i)
		if esc_start == i then
			flush_span()
			if params == "" or params == "0" then
				current_fg = nil
				is_bold = false
			else
				for code_str in (params .. ";"):gmatch("([0-9]*);") do
					local code = tonumber(code_str) or 0
					if code == 0 then
						current_fg = nil
						is_bold = false
					elseif code == 1 then
						is_bold = true
					elseif code == 22 then
						is_bold = false
					elseif code == 39 then
						current_fg = nil
					elseif (code >= 30 and code <= 37) or (code >= 90 and code <= 97) then
						current_fg = code
					end
				end
			end
			i = esc_end + 1
		else
			local next_esc = raw_line:find("\27%[", i)
			local chunk = next_esc and raw_line:sub(i, next_esc - 1) or raw_line:sub(i)
			if #chunk > 0 then
				begin_span_if_needed()
				table.insert(out, chunk)
				byte_pos = byte_pos + #chunk
			end
			i = next_esc or (len + 1)
		end
	end

	flush_span()
	return table.concat(out), spans
end

-- Shared format for both sync and async graph fetchers
local GRAPH_FORMAT = "%h %ad %<(8,trunc)%an %s"

local function build_graph_cmd(branch)
	return {
		"git",
		"--no-pager",
		"log",
		"--graph",
		"--color=always",
		"--date=format:%m/%d/%y",
		"--pretty=format:" .. GRAPH_FORMAT,
		branch,
	}
end

local function build_styled_entries(raw_lines)
	local entries = {}
	for _, raw in ipairs(raw_lines) do
		local text, spans = M.parse_ansi_line(raw)
		text = M.convert_graph(text)
		table.insert(entries, {
			text = text,
			spans = spans,
		})
	end
	return entries
end

function M.git_graph(branch)
	branch = branch or "HEAD"
	local obj = vim.system(build_graph_cmd(branch), { text = true }):wait()
	if obj.code ~= 0 or not obj.stdout then
		return { { text = "[No commits]", spans = {} } }
	end

	local raw_lines = vim.split(obj.stdout, "\n", { trimempty = true })
	if #raw_lines == 0 then
		return { { text = "[No commits]", spans = {} } }
	end

	return build_styled_entries(raw_lines)
end

function M.fetch_git_graph_async(branch)
	local Ui = State.Ui
	branch = branch or "HEAD"

	vim.system(build_graph_cmd(branch), { text = true }, function(obj)
		vim.schedule(function()
			if not Ui then
				return
			end

			local entries = { { text = "[No commits]", spans = {} } }
			if obj.code == 0 and obj.stdout then
				local raw_lines = vim.split(obj.stdout, "\n", { trimempty = true })
				if #raw_lines > 0 then
					entries = build_styled_entries(raw_lines)
				end
			end

			Ui.commit_graph_cache = Ui.commit_graph_cache or {}
			Ui.commit_graph_cache[branch] = entries

			if type(render_right_fn) == "function" then
				render_right_fn()
			end
		end)
	end)
end

return M
