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
  -- Enable per-branch session management
  -- When true, sessions are stored separately for each git branch
  -- Switching branches will automatically save current session and load branch-specific session
  per_branch_sessions = false,

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

  -- Save original dir_to_session_filename function BEFORE setup
  local session_manager_config = require("session_manager.config")
  local original_dir_to_session_filename = session_manager_config.dir_to_session_filename
  M.original_dir_to_session_filename = original_dir_to_session_filename

  -- Override dir_to_session_filename if per_branch_sessions is enabled
  -- Pass it as an option to setup() so it gets included in the metatable __index
  if M.options.per_branch_sessions then
    local git = require("neovim-project.utils.git")

    -- Override dir_to_session_filename to add branch suffix
    M.options.session_manager_opts.dir_to_session_filename = function(dir)
      -- Expand tilde in path for git commands
      local expanded_dir = vim.fn.expand(dir)
      local branch = git.get_git_branch(expanded_dir)
      if branch then
        -- Append branch to directory path with special separator
        local sanitized_branch = git.sanitize_branch_name(branch)
        local dir_with_branch = dir .. "@@branch@@" .. sanitized_branch
        -- Construct the path manually to avoid recursion
        local Path = require("plenary.path")
        local path_replacer = "__"
        local colon_replacer = "++"
        local filename = dir_with_branch:gsub(":", colon_replacer)
        filename = filename:gsub(Path.path.sep, path_replacer)
        return Path:new(session_manager_config.sessions_dir):joinpath(filename)
      else
        -- Not a git repo or detached HEAD - use regular session naming
        return original_dir_to_session_filename(dir)
      end
    end

    -- Override session_filename_to_dir to strip branch suffix
    local original_session_filename_to_dir = session_manager_config.session_filename_to_dir
    M.options.session_manager_opts.session_filename_to_dir = function(filename)
      -- Strip the @@branch@@ suffix before converting to dir
      local basename = filename:match("([^/]+)$") or filename
      local dir_part = basename:gsub("@@branch@@[^/]*$", "")

      -- Reconstruct filename without branch suffix for conversion
      local dir_name = filename:gsub(basename .. "$", dir_part)

      return original_session_filename_to_dir(dir_name)
    end
  end

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
