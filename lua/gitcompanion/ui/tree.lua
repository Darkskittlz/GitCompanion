local M = {}

function M.format_node_text(node, indent_level)
   indent_level = indent_level or 0
   local indent = string.rep("  ", indent_level)
   if node.is_dir then
      local icon = node.expanded and "📂 " or "📁 "
      return indent .. icon .. node.name .. "/"
   else
      local icon = node.staged and "✓ " or "• "
      return indent .. icon .. node.name
   end
end

function M.build_tree_from_files(files)
   local root = { name = "", is_dir = true, children = {}, expanded = true }

   for _, item in ipairs(files or {}) do
      local raw_path = item.value or item.path or item
      if type(raw_path) == "string" then
         local path = raw_path:gsub("/+$", "")

         local parts = {}
         for part in path:gmatch("[^/]+") do
            table.insert(parts, part)
         end

         local current = root
         local current_path = ""

         for i, part in ipairs(parts) do
            current_path = (current_path == "") and part or (current_path .. "/" .. part)

            if i == #parts then
               if not (current.children[part] and current.children[part].is_dir) then
                  local is_dir = raw_path:sub(-1) == "/"
                  current.children[part] = {
                     name = part,
                     is_dir = is_dir,
                     children = is_dir and {} or nil,
                     expanded = is_dir,
                     path = path,
                     old_path = item.old_path,
                     status = item.status or "M",
                     staged = item.staged or false,
                  }
               end
            else
               if not current.children[part] then
                  current.children[part] = {
                     name = part,
                     path = current_path,
                     is_dir = true,
                     children = {},
                     expanded = true,
                  }
               end
               current = current.children[part]
            end
         end
      end
   end
   return root
end

function M.flatten_tree(node, depth, result)
   result = result or {}
   depth = depth or 0

   -- FIX 1: Only insert node text if it isn't the invisible root node
   if node.name ~= "" then
      table.insert(result, {
         node = node,
         depth = depth,
         path = node.path,
         is_dir = node.is_dir,
         text = M.format_node_text(node, depth - 1),
      })
   end

   if node.is_dir and node.expanded and node.children then
      local keys = {}
      for k in pairs(node.children) do
         table.insert(keys, k)
      end
      table.sort(keys)

      for _, k in ipairs(keys) do
         M.flatten_tree(node.children[k], depth + 1, result)
      end
   end

   return result
end

function M.build_tree()
   local State = require("gitcompanion.state")
   local ui = State.Ui
   if not ui then
      return
   end

   if ui.changed_files and #ui.changed_files > 0 then
      ui.tree_root = M.build_tree_from_files(ui.changed_files)
      ui.visible_tree_lines = M.flatten_tree(ui.tree_root)
      ui.flat_nodes = ui.visible_tree_lines
   else
      ui.tree_root = { name = "", is_dir = true, children = {}, expanded = true }
      ui.visible_tree_lines = {}
      ui.flat_nodes = {}
   end
end

function M.toggle_tree_node()
   local State = require("gitcompanion.state")
   local ui = State.Ui
   if not ui or ui.mode ~= "files" or not ui.left_win or not vim.api.nvim_win_is_valid(ui.left_win) then
      return
   end

   local cursor = vim.api.nvim_win_get_cursor(ui.left_win)
   local line_idx = cursor[1]

   local item = ui.visible_tree_lines and ui.visible_tree_lines[line_idx]
   local node = item and item.node

   if not node or not node.is_dir then
      return
   end

   node.expanded = not node.expanded

   ui.visible_tree_lines = M.flatten_tree(ui.tree_root)
   ui.flat_nodes = ui.visible_tree_lines
   M.render_files_tree()

   local max_line = #ui.visible_tree_lines
   local safe_idx = math.min(math.max(1, line_idx), max_line)
   if safe_idx > 0 then
      pcall(vim.api.nvim_win_set_cursor, ui.left_win, { safe_idx, 0 })
   end

   local layout_ok, layout = pcall(require, "gitcompanion.ui.layout")
   local render_fn = (layout_ok and layout.render_diff)
       or rawget(_G, "render_diff")
       or (type(ui.render_diff) == "function" and ui.render_diff or nil)

   if type(render_fn) == "function" then
      render_fn()
   end
end

function M.render_files_tree()
   local State = require("gitcompanion.state")
   local ui = State.Ui
   if not ui or not ui.left_buf or not vim.api.nvim_buf_is_valid(ui.left_buf) then
      return
   end

   if not ui.tree_root or ui._last_rendered_files ~= ui.changed_files then
      M.build_tree()
      ui._last_rendered_files = ui.changed_files
   end

   local buf = ui.left_buf
   local ns = vim.api.nvim_create_namespace("gitcompanion_tree_hl")

   -- FIX 2: Safely handle modifiable state in a pcall block
   vim.bo[buf].modifiable = true

   local ok, err = pcall(function()
      vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)

      local lines = {}
      local visible_items = ui.visible_tree_lines or {}

      for _, item in ipairs(visible_items) do
         table.insert(lines, item.text or item.name or "")
      end

      if #lines == 0 then
         if ui.changed_files and #ui.changed_files > 0 then
            for _, file in ipairs(ui.changed_files) do
               local path = type(file) == "table" and (file.path or file[1]) or file
               table.insert(lines, "  " .. tostring(path))
            end
         else
            lines = { "  (No changed files)" }
         end
      end

      vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

      for line_idx, item in ipairs(visible_items) do
         local node = item.node
         if node and not node.is_dir then
            local hl_group = node.staged and "GitSignsAdd" or "GitSignsChange"
            if vim.fn.hlexists(hl_group) == 0 then
               hl_group = node.staged and "Added" or "Changed"
            end
            vim.api.nvim_buf_add_highlight(buf, ns, hl_group, line_idx - 1, 0, -1)
         elseif node and node.is_dir then
            vim.api.nvim_buf_add_highlight(buf, ns, "Directory", line_idx - 1, 0, -1)
         end
      end
   end)

   -- Always lock buffer back down
   vim.bo[buf].modifiable = false
   vim.bo[buf].modified = false

   if not ok then
      vim.notify("[GitCompanion Tree Render Error] " .. tostring(err), vim.log.levels.ERROR)
   end
end

return M
