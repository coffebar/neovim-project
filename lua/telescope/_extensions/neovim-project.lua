local has_telescope, telescope = pcall(require, "telescope")

if not has_telescope then
  return
end

local finders = require("telescope.finders")
local pickers = require("telescope.pickers")
local telescope_config = require("telescope.config").values
local actions = require("telescope.actions")
local state = require("telescope.actions.state")
local entry_display = require("telescope.pickers.entry_display")
local previewers = require("telescope.previewers")

local path = require("neovim-project.utils.path")
local git_status = require("neovim-project.utils.git-status")
local history = require("neovim-project.utils.history")
local project = require("neovim-project.project")
local config = require("neovim-project.config")

-- Custom previewer that shows a clean directory listing
local project_previewer = previewers.new_buffer_previewer({
  title = "Project Preview",
  define_preview = function(self, entry, status)
    local project_path = vim.fn.expand(entry.value)

    -- Check if the directory exists
    if vim.fn.isdirectory(project_path) == 0 then
      vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, { "Directory not found: " .. project_path })
      return
    end

    -- Get directory contents
    local items = vim.fn.readdir(project_path)
    table.sort(items, function(a, b)
      local a_is_dir = vim.fn.isdirectory(project_path .. "/" .. a) == 1
      local b_is_dir = vim.fn.isdirectory(project_path .. "/" .. b) == 1

      -- Directories first, then alphabetical
      if a_is_dir and not b_is_dir then
        return true
      elseif not a_is_dir and b_is_dir then
        return false
      else
        return a < b
      end
    end)

    -- Format the output
    local output = {}
    table.insert(output, "")

    for _, item in ipairs(items) do
      -- Skip hidden files starting with .
      if not item:match("^%.") then
        local is_dir = vim.fn.isdirectory(project_path .. "/" .. item) == 1
        if is_dir then
          table.insert(output, "  📁 " .. item .. "/")
        else
          table.insert(output, "  📄 " .. item)
        end
      end
    end

    -- Display the output
    vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, output)
  end,
})
----------
-- Actions
----------

local function create_finder(discover)
  local results
  if discover then
    results = path.get_all_projects_with_sorting()
  else
    results = history.get_recent_projects()
    results = path.fix_symlinks_for_history(results)
    -- Reverse results
    for i = 1, math.floor(#results / 2) do
      results[i], results[#results - i + 1] = results[#results - i + 1], results[i]
    end
  end

  local displayer_config = {
    separator = " ",
    items = {
      {
        width = 30,
      },
      {
        remaining = true,
      },
    },
  }

  local function make_display(entry)
    if config.options.git_status then
      local uncommitted = git_status.get_status(entry.value)
      if uncommitted then
        displayer_config.separator = "* "
      else
        displayer_config.separator = "  "
      end
    end

    local displayer = entry_display.create(displayer_config)
    return displayer({ entry.name, { entry.value, "Comment" } })
  end

  return finders.new_table({
    results = results,
    entry_maker = function(entry)
      local name = vim.fn.fnamemodify(entry, ":t")
      return {
        display = make_display,
        name = name,
        value = entry,
        ordinal = name .. " " .. entry,
      }
    end,
  })
end

local function change_working_directory(prompt_bufnr)
  local selected_entry = state.get_selected_entry()
  if selected_entry == nil then
    actions.close(prompt_bufnr)
    return
  end
  local dir = selected_entry.value
  actions.close(prompt_bufnr)
  -- session_manager will change session
  project.switch_project(dir)
end

local function delete_project(prompt_bufnr)
  local selectedEntry = state.get_selected_entry()
  if selectedEntry == nil then
    actions.close(prompt_bufnr)
    return
  end
  local dir = selectedEntry.value
  local choice = vim.fn.confirm("Delete '" .. dir .. "' from project list?", "&Yes\n&No", 2)

  if choice == 1 then
    history.delete_project(dir)
    project.delete_session(dir)

    local finder = create_finder(false)
    state.get_current_picker(prompt_bufnr):refresh(finder, {
      reset_prompt = true,
    })
  end
end

---Main entrypoint for Telescope.
---@param opts table
local function project_history(opts)
  opts = opts or {}

  pickers
    .new(opts, {
      prompt_title = "Recent Projects",
      finder = create_finder(false),
      previewer = project_previewer,
      sorter = telescope_config.generic_sorter(opts),
      attach_mappings = function(prompt_bufnr, map)
        local config = require("neovim-project.config")
        local forget_project_keys = config.options.forget_project_keys
        if forget_project_keys then
          for mode, key in pairs(forget_project_keys) do
            map(mode, key, delete_project)
          end
        end

        local on_project_selected = function()
          change_working_directory(prompt_bufnr)
        end
        actions.select_default:replace(on_project_selected)
        return true
      end,
    })
    :find()
end

---@param opts table
local function project_discover(opts)
  opts = opts or {}

  pickers
    .new(opts, {
      prompt_title = "Discover Projects",
      finder = create_finder(true),
      previewer = project_previewer,
      sorter = telescope_config.generic_sorter(opts),
      attach_mappings = function(prompt_bufnr)
        local on_project_selected = function()
          change_working_directory(prompt_bufnr)
        end
        actions.select_default:replace(on_project_selected)
        return true
      end,
    })
    :find()
end
return telescope.register_extension({
  exports = {
    ["neovim-project"] = project_history,
    history = project_history,
    discover = project_discover,
  },
})
