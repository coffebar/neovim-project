local path = require("neovim-project.utils.path")
local uv = vim.loop
local M = {}

M.recent_projects = nil -- projects from previous neovim sessions
M.session_projects = {} -- projects from current neovim session
M.has_watch_setup = false

local function open_history(mode, callback)
  if callback ~= nil then -- async
    path.create_scaffolding(function(_, _)
      uv.fs_open(path.historyfile, mode, 438, callback)
    end)
  else -- sync
    path.create_scaffolding()
    return uv.fs_open(path.historyfile, mode, 438)
  end
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
  open_history("r", function(_, fd)
    setup_watch()
    if fd ~= nil then
      uv.fs_fstat(fd, function(_, stat)
        if stat ~= nil then
          uv.fs_read(fd, stat.size, -1, function(_, data)
            uv.fs_close(fd, function(_, _) end)
            deserialize_history(data)
          end)
        end
      end)
    end
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

  tbl = delete_duplicates(tbl)

  local real_tbl = {}
  for _, dir in ipairs(tbl) do
    if dir_exists(dir) then
      table.insert(real_tbl, dir)
    end
  end

  return real_tbl
end

function M.get_recent_projects()
  return sanitize_projects()
end

M.write_projects_to_history = function()
  -- Unlike read projects, write projects is synchronous
  -- because it runs when vim ends
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
