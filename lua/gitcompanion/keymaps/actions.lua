-- lua/gitcompanion/keymaps/actions.lua
local git_actions = require("gitcompanion.git.actions")

local M = {}

function M.attach(buf, state)
   local Ui = state.Ui or state

   local function debug_log(msg)
      vim.schedule(function()
         vim.notify("[GitCompanion Keymaps] " .. msg, vim.log.levels.DEBUG)
      end)
   end

   for _, b in ipairs({ Ui.left_buf, Ui.right_buf, Ui.diff_buf }) do
      if b and vim.api.nvim_buf_is_valid(b) then
         vim.notify(
            string.format("[Keymap] Executing Space | Mode: %s | Index: %s", Ui.mode, tostring(Ui.selected_index)),
            vim.log.levels.DEBUG
         )
         vim.keymap.set("n", "<Space>", function()
            local current_win = vim.api.nvim_get_current_win()
            local expected_win = Ui and Ui.left_win or nil

            debug_log(
               string.format(
                  "Space pressed | Current Win: %s | Left Win: %s | Mode: %s",
                  tostring(current_win),
                  tostring(expected_win),
                  tostring(Ui and Ui.mode)
               )
            )

            -- Check window match
            if current_win ~= expected_win then
               debug_log("Space keymap aborted: Not in Ui.left_win")
               return
            end

            if Ui.mode == "files" then
               -- Call the function directly from the imported git_actions module
               if type(git_actions.stage_unstage_selected) == "function" then
                  vim.notify("[Keymap] Calling git_actions.stage_unstage_selected...", vim.log.levels.DEBUG)
                  git_actions.stage_unstage_selected()
               else
                  vim.notify(
                     "[Keymap ERROR] git_actions.stage_unstage_selected is NOT a function!",
                     vim.log.levels.ERROR
                  )
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
            else
               debug_log("Space keymap unhandled mode: " .. tostring(Ui.mode))
            end
         end, { buffer = b, noremap = true, silent = true, desc = "Toggle stage/checkout/pop stash" })
      end
   end
end

return M
