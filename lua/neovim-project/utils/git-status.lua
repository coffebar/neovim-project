local M = {}

local project_git_status = {}

-- check and store initial git status of each project
function M.init(paths)
  if paths then
    for _, project_path in ipairs(paths) do
      project_git_status[project_path] = M.check_uncommitted(project_path)
    end
  end
end

-- getter
function M.get_status(path)
  if not path then
    return false
  end

  return project_git_status[path]
end

-- setter, use to update git status when changing projects
function M.update_status(path)
  if path then
    project_git_status[path] = M.check_uncommitted(path)
  end
end

-- given a project path, determine if that project has uncommitted changes
function M.check_uncommitted(path)
  if not path or path == "" then
    return false
  end

  local normalized_path = path:gsub("^~", vim.fn.expand("~"))
  if vim.fn.isdirectory(normalized_path) ~= 1 then
    return false
  end

  local is_windows = vim.fn.has("win32") == 1 or vim.fn.has("win64") == 1
  local cmd
  if is_windows then
    -- Windows-specific command (using cmd.exe's pushd/popd for directory changing)
    normalized_path = normalized_path:gsub("/", "\\")
    cmd = string.format('pushd "%s" && git rev-parse --is-inside-work-tree 2>nul && popd', normalized_path)
  else
    -- Unix command
    cmd = "cd " .. vim.fn.shellescape(normalized_path) .. " && git rev-parse --is-inside-work-tree 2>/dev/null"
  end

  local is_repo, _ = pcall(function()
    return vim.fn.system(cmd)
  end)

  if not is_repo or vim.v.shell_error ~= 0 then
    return false -- Not a git repository or command failed
  end

  local status_cmd
  if is_windows then
    -- Windows-specific command
    status_cmd = string.format('pushd "%s" && git status --porcelain && popd', normalized_path)
  else
    -- Unix command
    status_cmd = "cd " .. vim.fn.shellescape(normalized_path) .. " && git status --porcelain"
  end

  local status_ok, git_status = pcall(function()
    return vim.fn.system(status_cmd)
  end)

  if not status_ok then
    return false
  end

  return git_status ~= ""
end

return M
