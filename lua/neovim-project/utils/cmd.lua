local M = {}

M.check_open_cmd = function(cmd)
  local open_cmd = vim.fn.split(vim.fn.readfile("/proc/self/cmdline")[1], "\n", 1)
  local found = false

  for _, arg in ipairs(open_cmd) do
    if arg == cmd then
      found = true
    end
  end
  return found
end

return M
