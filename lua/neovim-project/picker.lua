local M = {}
local config = require("neovim-project.config")
local path = require("neovim-project.utils.path")
local history = require("neovim-project.utils.history")

local function get_picker_entries(discover)
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

  return results
end

local function confirm_deletion(discover, dir)
  if discover then
    vim.notify("Cannot delete projects from discovery mode", vim.log.levels.WARN)
    return false
  end

  local choice = vim.fn.confirm("Delete '" .. dir .. "' from project list?", "&Yes\n&No", 2)

  return choice == 1
end

-- Function to delete a project from the session and history
-- Does not delete the actual project directory
function M.delete_confirmed_project(dir)
  local project = require("neovim-project.project")
  project.delete_session(dir)
  history.delete_project(dir)
end

function M.create_picker(opts, discover, callback)
  local picker = config.options.picker.type
  local picker_opts = vim.tbl_deep_extend("force", config.options.picker.opts or {}, opts or {})

  if picker == "telescope" and pcall(require, "telescope") then
    return M.create_telescope_picker(picker_opts, discover)
  elseif picker == "fzf-lua" and pcall(require, "fzf-lua") then
    return M.create_fzf_lua_picker(picker_opts, discover, callback)
  elseif picker == "snacks" and Snacks ~= nil then
    return M.create_snacks_picker(picker_opts, discover, callback)
  else
    return M.create_builtin_picker(picker_opts, discover, callback)
  end
end

function M.create_telescope_picker(opts, discover)
  local telescope = require("telescope")
  if discover then
    return telescope.extensions["neovim-project"].discover(opts)
  else
    return telescope.extensions["neovim-project"].history(opts)
  end
end

function M.create_fzf_lua_picker(opts, discover, callback)
  local fzf = require("fzf-lua")

  local function format_entry(entry)
    local name = vim.fn.fnamemodify(entry, ":t")
    return string.format("%s\t%s", name, entry)
  end

  local results = get_picker_entries(discover)
  local formatted_results = vim.tbl_map(format_entry, results)

  -- Default options
  local default_opts = {
    prompt = discover and "Discover Projects> " or "Recent Projects> ",
    actions = {
      ["default"] = function(selected)
        if selected and #selected > 0 then
          local dir = selected[1]:match("\t(.+)$")
          callback(dir)
        end
      end,
      ["ctrl-d"] = function(selected)
        if selected and #selected > 0 then
          local dir = selected[1]:match("\t(.+)$")
          local confirmed = confirm_deletion(discover, dir)
          if confirmed then
            M.delete_confirmed_project(dir)
            -- Refresh the picker
            M.create_fzf_lua_picker(opts, discover, callback)
          end
        end
      end,
    },
    fzf_opts = {
      ["--delimiter"] = "\t",
      ["--with-nth"] = "1",
      ["--preview"] = "echo {}",
      ["--preview-window"] = "hidden:right:0",
    },
  }

  local merged_opts = vim.tbl_deep_extend("force", default_opts, opts or {})

  fzf.fzf_exec(formatted_results, merged_opts)
end

function M.create_snacks_picker(opts, discover, callback)
  local function make_item(text)
    return {
      text = text,
      file = text,
      dir = true,
    }
  end

  local title = "neovim-project"
  if discover then
    title = title .. " (Discover Projects)"
  else
    title = title .. " (Recent Projects)"
  end

  local results = get_picker_entries(discover)

  local default_opts = {
    source = "neovim-project",
    title = title,
    items = results,
    format = "filename",
    transform = make_item,
    confirm = function(_, item)
      if item then
        callback(Snacks.picker.util.dir(item))
      end
    end,
    actions = {
      delete_project = function(picker, item)
        local dir = item.file
        local confirmed = confirm_deletion(discover, dir)
        if confirmed then
          M.delete_confirmed_project(dir)

          -- Remove from the list and refresh
          table.remove(results, item.idx)
          picker:find()
        end
      end,
    },
    win = {
      input = {
        keys = {
          ["<C-d>"] = { "delete_project", mode = { "i", "n" } },
        },
      },
      list = {
        keys = {
          ["<C-d>"] = { "delete_project", mode = { "i", "n" } },
        },
      },
    },
  }

  local merged_opts = vim.tbl_deep_extend("force", default_opts, opts or {})

  Snacks.picker.pick(merged_opts)
end

function M.create_builtin_picker(opts, discover, callback)
  local results = get_picker_entries(discover)

  local default_opts = {
    prompt = discover and "Discover Projects" or "Recent Projects",
    format_item = function(item)
      return vim.fn.fnamemodify(item, ":t") .. " (" .. item .. ")"
    end,
  }

  local merged_opts = vim.tbl_deep_extend("force", default_opts, opts or {})

  local function select_project()
    vim.ui.select(results, merged_opts, function(choice)
      if choice then
        callback(choice)
      end
    end)
  end

  local function delete_project()
    vim.ui.select(results, {
      prompt = "Select project to delete",
      format_item = merged_opts.format_item,
    }, function(choice)
      if choice then
        local confirm = vim.fn.confirm("Delete '" .. choice .. "' from project list?", "&Yes\n&No", 2)
        if confirm == 1 then
          M.delete_confirmed_project(choice)
          -- Refresh the picker
          M.create_builtin_picker(opts, discover, callback)
        else
          -- Go back to project selection
          select_project()
        end
      end
    end)
  end

  -- Add an option to delete projects
  vim.ui.select({ "Select Project", "Delete Project" }, {
    prompt = "Choose an action",
  }, function(choice)
    if choice == "Select Project" then
      select_project()
    elseif choice == "Delete Project" then
      delete_project()
    end
  end)
end

return M
