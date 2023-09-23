local M = {}

---@class ProjectOptions
M.defaults = {
  -- Project directories
  projects = {
    "~/projects/*",
    "~/p*cts/*", -- glob pattern is supported
    "~/projects/repos/*",
    "~/.config/*",
    "~/work/*",
  },
  -- Path to store history and sessions
  datapath = vim.fn.stdpath("data"), -- ~/.local/share/nvim/

  -- Overwrite some of Session Manager options
  session_manager_opts = {
    autosave_ignore_dirs = {
      vim.fn.expand("~"), -- don't create a session for $HOME/
      "/tmp",
    },
    autosave_ignore_filetypes = {
      -- All buffers of these file types will be closed before the session is saved
      "ccc-ui",
      "gitcommit",
      "gitrebase",
      "qf",
    },
    -- keep these as is
    autosave_last_session = true,
    autosave_only_in_session = true,
    autosave_ignore_not_normal = false,
  },
}

---@type ProjectOptions
M.options = {}

M.setup = function(options)
  M.options = vim.tbl_deep_extend("force", M.defaults, options or {})

  vim.opt.autochdir = false -- implicitly unset autochdir

  local path = require("neovim-project.utils.path")
  path.init()
  local project = require("neovim-project.project")
  project.init()

  local start_session_here = false -- open or create session in current dir

  local session_manager_config = require("session_manager.config")
  local AutoLoadMode = session_manager_config.AutoloadMode
  if vim.fn.argc() > 0 then
    -- if nvim started with args, disable autoload
    -- open just given files
    M.options.session_manager_opts.autoload_mode = AutoLoadMode.Disabled
  else
    -- if nvim started in project dir, open project's session
    if path.cwd_matches_project() then
      M.options.session_manager_opts.autoload_mode = AutoLoadMode.Disabled
      start_session_here = true
    else
      -- open last session
      M.options.session_manager_opts.autoload_mode = AutoLoadMode.LastSession
    end
  end

  M.options.session_manager_opts.sessions_dir = path.sessionspath

  -- Session Manager setup
  require("session_manager").setup(M.options.session_manager_opts)

  -- Register Telescope extension
  require("telescope").load_extension("neovim-project")

  -- unset session_manager_opts
  ---@diagnostic disable-next-line: inject-field
  M.options.session_manager_opts = nil

  if start_session_here then
    project.start_session_here()
  end

  -- unregister SessionManager command
  if vim.fn.exists(":SessionManager") == 2 then
    vim.api.nvim_del_user_command("SessionManager")
  else
    -- defer is needed on Packer
    vim.defer_fn(function()
      if vim.fn.exists(":SessionManager") == 2 then
        vim.api.nvim_del_user_command("SessionManager")
      end
    end, 100)
  end
end

return M

-- 1. If nvim started with args, disable autoload. On project switch - close all buffers and load session
-- 2. If nvim started in project dir, open project's session. If session does not exist - create it
-- 3. Else open last session. If no sessions: not create and close all buffers prior to project switch.
