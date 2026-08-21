-- lua/gitcompanion/keymaps/global.lua

local actions = require("gitcompanion.keymaps.actions")
local branches = require("gitcompanion.keymaps.branches")
local commits = require("gitcompanion.keymaps.commits")
local delete = require("gitcompanion.keymaps.delete")
local files = require("gitcompanion.keymaps.files")
local stashes = require("gitcompanion.keymaps.stashes")

local M = {}

local function debug_log(msg)
	vim.schedule(function()
		vim.notify("[GitCompanion Keymaps] " .. msg, vim.log.levels.DEBUG)
	end)
end

--- Attach global navigation, help, stash, and exit keymaps to the target buffer.
-- @param buf number: Buffer handle to attach maps to
-- @param state table: Plugin state containing UI methods (toggle_mode, refresh_ui, etc.)
function M.attach(buf, state)
	if not buf or not vim.api.nvim_buf_is_valid(buf) then
		debug_log("Failed to attach keymaps: Invalid buffer ID " .. tostring(buf))
		return
	end

	-- -------------------------------------------------------------------------
	-- Attach Mode-Specific Keymaps
	-- -------------------------------------------------------------------------
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

	-- Skip attachment if keymaps are already bound to this buffer
	if vim.b[buf].gitcompanion_global_keymaps then
		return
	end

	debug_log("Attaching global keymaps to buffer: " .. tostring(buf))

	-- Mark buffer as attached
	vim.b[buf].gitcompanion_global_keymaps = true

	local opts = function(desc)
		return { buffer = buf, noremap = true, silent = true, desc = desc }
	end

	-- -------------------------------------------------------------------------
	-- Close Plugin UI
	-- -------------------------------------------------------------------------
	vim.keymap.set("n", "q", function()
		debug_log("Action triggered: Close UI")
		if type(state.close_ui) == "function" then
			state.close_ui()
		end
		if type(state.reload_file_buffer) == "function" then
			state.reload_file_buffer()
		end
	end, opts("Close Git Companion UI"))

	-- -------------------------------------------------------------------------
	-- Navigation: Previous Mode
	-- -------------------------------------------------------------------------
	vim.keymap.set("n", "H", function()
		debug_log("Action triggered: Prev Mode (H)")
		if type(state.toggle_mode) == "function" then
			state.toggle_mode("prev")
		else
			debug_log("Error: state.toggle_mode is not a function")
		end
	end, opts("Previous view mode"))

	-- -------------------------------------------------------------------------
	-- Navigation: Next Mode
	-- -------------------------------------------------------------------------
	vim.keymap.set("n", "L", function()
		debug_log("Action triggered: Next Mode (L)")
		if type(state.toggle_mode) == "function" then
			state.toggle_mode("next")
		else
			debug_log("Error: state.toggle_mode is not a function")
		end
	end, opts("Next view mode"))

	-- -------------------------------------------------------------------------
	-- Open Help Modal
	-- -------------------------------------------------------------------------
	vim.keymap.set("n", "?", function()
		debug_log("Action triggered: Show Help (?)")
		if type(state.show_help) == "function" then
			state.show_help()
		end
	end, opts("Show keybindings help"))

	-- -------------------------------------------------------------------------
	-- Create New Stash (Global)
	-- -------------------------------------------------------------------------
	vim.keymap.set("n", "s", function()
		debug_log("Action triggered: Create Stash (s)")
		vim.ui.input({ prompt = "Stash Message (leave blank for WIP): " }, function(input)
			if input == nil then
				debug_log("Stash creation cancelled")
				return
			end

			local msg = input == "" and "WIP" or input
			debug_log("Executing git stash push with msg: " .. msg)
			vim.fn.system("git stash push -m " .. vim.fn.shellescape(msg))

			-- Update UI State
			if state.Ui then
				state.Ui.mode = "stashes"
				state.Ui.selected_index = 1
			end

			if type(state.load_stashes) == "function" then
				state.load_stashes()
			end
			if type(state.update_window_layout) == "function" then
				state.update_window_layout()
			end
			if type(state.refresh_ui) == "function" then
				state.refresh_ui()
			end
			if type(state.focus_left) == "function" then
				state.focus_left()
			end
			if type(state.show_centered_message) == "function" then
				state.show_centered_message("Stash created: " .. msg, "📦")
			end
		end)
	end, opts("Create new stash"))
end

return M
