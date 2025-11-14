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
local debug_log = require("neovim-project.debug_log")

M.save_project_waiting = false
M.git_head_watcher = nil
M.git_debounce_timer = nil
M.switching_project = false

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
      M.save_project_waiting = false
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
        -- Use vim.schedule to ensure cwd is updated after session finishes loading
        vim.schedule(function()
          local cwd = path.cwd()
          if cwd then
            local fullpath = vim.fn.expand(cwd)
            M.setup_git_head_watcher(fullpath)
          end
        end)
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
      -- Ignore directory changes initiated by plugin's project switching
      if M.switching_project then
        return
      end
      if path.dir_pretty ~= path.short_path(event.file) then
        -- directory changed from outside
        debug_log.log("Exiting session due to external directory change: " .. path.dir_pretty, "DirChangedPre")
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
    return not M.save_project_waiting
  end, 1)
  M.load_session(dir)
end

M.load_session = function(dir)
  if not dir then
    debug_log.log("load_session called with nil dir", "load_session")
    return
  end

  debug_log.log("Loading session for: " .. dir, "load_session")

  -- Set flag to prevent DirChangedPre from interfering
  M.switching_project = true

  local current_cwd = path.cwd()

  if current_cwd ~= dir then
    path.dir_pretty = path.short_path(dir)
    vim.api.nvim_set_current_dir(dir)
    M.start_session_here()
  else
    -- Check if we're already in a session for this directory
    if M.in_session() then
      debug_log.log("Already in session, updating history", "load_session")
      -- Just ensure history is updated
      if path.dir_pretty ~= nil then
        history.add_session_project(path.dir_pretty)
      else
        history.add_session_project(current_cwd)
      end
      -- Write history to file immediately
      history.write_projects_to_history()
    else
      M.start_session_here()
    end
  end

  -- Clear flag after session is loaded
  vim.schedule(function()
    M.switching_project = false
  end)
end

M.start_session_here = function()
  -- load session or create new one if not exists
  local cwd = path.cwd()

  if not cwd then
    debug_log.log("start_session_here called with nil cwd", "start_session_here")
    return
  end

  local fullpath = vim.fn.expand(cwd)

  local session_loaded = false
  local loaded_from_fallback = false

  -- Session manager will use branch-aware naming if per_branch_sessions is enabled
  local session_exists = manager.current_dir_session_exists()

  if session_exists then
    -- Get the session filename that should be loaded
    local session_config = require("session_manager.config")
    local session_file = session_config.dir_to_session_filename(fullpath)

    -- Check if the file actually exists
    if not session_file:exists() then
      debug_log.log("Session file missing, trying fallback", "start_session_here")
      session_exists = false
    else
      -- Set the active session filename BEFORE loading to prevent session_manager from overriding
      local utils_sm = require("session_manager.utils")
      utils_sm.active_session_filename = session_file.filename

      -- Load the session using session_manager
      debug_log.log("Loading session: " .. session_file.filename, "start_session_here")
      utils_sm.load_session(session_file.filename, false)
      session_loaded = true
    end
  elseif config.options.per_branch_sessions and config.original_dir_to_session_filename then
    -- Fallback: try loading regular session file if branch-specific doesn't exist
    -- Use the original (non-branch-aware) function for fallback
    local regular_session = config.original_dir_to_session_filename(fullpath)

    if regular_session:exists() then
      debug_log.log("Loading fallback session and migrating to branch-specific", "start_session_here")
      local utils_sm = require("session_manager.utils")
      utils_sm.load_session(regular_session.filename, false)
      session_loaded = true
      loaded_from_fallback = true
    end
  end

  if not session_loaded then
    debug_log.log("Creating new session", "start_session_here")
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

  -- Write history to file immediately after project switch
  -- This ensures history is persisted even if Neovim crashes
  if M.switching_project then
    history.write_projects_to_history()
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
  debug_log.log("Switching to project: " .. tostring(dir), "switch_project")

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
    debug_log.log("handle_branch_change: cwd is nil", "handle_branch_change")
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

  -- Use the stored active_session_filename directly instead of get_last_session_filename()
  -- because get_last_session_filename() might compute based on current directory/branch
  local current_session_filename = utils.active_session_filename

  -- If session filename doesn't match, branch changed
  if current_session_filename and expected_session.filename ~= current_session_filename then
    debug_log.log("Branch switched to: " .. current_branch, "handle_branch_change")
    vim.notify(
      "Branch changed to '" .. current_branch .. "'. Switching sessions...",
      vim.log.levels.INFO,
      { title = "Neovim Project" }
    )

    -- Save current buffers to the OLD session file (before branch switch)
    -- We need to force the session filename to the old one because
    -- dir_to_session_filename now returns the NEW branch's filename
    local session_filename_module = require("neovim-project.utils.session_filename")
    local Path = require("plenary.path")
    session_filename_module.set_force_session_filename(Path:new(current_session_filename))

    -- Save current session and wait for completion
    M.save_project_waiting = true
    manager.save_current_session()

    -- Clear the forced filename after save
    session_filename_module.clear_force_session_filename()

    -- Wait for SessionSavePost autocmd or timeout 2 sec
    vim.wait(2000, function()
      return not M.save_project_waiting
    end, 1)

    -- Load or create session for new branch
    -- Check directly if the expected session file exists
    -- Don't rely on manager.current_dir_session_exists() as it might call
    -- git branch detection before git has fully updated the working tree
    local new_session_exists = expected_session:exists()

    if new_session_exists then
      debug_log.log("Loading session for branch: " .. current_branch, "handle_branch_change")
      -- Load the session directly using the expected filename
      utils.active_session_filename = expected_session.filename
      utils.load_session(expected_session.filename, false)
    else
      debug_log.log("Creating new session for branch: " .. current_branch, "handle_branch_change")
      -- Close all buffers and create new session for this branch
      vim.cmd("silent! %bd")
      utils.active_session_filename = expected_session.filename
      manager.save_current_session()
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
    debug_log.log("Failed to create git HEAD watcher", "setup_git_head_watcher")
    return
  end

  if not M.git_debounce_timer then
    M.git_debounce_timer = vim.loop.new_timer()
  end

  debug_log.log("Watching git HEAD: " .. head_file, "setup_git_head_watcher")

  M.git_head_watcher:start(head_file, { recursive = false }, function(err, filename, events)
    if err then
      -- Watcher error, try to restart it
      debug_log.log("Git watcher error, restarting: " .. tostring(err), "git_head_watcher")
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
