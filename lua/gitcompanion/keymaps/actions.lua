-- lua/gitcompanion/keymaps/actions.lua
local M = {}

function M.attach(buf, state)
   local Ui = state.Ui or state

   for _, buf in ipairs({ Ui.left_buf, Ui.right_buf, Ui.diff_buf }) do
      if buf and vim.api.nvim_buf_is_valid(buf) then
         vim.keymap.set("n", "<Space>", function()
            local win = vim.api.nvim_get_current_win()
            if win ~= Ui.left_win then
               return
            end

            if Ui.mode == "files" then
               if type(state.stage_unstage_selected) == "function" then
                  state.stage_unstage_selected()
               end
            elseif Ui.mode == "branches" then
               if type(state.checkout_branch) == "function" then
                  state.checkout_branch()
               end
            elseif Ui.mode == "stashes" then
               local stash = Ui.stashes and Ui.stashes[Ui.selected_index]
               if stash then
                  local ref = stash:match("(stash@{%d+})")
                  if ref then
                     local ok = vim.fn.confirm("Pop " .. ref .. "?", "Yes\nNo", 2)
                     if ok == 1 then
                        local out = vim.fn.system("git stash pop " .. vim.fn.shellescape(ref))
                        if vim.v.shell_error == 0 then
                           if state.show_centered_message then
                              state.show_centered_message("Successfully popped " .. ref, "✅")
                           end
                        else
                           if state.show_centered_message then
                              state.show_centered_message("Merge conflict or error popping stash", "⚠️")
                           end
                        end

                        if type(state.load_stashes) == "function" then
                           state.load_stashes()
                        end
                        Ui.selected_index = math.max(1, (Ui.selected_index or 1) - 1)
                        if type(state.refresh_ui) == "function" then
                           state.refresh_ui()
                        end
                     end
                  end
               end
            end
         end, { buffer = buf, noremap = true, silent = true, desc = "Toggle stage/checkout/pop stash" })
      end
   end
end

return M
