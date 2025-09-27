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
  -- Load the most recent session on startup if not in the project directory
  last_session_on_startup = true,
  -- Dashboard mode prevent session autoload on startup
  dashboard_mode = false,
  -- Timeout in milliseconds before trigger FileType autocmd after session load
  -- to make sure lsp servers are attached to the current buffer.
  -- Set to 0 to disable triggering FileType autocmd
  filetype_autocmd_timeout = 200,
  -- Keymap to delete project from history in Telescope picker
  forget_project_keys = {
    -- insert mode
    i = "<C-d>",
    -- normal mode
    n = "d",
  },
  -- Follow symbolic links in glob patterns (affects startup speed)
  -- "full" or true - follow symlinks in all matched directories
  -- "partial" - follow symlinks before any matching operators (*, ?, [])
  -- "none" or false or nil - do not follow symlinks
  follow_symlinks = "full",

  -- Overwrite some of Session Manager options
  session_manager_opts = {
    autosave_ignore_dirs = {
      vim.fn.expand("~"), -- don't create a session for $HOME/
      "/tmp",
    },
    autosave_ignore_filetypes = {
      -- All buffers of these file types will be closed before the session is saved
      "ccc-ui",
      "dap-repl",
      "dap-view",
      "dap-view-term",
      "gitcommit",
      "gitrebase",
      "qf",
      "toggleterm",
    },
    -- keep these as is
    autosave_last_session = true,
    autosave_only_in_session = true,
    autosave_ignore_not_normal = false,
  },

  -- Picker to use for project selection
  -- Options: "telescope", "fzf-lua"
  -- Fallback to builtin select ui if the specified picker is not available
  picker = {
    type = "telescope", -- or "fzf-lua"
    preview = {
      enabled = true, -- show directory structure in Telescope preview
      git_status = true, -- show branch name and the git status of each file/folder
      git_fetch = false, -- fetch from remote, used to display the number of commits ahead/behind, requires git authorization
      show_hidden = true, -- show hidden files/folders
    },
    opts = {
      -- picker-specific options
    },
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
  -- Disable session autoload by default
  M.options.session_manager_opts.autoload_mode = AutoLoadMode.Disabled

  -- Don't load a session if nvim started with args, open just given files
  if vim.fn.argc() == 0 and not M.options.dashboard_mode then
    local cmd = require("neovim-project.utils.cmd")
    local is_man = cmd.check_open_cmd("+Man!")

    if
      not is_man and (path.chdir_closest_parent_project() or path.chdir_closest_parent_project(path.resolve("%:p")))
    then
      -- nvim started in the project dir or sub project , open current dir session
      start_session_here = true
    else
      -- Open the recent session if not disabled from config
      if M.options.last_session_on_startup then
        M.options.session_manager_opts.autoload_mode = AutoLoadMode.LastSession
      end
    end
  end

  M.options.session_manager_opts.sessions_dir = path.sessionspath

  -- Session Manager setup
  require("session_manager").setup(M.options.session_manager_opts)

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
