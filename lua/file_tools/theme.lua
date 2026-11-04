local api = vim.api
local M = {}
local initialized, stop = false, nil

local function fallback()
  for name, link in pairs({
    Root = "Title",
    Directory = "Directory",
    File = "Normal",
    Symlink = "Special",
    Normal = "Normal",
    CursorLine = "CursorLine",
    WinSeparator = "WinSeparator",
    Error = "DiagnosticError",
    Warn = "DiagnosticWarn",
  }) do
    api.nvim_set_hl(0, "FileTools" .. name, { default = true, link = link })
  end
end

local function apply(c)
  local groups = {
    Root = { fg = c.ui.accent, bold = true },
    Directory = { fg = c.palette.blue },
    File = { fg = c.ui.fg },
    Symlink = { fg = c.palette.cyan },
    Normal = { fg = c.ui.fg, bg = c.ui.bg },
    CursorLine = { bg = c.ui.cursorline_bg },
    WinSeparator = { fg = c.ui.border, bg = c.ui.bg },
    Error = { fg = c.diagnostic.error },
    Warn = { fg = c.diagnostic.warn },
  }
  for name, value in pairs(groups) do
    api.nvim_set_hl(0, "FileTools" .. name, value)
  end
end

local function attach()
  if stop then
    return true
  end
  -- Use the shared service when loaded, without initializing a theme manager
  -- or changing the user's colorscheme as a side effect of opening a tree.
  local themes = package.loaded.theme_tools
  if type(themes) == "table" and type(themes.on_change) == "function" then
    stop = themes.on_change("file-tools.tree", apply)
    return true
  end
  return false
end

function M.setup()
  if initialized then
    return
  end
  initialized = true
  fallback()
  local group = api.nvim_create_augroup("FileToolsTheme", { clear = true })
  api.nvim_create_autocmd("User", { group = group, pattern = "ThemeToolsReady", callback = attach })
  api.nvim_create_autocmd("ColorScheme", {
    group = group,
    callback = function()
      if not attach() then
        fallback()
      end
    end,
  })
  attach()
end

return M
