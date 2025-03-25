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
    ahead = "",
    behind = "",
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
    behind = tonumber(behind)
    ahead = tonumber(ahead)

    if behind and behind > 0 then
      result.behind = behind
    end
    if ahead and ahead > 0 then
      result.ahead = ahead
    end
  end

  vim.fn.chdir(current_dir)

  return result
end

function M.define_preview_highlighting()
  -- Basic UI elements
  local normal_fg = vim.fn.synIDattr(vim.fn.hlID("Normal"), "fg#")
  local normal_bg = vim.fn.synIDattr(vim.fn.hlID("Normal"), "bg#")
  local cursor_line_bg = vim.fn.synIDattr(vim.fn.hlID("CursorLine"), "bg#")
  local visual_bg = vim.fn.synIDattr(vim.fn.hlID("Visual"), "bg#")

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

  local title_group = "NeovimProjectTitle"
  local branch_group = "NeovimProjectBranch"
  local sync_group = "NeovimProjectSync"

  vim.api.nvim_set_hl(0, title_group, {
    bg = title_fg,
    fg = normal_bg,
    bold = true,
  })

  vim.api.nvim_set_hl(0, branch_group, {
    bg = function_fg,
    fg = normal_bg,
    bold = true,
  })

  vim.api.nvim_set_hl(0, sync_group, {
    bg = cursor_line_bg,
    fg = normal_fg,
    bold = true,
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
  local sync_string = git_info.ahead .. " " .. git_info.behind
  local formatted_header = title_string .. branch_string -- .. sync_string
  table.insert(header, formatted_header)

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
  -- Add a separator line
  -- table.insert(header, string.rep("─", 200))

  -- -- Add a blank line for spacing
  -- table.insert(header, "")

  return { lines = header, highlights = header_highlights }
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

  local items = vim.fn.readdir(project_path)
  -- Separate directories and files
  local directories = {}
  local files = {}

  for _, item in ipairs(items) do
    -- Skip hidden files starting with .
    if not item:match("^%.") then
      local is_dir = vim.fn.isdirectory(project_path .. "/" .. item) == 1
      if is_dir then
        table.insert(directories, item)
      else
        table.insert(files, item)
      end
    end
  end

  --  Sort directories and files alphabetically
  table.sort(directories)
  table.sort(files)

  local output = {}
  local highlights = {}

  -- -- blank line for padding
  -- table.insert(output, "")
  -- Get header content
  local header = M.generate_preview_header(project_path)

  -- Add header lines to output
  for _, line in ipairs(header.lines) do
    table.insert(output, line)
  end

  -- Add header highlights to highlights
  for _, hl in ipairs(header.highlights) do
    table.insert(highlights, hl)
  end

  -- Helper function to format a file/folder and add it to the output
  local function process_item(item, is_directory)
    local field_type = is_directory and "directory" or "file"

    -- Get icon from provider
    local icon, hl = M.icon_provider(field_type, item, {
      -- fallback icons
      directory = "📁",
      default_file = "📄",
    })

    -- Add trailing slash for directories
    local display_name = item
    if is_directory then
      display_name = item .. "/"
    end

    -- Add line to output
    local line = "  " .. icon .. " " .. display_name
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
  end

  -- Process directories first
  for _, item in ipairs(directories) do
    process_item(item, true)
  end

  -- Then process files
  for _, item in ipairs(files) do
    process_item(item, false)
  end

  return { lines = output, highlights = highlights }
end

return M
