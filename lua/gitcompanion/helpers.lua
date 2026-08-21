-- lua/gitcompanion/helpers.lua
local M = {}

--- Extracts all file paths recursively under a given directory node
---@param node table
---@return table
function M.get_all_child_paths(node)
   local paths = {}
   if not node then
      return paths
   end

   local function traverse(n)
      if not n.is_dir and n.path then
         table.insert(paths, n.path)
      elseif n.children then
         for _, child in ipairs(n.children) do
            traverse(child)
         end
      end
   end

   traverse(node)
   return paths
end

--- Generates git diff output for an array of paths
---@param paths table
---@return table
function M.get_diff_for_paths(paths)
   if not paths or #paths == 0 then
      return { "[No files in directory]" }
   end
   local escaped_paths = {}
   for _, p in ipairs(paths) do
      table.insert(escaped_paths, vim.fn.shellescape(p))
   end
   local cmd = "git --no-pager diff -- " .. table.concat(escaped_paths, " ")
   return vim.fn.systemlist(cmd)
end

--- Generates git diff output for a single target path
---@param target_path string
---@return table
function M.get_diff_for_target(target_path)
   if not target_path or target_path == "" then
      return { "[No file selected]" }
   end
   local cmd = "git --no-pager diff -- " .. vim.fn.shellescape(target_path)
   return vim.fn.systemlist(cmd)
end

--- Strips branch decorations like '*' or leading spaces
---@param branch string
---@return string
function M.clean_branch_name(branch)
   if not branch then
      return ""
   end
   return branch:gsub("^%*%s*", ""):gsub("%s+", "")
end

return M
