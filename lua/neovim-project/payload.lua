-- Module uses global variable to store additional data inside session file
-- It's required to add this line to config:
-- vim.opt.sessionoptions:append("globals")
--
local neotree_util = require("neovim-project.utils.neo-tree")
local M = {}

--- @class Payload
local Payload = {
  -- @type "string"
  neotree_opened_directories = "nil", -- store neo-tree explicitly opened directories
  --
  -- add more plugins here
}

function M.store(
  payload --[[Payload]]
)
  -- Must be called prior to session save

  -- convert table to lua code string
  vim.g.NeovimProjectPayload__session_restore =
    string.format("return { neotree_opened_directories = %s, }", payload.neotree_opened_directories)
end

function M.restore(
  payload --[[Payload]]
)
  if payload == nil then
    return
  end
  if payload.neotree_opened_directories ~= nil then
    neotree_util.restore_expanded(payload.neotree_opened_directories)
  end
end

function M.load_post()
  -- Must be called after session load
  if vim.g.NeovimProjectPayload__session_restore ~= nil then
    -- convert lua code string to table
    local load_func
    if vim.fn.has("nvim-0.5") == 1 then
      load_func = load(vim.g.NeovimProjectPayload__session_restore)
    else
      load_func = loadstring(vim.g.NeovimProjectPayload__session_restore)
    end
    -- local load_func = loadstring(vim.g.NeovimProjectPayload__session_restore)
    if load_func ~= nil then
      M.restore(load_func())
    end
    vim.g.NeovimProjectPayload__session_restore = nil -- clear global variable
  end
end

function M.pre_save()
  -- Must be called prior to session save
  M.store({
    -- expanded neo-tree directories
    neotree_opened_directories = neotree_util.get_state_as_lua_string(),
  })
end

return M
