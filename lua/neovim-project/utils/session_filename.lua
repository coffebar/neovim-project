local M = {}

-- Store the original session_manager functions
M.original_dir_to_session_filename = nil
M.original_session_filename_to_dir = nil

-- Track the current branch for each directory to detect changes
-- Key: directory path, Value: { branch = "branch_name", session_filename = "path/to/session" }
M.branch_cache = {}

-- Flag to temporarily force using a specific session filename
-- Used when saving to old branch before switching to new branch
M.force_session_filename = nil

--- Initialize the module by storing original functions
--- @param session_manager_config table The session_manager.config module
M.init = function(session_manager_config)
  M.original_dir_to_session_filename = session_manager_config.dir_to_session_filename
  M.original_session_filename_to_dir = session_manager_config.session_filename_to_dir
end

--- Get the current branch and cached session filename for a directory
--- @param dir string The directory path
--- @return table|nil { branch = string, session_filename = string } or nil if not cached
M.get_cached_branch_info = function(dir)
  local expanded_dir = vim.fn.expand(dir)
  return M.branch_cache[expanded_dir]
end

--- Update the branch cache for a directory
--- @param dir string The directory path
--- @param branch string|nil The current branch name (nil if not a git repo)
--- @param session_filename string|nil The session filename for this branch
M.update_branch_cache = function(dir, branch, session_filename)
  local expanded_dir = vim.fn.expand(dir)
  if branch then
    M.branch_cache[expanded_dir] = {
      branch = branch,
      session_filename = session_filename,
    }
  else
    M.branch_cache[expanded_dir] = nil
  end
end

--- Create dir_to_session_filename function with branch awareness
--- @return function The function to use as dir_to_session_filename
M.create_dir_to_session_filename = function()
  return function(dir)
    local debug_log = require("neovim-project.debug_log")
    debug_log.log("Called with dir: " .. tostring(dir), "dir_to_session_filename")

    -- If we're forcing a specific session filename (during branch switch save), use it
    if M.force_session_filename then
      debug_log.log("Using forced filename: " .. tostring(M.force_session_filename.filename), "dir_to_session_filename")
      return M.force_session_filename
    end

    local git = require("neovim-project.utils.git")
    local expanded_dir = vim.fn.expand(dir)
    local branch = git.get_git_branch(expanded_dir)
    debug_log.log("Branch for " .. expanded_dir .. ": " .. tostring(branch), "dir_to_session_filename")

    if branch then
      -- Append branch to directory path with special separator
      local sanitized_branch = git.sanitize_branch_name(branch)
      local dir_with_branch = dir .. "@@branch@@" .. sanitized_branch
      -- Use original function with modified path
      local session_filename = M.original_dir_to_session_filename(dir_with_branch)

      debug_log.log("Returning branch-aware filename: " .. tostring(session_filename.filename), "dir_to_session_filename")

      -- Update cache with current branch and session filename
      M.update_branch_cache(dir, branch, session_filename)

      return session_filename
    else
      -- Not a git repo or detached HEAD - use regular session naming
      debug_log.log("No branch, returning regular filename", "dir_to_session_filename")
      M.update_branch_cache(dir, nil, nil)
      return M.original_dir_to_session_filename(dir)
    end
  end
end

--- Create session_filename_to_dir function that strips branch suffix
--- @return function The function to use as session_filename_to_dir
M.create_session_filename_to_dir = function()
  return function(filename)
    -- Strip the @@branch@@ suffix before converting to dir
    local basename = filename:match("([^/]+)$") or filename
    local dir_part = basename:gsub("@@branch@@[^/]*$", "")

    -- Reconstruct filename without branch suffix for conversion
    local dir_name = filename:gsub(basename .. "$", dir_part)

    return M.original_session_filename_to_dir(dir_name)
  end
end

--- Temporarily force using a specific session filename for the next save
--- This is used when we need to save to the old branch's session file
--- before switching to the new branch
--- @param session_filename string|nil The session filename to force, or nil to clear
M.set_force_session_filename = function(session_filename)
  M.force_session_filename = session_filename
end

--- Clear the force session filename flag
M.clear_force_session_filename = function()
  M.force_session_filename = nil
end

return M
