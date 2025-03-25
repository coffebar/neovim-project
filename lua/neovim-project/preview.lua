local M = {}

local previewers = require("telescope.previewers")

local initialized = false

M.init = function()
  M.define_preview_highlighting()
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
    end
    local project_path = entry.value
    local preview_data = M.generate_project_preview(project_path)

    -- Display the output
    vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, preview_data.lines)

    -- Apply highlights
    for _, hl_info in ipairs(preview_data.highlights) do
      vim.api.nvim_buf_add_highlight(
        self.state.bufnr,
        -1, -- namespace ID (-1 for a new namespace)
        hl_info.hl,
        hl_info.line,
        hl_info.start_col,
        hl_info.end_col
      )
    end
  end,
})

-- Get the current git branch and status for a project path
function M.get_git_info(project_path)
  local current_dir = vim.fn.getcwd()
  local result = {
    branch = "",
    ahead = 0,
    behind = 0,
    status = "",
  }

  vim.fn.chdir(project_path)

  -- Get branch name
  local branch_name = vim.fn.system("git branch --show-current 2>/dev/null"):gsub("\n", "")

  -- Only proceed if we have a valid branch
  if branch_name ~= "" then
    result.branch = branch_name

    -- Fetch from remote to get up-to-date information (optional, can be removed if too slow)
    -- vim.fn.system("git fetch --quiet 2>/dev/null")

    -- Get ahead/behind counts
    local status_output = vim.fn.system(
      "git rev-list --left-right --count origin/" .. branch_name .. "..." .. branch_name .. " 2>/dev/null"
    )

    -- Parse the output which is in format "N M" where N is behind and M is ahead
    local behind, ahead = status_output:match("(%d+)%s+(%d+)")
    result.behind = tonumber(behind)
    result.ahead = tonumber(ahead)
  end

  result.status = vim.fn.system("git status --porcelain")

  vim.fn.chdir(current_dir)

  return result
end

function M.define_preview_highlighting()
  -- Basic UI elements
  local normal_fg = vim.fn.synIDattr(vim.fn.hlID("Normal"), "fg#")
  local normal_bg = vim.fn.synIDattr(vim.fn.hlID("Normal"), "bg#")
  local cursor_line_bg = vim.fn.synIDattr(vim.fn.hlID("CursorLine"), "bg#")
  local visual_bg = vim.fn.synIDattr(vim.fn.hlID("Visual"), "bg#")
  local insert_bg = vim.fn.synIDattr(vim.fn.hlID("Insert"), "bg#")

  -- Text elements
  local comment_fg = vim.fn.synIDattr(vim.fn.hlID("Comment"), "fg#")
  local string_fg = vim.fn.synIDattr(vim.fn.hlID("String"), "fg#")
  local number_fg = vim.fn.synIDattr(vim.fn.hlID("Number"), "fg#")
  local constant_fg = vim.fn.synIDattr(vim.fn.hlID("Constant"), "fg#")

  -- Programming elements
  local function_fg = vim.fn.synIDattr(vim.fn.hlID("Function"), "fg#")
  local keyword_fg = vim.fn.synIDattr(vim.fn.hlID("Keyword"), "fg#")
  local statement_fg = vim.fn.synIDattr(vim.fn.hlID("Statement"), "fg#")
  local type_fg = vim.fn.synIDattr(vim.fn.hlID("Type"), "fg#")
  local special_fg = vim.fn.synIDattr(vim.fn.hlID("Special"), "fg#")
  local identifier_fg = vim.fn.synIDattr(vim.fn.hlID("Identifier"), "fg#")

  -- UI elements
  local pmenu_bg = vim.fn.synIDattr(vim.fn.hlID("Pmenu"), "bg#")
  local pmenu_sel_bg = vim.fn.synIDattr(vim.fn.hlID("PmenuSel"), "bg#")
  local error_fg = vim.fn.synIDattr(vim.fn.hlID("Error"), "fg#")
  local warning_fg = vim.fn.synIDattr(vim.fn.hlID("WarningMsg"), "fg#")
  local todo_fg = vim.fn.synIDattr(vim.fn.hlID("Todo"), "fg#")
  local directory_fg = vim.fn.synIDattr(vim.fn.hlID("Directory"), "fg#")
  local title_fg = vim.fn.synIDattr(vim.fn.hlID("Title"), "fg#")

  -- Status line
  local statusline_fg = vim.fn.synIDattr(vim.fn.hlID("StatusLine"), "fg#")
  local statusline_bg = vim.fn.synIDattr(vim.fn.hlID("StatusLine"), "bg#")
  local statusline_nc_bg = vim.fn.synIDattr(vim.fn.hlID("StatusLineNC"), "bg#")

  -- Diff colors
  local diff_add_bg = vim.fn.synIDattr(vim.fn.hlID("DiffAdd"), "bg#")
  local diff_change_bg = vim.fn.synIDattr(vim.fn.hlID("DiffChange"), "bg#")
  local diff_delete_bg = vim.fn.synIDattr(vim.fn.hlID("DiffDelete"), "bg#")
  local diff_text_bg = vim.fn.synIDattr(vim.fn.hlID("DiffText"), "bg#")

  vim.api.nvim_set_hl(0, "NeovimProjectTitle", {
    bg = title_fg,
    fg = normal_bg,
    bold = true,
  })

  vim.api.nvim_set_hl(0, "NeovimProjectBranch", {
    bg = function_fg,
    fg = normal_bg,
    bold = true,
  })

  vim.api.nvim_set_hl(0, "NeovimProjectSync", {
    bg = normal_bg,
    fg = warning_fg,
    bold = true,
  })

  vim.api.nvim_set_hl(0, "NeovimProjectDeleted", {
    fg = comment_fg,
    strikethrough = true,
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
  local sync_string = " " .. behind .. ahead
  local formatted_header = title_string .. branch_string .. sync_string
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
    hl = "DiffChange", -- Use our custom highlight group
    start_col = sync_start,
    end_col = sync_end,
  })

  return { lines = header, highlights = header_highlights }, git_info
end

local function prep_items(project_path, items, git_status)
  local result = {}
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

  local function normalize_git_status(status_code)
    if not status_code or status_code == "" then
      return ""
    end

    -- Trim any whitespace
    status_code = status_code:gsub("^%s*(.-)%s*$", "%1")

    -- Convert ? to A
    status_code = status_code:gsub("?", "A")

    -- Remove duplicates by using a set-like table
    local seen = {}
    local result = ""

    for i = 1, #status_code do
      local char = status_code:sub(i, i)
      if not seen[char] and char:match("[ADMR]") then
        seen[char] = true
        result = result .. char
      end
    end

    return result
  end

  local function git_status_display(status_code)
    if not status_code or status_code == "" then
      return ""
    end

    -- Trim any whitespace
    status_code = normalize_git_status(status_code)

    if status_code == "A" then
      return "A"
    end

    if status_code == "?" then
      return "A"
    end
    if status_code == "D" then
      return "D"
    end

    return "M"
  end

  -- Parse git status output line by line
  for line in git_status:gmatch("[^\r\n]+") do
    -- D means deleted, so we look for lines with 'D' in either position
    local status_code = line:sub(0, 2)
    local path = line:sub(4) -- Skip status code and space
    local top_level_item = path:match("^([^/]+)")
    if status_code:match("[D]") and top_level_item and not result[top_level_item] then -- if file is deleted, add back to output list with deleted = true
      local is_directory = path:match("^[^/]+/") ~= nil
      result[top_level_item] = {
        is_dir = is_directory,
        git_status = status_code,
        deleted = true,
      }
    else
      if result[top_level_item] then -- accumulate status codes on all top level items
        result[top_level_item].git_status = result[top_level_item].git_status .. status_code
      end
    end
  end
  for _, item in pairs(result) do
    item.git_status = git_status_display(item.git_status)
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
      return "DiffAdd"
    end

    if status == "D" then
      return "DiffDelete"
    end

    return "DiffChange"
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
        end_col = 1,
      })
    end

    if properties.deleted then
      local text_start = 3
      local text_end = #line

      table.insert(highlights, {
        line = line_idx - 1, -- 0-indexed line number
        hl = "NeovimProjectDeleted",
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
