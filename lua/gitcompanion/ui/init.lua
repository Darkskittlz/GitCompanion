local M = {}

local layout = require("gitcompanion.ui.layout")
local tree = require("gitcompanion.ui.tree")
local help = require("gitcompanion.ui.help")

-- Re-export layout & rendering helpers
M.refresh_ui = layout.refresh_ui
M.render_right = layout.render_right
M.render_diff = layout.render_diff
M.update_window_layout = layout.update_window_layout
M.get_diff_for_target = layout.get_diff_for_target
M.reload_file_buffer = layout.reload_file_buffer
M.toggle_mode = layout.toggle_mode
M.show_centered_message = layout.show_centered_message
M.init_ui = layout.init_ui

-- Re-export tree helpers
M.toggle_tree_node = tree.toggle_tree_node

-- Re-export help helpers
M.show_help = help.show_help

return M
