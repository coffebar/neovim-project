-- Hacking neo-tree to restore expanded dirs after session load

local M = {}

local path_util = require("neovim-project.utils.path")

M.dirs_to_restore = nil

function M.get_sources_manager()
  -- Require neo-tree sources manager
  local installed, src_manager = pcall(require, "neo-tree.sources.manager")
  if installed then
    return src_manager
  end
end

local function filesystem_state()
  -- Returns a table with filesystem source state of neo-tree
  local sm = M.get_sources_manager()
  if sm == nil then
    return nil
  end
  local ok, state = pcall(sm.get_state, "filesystem")
  if ok then
    return state
  else
    return nil
  end
end

function M.get_state_as_lua_string()
  -- Returns a string that can be used in lua code as value (table or nil)
  -- Value is a table of paths that were explicitly opened in neo-tree
  local state = filesystem_state()
  if state == nil and M.dirs_to_restore ~= nil then
    -- neo-tree was not opened yet, but we have dirs from the previous session
    state = { explicitly_opened_directories = {} }
    -- create a fake state
    for _, path in ipairs(M.dirs_to_restore) do
      state.explicitly_opened_directories[path] = true
    end
  end
  if state ~= nil and state.explicitly_opened_directories ~= nil then
    -- join all keys with a comma
    local cwd = vim.loop.cwd()
    local data = {}
    for k, v in pairs(state.explicitly_opened_directories) do
      if v then -- is opened
        if vim.startswith(k, cwd) then -- path belongs to current project directory
          k = path_util.short_path(k) -- short path for syncing
          k = vim.inspect(k) -- wrap in quotes and escape special characters
          table.insert(data, k)
        end
      end
    end
    return "{" .. table.concat(data, ",") .. "}"
  else
    return "nil"
  end
  -- output current state in command mode:
  -- lua print(require("neovim-project.utils.neo-tree").get_state_as_lua_string())
end

function M.restore_expanded(dirs)
  -- Call this function after session load
  local state = filesystem_state()
  local dirs_absolute = {}
  if state ~= nil and state.explicitly_opened_directories == nil then
    state.explicitly_opened_directories = {}
  end
  for _, path in ipairs(dirs) do
    path = vim.fn.expand(path)
    table.insert(dirs_absolute, path)
    -- save state in case user will not open neo-tree before exit session
    if state ~= nil then
      state.explicitly_opened_directories[path] = true
    end
  end

  -- Impossible to restore state until user opens neo-tree because tree is not built yet
  M.dirs_to_restore = dirs_absolute -- save dirs to restore later in autocmd
end

local function expand_node(path)
  -- Expand neo-tree node by absolute path
  local state = filesystem_state()
  if state == nil then
    return
  end
  local nui_tree = state.tree
  local node = nui_tree:get_node(path)
  if node ~= nil then
    -- state.explicitly_opened_directories[path] = true
    node:expand()
  end
end

function M.expand_dirs(dirs, state)
  -- Expand neo-tree directories recursively
  if #dirs == 0 then
    return
  end
  -- take the first path from the list
  local path_to_reveal = table.remove(dirs, 1)
  expand_node(path_to_reveal)
  -- refresh tree to load children
  state.commands["refresh"](state)
  -- repeat with the rest of the paths with interval for refreshing
  vim.defer_fn(function()
    M.expand_dirs(dirs, state)
  end, 50)
end

function M.autocmd_for_restore()
  if M.dirs_to_restore ~= nil then
    -- async delay to allow neo-tree to initialize
    vim.defer_fn(function()
      -- sort dirs by depths before expanding
      -- nodes with bigger depths are not in the tree yet
      table.sort(M.dirs_to_restore, function(a, b)
        local _, depth_a = string.gsub(a, "/", "")
        local _, depth_b = string.gsub(b, "/", "")
        return depth_a < depth_b
      end)
      local state = filesystem_state()
      if state == nil then
        return
      end

      if state.tree == nil then
        vim.notify("Neovim-project: neo-tree filesystem state.tree is not built yet", vim.log.levels.WARN)
        -- consider to increase delay
        return
      end
      -- save opened dirs to neo-tree state
      if state.explicitly_opened_directories == nil then
        state.explicitly_opened_directories = {}
      end
      for _, path in ipairs(M.dirs_to_restore) do
        state.explicitly_opened_directories[path] = true
      end
      -- start to expand dirs recursively
      M.expand_dirs(M.dirs_to_restore, state)
      -- clear saved dirs
      M.dirs_to_restore = nil
    end, 100)
  end
end

return M
