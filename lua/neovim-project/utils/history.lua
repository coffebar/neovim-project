local path = require("neovim-project.utils.path")
local uv = vim.loop
local M = {}

M.recent_projects = nil -- projects from previous neovim sessions
M.session_projects = {} -- projects from current neovim session
M.has_watch_setup = false -- file change watch has been setup
M.history_read = false -- history has been read at least once

local function open_history(mode)
  path.create_scaffolding()
  return uv.fs_open(path.historyfile, mode, 438)
end

local function dir_exists(dir)
  dir = dir:gsub("^~", path.homedir)
  local stat = uv.fs_stat(dir)
  if stat ~= nil and stat.type == "directory" then
    return true
  end
  return false
end

M.add_session_project = function(dir)
  table.insert(M.session_projects, dir)
end

M.delete_project = function(dir)
  for k, v in pairs(M.recent_projects) do
    if v == dir then
      M.recent_projects[k] = nil
    end
  end
  for k, v in pairs(M.session_projects) do
    if v == dir then
      M.session_projects[k] = nil
    end
  end
end

local function deserialize_history(history_data)
  -- split data to table
  local projects = {}
  for s in history_data:gmatch("[^\r\n]+") do
    if dir_exists(s) then
      table.insert(projects, s)
    end
  end

  M.recent_projects = path.delete_duplicates(projects)
end

local function setup_watch()
  -- Only runs once
  if M.has_watch_setup == false then
    M.has_watch_setup = true
    local event = uv.new_fs_event()
    if event == nil then
      return
    end
    event:start(path.projectpath, {}, function(err, _, events)
      if err ~= nil then
        return
      end
      if events["change"] then
        M.recent_projects = nil
        M.read_projects_from_history()
      end
    end)
  end
end

M.read_projects_from_history = function()
  local file = open_history("r")
  setup_watch()
  if file == nil then
    M.history_read = true
    return
  end
  uv.fs_fstat(file, function(_, stat)
    if stat == nil then
      M.history_read = true
      return
    end
    uv.fs_read(file, stat.size, -1, function(_, data)
      uv.fs_close(file, function(_, _) end)
      deserialize_history(data)
      M.history_read = true
    end)
  end)
end

local function sanitize_projects()
  local tbl = {}
  if M.recent_projects ~= nil then
    vim.list_extend(tbl, M.recent_projects)
    vim.list_extend(tbl, M.session_projects)
  else
    tbl = M.session_projects
  end

  tbl = path.delete_duplicates(tbl)

  local real_tbl = {}
  for _, dir in ipairs(tbl) do
    if dir_exists(dir) then
      table.insert(real_tbl, dir)
    end
  end

  return real_tbl
end

function M.get_recent_projects()
  M.make_sure_read_projects_from_history()
  return sanitize_projects()
end

function M.get_most_recent_project()
  local projects = M.get_recent_projects()
  if #projects > 0 then
    return projects[#projects]
  end
  return nil
end

function M.make_sure_read_projects_from_history()
  if M.history_read == false then
    M.read_projects_from_history()
    vim.wait(200, function()
      return M.history_read
    end)
  end
end

M.write_projects_to_history = function()
  -- Write projects is synchronous
  -- because it runs when vim ends
  M.make_sure_read_projects_from_history()
  local mode = "w"
  if M.recent_projects == nil then
    mode = "a"
  end
  local file = open_history(mode)

  if file ~= nil then
    local res = sanitize_projects()

    -- Trim table to last 100 entries
    local len_res = #res
    local tbl_out
    if #res > 100 then
      tbl_out = vim.list_slice(res, len_res - 100, len_res)
    else
      tbl_out = res
    end

    -- Transform table to string
    local out = ""
    for _, v in ipairs(tbl_out) do
      out = out .. v .. "\n"
    end

    -- Write string out to file and close
    uv.fs_write(file, out, -1)
    uv.fs_close(file)
  end
end

return M
