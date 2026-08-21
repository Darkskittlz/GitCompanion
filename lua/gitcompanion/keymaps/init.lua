local M = {}

local global_km = require("gitcompanion.keymaps.global")
local branches_km = require("gitcompanion.keymaps.branches")
local commits_km = require("gitcompanion.keymaps.commits")
local files_km = require("gitcompanion.keymaps.files")
local stashes_km = require("gitcompanion.keymaps.stashes")

function M.attach_all(Ui)
   -- Attach global shortcuts across all active buffers
   for _, buf in ipairs({ Ui.left_buf, Ui.right_buf, Ui.diff_buf }) do
      if buf and vim.api.nvim_buf_is_valid(buf) then
         global_km.attach(buf, Ui)
      end
   end

   -- Contextual keymaps delegated based on current active view/window
   branches_km.attach(Ui)
   commits_km.attach(Ui)
   files_km.attach(Ui)
   stashes_km.attach(Ui)
end

return M
