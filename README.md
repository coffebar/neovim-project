# 🗃️ Neovim project manager plugin

**Neovim project** plugin simplifies project management by maintaining project history and providing quick access to saved sessions via [Telescope](https://github.com/nvim-telescope/telescope.nvim), [fzf-lua](https://github.com/ibhagwan/fzf-lua), or ["snacks.nvim"](https://github.com/folke/snacks.nvim/). It runs on top of the [Neovim Session Manager](https://github.com/Shatur/neovim-session-manager), which is needed to store all open tabs and buffers for each project.

- ✅ Start where you left off last time.
- ✅ Switch from project to project in a second.
- ✅ Sessions and history can be synced across your devices (rsync, Syncthing, Nextcloud, Dropbox, etc.)
- ✅ Find all your projects by glob patterns defined in config.
- ✅ Autosave **neo-tree.nvim** expanded directories and buffers order in **barbar.nvim**.
- ✅ Choose your favorite picker.

![Neovim project manager plugin dracula theme](https://github.com/coffebar/neovim-project/assets/3100053/b75e9373-d694-48e4-abbf-3abfe98ae46f)

![Neovim project manager plugin onedark theme](https://github.com/coffebar/neovim-project/assets/3100053/2bc9b472-071c-4975-97b0-545bd1390053)

![Neovim project preview](https://github.com/user-attachments/assets/7a4aa83d-c57d-4e11-9702-88d4d174fe77)

🙏 **Neovim project manager** plugin is heavily inspired by [project.vim](https://github.com/ahmedkhalf/project.nvim)

## Usage

1. Set patterns in the [configuration](#%EF%B8%8F-configuration) to discover your projects.
2. Use [commands](#commands) to open your project. Or open Neovim in the project directory. Both methods will create a session.
3. Open files inside the project and work.
4. The session will be saved before closing Neovim or switching to another project via [commands](#commands).
5. Open Neovim in any non-project directory and the latest session will be loaded.

## 📦 Installation

You can install the plugin using your preferred package manager.

<details open><summary>Lazy.nvim</summary>

```lua
{
  "coffebar/neovim-project",
  opts = {
    projects = { -- define project roots
      "~/projects/*",
      "~/.config/*",
    },
    picker = {
      type = "telescope", -- one of "telescope", "fzf-lua", or "snacks"
    }
  },
  init = function()
    -- enable saving the state of plugins in the session
    vim.opt.sessionoptions:append("globals") -- save global variables that start with an uppercase letter and contain at least one lowercase letter.
  end,
  dependencies = {
    { "nvim-lua/plenary.nvim" },
    -- optional picker
    { "nvim-telescope/telescope.nvim", tag = "0.1.4" },
    -- optional picker
    { "ibhagwan/fzf-lua" },
    -- optional picker
    { "folke/snacks.nvim" },
    { "Shatur/neovim-session-manager" },
  },
  lazy = false,
  priority = 100,
},
```

</details>

<details><summary>packer.nvim</summary>

```lua
use({
  "coffebar/neovim-project",
  config = function()
    -- enable saving the state of plugins in the session
    vim.opt.sessionoptions:append("globals") -- save global variables that start with an uppercase letter and contain at least one lowercase letter.
    -- setup neovim-project plugin
    require("neovim-project").setup {
      projects = { -- define project roots
        "~/projects/*",
        "~/.config/*",
      },
      picker = {
      type = "telescope", -- one of "telescope", "fzf-lua", or "snacks"
      }
    }
  end,
  requires = {
    { "nvim-lua/plenary.nvim" },
    -- optional picker
    { "nvim-telescope/telescope.nvim", tag = "0.1.4" },
    -- optional picker
    { "ibhagwan/fzf-lua" },
    -- optional picker
    { "folke/snacks.nvim" },
    { "Shatur/neovim-session-manager" },
  }
})
```

</details>

<details><summary>pckr.nvim</summary>

```lua
{
  "coffebar/neovim-project",
  config = function()
    -- enable saving the state of plugins in the session
    vim.opt.sessionoptions:append("globals") -- save global variables that start with an uppercase letter and contain at least one lowercase letter.
    -- setup neovim-project plugin
    require("neovim-project").setup {
      projects = { -- define project roots
        "~/projects/*",
        "~/.config/*",
      },
      picker = {
        type = "telescope", -- one of "telescope", "fzf-lua", or "snacks"
      }
    }
  end,
  requires = {
    { "nvim-lua/plenary.nvim" },
    -- optional picker
    { "nvim-telescope/telescope.nvim", tag = "0.1.4" },
    -- optional picker
    { "ibhagwan/fzf-lua" },
    -- optional picker
    { "folke/snacks.nvim" },
    { "Shatur/neovim-session-manager" },
  }
};
```

</details>

## ⚙️ Configuration

### Default options:

```lua
{
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
      -- insert mode: Ctrl+d
      i = "<C-d>",
      -- normal mode: d
      n = "d"
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
  },
  -- Picker to use for project selection
  -- Options: "telescope", "fzf-lua", "snacks"
  -- Fallback to builtin select ui if the specified picker is not available
  picker = {
    type = "telescope", -- one of "telescope", "fzf-lua", or "snacks"

    preview = {
      enabled = true, -- show directory structure in Telescope preview
      git_status = true, -- show branch name, an ahead/behind counter, and the git status of each file/folder
      git_fetch = false, -- fetch from remote, used to display the number of commits ahead/behind, requires git authorization
      show_hidden = true, -- show hidden files/folders
    },
    opts = {
      -- picker-specific options
    },
  },
  
}
```

## Commands

Neovim project manager will add these commands:

- `:NeovimProjectDiscover [sort]` - find a project based on patterns, with optional sorting arguments:
  - `default` (or no argument) - uses the order specified in the config.
  - `history` - prioritises the most recently accessed projects.
  - `alphabetical_name` - sorts projects alphabetically by project name.
  - `alphabetical_path` - sorts projects alphabetically by their full path.

- `:NeovimProjectHistory` - select a project from your recent history.

- `:NeovimProjectLoadRecent` - open the previous session.

- `:NeovimProjectLoadHist` - opens the project from the history providing a project directory.

- `:NeovimProjectLoad` - opens the project from all your projects providing a project directory.

History is sorted by access time. "Discover" keeps order as you have in the config, but can be overridden using the sorting options.

#### Mappings

Use `Ctrl+d` in Telescope / fzf-lua / snacks.nvim to delete the project's session and remove it from the history.

## ⚡ Requirements

- Neovim >= 0.10.0
- Optional: Telescope.nvim for the Telescope picker
- Optional: fzf-lua for the fzf-lua picker
- Optional: snacks.nvim for the snacks.nvim picker

## Demo video

https://github.com/coffebar/neovim-project/assets/3100053/e88ae41a-5606-46c4-a287-4c476ed97ccc

## How to manage dotfiles repo

If you have a repository for your dotfiles, you will find it convenient to access them through projects.

Project pattern `~/.config/*` matches many programs config folders, including Neovim.
So when you need to edit Neovim config, you open project `~/.config/nvim` by typing "nv..". When you need to edit alacritty config - you start typing "ala.."

Of course, you want to use vim-fugitive and gitsigns in these projects. And it should be a single git repo for dotfiles. By default, Neovim will know nothing about your dotfiles repo.

Create autocommands to update env variables to tell Neovim where is your dotfiles bare repo. Here is an example from my dotfiles:

```lua
local augroup = vim.api.nvim_create_augroup("user_cmds", { clear = true })

local function update_git_env_for_dotfiles()
  -- Auto change ENV variables to enable
  -- bare git repository for dotfiles after
  -- loading saved session
  local home = vim.fn.expand("~")
  local git_dir = home .. "/dotfiles"

  if vim.env.GIT_DIR ~= nil and vim.env.GIT_DIR ~= git_dir then
    return
  end

  -- check dotfiles dir exists on current machine
  if vim.fn.isdirectory(git_dir) ~= 1 then
    vim.env.GIT_DIR = nil
    vim.env.GIT_WORK_TREE = nil
    return
  end

  -- check if the current working directory should belong to dotfiles
  local cwd = vim.loop.cwd()
  if vim.startswith(cwd, home .. "/.config/") or cwd == home or cwd == home .. "/.local/bin" then
    if vim.env.GIT_DIR == nil then
      -- export git location into ENV
      vim.env.GIT_DIR = git_dir
      vim.env.GIT_WORK_TREE = home
    end
  else
    if vim.env.GIT_DIR == git_dir then
      -- unset variables
      vim.env.GIT_DIR = nil
      vim.env.GIT_WORK_TREE = nil
    end
  end
end

vim.api.nvim_create_autocmd("DirChanged", {
  pattern = { "*" },
  group = augroup,
  desc = "Update git env for dotfiles after changing directory",
  callback = function()
    update_git_env_for_dotfiles()
  end,
})

vim.api.nvim_create_autocmd("User", {
  pattern = { "SessionLoadPost" },
  group = augroup,
  desc = "Update git env for dotfiles after loading session",
  callback = function()
    update_git_env_for_dotfiles()
  end,
})
```

This code should be required from your `init.lua` before plugins.

## 🤝 Contributing

- Open a ticket if you want integration with another plugin, or if you want to request a new feature.
- If you encounter bugs please open an issue.
- Pull requests are welcome. Follow the Conventional Commits specification for commit naming.
