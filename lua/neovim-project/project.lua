local M = {}

local history = require("neovim-project.utils.history")
local manager = require("session_manager")
local path = require("neovim-project.utils.path")
local payload = require("neovim-project.payload")
local utils = require("session_manager.utils")
local config = require("neovim-project.config")
local picker = require("neovim-project.picker")
local showkeys = require("neovim-project.utils.showkeys")
local git = require("neovim-project.utils.git")

M.save_project_waiting = false
M.git_head_watcher = nil
M.git_debounce_timer = nil

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
      -- Cleanup git watcher
      M.stop_git_head_watcher()
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
  -- 1. Add state data to the session file via global variable
  -- 2. Workaround for showkeys plugin: close the buffer and save it's state
  vim.api.nvim_create_autocmd({ "User" }, {
    pattern = "SessionSavePre",
    group = augroup,
    callback = function()
      payload.pre_save()
      showkeys.pre_save()
    end,
  })
  -- 1. Trigger FileType autocmd to attach lsp server to the active buffer
  -- 2. Restore saved state data from the global var in the session file
  -- 3. Workaround for showkeys plugin: reopen the it's buffer
  -- 4. Restart git HEAD watcher after session load
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
      showkeys.post_load()
      -- Restart git watcher after session load (session load clears it)
      if config.options.per_branch_sessions then
        local cwd = path.cwd()
        if cwd then
          local fullpath = vim.fn.expand(cwd)
          M.setup_git_head_watcher(fullpath)
        end
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
  picker.create_picker({}, false, switch_project_callback)
end

function M.discover_projects()
  picker.create_picker({}, true, switch_project_callback)
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
  local session_loaded = false
  local loaded_from_fallback = false

  -- Session manager will use branch-aware naming if per_branch_sessions is enabled
  if manager.current_dir_session_exists() then
    manager.load_current_dir_session(false)
    session_loaded = true
  elseif config.options.per_branch_sessions and config.original_dir_to_session_filename then
    -- Fallback: try loading regular session file if branch-specific doesn't exist
    -- Use the original (non-branch-aware) function for fallback
    local regular_session = config.original_dir_to_session_filename(fullpath)
    if regular_session:exists() then
      local utils_sm = require("session_manager.utils")
      utils_sm.load_session(regular_session.filename, false)
      session_loaded = true
      loaded_from_fallback = true
    end
  end

  if not session_loaded then
    vim.cmd("silent! %bd") -- close all buffers from previous session
    -- create empty session
    manager.save_current_session()
  elseif loaded_from_fallback then
    -- We loaded from old session file, save it immediately to new branch-specific filename
    -- This migrates the session and updates active_session_filename
    manager.save_current_session()
  end

  -- add to history
  if path.dir_pretty ~= nil then
    history.add_session_project(path.dir_pretty)
  else
    history.add_session_project(cwd)
  end

  -- Setup git HEAD watcher if per-branch sessions enabled
  if config.options.per_branch_sessions then
    M.setup_git_head_watcher(fullpath)
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
    local allprojects = path.get_all_projects_with_sorting()
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
      local allprojects = path.get_all_projects_with_sorting()
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
    -- Default sorting based on patterns
    config.options.picker.opts.sorting = args.args or "default"
    picker.create_picker(args, true, M.switch_project)
  end, {
    nargs = "?",
    complete = function()
      return { "default", "history", "alphabetical_name", "alphabetical_path" }
    end,
  })
end

M.switch_project = function(dir)
  if M.in_session() then
    M.switch_after_save_session(dir)
  else
    M.load_session(dir)
  end
end

--- Handle git branch change - save current session and load branch-specific session
M.handle_branch_change = function()
  if not config.options.per_branch_sessions then
    return
  end

  local cwd = path.cwd()
  if not cwd then
    return
  end

  -- Expand tilde to full path for git commands
  local fullpath = vim.fn.expand(cwd)

  local current_branch = git.get_git_branch(fullpath)
  if not current_branch then
    return
  end

  -- Check if we're in any session (not necessarily the current branch's session)
  if not utils.active_session_filename then
    return
  end

  -- Get the expected session filename for current branch
  local session_config = require("session_manager.config")
  local expected_session = session_config.dir_to_session_filename(fullpath)
  local current_session_filename = utils.get_last_session_filename()

  -- If session filename doesn't match, branch changed
  if current_session_filename and expected_session.filename ~= current_session_filename then
    vim.notify(
      "Branch changed to '" .. current_branch .. "'. Switching sessions...",
      vim.log.levels.INFO,
      { title = "Neovim Project" }
    )

    -- Save current buffers to the OLD session file (before branch switch)
    -- We need to save explicitly to current_session_filename because
    -- dir_to_session_filename now returns the NEW branch's filename
    local utils_sm = require("session_manager.utils")
    utils_sm.save_session(current_session_filename)

    -- Load or create session for new branch
    if manager.current_dir_session_exists() then
      manager.load_current_dir_session(false)
      vim.notify("Loaded session for branch: " .. current_branch, vim.log.levels.INFO, { title = "Neovim Project" })
    else
      -- Create new session for this branch
      vim.cmd("silent! %bd") -- close all buffers
      manager.save_current_session()
      vim.notify("Created new session for branch: " .. current_branch, vim.log.levels.INFO, { title = "Neovim Project" })
    end
  end
end

--- Stop git HEAD watcher
M.stop_git_head_watcher = function()
  if M.git_debounce_timer then
    -- Stop and close the timer to prevent pending callbacks
    if not M.git_debounce_timer:is_closing() then
      M.git_debounce_timer:stop()
      M.git_debounce_timer:close()
    end
    M.git_debounce_timer = nil
  end
  if M.git_head_watcher then
    -- Stop and close the watcher
    if not M.git_head_watcher:is_closing() then
      M.git_head_watcher:stop()
      M.git_head_watcher:close()
    end
    M.git_head_watcher = nil
  end
end

--- Setup git HEAD watcher for per-branch session management
--- @param dir string The directory to watch
M.setup_git_head_watcher = function(dir)
  if not config.options.per_branch_sessions then
    return
  end

  if not git.is_git_available() then
    return -- Git not installed
  end

  -- Stop existing watcher if any (for project switch)
  M.stop_git_head_watcher()

  local head_file = git.get_git_head_file(dir)
  if not head_file then
    return -- Not a git repo or couldn't find HEAD file
  end

  M.git_head_watcher = vim.loop.new_fs_event()
  if not M.git_head_watcher then
    return
  end

  if not M.git_debounce_timer then
    M.git_debounce_timer = vim.loop.new_timer()
  end

  M.git_head_watcher:start(head_file, { recursive = false }, function(err, filename, events)
    if err then
      -- Watcher error, try to restart it
      vim.schedule(function()
        M.setup_git_head_watcher(dir)
      end)
      return
    end

    -- React to both change and rename events (git can rename HEAD during branch switch)
    if events.change or events.rename then
      M.git_debounce_timer:stop()
      M.git_debounce_timer:start(
        500,
        0,
        vim.schedule_wrap(function()
          M.handle_branch_change()
        end)
      )
    end
  end)
end

M.init = function()
  M.setup_autocmds()
  M.create_commands()
end

return M
