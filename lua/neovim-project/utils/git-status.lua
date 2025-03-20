local M = {}

function M.check_uncommitted(path)
  if not path or path == "" then
    return false
  end

  local normalized_path = path:gsub("^~", vim.fn.expand("~"))

  if vim.fn.isdirectory(normalized_path) ~= 1 then
    return false
  end

  local is_repo, _ = pcall(function()
    return vim.fn.system(
      "cd " .. vim.fn.shellescape(normalized_path) .. " && git rev-parse --is-inside-work-tree 2>/dev/null"
    )
  end)

  if not is_repo or vim.v.shell_error ~= 0 then
    return false -- Not a git repository or command failed
  end

  local status_ok, git_status = pcall(function()
    return vim.fn.system("cd " .. vim.fn.shellescape(normalized_path) .. " && git status --porcelain")
  end)

  if not status_ok then
    return false
  end

  return git_status ~= ""
end

return M
