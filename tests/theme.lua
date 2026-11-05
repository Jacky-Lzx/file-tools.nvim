local h = dofile("tests/helpers.lua")
local api = vim.api
local theme_root = vim.env.FILE_TOOLS_THEME_TOOLS
  or vim.fs.normalize(vim.fn.getcwd() .. "/../theme-tools.nvim")
local available = vim.uv.fs_stat(theme_root .. "/lua/theme_tools/init.lua") ~= nil
local early = vim.env.FILE_TOOLS_THEME_EARLY == "1"
local themes, tree, state
local options = {
  catppuccin = false,
  dracula = false,
  discover = false,
  persist = false,
  themes = {
    "theme-tools-mocha",
    "theme-tools-dracula",
    "habamax",
    { name = "transparent", colorscheme = "theme-tools-mocha", transparent = true },
  },
  default = "theme-tools-mocha",
  icons = { default = "none" },
}
local function load_themes()
  vim.opt.runtimepath:append(theme_root)
  themes = require("theme_tools")
  themes.setup(options)
end
local function hl(name)
  return api.nvim_get_hl(0, { name = name, link = false })
end
local function number(color)
  return color == "NONE" and nil or tonumber(color:sub(2), 16)
end
local function expect_palette()
  local c = themes.palette()
  h.eq(number(c.ui.accent), hl("FileToolsRoot").fg)
  h.eq(number(c.palette.blue), hl("FileToolsDirectory").fg)
  h.eq(number(c.palette.cyan), hl("FileToolsSymlink").fg)
  h.eq(number(c.ui.fg), hl("FileToolsFile").fg)
  h.eq(number(c.ui.sidebar_bg), hl("FileToolsNormal").bg)
  h.eq(number(c.ui.cursorline_bg), hl("FileToolsCursorLine").bg)
  h.eq(number(c.ui.border), hl("FileToolsWinSeparator").fg)
  h.eq(number(c.diagnostic.error), hl("FileToolsError").fg)
  h.eq(number(c.diagnostic.warn), hl("FileToolsWarn").fg)
end

if early then
  assert(available, "theme-tools checkout required")
  load_themes()
end
h.write(h.root .. "/src/child.txt")
tree = require("file_tools.tree")
state = tree.open({ root = h.root })

if not early then
  h.test("standalone tree never loads theme-tools and follows standard highlights", function()
    assert(package.loaded.theme_tools == nil)
    h.eq("Directory", api.nvim_get_hl(0, { name = "FileToolsDirectory" }).link)
    assert(vim.wo[state.win].winhighlight:find("Normal:FileToolsNormal", 1, true))
    vim.cmd.colorscheme("habamax")
    h.eq("Directory", api.nvim_get_hl(0, { name = "FileToolsDirectory" }).link)
    assert(package.loaded.theme_tools == nil)
  end)
  if available then
    load_themes()
  end
end

if available then
  h.test(early and "theme-tools before tree" or "ThemeToolsReady binds an already open tree", function()
    expect_palette()
  end)
  h.test("managed and direct theme changes recolor an open tree without altering selection", function()
    local cursor = api.nvim_win_get_cursor(state.win)
    local buf = state.buf
    for _, name in ipairs({ "theme-tools-dracula", "theme-tools-mocha", "habamax" }) do
      assert(themes.set(name))
      expect_palette()
      h.eq(cursor, api.nvim_win_get_cursor(state.win))
      h.eq(buf, state.buf)
    end
    vim.cmd.colorscheme("theme-tools-dracula")
    assert(vim.wait(1000, function()
      return hl("FileToolsRoot").fg == number(themes.palette().ui.accent)
    end, 10))
    expect_palette()
  end)
  h.test("transparency, palette overrides and repeated setup reach every tree", function()
    assert(themes.set("transparent"))
    expect_palette()
    h.eq(nil, hl("FileToolsNormal").bg)
    options.palette =
      { overrides = { ui = { accent = "#123456", border = "#234567" }, diagnostic = { error = "#345678" } } }
    themes.setup(options)
    expect_palette()
    h.eq(0x123456, hl("FileToolsRoot").fg)
    h.eq(0x234567, hl("FileToolsWinSeparator").fg)
    h.eq(0x345678, hl("FileToolsError").fg)
    options.palette.overrides.ui.sidebar_bg = "#171720"
    themes.setup(options)
    h.eq(0x171720, hl("FileToolsNormal").bg)
    h.eq(0x171720, hl("FileToolsWinSeparator").bg)
    -- Updating consumer colors must not change the editor's global highlights.
    local global_normal = hl("Normal")
    local global_directory = hl("Directory")
    themes.refresh_palette()
    h.eq(global_normal, hl("Normal"))
    h.eq(global_directory, hl("Directory"))
    api.nvim_set_hl(0, "Normal", vim.tbl_extend("force", global_normal, { fg = "#456789" }))
    themes.refresh_palette()
    h.eq(0x456789, hl("FileToolsFile").fg)
    vim.cmd.tabnew()
    local other = tree.open({ root = h.root })
    expect_palette()
    assert(vim.wo[other.win].winhighlight:find("CursorLine:FileToolsCursorLine", 1, true))
    tree.close()
    vim.cmd.tabclose()
    h.eq(state, tree.state())
  end)
else
  assert(not vim.env.FILE_TOOLS_THEME_TOOLS, "FILE_TOOLS_THEME_TOOLS does not contain theme-tools.nvim")
  print("skip real theme-tools integration: sibling checkout unavailable")
end
tree.close()
h.finish()
