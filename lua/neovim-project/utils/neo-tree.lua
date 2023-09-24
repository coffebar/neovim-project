-- Hacking neo-tree to restore expanded dirs after session load

local M = {}

local path_util = require("neovim-project.utils.path")

M.dirs_to_restore = nil

local function filesystem_state()
  -- Returns a table with filesystem source state of neo-tree
  local installed, sm = pcall(require, "neo-tree.sources.manager")
  if not installed or sm == nil then
    return nil
  end
  local ok, state = pcall(sm.get_state, "filesystem")
  if ok then
    return state
  else
    return nil
  end
end

local function after_render()
  if M.dirs_to_restore ~= nil and #M.dirs_to_restore > 0 then
    local state = filesystem_state()
    if state == nil then
      return
    end

    local nui_tree = state.tree
    if nui_tree == nil then
      -- filesystem source is not ready.
      -- probably, neo-tree is opened with another source
      return
    end
    if state.explicitly_opened_directories == nil then
      state.explicitly_opened_directories = {}
    end
    local dir = table.remove(M.dirs_to_restore, 1)
    state.explicitly_opened_directories[dir] = true
    local node = nui_tree:get_node(dir)
    if node ~= nil then
      node:expand()
    end
    -- refresh tree to load children
    state.commands["refresh"](state)
  end
end

function M.get_state_as_lua_string()
  -- Returns a string that can be used in lua code as value (table or nil)
  -- Value is a table of paths that were explicitly opened in neo-tree
  local state = filesystem_state()
  -- create table dirs_to_restore from state.explicitly_opened_directories and M.dirs_to_restore
  local restore = {}

  if M.dirs_to_restore ~= nil then
    for _, path in ipairs(M.dirs_to_restore) do
      restore[path] = true
    end
  end
  if state ~= nil and state.explicitly_opened_directories ~= nil then
    for path, opened in pairs(state.explicitly_opened_directories) do
      if opened then
        restore[path] = true
      end
    end
  end

  if vim.tbl_count(restore) > 0 then
    -- join all keys with a comma
    local cwd = vim.loop.cwd()
    local data = {}
    for dir, _ in pairs(restore) do
      if vim.startswith(dir, cwd) then -- path belongs to current project directory
        dir = path_util.short_path(dir) -- short path for syncing
        dir = vim.inspect(dir) -- wrap in quotes and escape special characters
        table.insert(data, dir)
      end
    end
    return "{" .. table.concat(data, ",") .. "}"
  else
    return "nil"
  end
  -- output current state in command mode:
  -- lua print(require("neovim-project.utils.neo-tree").get_state_as_lua_string())
end

function M.restore_expanded(dirs_relative)
  -- Call this function after session load
  if #dirs_relative == 0 then
    return
  end
  local dirs_absolute = {}
  for _, path in ipairs(dirs_relative) do
    path = vim.fn.expand(path)
    table.insert(dirs_absolute, path)
  end

  -- sort dirs by depths before expanding
  -- nodes with bigger depths are not in the tree until parent is expanded
  table.sort(dirs_absolute, function(a, b)
    local _, depth_a = string.gsub(a, "/", "")
    local _, depth_b = string.gsub(b, "/", "")
    return depth_a < depth_b
  end)

  -- Impossible to restore state until user opens neo-tree because tree is not built yet
  M.dirs_to_restore = dirs_absolute -- save dirs to restore later in autocmd
end

function M.setup_events_for_neotree()
  local installed, events = pcall(require, "neo-tree.events")
  if not installed then
    vim.notify("Neovim-project: neo-tree.events is not found", vim.log.levels.WARN)
    return
  end
  events.subscribe({
    event = events.AFTER_RENDER,
    handler = after_render,
  })
end

return M
