local M = {}

local history = require("neovim-project.utils.history")
local manager = require("session_manager")
local path = require("neovim-project.utils.path")
local payload = require("neovim-project.payload")
local utils = require("session_manager.utils")

M.save_project_waiting = false

M.setup_autocmds = function()
  local augroup = vim.api.nvim_create_augroup("neovim-project", { clear = true })

  -- setup events for neo-tree when it's loaded
  vim.api.nvim_create_autocmd({ "FileType" }, {
    pattern = "neo-tree",
    group = augroup,
    once = true,
    callback = require("neovim-project.utils.neo-tree").setup_events_for_neotree,
  })
  -- save history to file when exit nvim
  vim.api.nvim_create_autocmd({ "VimLeavePre" }, {
    pattern = "*",
    group = augroup,
    callback = function()
      history.write_projects_to_history()
    end,
  })
  -- add project to history when open nvim in project's directory
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
  -- switch project after save previous session
  vim.api.nvim_create_autocmd({ "User" }, {
    pattern = "SessionSavePost",
    group = augroup,
    callback = function()
      M.save_project_waiting = true
    end,
  })
  -- add more state data to the session file via global variable
  vim.api.nvim_create_autocmd({ "User" }, {
    pattern = "SessionSavePre",
    group = augroup,
    callback = function()
      payload.pre_save()
    end,
  })
  -- restore saved state data from the global var in the session file
  vim.api.nvim_create_autocmd({ "User" }, {
    pattern = "SessionLoadPost",
    group = augroup,
    callback = function()
      payload.load_post()
    end,
  })
end

M.delete_session = function(dir)
  if utils.is_session and dir == path.cwd() then
    utils.is_session = false
  end
  local sessions = utils.get_sessions()
  for idx, session in ipairs(sessions) do
    if path.short_path(session.dir.filename) == dir then
      local Path = require("plenary.path")
      return Path:new(sessions[idx].filename):rm()
    end
  end
end

M.in_session = function()
  return utils.is_session
end

M.switch_after_save_session = function(dir)
  -- Switch project after saving current session
  --
  -- save current session
  -- before switch project
  M.save_project_waiting = true
  manager.save_current_session()
  -- wait for SessionSavePost autocmd or timeout 2 sec
  vim.wait(2000, function()
    return not M.switing_project
  end, 1)
  M.load_session(dir)
end

M.load_session = function(dir)
  if not dir then
    return
  end
  if path.cwd() ~= dir then
    vim.api.nvim_set_current_dir(dir)
  end

  path.dir_pretty = path.short_path(dir)
  M.start_session_here()
end

M.start_session_here = function()
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
  if path.dir_pretty ~= nil then
    history.add_session_project(path.dir_pretty)
  else
    history.add_session_project(cwd)
  end
end

M.init = function()
  M.setup_autocmds()
  history.read_projects_from_history()
end

return M
