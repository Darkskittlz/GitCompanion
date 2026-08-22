local M = {}

function M.attach(buf, state)
   if not buf or not vim.api.nvim_buf_is_valid(buf) then
      return
   end

   local Ui = state.Ui
   local map = function(mode, key, fn, opts)
      opts = opts or {}
      opts.buffer = buf
      opts.silent = opts.silent ~= false
      vim.keymap.set(mode, key, fn, opts)
   end

   -- Example file keymaps
   map("n", "<CR>", function()
      -- toggle tree node or stage file logic
      if state.toggle_tree_node then
         state.toggle_tree_node()
      end
   end)
end

return M
