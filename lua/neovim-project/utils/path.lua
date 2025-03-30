local uv = vim.loop
local M = {}
local all_projects_cache = {}
local ram_cache_lifetime = 5
local last_scan_timestamp = 0

M.datapath = vim.fn.stdpath("data") -- directory
M.projectpath = M.datapath .. "/neovim-project" -- directory
M.historyfile = M.projectpath .. "/history" -- file
M.sessionspath = M.datapath .. "/neovim-sessions" --directory
M.homedir = nil
M.dir_pretty = nil -- directory of current project (respects user defined symlinks in config)
M._VimLeavePre = false -- flag to check if VimLeavePre was called

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

M.get_all_projects = function()
  -- Get all existing projects from patterns
  local projects = {}
  local patterns = require("neovim-project.config").options.projects
  for _, pattern in ipairs(patterns) do
    local tbl = vim.fn.glob(pattern, true, true, true)
    for _, path in ipairs(tbl) do
      if vim.fn.isdirectory(path) == 1 then
        local short = M.short_path(path)
        if not vim.tbl_contains(projects, short) then
          table.insert(projects, short)
        end
      end
    end
  end
  return projects
end

local write_all_project_list_to_file = function(projects)
  local filename = M.projectpath .. "/.project-list.cache"
  local file = io.open(filename, "w")
  if file then
    for _, project in ipairs(projects) do
      file:write(project .. "\n")
    end
    file:close()
  end
end

local get_all_projects_with_ram_cache = function()
  -- read filesystem only if the cache is older than 5 seconds
  local current_time = os.time()
  if current_time - last_scan_timestamp > ram_cache_lifetime then
    local projects = M.get_all_projects()
    if last_scan_timestamp > 0 and not M._VimLeavePre then
      -- update the peresistent cache if project list has changed
      local old_projects = all_projects_cache
      vim.defer_fn(function()
        if not vim.deep_equal(old_projects, projects) then
          -- update persistent cache
          write_all_project_list_to_file(projects)
        end
      end, 100)
    end
    all_projects_cache = projects
    last_scan_timestamp = current_time
  end
  return all_projects_cache
end

M.get_all_projects_with_sorting = function()
  -- Get all projects but with specific sorting
  local sorting = require("neovim-project.config").options.picker.opts.sorting
  local all_projects = get_all_projects_with_ram_cache()

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
  local projects = get_all_projects_with_ram_cache()
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

M.write_persistent_cache = function()
  -- update the persistent cache file
  local projects = get_all_projects_with_ram_cache()
  write_all_project_list_to_file(projects)
  -- return the projects
  return projects
end

-- Get all projects with persistent cache
-- to avoid reading the filesystem on startup, except for the first time
local get_all_projects_with_peresistent_cache = function()
  local filename = M.projectpath .. "/.project-list.cache"
  -- if file exists, read it and return the contents as a table
  -- otherwise, create the file and write the projects to it
  local file = io.open(filename, "r")
  if file then
    local projects = {}
    for line in file:lines() do
      table.insert(projects, line)
    end
    file:close()
    return projects
  else
    -- create the file and write the projects to it
    return M.write_persistent_cache()
  end
end

M.chdir_closest_parent_project = function(dir)
  -- returns the parent project and chdir to that parent
  -- if no parent project returns nil
  -- if dir is a project return dir
  local dir_resolved = dir or M.resolve(M.cwd())
  local parent = find_closest_parent(get_all_projects_with_peresistent_cache(), dir_resolved)
  if parent then
    M.dir_pretty = M.short_path(parent) -- store path with user defined symlinks
    vim.api.nvim_set_current_dir(parent)
  end
  return parent
end

return M
