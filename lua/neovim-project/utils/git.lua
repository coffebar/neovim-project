local M = {}

-- Cache git executable check result
M._git_available = nil

--- Check if git is installed and available
--- @return boolean True if git is available
M.is_git_available = function()
  if M._git_available ~= nil then
    return M._git_available
  end

  M._git_available = vim.fn.executable("git") == 1
  return M._git_available
end

--- Get the current git branch for a directory
--- @param dir string The directory to check
--- @return string|nil The branch name, or nil if not a git repo or detached HEAD
M.get_git_branch = function(dir)
  if not M.is_git_available() then
    return nil
  end

  local is_git_repo =
    vim.fn.system("git -C " .. vim.fn.shellescape(dir) .. " rev-parse --is-inside-work-tree 2>/dev/null")
  if not is_git_repo:match("true") then
    return nil
  end

  local branch =
    vim.fn.system("git -C " .. vim.fn.shellescape(dir) .. " branch --show-current 2>/dev/null"):gsub("\n", "")

  -- Empty string means detached HEAD or error
  return branch ~= "" and branch or nil
end

--- Get the path to the .git/HEAD file, handling both regular repos and worktrees
--- @param dir string The directory to check
--- @return string|nil The path to the HEAD file, or nil if not a git repo
M.get_git_head_file = function(dir)
  local git_path = dir .. "/.git"
  local stat = vim.loop.fs_stat(git_path)

  if not stat then
    return nil
  end

  if stat.type == "directory" then
    -- Regular git repository
    return git_path .. "/HEAD"
  elseif stat.type == "file" then
    -- Git worktree - .git is a file containing "gitdir: /path/to/real/git/dir"
    local file = io.open(git_path, "r")
    if not file then
      return nil
    end

    local content = file:read("*all")
    file:close()

    -- Parse "gitdir: /path/to/git/dir"
    local gitdir = content:match("gitdir:%s*(.+)")
    if gitdir then
      gitdir = gitdir:gsub("\n", "")
      -- Handle relative paths
      if not gitdir:match("^/") then
        gitdir = dir .. "/" .. gitdir
      end
      return gitdir .. "/HEAD"
    end
  end

  return nil
end

--- Sanitize branch name for use in filenames
--- @param branch string The branch name
--- @return string The sanitized branch name
M.sanitize_branch_name = function(branch)
  -- Replace characters that could cause issues in filenames
  return branch:gsub("/", "-"):gsub("\\", "-"):gsub(":", "-")
end

return M
