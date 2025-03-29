local uv = vim.loop
local M = {}

M.datapath = vim.fn.stdpath("data") -- directory
M.projectpath = M.datapath .. "/neovim-project" -- directory
M.allprojectsfile = M.projectpath .. "/all-projects.json" -- file
M.allprojectsmtime = nil
M.historyfile = M.projectpath .. "/history" -- file
M.sessionspath = M.datapath .. "/neovim-sessions" --directory
M.homedir = nil
M.dir_pretty = nil -- directory of current project (respects user defined symlinks in config)

function M.init()
  M.datapath = vim.fn.expand(require("neovim-project.config").options.datapath)
  M.projectpath = M.datapath .. "/neovim-project" -- directory
  M.allprojectsfile = M.projectpath .. "/all-projects.json" -- file
  M.historyfile = M.projectpath .. "/history" -- file
  M.sessionspath = M.datapath .. "/neovim-sessions" --directory
  M.homedir = vim.fn.expand("~")
end

local function is_subdirectory(parent, sub)
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
    M.dir_pretty = parent -- store path with user defined symlinks
    vim.api.nvim_set_current_dir(parent)
  end
  return parent
end

local function open_cached_projects(mode)
  M.create_scaffolding()
  return uv.fs_open(M.allprojectsfile, mode, 438)
end

local function read_cached_projects()
  local file = open_cached_projects("r")
  if file ~= nil then
    local stat = uv.fs_fstat(file)
    if stat ~= nil then
      if M.allprojectsmtime == nil or stat.mtime.nsec > M.allprojectsmtime then
        M.allprojectsmtime = stat.mtime.nsec
        local data = uv.fs_read(file, stat.size, -1)
        if data ~= nil then
          return vim.json.decode(data)
        end
      end
    end
    uv.fs_close(file)
  end
  return {}
end

local function write_cached_projects(cached_projects)
  local file = open_cached_projects("w")
  if file ~= nil then
    uv.fs_write(file, vim.json.encode(cached_projects))
  end
end

-- Diff between cached patterns and config patterns and
-- determine the patterns to update.
local function find_out_changed_patterns(patterns, cached_projects)
  local added = {}
  local removed = {}
  for _, pattern in ipairs(patterns) do
    if cached_projects[pattern] == nil then
      table.insert(added, pattern)
    end
  end
  for pattern, _ in pairs(cached_projects) do
    if not vim.list_contains(patterns, pattern) then
      table.insert(removed, pattern)
    end
  end
  return added, removed
end

M.get_all_projects = function()
  -- Get all existing projects from patterns
  local projects = {}
  local patterns = require("neovim-project.config").options.projects
  local cached_projects = read_cached_projects()
  local added, removed = find_out_changed_patterns(patterns, cached_projects)
  for _, pattern in ipairs(added) do
    cached_projects[pattern] = {}
    local tbl = vim.fn.glob(pattern, true, true, true)
    for _, path in ipairs(tbl) do
      if vim.fn.isdirectory(path) == 1 then
        local short = M.short_path(path)
        if not vim.list_contains(cached_projects[pattern], short) then
          table.insert(cached_projects[pattern], short)
        end
      end
    end
  end
  for _, pattern in ipairs(removed) do
    cached_projects[pattern] = nil
  end
  if not vim.tbl_isempty(added) or not vim.tbl_isempty(removed) then
    write_cached_projects(cached_projects)
  end
  for _, pattern_projects in pairs(cached_projects) do
    vim.list_extend(projects, pattern_projects)
  end
  return projects
end

M.get_all_projects_with_sorting = function()
  -- Get all projects but with specific sorting
  local sorting = require("neovim-project.config").options.picker.opts.sorting
  local all_projects = M.get_all_projects()

  -- Sort by most recent projects first
  if sorting == "history" then
    local recent = require("neovim-project.utils.history").get_recent_projects()
    recent = M.fix_symlinks_for_history(recent)

    -- Reverse projects
    for i = 1, math.floor(#recent / 2) do
      recent[i], recent[#recent - i + 1] = recent[#recent - i + 1], recent[i]
    end

    -- Add all projects and prioritise history
    local seen, projects = {}, {}
    for _, project in ipairs(vim.list_extend(recent, all_projects)) do
      if not seen[project] then
        table.insert(projects, project)
        seen[project] = true
      end
    end
    return projects

  -- Sort alphabetically ascending by project name
  elseif sorting == "alphabetical_name" then
    table.sort(all_projects, function(a, b)
      local name_a = a:match(".*/([^/]+)$") or a
      local name_b = b:match(".*/([^/]+)$") or b
      return name_a:lower() < name_b:lower()
    end)
    return all_projects

  -- Sort alphabetically ascending by project path
  elseif sorting == "alphabetical_path" then
    table.sort(all_projects)
    return all_projects

  -- Default sort based on patterns
  else
    return all_projects
  end
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
    local dir_resolved
    for _, path in ipairs(projects) do
      if path == dir then
        dirs[i] = path
        break
      else
        if dir_resolved == nil then
          dir_resolved = M.resolve(dir)
        end
        if path == dir_resolved then
          dirs[i] = path
          break
        elseif M.resolve(path) == dir_resolved then
          dirs[i] = path
          break
        end
      end
    end
  end
  -- remove duplicates
  return M.delete_duplicates(dirs)
end

return M
