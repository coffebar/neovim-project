local M = {}

local previewers = require("telescope.previewers")

local initialized = false

-- Add a function to clear caches
M.clear_caches = function()
  preview_cache = {}
end

M.init = function()
  M.define_preview_highlighting()
  M.clear_caches()
  -- Set up an autocmd to clear caches periodically
  vim.api.nvim_create_autocmd({ "FocusGained", "BufEnter" }, {
    callback = function()
      M.clear_caches()
    end,
    group = vim.api.nvim_create_augroup("NeovimProjectCacheClear", { clear = true }),
  })
end

--- Stolen from oil.nvim
--- Check for an icon provider and return a common icon provider API
M.get_icon_provider = function()
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

M.icon_provider = M.get_icon_provider() or function(_, _, _)
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

    -- Create a debounced preview generation
    if not self._preview_timer then
      self._preview_timer = vim.loop.new_timer()
    else
      -- Cancel any pending preview generation
      self._preview_timer:stop()
    end

    -- Clear the buffer first to show something is happening
    vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, { "Loading preview..." })

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
      self._preview_timer:start(50, 0, vim.schedule_wrap(render_preview))
    end
  end,
})

-- Get the current git branch and status for a project path
function M.get_git_info(project_path)
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

  -- Use --porcelain=v1 for stable output format and limit to top-level entries
  result.status = vim.fn.system("git status --porcelain=v1")

  vim.fn.chdir(current_dir)

  return result
end

function M.define_preview_highlighting()
  local normal_bg = vim.fn.synIDattr(vim.fn.hlID("Normal"), "bg#")
  local branch_bg = vim.fn.synIDattr(vim.fn.hlID("Directory"), "fg#")
  local title_bg = vim.fn.synIDattr(vim.fn.hlID("Title"), "fg#")

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

  vim.api.nvim_set_hl(0, "NeovimProjectSync", {
    fg = "#d29922",
    bold = true,
  })

  vim.api.nvim_set_hl(0, "NeovimProjectAdded", {
    fg = "#3fb950",
  })

  vim.api.nvim_set_hl(0, "NeovimProjectModified", {
    fg = "#d29922",
  })

  vim.api.nvim_set_hl(0, "NeovimProjectDeleted", {
    fg = "#f85149",
  })
end

-- Generate header for project preview
function M.generate_preview_header(project_path)
  local header = {}
  local header_highlights = {}
  local project_title = vim.fn.fnamemodify(project_path, ":t")
  -- Add padding spaces for better appearance with background color

  local branch_icon = M.icon_provider("filetype", "git", {
    default_file = "",
  })
  local git_info = M.get_git_info(project_path)
  local title_string = " " .. project_title .. " "
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
  local formatted_header = title_string
  if git_info.is_repo then
    formatted_header = formatted_header .. branch_string .. sync_string
  end
  table.insert(header, formatted_header)
  -- table.insert(header, string.rep(" ", 200))
  local title_width = #title_string
  local title_start = 0
  local title_end = title_start + title_width

  local branch_width = #branch_string
  local branch_start = title_end
  local branch_end = branch_start + branch_width

  local sync_width = #sync_string
  local sync_start = branch_end
  local sync_end = sync_start + sync_width

  table.insert(header_highlights, {
    line = 0, -- 0-indexed line number
    hl = "NeovimProjectTitle", -- Use our custom highlight group
    start_col = title_start,
    end_col = title_end,
  })

  table.insert(header_highlights, {
    line = 0, -- 0-indexed line number
    hl = "NeovimProjectBranch", -- Use our custom highlight group
    start_col = branch_start,
    end_col = branch_end,
  })

  table.insert(header_highlights, {
    line = 0, -- 0-indexed line number
    hl = "NeovimProjectSync", -- Use our custom highlight group
    start_col = sync_start,
    end_col = sync_end,
  })

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
    ["?"] = "A", -- Untracked files are treated as Added
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

    if dir then
      return "M"
    end

    -- Quick lookup for common status codes
    if #status_code == 1 then
      return status_map[status_code] or "M"
    end

    -- For multiple status codes, prioritize D > A > M
    if status_code:match("D") then
      return "D"
    elseif status_code:match("A") or status_code:match("?") then
      return "A"
    else
      return "M"
    end
  end

  -- Parse git status output line by line - optimize by avoiding pattern matching where possible
  for line in git_status:gmatch("[^\r\n]+") do
    if #line >= 3 then
      local status_code = line:sub(1, 2)
      local path = line:sub(4) -- Skip status code and space

      -- Extract top-level item more efficiently
      local slash_pos = path:find("/")
      local top_level_item = slash_pos and path:sub(1, slash_pos - 1) or path

      if status_code:match("[D]") and top_level_item and not result[top_level_item] then
        local is_directory = slash_pos ~= nil
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

-- Generate project preview content
function M.generate_project_preview(project_path)
  if not project_path or project_path == "" then
    return { lines = { "No project path provided" }, highlights = {} }
  end

  -- Process path to make it usable
  project_path = vim.fn.expand(project_path)
  project_path = vim.fn.fnamemodify(project_path, ":p")
  project_path = project_path:gsub("[/\\]$", "")

  -- Check if the directory existsi
  if vim.fn.isdirectory(project_path) ~= 1 then
    return { lines = { "Directory does not exist: " .. project_path }, highlights = {} }
  end

  -- Get header content
  local header, git_info = M.generate_preview_header(project_path)

  local output = {}
  local highlights = {}

  -- Add header lines to output
  for _, line in ipairs(header.lines) do
    table.insert(output, line)
  end

  -- Add header highlights to highlights
  for _, hl in ipairs(header.highlights) do
    table.insert(highlights, hl)
  end

  local raw_items = vim.fn.readdir(project_path)
  local items = prep_items(project_path, raw_items, git_info.status)
  -- Separate directories and files
  local directories = {}
  local files = {}
  for name, properties in pairs(items) do
    -- if not name:match("^%.") then
    if properties.is_dir then
      table.insert(directories, name)
    else
      table.insert(files, name)
    end
  end

  -- Sort directories and files alphabetically
  table.sort(directories)
  table.sort(files)

  local function status_to_hl_group(status)
    if status == "A" then
      return "NeovimProjectAdded"
    end

    if status == "D" then
      return "NeovimProjectDeleted"
    end

    return "NeovimProjectModified"
  end

  -- Helper function to format a file/folder and add it to the output
  local function process_item(name, properties)
    local field_type = properties.is_dir and "directory" or "file"

    -- Get icon from provider
    local icon, hl = M.icon_provider(field_type, name, {
      -- fallback icons
      directory = "📁",
      default_file = "📄",
    })

    -- Add trailing slash for directories
    local display_name = name
    if properties.is_dir then
      display_name = name .. "/"
    end

    -- Add line to output
    local status_display = properties.git_status .. " "
    if #status_display == 1 then
      status_display = status_display .. " "
    end
    local line = status_display .. icon .. " " .. display_name
    local line_idx = #output + 1
    table.insert(output, line)

    -- Store highlight information if we have a highlight group
    if hl and hl ~= "" then
      -- Calculate icon position (after the leading spaces)
      local icon_start = 2
      local icon_end = icon_start + vim.fn.strwidth(icon)

      table.insert(highlights, {
        line = line_idx - 1, -- 0-indexed line number
        hl = hl,
        start_col = icon_start,
        end_col = icon_end,
      })
    end

    if properties.git_status ~= "" then
      table.insert(highlights, {
        line = line_idx - 1, -- 0-indexed line number
        hl = status_to_hl_group(properties.git_status),
        start_col = 0,
        end_col = #line,
      })
    end

    if name:match("^%.") then
      local text_start = 4
      local text_end = #line

      table.insert(highlights, {
        line = line_idx - 1, -- 0-indexed line number
        hl = "Comment", --"NeovimProjectDeleted",
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

  return { lines = output, highlights = highlights }
end

return M
