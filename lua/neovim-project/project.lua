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
      -- Ignore directory changes initiated by plugin's project switching
      if M.switching_project then
        debug_log.log("Ignoring directory change (switching_project=true)", "DirChangedPre")
        return
      end
      debug_log.log(
        "Dir change detected. path.dir_pretty=" .. tostring(path.dir_pretty) .. " event.file=" .. tostring(event.file),
        "DirChangedPre"
      )
      if path.dir_pretty ~= path.short_path(event.file) then
        -- directory changed from outside
        debug_log.log("Exiting from session: " .. path.dir_pretty, "DirChangedPre")
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
  debug_log.log("Called with dir: " .. tostring(dir), "load_session")

  if not dir then
    debug_log.log("dir is nil, returning", "load_session")
    return
  end

  -- Set flag to prevent DirChangedPre from interfering
  M.switching_project = true
  debug_log.log("Set switching_project = true", "load_session")

  local current_cwd = path.cwd()
  debug_log.log("Current cwd: " .. tostring(current_cwd), "load_session")
  debug_log.log("Target dir: " .. tostring(dir), "load_session")
  debug_log.log("Paths equal: " .. tostring(current_cwd == dir), "load_session")

  if current_cwd ~= dir then
    debug_log.log("Changing directory to: " .. dir, "load_session")
    path.dir_pretty = path.short_path(dir)
    vim.api.nvim_set_current_dir(dir)
    M.start_session_here()
  else
    debug_log.log("Already in target directory", "load_session")
    -- Check if we're already in a session for this directory
    if M.in_session() then
      debug_log.log("Already in session for this directory, doing nothing", "load_session")
      -- Just ensure history is updated
      if path.dir_pretty ~= nil then
        history.add_session_project(path.dir_pretty)
      else
        history.add_session_project(current_cwd)
      end
    else
      debug_log.log("Not in session, starting session here", "load_session")
      M.start_session_here()
    end
  end

  -- Clear flag after session is loaded
  vim.schedule(function()
    M.switching_project = false
    debug_log.log("Set switching_project = false", "load_session")
  end)
end

M.start_session_here = function()
  debug_log.log("Called", "start_session_here")

  -- load session or create new one if not exists
  local cwd = path.cwd()
  debug_log.log("cwd: " .. tostring(cwd), "start_session_here")

  if not cwd then
    debug_log.log("cwd is nil, returning", "start_session_here")
    return
  end

  local fullpath = vim.fn.expand(cwd)
  debug_log.log("fullpath: " .. tostring(fullpath), "start_session_here")

  local session_loaded = false
  local loaded_from_fallback = false

  -- Session manager will use branch-aware naming if per_branch_sessions is enabled
  local session_exists = manager.current_dir_session_exists()
  debug_log.log("current_dir_session_exists: " .. tostring(session_exists), "start_session_here")

  if session_exists then
    -- Get the session filename that should be loaded
    local session_config = require("session_manager.config")
    local session_file = session_config.dir_to_session_filename(fullpath)
    debug_log.log(
      "Expected session file: " .. tostring(session_file and session_file.filename or "unknown"),
      "start_session_here"
    )

    -- Check if the file actually exists
    if not session_file:exists() then
      debug_log.log("Session file doesn't exist, will try fallback", "start_session_here")
      session_exists = false
    else
      -- Check what session_manager thinks the current dir session is
      local utils_sm = require("session_manager.utils")
      local before_load = utils_sm.get_last_session_filename()
      debug_log.log("Session before load: " .. tostring(before_load), "start_session_here")

      -- Set the active session filename BEFORE loading to prevent session_manager from overriding
      utils_sm.active_session_filename = session_file.filename
      debug_log.log("Set active_session_filename to: " .. session_file.filename, "start_session_here")

      -- Load the session directly to ensure we load the correct one
      debug_log.log("Calling load_session with: " .. tostring(session_file.filename), "start_session_here")
      utils_sm.load_session(session_file.filename, false)
      session_loaded = true

      -- Log what was actually loaded
      local loaded_session = utils_sm.get_last_session_filename()
      debug_log.log("Actually loaded session: " .. tostring(loaded_session), "start_session_here")

      -- Check if they match
      if loaded_session ~= session_file.filename then
        debug_log.log("ERROR: Session mismatch! Expected != Actual", "start_session_here")
      end
    end
  elseif config.options.per_branch_sessions and config.original_dir_to_session_filename then
    debug_log.log("Checking fallback session", "start_session_here")
    -- Fallback: try loading regular session file if branch-specific doesn't exist
    -- Use the original (non-branch-aware) function for fallback
    local regular_session = config.original_dir_to_session_filename(fullpath)
    debug_log.log("regular_session path: " .. tostring(regular_session.filename), "start_session_here")

    if regular_session:exists() then
      debug_log.log("Loading fallback session", "start_session_here")
      local utils_sm = require("session_manager.utils")
      utils_sm.load_session(regular_session.filename, false)
      session_loaded = true
      loaded_from_fallback = true
    else
      debug_log.log("Fallback session does not exist", "start_session_here")
    end
  end

  if not session_loaded then
    debug_log.log("No session loaded, creating empty session", "start_session_here")
    vim.cmd("silent! %bd") -- close all buffers from previous session
    -- create empty session
    manager.save_current_session()
  elseif loaded_from_fallback then
    debug_log.log("Loaded from fallback, migrating to branch-specific", "start_session_here")
    -- We loaded from old session file, save it immediately to new branch-specific filename
    -- This migrates the session and updates active_session_filename
    manager.save_current_session()
  end

  -- add to history
  if path.dir_pretty ~= nil then
    debug_log.log("Adding to history: " .. path.dir_pretty, "start_session_here")
    history.add_session_project(path.dir_pretty)
  else
    debug_log.log("Adding to history: " .. cwd, "start_session_here")
    history.add_session_project(cwd)
  end

  -- Setup git HEAD watcher if per-branch sessions enabled
  if config.options.per_branch_sessions then
    M.setup_git_head_watcher(fullpath)
  end

  debug_log.log("Finished", "start_session_here")
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

  -- Debug commands
  vim.api.nvim_create_user_command("NeovimProjectDebugLog", function()
    vim.cmd("edit " .. debug_log.get_path())
  end, {})

  vim.api.nvim_create_user_command("NeovimProjectDebugClear", function()
    debug_log.clear()
    vim.notify("Debug log cleared", vim.log.levels.INFO, { title = "Neovim Project" })
  end, {})
end

M.switch_project = function(dir)
  debug_log.log("Called with dir: " .. tostring(dir), "switch_project")
  debug_log.log("Currently in session: " .. tostring(M.in_session()), "switch_project")
  debug_log.log("Current cwd: " .. tostring(path.cwd()), "switch_project")

  if M.in_session() then
    M.switch_after_save_session(dir)
  else
    M.load_session(dir)
  end
end

--- Handle git branch change - save current session and load branch-specific session
M.handle_branch_change = function()
  debug_log.log("Called", "handle_branch_change")

  if not config.options.per_branch_sessions then
    debug_log.log("per_branch_sessions disabled, returning", "handle_branch_change")
    return
  end

  local cwd = path.cwd()
  debug_log.log("cwd: " .. tostring(cwd), "handle_branch_change")

  if not cwd then
    debug_log.log("cwd is nil, returning", "handle_branch_change")
    return
  end

  -- Expand tilde to full path for git commands
  local fullpath = vim.fn.expand(cwd)
  debug_log.log("fullpath: " .. fullpath, "handle_branch_change")

  local current_branch = git.get_git_branch(fullpath)
  debug_log.log("current_branch: " .. tostring(current_branch), "handle_branch_change")

  if not current_branch then
    debug_log.log("No branch detected, returning", "handle_branch_change")
    return
  end

  -- Check if we're in any session (not necessarily the current branch's session)
  debug_log.log("active_session_filename: " .. tostring(utils.active_session_filename), "handle_branch_change")

  if not utils.active_session_filename then
    debug_log.log("No active session, returning", "handle_branch_change")
    return
  end

  -- Get the expected session filename for current branch
  local session_config = require("session_manager.config")
  local expected_session = session_config.dir_to_session_filename(fullpath)

  -- Use the stored active_session_filename directly instead of get_last_session_filename()
  -- because get_last_session_filename() might compute based on current directory/branch
  local current_session_filename = utils.active_session_filename

  debug_log.log("expected_session: " .. tostring(expected_session.filename), "handle_branch_change")
  debug_log.log(
    "current_session_filename (from active_session_filename): " .. tostring(current_session_filename),
    "handle_branch_change"
  )

  -- If session filename doesn't match, branch changed
  if current_session_filename and expected_session.filename ~= current_session_filename then
    debug_log.log("Branch change detected!", "handle_branch_change")
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
    debug_log.log("Setting forced filename to: " .. current_session_filename, "handle_branch_change")
    session_filename_module.set_force_session_filename(Path:new(current_session_filename))

    -- Save current session and wait for completion
    M.save_project_waiting = true
    debug_log.log("Saving current session to old branch file", "handle_branch_change")
    manager.save_current_session()

    -- Clear the forced filename after save
    session_filename_module.clear_force_session_filename()
    debug_log.log("Cleared forced filename", "handle_branch_change")

    -- Wait for SessionSavePost autocmd or timeout 2 sec
    debug_log.log("Waiting for save to complete...", "handle_branch_change")
    vim.wait(2000, function()
      return not M.save_project_waiting
    end, 1)
    debug_log.log("Wait finished. save_project_waiting=" .. tostring(M.save_project_waiting), "handle_branch_change")

    -- Load or create session for new branch
    debug_log.log("Checking if new branch session exists", "handle_branch_change")
    local new_session_exists = manager.current_dir_session_exists()
    debug_log.log("New session exists: " .. tostring(new_session_exists), "handle_branch_change")

    if new_session_exists then
      debug_log.log("Loading existing session for branch: " .. current_branch, "handle_branch_change")
      manager.load_current_dir_session(false)
    else
      debug_log.log("Creating new session for branch: " .. current_branch, "handle_branch_change")
      -- Create new session for this branch
      manager.save_current_session()
    end
    debug_log.log("Branch change handling complete", "handle_branch_change")
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
  debug_log.log("Called with dir: " .. tostring(dir), "setup_git_head_watcher")

  if not config.options.per_branch_sessions then
    debug_log.log("per_branch_sessions disabled, returning", "setup_git_head_watcher")
    return
  end

  if not git.is_git_available() then
    debug_log.log("Git not available, returning", "setup_git_head_watcher")
    return -- Git not installed
  end

  -- Stop existing watcher if any (for project switch)
  M.stop_git_head_watcher()
  debug_log.log("Stopped existing watcher", "setup_git_head_watcher")

  local head_file = git.get_git_head_file(dir)
  debug_log.log("HEAD file: " .. tostring(head_file), "setup_git_head_watcher")

  if not head_file then
    debug_log.log("No HEAD file found, returning", "setup_git_head_watcher")
    return -- Not a git repo or couldn't find HEAD file
  end

  M.git_head_watcher = vim.loop.new_fs_event()
  if not M.git_head_watcher then
    debug_log.log("Failed to create fs_event watcher", "setup_git_head_watcher")
    return
  end

  if not M.git_debounce_timer then
    M.git_debounce_timer = vim.loop.new_timer()
  end

  debug_log.log("Starting watcher on: " .. head_file, "setup_git_head_watcher")

  M.git_head_watcher:start(head_file, { recursive = false }, function(err, filename, events)
    debug_log.log(
      "Watcher triggered! err="
        .. tostring(err)
        .. " filename="
        .. tostring(filename)
        .. " events="
        .. vim.inspect(events),
      "git_head_watcher"
    )
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
