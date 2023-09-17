local M = {}

local history = require("neovim-project.utils.history")
local manager = require("session_manager")
local path = require("neovim-project.utils.path")

M.switing_project_to = nil

M.setup_autocmds = function()
  local augroup = vim.api.nvim_create_augroup("neovim-project", { clear = true })

  vim.api.nvim_create_autocmd({ "VimLeavePre" }, {
    pattern = "*",
    group = augroup,
    callback = function()
      history.write_projects_to_history()
    end,
  })
  vim.api.nvim_create_autocmd({ "User" }, {
    pattern = "SessionLoadPost",
    group = augroup,
    once = true,
    callback = function()
      if path.dir_pretty ~= nil then
        history.add_session_project(path.dir_pretty)
      end
    end,
  })
  vim.api.nvim_create_autocmd({ "User" }, {
    pattern = "SessionSavePost",
    group = augroup,
    callback = function()
      if M.switing_project_to ~= nil then
        local dir = M.switing_project_to
        M.switing_project_to = nil
        M.load_session(dir)
      end
    end,
  })
end

M.in_session = function()
  return require("session_manager.utils").is_session
end

function M.switch_after_save_session(dir)
  -- Switch project after saving current session
  M.switing_project_to = dir
  -- save current session
  -- before switch project
  manager.save_current_session()
end

function M.load_session(dir)
  if not dir then
    return
  end
  if path.cwd() ~= dir then
    vim.api.nvim_set_current_dir(dir)
  end

  path.dir_pretty = path.short_path(dir)
  M.start_session_here()
end

function M.start_session_here()
  -- load session or create new one if not exists
  local cwd = path.cwd()
  if not cwd then
    return
  end
  local fullpath = vim.fn.expand(cwd)
  local session = require("session_manager.config").dir_to_session_filename(fullpath)
  if session:exists() then
    manager.load_current_dir_session(false)
  else
    vim.cmd("silent! %bd") -- close all buffers from previous session
    -- create empty session
    manager.save_current_session()
  end
  -- add to history
  history.add_session_project(cwd)
end

function M.init()
  M.setup_autocmds()
  history.read_projects_from_history()
end

return M
