--- Workaround for plugin https://github.com/nvzone/showkeys
---
--- Close the plugin window before switching projects
--- and reopen it after
---

local M = {}

local showkeys_visible = false

M.post_load = function()
  if not showkeys_visible then
    return
  end
  local has_showkeys, showkeys = pcall(require, "showkeys")
  if has_showkeys and type(showkeys) == "table" and type(showkeys.open) == "function" then
    showkeys.open()
  end
end

M.pre_save = function()
  local has_state, state = pcall(require, "showkeys.state")
  if not has_state then
    return
  end
  local has_showkeys, showkeys = pcall(require, "showkeys")
  if not has_showkeys then
    return
  end
  if type(state) == "table" and type(showkeys.close) == "function" then
    showkeys_visible = state.visible
    if showkeys_visible then
      showkeys.close()
    end
  end
end

return M
