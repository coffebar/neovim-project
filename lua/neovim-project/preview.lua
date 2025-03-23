local M = {}

local previewers = require("telescope.previewers")

--- Stolen from Oil.nvim
--- Check for an icon provider and return a common icon provider API
M.get_icon_provider = function()
  -- prefer mini.icons
  local _, mini_icons = pcall(require, "mini.icons")
  ---@diagnostic disable-next-line: undefined-field
  if _G.MiniIcons then -- `_G.MiniIcons` is a better check to see if the module is setup
    return function(type, name)
      return mini_icons.get(type == "directory" and "directory" or "file", name)
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
    local project_path = entry.value
    local preview_data = M.generate_project_preview(project_path)

    -- Display the output
    vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, preview_data.lines)

    -- Apply highlights
    for _, hl_info in ipairs(preview_data.highlights) do
      vim.api.nvim_buf_add_highlight(
        self.state.bufnr,
        -1, -- namespace ID (-1 for a new namespace)
        hl_info.hl_group,
        hl_info.line,
        hl_info.start_col,
        hl_info.end_col
      )
    end
  end,
})

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

  -- List files in the project directory
  local items = vim.fn.readdir(project_path)
  table.sort(items)

  -- Format the output
  local output = {}
  table.insert(output, "")

  -- Track highlight information for each line
  local highlights = {}

  for _, item in ipairs(items) do
    -- Skip hidden files starting with .
    if not item:match("^%.") then
      local is_dir = vim.fn.isdirectory(project_path .. "/" .. item) == 1
      local field_type = is_dir and "directory" or "file"

      -- Get icon from provider
      local icon, hl = M.icon_provider(field_type, item, {
        directory = "📁", -- fallback directory icon
        default_file = "📄", -- fallback file icon
      })

      -- Add trailing slash for directories
      local display_name = item
      if is_dir then
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
          hl_group = hl,
          start_col = icon_start,
          end_col = icon_end,
        })
      end
    end
  end

  return { lines = output, highlights = highlights }
end

return M
