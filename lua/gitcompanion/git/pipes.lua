local M = {}

M.graph_chars = {
   ["*"] = "○",
   ["|"] = "│",
   ["\\"] = "╮",
   ["/"] = "╭",
   ["_"] = "─",
   ["--"] = "──",
   ["-"] = "─",
}

--- Processes only the leading graph portion of a git log line
function M.process_line(line)
   if type(line) ~= "string" then
      return line
   end

   -- Strip trailing carriage returns
   line = line:gsub("\r$", "")

   -- Find where the 7-character commit hash begins so we only modify the graph area
   local hash_start = line:find("%x%x%x%x%x%x%x+")
   if not hash_start then
      return line
   end

   local graph_part = line:sub(1, hash_start - 1)
   local rest_part = line:sub(hash_start)

   -- Apply graph character substitutions only to the graph prefix
   graph_part = graph_part:gsub("%-%-", "──")
   graph_part = graph_part:gsub("%*", "○")
   graph_part = graph_part:gsub("|", "│")
   graph_part = graph_part:gsub("\\", "╮")
   graph_part = graph_part:gsub("/", "╭")
   graph_part = graph_part:gsub("_", "─")
   graph_part = graph_part:gsub("%-", "─")

   return graph_part .. rest_part
end

function M.transform_output(raw_output)
   if type(raw_output) == "string" then
      raw_output = vim.split(raw_output, "\n", { trimempty = true })
   end

   local processed = {}
   for _, line in ipairs(raw_output) do
      table.insert(processed, M.process_line(line))
   end
   return processed
end

return M
