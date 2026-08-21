-- lua/gitcompanion/keymaps/delete.lua
local M = {}

function M.attach(buf, state)
   local Ui = state.Ui or state

   for _, buf in ipairs({ Ui.left_buf, Ui.right_buf, Ui.diff_buf }) do
      if buf and vim.api.nvim_buf_is_valid(buf) then
         vim.keymap.set("n", "d", function()
            local win = vim.api.nvim_get_current_win()

            -- Left Navigation Pane Context
            if win == Ui.left_win then
               if Ui.mode == "files" then
                  if type(state.discard_changes_selected) == "function" then
                     state.discard_changes_selected()
                  end
               elseif Ui.mode == "stashes" then
                  local stash = Ui.stashes and Ui.stashes[Ui.selected_index]
                  if stash then
                     local ref = stash:match("(stash@{%d+})")
                     if ref then
                        local ok = vim.fn.confirm("Drop " .. ref .. "?", "Yes\nNo", 2)
                        if ok == 1 then
                           vim.fn.system("git stash drop " .. vim.fn.shellescape(ref))
                           if type(state.load_stashes) == "function" then
                              state.load_stashes()
                           end
                           Ui.selected_index = math.max(1, (Ui.selected_index or 1) - 1)
                           if type(state.refresh_ui) == "function" then
                              state.refresh_ui()
                           end
                           if state.show_centered_message then
                              state.show_centered_message("Dropped " .. ref, "🗑️")
                           end
                        end
                     end
                  end
               elseif Ui.mode == "branches" then
                  if type(state.delete_branch) == "function" then
                     state.delete_branch()
                  end
               end

               -- Right Commit Log Window Context
            elseif win == Ui.right_win then
               local cursor = vim.api.nvim_win_get_cursor(Ui.right_win)
               local line = vim.api.nvim_buf_get_lines(Ui.right_buf, cursor[1] - 1, cursor[1], false)[1]
               local hash = line and line:match("([0-9a-f]+)")

               if hash then
                  local confirm = vim.fn.confirm("Revert commit " .. hash:sub(1, 7) .. "?", "Yes\nNo", 2)
                  if confirm == 1 then
                     local out = vim.fn.system("git revert --no-edit " .. vim.fn.shellescape(hash))
                     if vim.v.shell_error == 0 then
                        if state.show_centered_message then
                           state.show_centered_message("Reverted " .. hash:sub(1, 7), "🔄")
                        end
                        if type(state.refresh_ui) == "function" then
                           state.refresh_ui()
                        end
                     else
                        vim.notify("Failed to revert commit: " .. out, vim.log.levels.ERROR)
                     end
                  end
               end
            end
         end, {
            buffer = buf,
            noremap = true,
            silent = true,
            desc = "Discard, drop stash, delete branch, or revert commit",
         })
      end
   end
end

return M
