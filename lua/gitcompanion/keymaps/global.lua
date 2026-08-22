local actions = require("gitcompanion.keymaps.actions")
local branches = require("gitcompanion.keymaps.branches")
local commits = require("gitcompanion.keymaps.commits")
local delete = require("gitcompanion.keymaps.delete")
local files = require("gitcompanion.keymaps.files")
local stashes = require("gitcompanion.keymaps.stashes")

local M = {}

-- local function debug_log(msg)
--    vim.schedule(function()
--       vim.notify("[GitCompanion Keymaps] " .. msg, vim.log.levels.DEBUG)
--    end)
-- end

function M.attach(buf, state)
   if not buf or not vim.api.nvim_buf_is_valid(buf) then
      -- debug_log("Failed to attach keymaps: Invalid buffer ID " .. tostring(buf))
      return
   end

   local state_mod = require("gitcompanion.state")
   state = vim.tbl_extend("keep", state or {}, state_mod)

   -- Attach sub-keymaps to the passed buffer directly
   if type(actions.attach) == "function" then
      actions.attach(buf, state)
   end
   if type(branches.attach) == "function" then
      branches.attach(buf, state)
   end
   if type(commits.attach) == "function" then
      commits.attach(buf, state)
   end
   if type(delete.attach) == "function" then
      delete.attach(buf, state)
   end
   if type(files.attach) == "function" then
      files.attach(buf, state)
   end
   if type(stashes.attach) == "function" then
      stashes.attach(buf, state)
   end

   if vim.b[buf].gitcompanion_global_keymaps then
      return
   end

   -- debug_log("Attaching global keymaps to buffer: " .. tostring(buf))
   vim.b[buf].gitcompanion_global_keymaps = true

   local opts = function(desc)
      return { buffer = buf, noremap = true, silent = true, desc = desc }
   end

   -- Global Navigation Keymaps
   vim.keymap.set("n", "q", function()
      -- debug_log("Action triggered: Close UI")
      if type(state.close_ui) == "function" then
         state.close_ui()
      end
      if type(state.reload_file_buffer) == "function" then
         state.reload_file_buffer()
      end
   end, opts("Close Git Companion UI"))

   vim.keymap.set("n", "H", function()
      if type(state.toggle_mode) == "function" then
         state.toggle_mode("prev")
      end
   end, opts("Previous view mode"))

   vim.keymap.set("n", "L", function()
      if type(state.toggle_mode) == "function" then
         state.toggle_mode("next")
      end
   end, opts("Next view mode"))

   vim.keymap.set("n", "?", function()
      if type(state.show_help) == "function" then
         state.show_help()
      end
   end, opts("Show keybindings help"))

   vim.keymap.set("n", "s", function()
      -- debug_log("Action triggered: Create Stash (s)")
      vim.ui.input({ prompt = "Stash Message (leave blank for WIP): " }, function(input)
         if input == nil then
            return
         end
         local msg = input == "" and "WIP" or input
         vim.fn.system("git stash push -m " .. vim.fn.shellescape(msg))

         if state.Ui then
            state.Ui.mode = "stashes"
            state.Ui.selected_index = 1
         end

         if type(state.show_centered_message) == "function" then
            state.show_centered_message("Stash created: " .. msg, "📦")
         end

         state.reload_with_fetch()
      end)
   end, opts("Create new stash"))
end

return M
