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

local path = require("neovim-project.utils.path")
local history = require("neovim-project.utils.history")
local project = require("neovim-project.project")

----------
-- Actions
----------

local function create_finder(discover)
  local results
  if discover then
    results = path.get_all_projects()
  else
    results = history.get_recent_projects()
    -- Reverse results
    for i = 1, math.floor(#results / 2) do
      results[i], results[#results - i + 1] = results[#results - i + 1], results[i]
    end
  end

  local displayer = entry_display.create({
    separator = " ",
    items = {
      {
        width = 30,
      },
      {
        remaining = true,
      },
    },
  })

  local function make_display(entry)
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
  local project_path = selected_entry.value
  actions.close(prompt_bufnr)
  -- session_manager will change session
  if not project.in_session() then
    -- switch project without saving current session
    project.load_session(project_path)
  else
    project.switch_after_save_session(project_path)
  end
end

local function delete_project(prompt_bufnr)
  local selectedEntry = state.get_selected_entry()
  if selectedEntry == nil then
    actions.close(prompt_bufnr)
    return
  end
  local choice = vim.fn.confirm("Delete '" .. selectedEntry.value .. "' from project list?", "&Yes\n&No", 2)

  if choice == 1 then
    history.delete_project(selectedEntry.value)
    project.delete_session(selectedEntry.value)

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
      previewer = false,
      sorter = telescope_config.generic_sorter(opts),
      attach_mappings = function(prompt_bufnr, map)
        map("n", "d", delete_project)
        map("i", "<c-d>", delete_project)

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
      previewer = false,
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
