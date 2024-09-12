local M = {}

local history = require("neovim-project.utils.history")
local manager = require("session_manager")
local path = require("neovim-project.utils.path")
local payload = require("neovim-project.payload")
local utils = require("session_manager.utils")
local config = require("neovim-project.config")
local picker = require("neovim-project.picker")

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
  -- 1. Trigger FileType autocmd to attach lsp server to the active buffer
  -- 2. Restore saved state data from the global var in the session file
  vim.api.nvim_create_autocmd({ "User" }, {
    pattern = "SessionLoadPost",
    group = augroup,
    callback = function()
      if config.options.filetype_autocmd_timeout > 0 then
        vim.defer_fn(function()
          vim.api.nvim_command("silent! doautocmd FileType")
        end, config.options.filetype_autocmd_timeout)
      end
      payload.load_post()
      if path.dir_pretty == nil then
        path.dir_pretty = path.cwd()
      end
    end,
  })
  -- Exit from session when directory changed from outside
  vim.api.nvim_create_autocmd({ "DirChangedPre" }, {
    pattern = "global",
    group = augroup,
    callback = function(event)
      if path.dir_pretty == nil then
        return
      end
      if path.dir_pretty ~= path.short_path(event.file) then
        -- directory changed from outside
        history.write_projects_to_history()
        local dir = path.dir_pretty
        vim.notify("CWD Changed! Exit from session " .. dir, vim.log.levels.INFO, { title = "Neovim Project" })
        path.dir_pretty = nil
        utils.is_session = false
        -- touch session file to update mtime and auto load it on next start
        local sessions = utils.get_sessions()
        for idx, session in ipairs(sessions) do
          if path.short_path(session.dir.filename) == dir then
            local Path = require("plenary.path")
            return Path:new(sessions[idx].filename):touch()
          end
        end
      end
    end,
  })
end

local function switch_project_callback(dir)
  M.switch_project(dir)
end

function M.show_history()
  picker.create_picker({}, false, switch_project_callback, M.delete_session)
end

function M.discover_projects()
  picker.create_picker({}, true, switch_project_callback, M.delete_session)
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
  return utils.exists_in_session()
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
    path.dir_pretty = path.short_path(dir)
    vim.api.nvim_set_current_dir(dir)
  end

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

M.create_commands = function()
  -- Create user commands

  -- Open the previous session
  vim.api.nvim_create_user_command("NeovimProjectLoadRecent", function(args)
    local cnt = args.count
    if cnt < 1 then
      -- cnt is an offset from the last session in history
      if M.in_session() then
        cnt = 1 -- skip current session
      else
        cnt = 0
      end
    end
    local recent = history.get_recent_projects()
    local index = #recent - cnt
    if index < 1 then
      index = 1
    end
    if #recent > 0 then
      M.switch_project(recent[index])
    else
      vim.notify("No recent projects")
    end
  end, { nargs = 0, count = true })

  -- Open the project from the history by name
  vim.api.nvim_create_user_command("NeovimProjectLoadHist", function(args)
    local arg = args.args
    local recentprojects = history.get_recent_projects()
    local recent = {}
    for _, v in ipairs(recentprojects) do
      local val = string.gsub(v, "\\", "/")
      table.insert(recent, val)
    end

    if vim.tbl_contains(recent, arg) then
      M.switch_project(arg)
    else
      vim.notify("Project not found")
    end
  end, {
    nargs = 1,
    complete = function()
      local recentprojects = history.get_recent_projects()
      local recent = {}
      for _, v in ipairs(recentprojects) do
        local val = string.gsub(v, "\\", "/")
        table.insert(recent, val)
      end
      return recent
    end,
  })

  -- Open the project from all projects by name
  vim.api.nvim_create_user_command("NeovimProjectLoad", function(args)
    local arg = args.args
    local allprojects = path.get_all_projects()
    local projects = {}
    for _, v in ipairs(allprojects) do
      local val = string.gsub(v, "\\", "/")
      table.insert(projects, val)
    end

    if vim.tbl_contains(projects, arg) then
      M.switch_project(arg)
    else
      vim.notify("Project not found")
    end
  end, {
    nargs = 1,
    complete = function()
      local projects = {}
      local allprojects = path.get_all_projects()
      for _, v in ipairs(allprojects) do
        local val = string.gsub(v, "\\", "/")
        table.insert(projects, val)
      end
      return projects
    end,
  })

  vim.api.nvim_create_user_command("NeovimProjectHistory", function(args)
    picker.create_picker(args, false, M.switch_project)
  end, {})

  vim.api.nvim_create_user_command("NeovimProjectDiscover", function(args)
    picker.create_picker(args, true, M.switch_project)
  end, {})
end

M.switch_project = function(dir)
  if M.in_session() then
    M.switch_after_save_session(dir)
  else
    M.load_session(dir)
  end
end

M.init = function()
  M.setup_autocmds()
  M.create_commands()
end

return M
