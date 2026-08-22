-- lua/gitcompanion/keymaps/delete.lua
local M = {}
local git_actions = require("gitcompanion.git.actions")

function M.attach(buf, state)
   if not buf or not vim.api.nvim_buf_is_valid(buf) then
      return
   end

   local state_mod = state or _G.State or {}

   -- Helper to trigger UI refresh reliably
   local function trigger_refresh()
      vim.schedule(function()
         if type(state_mod.reload_with_fetch) == "function" then
            state_mod.reload_with_fetch()
         elseif type(state_mod.refresh_ui) == "function" then
            state_mod.refresh_ui()
         end
      end)
   end

   vim.keymap.set("n", "x", function()
      -- vim.schedule(function()
      -- 	vim.notify("[GitCompanion Keymaps] 'x' pressed in buffer: " .. tostring(buf), vim.log.levels.DEBUG)
      -- end)

      local active_ui = state_mod.Ui or _G.Ui or {}
      local current_win = vim.api.nvim_get_current_win()
      local current_buf = vim.api.nvim_get_current_buf()

      -- Check pane placement or fallback to active_ui.mode
      local is_left_pane = (current_win == active_ui.left_win)
          or (current_buf == active_ui.left_buf)
          or (current_buf == buf)

      if is_left_pane then
         local cursor_line = vim.api.nvim_win_get_cursor(0)[1]
         active_ui.selected_index = cursor_line

         if active_ui.mode == "files" then
            if type(git_actions.discard_changes_selected) == "function" then
               git_actions.discard_changes_selected()
               trigger_refresh()
            else
               -- vim.notify("[GitCompanion Error] discard_changes_selected not found", vim.log.levels.ERROR)
            end
         elseif active_ui.mode == "stashes" then
            local stash = active_ui.stashes and active_ui.stashes[active_ui.selected_index]
            if stash then
               local ref = stash:match("(stash@{%d+})")
               if ref and vim.fn.confirm("Drop " .. ref .. "?", "Yes\nNo", 2) == 1 then
                  vim.fn.system("git stash drop " .. vim.fn.shellescape(ref))
                  if type(state_mod.load_stashes) == "function" then
                     state_mod.load_stashes()
                  end
                  active_ui.selected_index = math.max(1, (active_ui.selected_index or 1) - 1)
                  trigger_refresh()
               end
            end
         elseif active_ui.mode == "branches" then
            local delete_fn = git_actions.delete_branch or state_mod.delete_branch
            if type(delete_fn) == "function" then
               -- Execute deletion (ensure reload happens after the action completes)
               delete_fn()
               trigger_refresh()
            else
               -- vim.notify("[GitCompanion Error] delete_branch function not found", vim.log.levels.ERROR)
            end
         end
      elseif (current_win == active_ui.right_win) or (current_buf == active_ui.right_buf) then
         local cursor = vim.api.nvim_win_get_cursor(0)
         local line = vim.api.nvim_buf_get_lines(active_ui.right_buf or 0, cursor[1] - 1, cursor[1], false)[1]
         local hash = line and line:match("([0-9a-f]+)")

         if hash and vim.fn.confirm("Revert commit " .. hash:sub(1, 7) .. "?", "Yes\nNo", 2) == 1 then
            local out = vim.fn.system("git revert --no-edit " .. vim.fn.shellescape(hash))
            if vim.v.shell_error == 0 then
               trigger_refresh()
            else
               -- vim.notify("Failed to revert commit: " .. out, vim.log.levels.ERROR)
            end
         end
      end
   end, {
      buffer = buf,
      noremap = true,
      silent = true,
      nowait = true,
      desc = "Discard changes, drop stash, delete branch, or revert commit",
   })
end

return M
