-- lua/gitcompanion/keymaps/stashes.lua
local M = {}

function M.attach(buf, state)
   local Ui = state.Ui or state
   local left_buf = Ui.left_buf

   if not left_buf or not vim.api.nvim_buf_is_valid(left_buf) then
      return
   end

   local opts = { buffer = left_buf, noremap = true, silent = true }

   -- -------------------------------------------------------------------------
   -- Helper: Get Stash Identifier (e.g., stash@{0})
   -- -------------------------------------------------------------------------
   local function get_selected_stash()
      if Ui.mode ~= "stashes" then
         return nil
      end

      local stash_line = Ui.stashes and Ui.stashes[Ui.selected_index]
      if not stash_line or stash_line == "" then
         return nil
      end

      -- Extract stash reference (e.g., "stash@{0}")
      local stash_ref = stash_line:match("^(stash@{%d+})")
      return stash_ref
   end

   -- -------------------------------------------------------------------------
   -- Helper: Refresh Stash Data and UI
   -- -------------------------------------------------------------------------
   local function reload_stashes()
      if Ui.stashes then
         Ui.stashes = vim.fn.systemlist("git stash list")
         if Ui.selected_index > #Ui.stashes then
            Ui.selected_index = math.max(1, #Ui.stashes)
         end
      end
      if type(state.load_stashes_async) == "function" then
         state.load_stashes_async()
      end
      if state.refresh_ui then
         state.refresh_ui()
      end
   end

   -- -------------------------------------------------------------------------
   -- 'a' - Apply Stash
   -- -------------------------------------------------------------------------
   vim.keymap.set("n", "a", function()
      local stash = get_selected_stash()
      if not stash then
         return
      end

      local cmd = string.format("git stash apply %s", vim.fn.shellescape(stash))
      local out = vim.fn.system(cmd)

      if vim.v.shell_error == 0 then
         if state.show_centered_message then
            state.show_centered_message("Applied " .. stash, "📦")
         end
         reload_stashes()
      else
         vim.notify("Failed to apply stash: " .. out, vim.log.levels.ERROR)
      end
   end, vim.tbl_extend("force", opts, { desc = "Apply selected stash" }))

   -- -------------------------------------------------------------------------
   -- 'p' - Pop Stash
   -- -------------------------------------------------------------------------
   vim.keymap.set("n", "p", function()
      local stash = get_selected_stash()
      if not stash then
         return
      end

      local cmd = string.format("git stash pop %s", vim.fn.shellescape(stash))
      local out = vim.fn.system(cmd)

      if vim.v.shell_error == 0 then
         if state.show_centered_message then
            state.show_centered_message("Popped " .. stash, "💥")
         end
         reload_stashes()
      else
         vim.notify("Failed to pop stash: " .. out, vim.log.levels.ERROR)
      end
   end, vim.tbl_extend("force", opts, { desc = "Pop selected stash" }))

   -- -------------------------------------------------------------------------
   -- 'd' - Drop Stash
   -- -------------------------------------------------------------------------
   vim.keymap.set("n", "d", function()
      local stash = get_selected_stash()
      if not stash then
         return
      end

      vim.ui.input({
         prompt = "Type 'yes' to drop " .. stash .. ": ",
      }, function(confirm)
         if confirm ~= "yes" then
            return
         end

         local cmd = string.format("git stash drop %s", vim.fn.shellescape(stash))
         local out = vim.fn.system(cmd)

         if vim.v.shell_error == 0 then
            if state.show_centered_message then
               state.show_centered_message("Dropped " .. stash, "🗑️")
            end
            reload_stashes()
         else
            vim.notify("Failed to drop stash: " .. out, vim.log.levels.ERROR)
         end
      end)
   end, vim.tbl_extend("force", opts, { desc = "Drop selected stash" }))

   -- -------------------------------------------------------------------------
   -- 'y' - Yank Stash Reference
   -- -------------------------------------------------------------------------
   vim.keymap.set("n", "y", function()
      local stash = get_selected_stash()
      if not stash then
         return
      end

      vim.fn.setreg('"', stash)
      vim.fn.setreg("+", stash)
      if state.show_centered_message then
         state.show_centered_message("Yanked: " .. stash, "📋")
      end
   end, vim.tbl_extend("force", opts, { desc = "Yank stash reference" }))
end

return M
