-- lua/gitcompanion/keymaps/stashes.lua
local M = {}

local function debug_log(msg)
   vim.schedule(function()
      vim.notify("[GitCompanion Stashes Debug] " .. msg, vim.log.levels.DEBUG)
   end)
end

function M.attach(buf, state)
   -- Resolve state module directly to guarantee fresh references
   local state_mod = require("gitcompanion.state")
   state = vim.tbl_extend("keep", state or {}, state_mod)

   local Ui = state.Ui or state
   local left_buf = Ui.left_buf

   if not left_buf or not vim.api.nvim_buf_is_valid(left_buf) then
      debug_log("Attach skipped: Invalid left_buf (" .. tostring(left_buf) .. ")")
      return
   end

   debug_log("Attaching stash keymaps to left_buf: " .. tostring(left_buf))
   local opts = { buffer = left_buf, noremap = true, silent = true }

   -- -------------------------------------------------------------------------
   -- Helper: Get Stash Identifier (e.g., stash@{0})
   -- -------------------------------------------------------------------------
   local function get_selected_stash()
      debug_log(
         string.format(
            "get_selected_stash called | Mode: %s | Index: %s",
            tostring(Ui.mode),
            tostring(Ui.selected_index)
         )
      )

      if Ui.mode ~= "stashes" then
         debug_log("get_selected_stash cancelled: Not in 'stashes' mode")
         return nil
      end

      local stash_line = Ui.stashes and Ui.stashes[Ui.selected_index]
      debug_log("Raw stash line at index: " .. tostring(stash_line))

      if not stash_line or stash_line == "" then
         debug_log("No valid stash string found at index " .. tostring(Ui.selected_index))
         return nil
      end

      -- Extract stash reference (e.g., "stash@{0}")
      local stash_ref = stash_line:match("^(stash@{%d+})")
      debug_log("Parsed stash reference: " .. tostring(stash_ref))
      return stash_ref
   end

   -- -------------------------------------------------------------------------
   -- Helper: Refresh Stash Data and UI
   -- -------------------------------------------------------------------------
   local function reload_stashes()
      debug_log("Scheduling deferred stash reload in 20ms...")
      vim.defer_fn(function()
         debug_log("Deferred stash reload timer fired")
         if type(state.reload_stashes) == "function" then
            debug_log("Calling state.reload_stashes()")
            state.reload_stashes(function()
               if Ui.selected_index > #(Ui.stashes or {}) then
                  Ui.selected_index = math.max(1, #(Ui.stashes or {}))
                  debug_log("Adjusted selected_index to: " .. tostring(Ui.selected_index))
               end
            end)
         else
            debug_log("Fallback: Executing synchronous git stash list")
            Ui.stashes = vim.fn.systemlist("git stash list")
            if Ui.selected_index > #Ui.stashes then
               Ui.selected_index = math.max(1, #Ui.stashes)
            end
            if type(state.refresh_ui) == "function" then
               debug_log("Calling state.refresh_ui()")
               state.refresh_ui()
            end
         end
      end, 20)
   end

   -- -------------------------------------------------------------------------
   -- 'a' - Apply Stash
   -- -------------------------------------------------------------------------
   vim.keymap.set("n", "a", function()
      debug_log("'a' pressed: Attempting Apply Stash")
      local stash = get_selected_stash()
      if not stash then
         vim.notify("[GitCompanion] No stash selected to apply", vim.log.levels.WARN)
         return
      end

      local cmd = string.format("git stash apply %s", vim.fn.shellescape(stash))
      debug_log("Executing cmd: " .. cmd)
      local out = vim.fn.system(cmd)
      local err = vim.v.shell_error

      debug_log(string.format("git stash apply output: '%s' | exit_code: %d", vim.trim(out or ""), err))

      if err == 0 then
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
      debug_log("'p' pressed: Attempting Pop Stash")
      local stash = get_selected_stash()
      if not stash then
         vim.notify("[GitCompanion] No stash selected to pop", vim.log.levels.WARN)
         return
      end

      local cmd = string.format("git stash pop %s", vim.fn.shellescape(stash))
      debug_log("Executing cmd: " .. cmd)
      local out = vim.fn.system(cmd)
      local err = vim.v.shell_error

      debug_log(string.format("git stash pop output: '%s' | exit_code: %d", vim.trim(out or ""), err))

      if err == 0 then
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
      debug_log("'d' pressed: Attempting Drop Stash")
      local stash = get_selected_stash()
      if not stash then
         vim.notify("[GitCompanion] No stash selected to drop", vim.log.levels.WARN)
         return
      end

      vim.ui.input({
         prompt = "Type 'yes' to drop " .. stash .. ": ",
      }, function(confirm)
         if confirm ~= "yes" then
            debug_log("Drop stash cancelled by user")
            return
         end

         local cmd = string.format("git stash drop %s", vim.fn.shellescape(stash))
         debug_log("Executing cmd: " .. cmd)
         local out = vim.fn.system(cmd)
         local err = vim.v.shell_error

         debug_log(string.format("git stash drop output: '%s' | exit_code: %d", vim.trim(out or ""), err))

         if err == 0 then
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
      debug_log("'y' pressed: Attempting Yank Stash")
      local stash = get_selected_stash()
      if not stash then
         vim.notify("[GitCompanion] No stash selected to yank", vim.log.levels.WARN)
         return
      end

      vim.fn.setreg('"', stash)
      vim.fn.setreg("+", stash)
      debug_log("Yanked stash reference to registers: " .. stash)

      if state.show_centered_message then
         state.show_centered_message("Yanked: " .. stash, "📋")
      end
   end, vim.tbl_extend("force", opts, { desc = "Yank stash reference" }))
end

return M
