local uv = vim.loop
local M = {}

M.datapath = vim.fn.stdpath("data") -- directory
M.projectpath = M.datapath .. "/neovim-project" -- directory
M.historyfile = M.projectpath .. "/history" -- file
M.sessionspath = M.datapath .. "/neovim-sessions" --directory
M.homedir = nil
M.dir_pretty = nil -- directory of current project (respects user defined symlinks in config)

function M.init()
  M.datapath = vim.fn.expand(require("neovim-project.config").options.datapath)
  M.projectpath = M.datapath .. "/neovim-project" -- directory
  M.historyfile = M.projectpath .. "/history" -- file
  M.sessionspath = M.datapath .. "/neovim-sessions" --directory
  M.homedir = vim.fn.expand("~")
end

M.cwd_matches_project = function()
  -- Check if current working directory mathch project patterns
  local projects = M.get_all_projects()
  local cwd_resolved = M.resolve(M.cwd())
  for _, path in ipairs(projects) do
    if M.resolve(path) == cwd_resolved then
      M.dir_pretty = M.short_path(path) -- store path with user defined symlinks
      return true
    end
  end
  return false
end

M.get_all_projects = function()
  -- Get all existing projects from patterns
  local projects = {}
  local patterns = require("neovim-project.config").options.projects
  for _, pattern in ipairs(patterns) do
    local tbl = vim.fn.glob(pattern, true, true, true)
    for _, path in ipairs(tbl) do
      if vim.fn.isdirectory(path) == 1 then
        table.insert(projects, M.short_path(path))
      end
    end
  end
  return projects
end

M.short_path = function(path)
  -- Reduce file name to be relative to the home directory, if possible.
  return vim.fn.fnamemodify(path, ":~")
end

M.cwd = function()
  -- Get current working directory in short form
  return M.short_path(uv.cwd())
end

M.create_scaffolding = function(callback)
  -- Create directories
  if callback ~= nil then -- async
    uv.fs_mkdir(M.projectpath, 448, callback)
  else -- sync
    uv.fs_mkdir(M.projectpath, 448)
  end
end

M.resolve = function(filename)
  -- Replace symlink with real path
  filename = vim.fn.expand(filename)
  return vim.fn.resolve(filename)
end

M.fix_symlinks_for_history = function(dirs)
  -- Replace paths with paths from `projects` option
  local projects = M.get_all_projects()
  for i, dir in ipairs(dirs) do
    for _, path in ipairs(projects) do
      if M.resolve(path) == M.resolve(dir) then
        dirs[i] = path
        break
      end
    end
  end
  -- remove duplicates
  local unique = {}
  for _, dir in ipairs(dirs) do
    if not vim.tbl_contains(unique, dir) then
      table.insert(unique, dir)
    end
  end
  return unique
end

return M
