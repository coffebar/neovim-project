local M = {}

-- Log file path
local log_file = vim.fn.stdpath("data") .. "/neovim-project-debug.log"

-- Enable/disable logging
M.enabled = true

--- Log a message to file
--- @param message string The message to log
--- @param context string|nil Optional context (e.g., function name)
M.log = function(message, context)
  if not M.enabled then
    return
  end

  local timestamp = os.date("%Y-%m-%d %H:%M:%S")
  local prefix = context and ("[" .. context .. "] ") or ""
  local log_line = string.format("[%s] %s%s\n", timestamp, prefix, message)

  local file = io.open(log_file, "a")
  if file then
    file:write(log_line)
    file:close()
  end
end

--- Clear the log file
M.clear = function()
  local file = io.open(log_file, "w")
  if file then
    file:close()
  end
end

--- Get the log file path
M.get_path = function()
  return log_file
end

return M
