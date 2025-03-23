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

    -- Display the output
    vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, output)

    -- Apply highlights
    for _, hl_info in ipairs(highlights) do
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

return M
