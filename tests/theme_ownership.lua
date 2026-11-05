local h = dofile("tests/helpers.lua")
local root = vim.env.FILE_TOOLS_THEME_TOOLS or vim.fn.getcwd() .. "/../theme-tools.nvim"
if vim.fn.isdirectory(root) == 0 then
  print("skip optional theme ownership integration")
  h.finish()
  return
end
h.test("explicit theme overrides and restoration", function()
  vim.opt.rtp:append(root)
  local api = vim.api
  vim.cmd.colorscheme("theme-tools-mocha")
  api.nvim_set_hl(0, "FileToolsRoot", { fg = "#123456", italic = true })
  local tree = require("file_tools.tree")
  local state = tree.open({ root = h.root })
  assert(not package.loaded.theme_tools)
  local t = require("theme_tools")
  t.setup({
    persist = false,
    catppuccin = false,
    dracula = false,
    themes = { "theme-tools-mocha", "morning" },
    icons = { default = "none" },
  })
  local function hl(name)
    return api.nvim_get_hl(0, { name = name, link = false })
  end
  local function explicit()
    h.eq(0x123456, hl("FileToolsRoot").fg)
    assert(hl("FileToolsRoot").italic)
  end
  explicit()
  t.refresh_palette()
  explicit()
  local cursor = api.nvim_win_get_cursor(state.win)
  local snapshot = require("theme_tools.colors").snapshot()
  assert(t.set("morning"))
  assert(hl("FileToolsRoot").fg ~= 0x123456)
  require("theme_tools.colors").restore(snapshot)
  explicit()
  h.eq(cursor, api.nvim_win_get_cursor(state.win))
  local group = api.nvim_create_augroup("FileOwnershipTest", { clear = true })
  api.nvim_create_autocmd("ColorScheme", {
    group = group,
    pattern = "morning",
    callback = function()
      api.nvim_set_hl(0, "FileToolsDirectory", { fg = "#abcdef", bold = true })
    end,
  })
  vim.cmd.colorscheme("morning")
  vim.wait(20)
  h.eq(0xabcdef, hl("FileToolsDirectory").fg)
  t.refresh_palette()
  h.eq(0xabcdef, hl("FileToolsDirectory").fg)
  api.nvim_set_hl(0, "FileToolsRoot", { link = "DiagnosticWarn" })
  t.refresh_palette()
  h.eq("DiagnosticWarn", api.nvim_get_hl(0, { name = "FileToolsRoot" }).link)
  api.nvim_set_hl(0, "FileToolsNormal", {})
  t.refresh_palette()
  assert(hl("FileToolsNormal").fg)
  tree.close()
  tree.open({ root = h.root })
  h.eq(0xabcdef, hl("FileToolsDirectory").fg)
  tree.close()
end)
h.finish()
print(
  "file ownership: standalone and late palette, explicit styles/links, live tree, switches and rollback passed"
)
