local uv = vim.loop
local M = {}

M.datapath = vim.fn.stdpath("data") -- directory
M.projectpath = M.datapath .. "/neovim-project" -- directory
M.historyfile = M.projectpath .. "/history" -- file
M.sessionspath = M.datapath .. "/neovim-sessions" --directory
M.homedir = nil
M.dir_pretty = nil -- directory of current project (respects user defined symlinks in config)

---Convert glob-style wildcards to Lua pattern
---@param wildcard string wildcard string
---@param resolve boolean whether or not to resolve symlinks for the "prefix"
---@param eol boolean? whether or not to add `$` at the end of the pattern, default is true
---@return string converted Lua pattern
local function wildcard_to_pattern(wildcard, resolve, eol)
  if not wildcard or wildcard == "" then
    return ""
  end
  if eol == nil then
    eol = true
  end

  -- Expand to absolute path, fnamemodify can work with wildcards
  local pattern = vim.fn.fnamemodify(wildcard, ":p")

  if resolve then
    -- It turns out that `vim.fn.resolve` can actually resolve the "prefix" even if it is a wildcard
    pattern = vim.fn.resolve(pattern)
  end

  -- Escape special characters for Lua patterns (except wildcards we need to handle specially)
  pattern = pattern:gsub("([%%%.%+%-%$%^%(%)%]])", "%%%1")

  -- Handle the beginning of the pattern
  local start_pattern = "^"

  -- Keep track of current position
  local i = 1
  local len = #pattern
  local result = start_pattern

  while i <= len do
    local c = pattern:sub(i, i)

    if c == "?" then
      -- ? matches one character, but not path separators
      result = result .. "[^/\\]"
      i = i + 1
    elseif c == "*" then
      if i < len and pattern:sub(i + 1, i + 1) == "*" then
        -- ** recursively matches all directories
        if i + 2 <= len and (pattern:sub(i + 2, i + 2) == "/" or pattern:sub(i + 2, i + 2) == "\\") then
          -- Handle **/ or **\ patterns, match any level of directories
          result = result .. ".*"
          i = i + 3
        else
          -- Standalone ** treated as *
          if i == 1 or pattern:sub(i - 1, i - 1) == "." then
            -- Patterns starting with .* can match hidden files
            result = result .. ".*"
          else
            -- * doesn't match files starting with a dot (nosuf=true)
            result = result .. "([^.][^/\\]*)"
          end
          i = i + 2
        end
      else
        -- Single * case
        if i == 1 or pattern:sub(i - 1, i - 1) == "." then
          -- Patterns starting with .* can match hidden files
          result = result .. "[^/\\]*"
        else
          -- * doesn't match files starting with a dot (nosuf=true)
          result = result .. "([^.][^/\\]*)"
        end
        i = i + 1
      end
    elseif c == "[" then
      -- Handle [abc] character classes
      local closing = pattern:find("]", i + 1)
      if closing then
        if pattern:sub(i + 1, i + 1) == "!" then
          -- Handle [!abc] character classes
          result = result .. "[^"
          i = i + 2
        end
        result = result .. pattern:sub(i, closing)
        i = closing + 1
      else
        -- No closing bracket found, treat as a normal character
        result = result .. "%["
        i = i + 1
      end
    elseif c == "/" or c == "\\" then
      -- Handle path separators uniformly
      result = result .. "[/\\]"
      i = i + 1
    else
      -- Normal characters
      result = result .. c
      i = i + 1
    end
  end

  if eol then
    result = result .. "$" -- Add ending anchor
  end

  return result
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

M.get_all_projects = function(patterns)
  -- Get all existing projects from patterns
  local projects = {}
  if patterns == nil then
    patterns = require("neovim-project.config").options.projects
  end
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

function M.init()
  M.datapath = vim.fn.expand(require("neovim-project.config").options.datapath)
  M.projectpath = M.datapath .. "/neovim-project" -- directory
  M.historyfile = M.projectpath .. "/history" -- file
  M.sessionspath = M.datapath .. "/neovim-sessions" --directory
  M.homedir = vim.fn.expand("~")
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

local find_longest_matched_pattern = function(patterns, dir, resolve)
  local longest_pattern = nil
  local longest_length = 0
  for _, pattern in ipairs(patterns) do
    local lua_pattern = wildcard_to_pattern(pattern, resolve, false)
    local startindex, endindex = dir:find(lua_pattern)
    if startindex ~= nil and endindex ~= nil then
      local len = endindex - startindex + 1
      if len > longest_length then
        longest_length = len
        longest_pattern = pattern
      end
    end
  end

  return longest_pattern
end

M.fix_symlinks_for_history = function(dirs)
  -- Replace paths with paths from `projects` option
  local patterns = require("neovim-project.config").options.projects
  local follow_symlinks = require("neovim-project.config").options.follow_symlinks

  if follow_symlinks == true or follow_symlinks == "full" then
    local projects = M.get_all_projects()
    for i, dir in ipairs(dirs) do
      local dir_resolved
      for _, path in ipairs(projects) do
        local path_resolved
        if dir_resolved == nil then
          if path_resolved == nil then
            if path == dir then
              dirs[i] = path
              break
            end
            path_resolved = M.resolve(path)
          end
          if path_resolved == dir then
            dirs[i] = path
            break
          end
          dir_resolved = M.resolve(dir)
        end
        if path_resolved == nil then
          if path == dir_resolved then
            dirs[i] = path
            break
          end
          path_resolved = M.resolve(path)
        end
        if path_resolved == dir_resolved then
          dirs[i] = path
          break
        end
      end
    end
  else
    local resolve
    if follow_symlinks == "partial" then
      resolve = true
    elseif not follow_symlinks or follow_symlinks == "none" then
      resolve = false
    end
    for i, dir in ipairs(dirs) do
      local dir_resolved
      for _, pattern in ipairs(patterns) do
        local lua_pattern = wildcard_to_pattern(pattern, resolve, true)
        local startindex, endindex
        if dir_resolved == nil then
          startindex, endindex = dir:find(lua_pattern)
          if startindex == nil or endindex == nil then
            dir_resolved = M.resolve(dir)
            startindex, endindex = dir_resolved:find(lua_pattern)
          end
        else
          startindex, endindex = dir_resolved:find(lua_pattern)
        end
        if startindex ~= nil and endindex ~= nil then
          local projects = M.get_all_projects({ pattern })
          for _, path in ipairs(projects) do
            if path == dir_resolved or M.resolve(path) == dir_resolved then
              dirs[i] = path
              break
            end
          end
          break
        end
      end
    end
  end
  -- remove duplicates
  return M.delete_duplicates(dirs)
end

M.chdir_closest_parent_project = function(dir)
  local patterns = require("neovim-project.config").options.projects
  local follow_symlinks = require("neovim-project.config").options.follow_symlinks

  -- returns the parent project and chdir to that parent
  -- if no parent project returns nil
  -- if dir is a project return dir
  local dir_resolved = dir or M.resolve(M.cwd())

  local parent
  if follow_symlinks == true or follow_symlinks == "full" then
    parent = find_closest_parent(M.get_all_projects(), dir_resolved)
  else
    local resolve
    if follow_symlinks == "partial" then
      resolve = true
    elseif not follow_symlinks or follow_symlinks == "none" then
      resolve = false
    end
    local pattern = find_longest_matched_pattern(patterns, dir_resolved, resolve)
    if pattern then
      parent = find_closest_parent(M.get_all_projects({ pattern }), dir_resolved)
    end
  end

  if parent then
    M.dir_pretty = M.short_path(parent) -- store path with user defined symlinks
    vim.api.nvim_set_current_dir(parent)
  end
  return parent
end

return M
