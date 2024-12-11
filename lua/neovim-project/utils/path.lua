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

local function is_subdirectory(parent, sub)
  parent = M.short_path(parent)
  sub = M.short_path(sub)
  return sub:sub(1, #parent) == parent
end

local function find_closest_parent(directories, subdirectory)
  local closest_parent = nil
  local closest_length = 0
  subdirectory = M.short_path(subdirectory)
  for _, dir in ipairs(directories) do
    dir = M.short_path(dir)
    if is_subdirectory(dir, subdirectory) then
      local length = #dir
      if length > closest_length then
        closest_length = length
        closest_parent = dir
      end
    end
  end
  return closest_parent
end

M.chdir_closest_parent_project = function(dir)
  -- returns the parent project and chdir to that parent
  -- if no parent project returns nil
  -- if dir is a project return dir
  local dir_resolved = dir or M.resolve(M.cwd())
  local parent = find_closest_parent(M.get_all_projects(), dir_resolved)
  if parent then
    M.dir_pretty = M.short_path(parent) -- store path with user defined symlinks
    vim.api.nvim_set_current_dir(parent)
  end
  return parent
end

M.get_all_projects = function()
  -- Get all existing projects from patterns
  local projects = {}
  local patterns = require("neovim-project.config").options.projects
  for _, pattern in ipairs(patterns) do
    local tbl = vim.fn.glob(pattern, true, true, true)
    for _, path in ipairs(tbl) do
      if vim.fn.isdirectory(path) == 1 and not vim.tbl_contains(projects, path) then
        table.insert(projects, M.short_path(path))
      end
    end
  end
  return projects
end

M.short_path = function(path)
  -- Reduce file name to be relative to the home directory, if possible.
  path = M.resolve(path)
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

M.delete_duplicates = function(tbl)
  -- Remove duplicates from table, preserving order
  local cache_dict = {}
  for _, v in ipairs(tbl) do
    if cache_dict[v] == nil then
      cache_dict[v] = 1
    else
      cache_dict[v] = cache_dict[v] + 1
    end
  end

  local res = {}
  for _, v in ipairs(tbl) do
    if cache_dict[v] == 1 then
      table.insert(res, v)
    else
      cache_dict[v] = cache_dict[v] - 1
    end
  end
  return res
end

M.fix_symlinks_for_history = function(dirs)
  -- Replace paths with paths from `projects` option
  local projects = M.get_all_projects()
  for i, dir in ipairs(dirs) do
    local dir_resolved = M.resolve(dir)
    for _, path in ipairs(projects) do
      if M.resolve(path) == dir_resolved then
        dirs[i] = path
        break
      end
    end
  end
  -- remove duplicates
  return M.delete_duplicates(dirs)
end

return M
