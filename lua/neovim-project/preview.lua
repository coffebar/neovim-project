local M = {}

local previewers = require("telescope.previewers")
local config = require("neovim-project.config")
local history = require("neovim-project.utils.history")

local initialized = false
local preview_cache = {}
local fetched = {}

local function expand_path(project_path)
  project_path = vim.fn.expand(project_path)
  project_path = vim.fn.fnamemodify(project_path, ":p")
  project_path = project_path:gsub("[/\\]$", "")
  return project_path
end

local function clear_caches()
  local current_project = expand_path(history.get_current_project())
  preview_cache[current_project] = nil
  fetched[current_project] = nil
end

function M.define_preview_highlighting()
  local normal_bg = vim.fn.synIDattr(vim.fn.hlID("Normal"), "bg#")
  local branch_bg = vim.fn.synIDattr(vim.fn.hlID("Function"), "fg#")
  local title_bg = vim.fn.synIDattr(vim.fn.hlID("Constant"), "fg#")
  local added_fg = vim.fn.synIDattr(vim.fn.hlID("Added"), "fg#")
  local changed_fg = vim.fn.synIDattr(vim.fn.hlID("Changed"), "fg#")
  local removed_fg = vim.fn.synIDattr(vim.fn.hlID("Removed"), "fg#")
  -- fallback, not all themes have Function
  if not branch_bg or branch_bg == "" then
    branch_bg = vim.fn.synIDattr(vim.fn.hlID("Statement"), "fg#")
  end

  vim.api.nvim_set_hl(0, "NeovimProjectTitle", {
    bg = title_bg,
    fg = normal_bg,
    bold = true,
  })

  vim.api.nvim_set_hl(0, "NeovimProjectBranch", {
    bg = branch_bg,
    fg = normal_bg,
    bold = true,
  })

  vim.api.nvim_set_hl(0, "NeovimProjectAdded", {
    bg = normal_bg,
    fg = added_fg,
  })

  vim.api.nvim_set_hl(0, "NeovimProjectChanged", {
    bg = normal_bg,
    fg = changed_fg,
  })

  vim.api.nvim_set_hl(0, "NeovimProjectRemoved", {
    bg = normal_bg,
    fg = removed_fg,
  })
end

M.init = function()
  M.define_preview_highlighting()
  clear_caches()

  -- autocmd to enforce proper highlighting when changing colorschemes
  vim.api.nvim_create_autocmd("ColorScheme", {
    callback = function()
      local preview = require("neovim-project.preview")
      preview.define_preview_highlighting()
    end,
    group = vim.api.nvim_create_augroup("NeovimProjectHighlights", { clear = true }),
  })

  -- Set up an autocmd to clear caches periodically
  vim.api.nvim_create_autocmd({ "FocusGained", "BufEnter" }, {
    callback = function()
      clear_caches()
    end,
    group = vim.api.nvim_create_augroup("NeovimProjectCacheClear", { clear = true }),
  })
end

--- Stolen from oil.nvim
--- Check for an icon provider and return a common icon provider API
local function get_icon_provider()
  -- prefer mini.icons
  local _, mini_icons = pcall(require, "mini.icons")
  ---@diagnostic disable-next-line: undefined-field
  if _G.MiniIcons then -- `_G.MiniIcons` is a better check to see if the module is setup
    return function(type, name)
      return mini_icons.get(type, name)
    end
  end

  -- fallback to `nvim-web-devicons`
  local has_devicons, devicons = pcall(require, "nvim-web-devicons")
  if has_devicons then
    return function(type, name, conf)
      if type == "directory" then
        return conf and conf.directory or "", "OilDirIcon"
      else
        local icon, hl = devicons.get_icon(name)
        icon = icon or (conf and conf.default_file or "")
        return icon, hl
      end
    end
  end
end

local icon_provider = get_icon_provider() or function(_, _, _)
  return "", ""
end

-- Custom previewer that shows the contents of the project directory
M.project_previewer = previewers.new_buffer_previewer({
  title = "Project Preview",
  get_buffer_by_name = function(_, entry)
    return entry.value
  end,
  define_preview = function(self, entry)
    if not initialized then
      M.init()
      initialized = true
    end

    local project_path = entry.value

    -- Process path to make it usable
    project_path = expand_path(project_path)
    -- Create a timer for debouncing preview generation
    if not self._preview_timer then
      self._preview_timer = vim.loop.new_timer()
    else
      -- Cancel any pending preview generation
      self._preview_timer:stop()
    end

    local function render_preview()
      -- Check if the buffer still exists
      if vim.api.nvim_buf_is_valid(self.state.bufnr) then
        if not preview_cache[project_path] then
          preview_cache[project_path] = M.generate_project_preview(project_path)
        end
        -- Display the output
        vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, preview_cache[project_path].lines)

        -- Apply highlights
        local ns_id = vim.api.nvim_create_namespace("neovim_project_preview")
        vim.api.nvim_buf_clear_namespace(self.state.bufnr, ns_id, 0, -1)

        for _, hl_info in ipairs(preview_cache[project_path].highlights) do
          vim.api.nvim_buf_add_highlight(
            self.state.bufnr,
            ns_id,
            hl_info.hl,
            hl_info.line,
            hl_info.start_col,
            hl_info.end_col
          )
        end
      end
    end
    if preview_cache[project_path] then
      render_preview()
    else
      self._preview_timer:start(33, 0, vim.schedule_wrap(render_preview))
    end
  end,
})

-- Get the current git branch and status for a project path
local function get_git_info(project_path)
  local current_dir = vim.fn.getcwd()
  local result = {
    is_repo = false,
    branch = "",
    ahead = 0,
    behind = 0,
    status = "",
  }

  vim.fn.chdir(project_path)

  -- Get branch name
  local is_git_repo = vim.fn.system("git rev-parse --is-inside-work-tree"):match("true")
  if not is_git_repo then
    vim.fn.chdir(current_dir)
    return result
  end

  result.is_repo = true

  local branch_name = vim.fn.system("git branch --show-current"):gsub("\n", "")

  -- Only proceed if we have a valid branch
  if branch_name ~= "" then
    result.branch = branch_name

    -- Fetch remote information for accurate ahead/behind counters
    -- Done asynchronously to prevent freezing UI
    -- This will fetch once per project during a particular nvim session
    -- This wipes the cache for a project, so it will force a regeneration of the preview when it is viewed again
    if not fetched[project_path] then
      local fetch_job_id = vim.fn.jobstart("git fetch --quiet", {
        cwd = project_path,
        detach = false,
        on_exit = function(_, _, _)
          -- Clear preview cache to refresh the ahead/behind counts
          preview_cache[project_path] = nil
          fetched[project_path] = true

          -- These commands are idempotent, it is harmless to spam them
          -- They enable maintenance and fsmonitor, optimizations that speed up fetch and status commands on large repos, and are harmless on small ones
          vim.fn.system("git -C config core.fsmonitor builtin")
          vim.fn.system("git -C maintenance start")
        end,
      })
    end

    -- Get ahead/behind counts - use plumbing commands for better performance
    local status_output =
      vim.fn.system("git rev-list --left-right --count origin/" .. branch_name .. "..." .. branch_name .. " ")

    -- Parse the output which is in format "N M" where N is behind and M is ahead
    local behind, ahead = status_output:match("(%d+)%s+(%d+)")
    if tonumber(behind) then
      result.behind = tonumber(behind)
    end
    if tonumber(ahead) then
      result.ahead = tonumber(ahead)
    end
  end

  result.status = vim.fn.system("git status --porcelain=v1")

  vim.fn.chdir(current_dir)

  return result
end

-- Generate header for project preview
local function generate_preview_header(project_path)
  local header = {}
  local header_highlights = {}
  local project_title = vim.fn.fnamemodify(project_path, ":t")
  -- Add padding spaces for better appearance with background color

  local title_string = " " .. project_title .. " "
  local formatted_header = title_string

  local title_width = #title_string
  local title_start = 0
  local title_end = title_start + title_width

  table.insert(header_highlights, {
    line = 0, -- 0-indexed line number
    hl = "NeovimProjectTitle", -- Use our custom highlight group
    start_col = title_start,
    end_col = title_end,
  })
  local git_info = {}
  if config.options.picker.preview.git_status then
    git_info = get_git_info(project_path)
    if git_info.is_repo then
      local branch_icon = icon_provider("filetype", "git", {
        default_file = "",
      })
      local branch_string = " " .. branch_icon .. " " .. git_info.branch .. " "

      local ahead = ""
      local behind = ""
      if git_info.ahead > 0 then
        ahead = "↑" .. git_info.ahead
      end
      if git_info.behind > 0 then
        behind = "↓" .. git_info.behind
      end
      local sync_string = " " .. behind .. ahead .. " "
      formatted_header = formatted_header .. branch_string .. sync_string

      local branch_width = #branch_string
      local branch_start = title_end
      local branch_end = branch_start + branch_width

      local sync_width = #sync_string
      local sync_start = branch_end
      local sync_end = sync_start + sync_width
      table.insert(header_highlights, {
        line = 0, -- 0-indexed line number
        hl = "NeovimProjectBranch", -- Use our custom highlight group
        start_col = branch_start,
        end_col = branch_end,
      })

      table.insert(header_highlights, {
        line = 0, -- 0-indexed line number
        hl = "NeovimProjectChanged", -- Use our custom highlight group
        start_col = sync_start,
        end_col = sync_end,
      })
    end
  end

  table.insert(header, formatted_header)

  return { lines = header, highlights = header_highlights }, git_info
end

local function prep_items(project_path, items, git_status)
  local result = {}
  -- Pre-allocate the table size for better performance
  for _, item in ipairs(items) do
    result[item] = {
      is_dir = vim.fn.isdirectory(project_path .. "/" .. item) == 1,
      git_status = "",
      deleted = false,
    }
  end

  -- For each top level file/folder in git_status, check if it is in items, if not, add it to the items list
  if not git_status or git_status == "" then
    return result
  end

  -- Optimize status code normalization
  local status_map = {
    ["??"] = "A", -- Untracked files are treated as Added
    ["A"] = "A", -- Added
    ["M"] = "M", -- Modified
    ["R"] = "M", -- Renamed (treat as modified)
    ["D"] = "D", -- Deleted
  }

  local function git_status_display(status_code, deleted, dir)
    if not status_code or status_code == "" then
      return ""
    end

    if deleted then
      return "D"
    end

    status_code = status_code:gsub("%?", "A")
    -- Remove duplicate characters
    local seen = {}
    local result = ""
    for i = 1, #status_code do
      local char = status_code:sub(i, i)
      if not seen[char] then
        seen[char] = true
        result = result .. char
      end
    end
    status_code = result

    if #status_code == 1 then
      return status_map[status_code] or "M"
    end

    -- For multiple status codes, prioritize A > M > D
    if dir then
      return "M"
    elseif status_code:match("A") or status_code:match("?") then
      return "A"
    elseif status_code:match("M") then
      return "M"
    else
      return "D"
    end
  end

  -- Parse git status output line by line - optimize by avoiding pattern matching where possible
  for line in git_status:gmatch("[^\r\n]+") do
    if #line >= 3 then
      local status_code = line:sub(1, 2)
      local path = line:sub(4)

      local first_slash = path:find("/")
      local top_level_item = first_slash and path:sub(1, first_slash - 1) or path

      if status_code:match("[D]") and top_level_item and not result[top_level_item] then
        local is_directory = first_slash ~= nil
        result[top_level_item] = {
          is_dir = is_directory,
          git_status = "D",
          deleted = true,
        }
      elseif result[top_level_item] then
        result[top_level_item].git_status = result[top_level_item].git_status .. status_code
      end
    end
  end

  -- Process git status in a single pass
  for item_name, item_data in pairs(result) do
    item_data.git_status = git_status_display(item_data.git_status, item_data.deleted, item_data.is_dir)
  end

  return result
end

local function generate_preview_body(project_path, git_info)
  local body = {}
  local highlights = {}

  local items = prep_items(project_path, vim.fn.readdir(project_path), git_info.status)
  -- Separate directories and files
  local directories = {}
  local files = {}
  for name, properties in pairs(items) do
    if config.options.picker.preview.show_hidden or not name:match("^%.") then
      if properties.is_dir then
        table.insert(directories, name)
      else
        table.insert(files, name)
      end
    end
  end

  -- Sort directories and files alphabetically
  table.sort(directories)
  table.sort(files)

  local function status_to_hl_group(status)
    if status == "A" then
      return "NeovimProjectAdded"
    elseif status == "D" then
      return "NeovimProjectRemoved"
    else
      return "NeovimProjectChanged"
    end
  end

  -- Helper function to format a file/folder and add it to the output
  local function process_item(name, properties)
    local field_type = properties.is_dir and "directory" or "file"

    -- Get icon from provider
    local icon, hl = icon_provider(field_type, name, {
      -- fallback icons
      directory = "📁",
      default_file = "📄",
    })

    -- Add trailing slash for directories
    local display_name = name
    if properties.is_dir then
      display_name = name .. "/"
    end

    -- Add status letter and insert line
    local status_display = properties.git_status .. " "
    if #status_display == 1 then
      status_display = "  "
    end
    local line = status_display .. icon .. " " .. display_name
    local line_idx = #body + 2
    table.insert(body, line)

    -- Icon highlighting
    if hl and hl ~= "" then
      local icon_start = 2
      local icon_end = icon_start + vim.fn.strwidth(icon)

      table.insert(highlights, {
        line = line_idx - 1,
        hl = hl,
        start_col = icon_start,
        end_col = icon_end,
      })
    end

    -- Highlight for files with a git_status
    if properties.git_status ~= "" then
      table.insert(highlights, {
        line = line_idx - 1,
        hl = status_to_hl_group(properties.git_status),
        start_col = 0,
        end_col = #line,
      })
    -- Highlight for hidden files
    elseif name:match("^%.") then
      local text_start = 4
      local text_end = #line

      table.insert(highlights, {
        line = line_idx - 1,
        hl = "Comment",
        start_col = text_start,
        end_col = text_end,
      })
    end
  end

  -- Process directories first
  for _, name in ipairs(directories) do
    process_item(name, items[name])
  end

  -- Then process files
  for _, name in ipairs(files) do
    process_item(name, items[name])
  end

  return { lines = body, highlights = highlights }
end

-- Generate project preview content
function M.generate_project_preview(project_path)
  local output = {}
  local highlights = {}

  -- Get header content
  local header, git_info = generate_preview_header(project_path)

  -- Add header lines to output
  for _, line in ipairs(header.lines) do
    table.insert(output, line)
  end

  -- Add header highlights to highlights
  for _, hl in ipairs(header.highlights) do
    table.insert(highlights, hl)
  end

  local body = generate_preview_body(project_path, git_info)

  -- Add body lines to output
  for _, line in ipairs(body.lines) do
    table.insert(output, line)
  end

  -- Add body highlights to highlights
  for _, hl in ipairs(body.highlights) do
    table.insert(highlights, hl)
  end
  return { lines = output, highlights = highlights }
end

return M
