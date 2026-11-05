local h = dofile("tests/helpers.lua")
local api = vim.api
local theme_root = vim.fs.normalize(vim.fn.getcwd() .. "/../theme-tools.nvim")
if vim.fn.isdirectory(theme_root) == 0 then
  print("skip shared icons: theme-tools checkout unavailable")
  h.finish()
  return
end
vim.opt.rtp:append(theme_root)
h.write(h.root .. "/src/子.lua")
h.write(h.root .. "/init.lua")
local tree = require("file_tools.tree")
local first = tree.open({ root = h.root })
assert(not package.loaded.theme_tools, "standalone tree loaded theme-tools")
local function line(state, name)
  for index, node in ipairs(state.nodes) do
    if node.name == name then
      return api.nvim_buf_get_lines(state.buf, index - 1, index, false)[1], node, index
    end
  end
  error("missing node: " .. name)
end
local function expect(state, file, folder)
  assert(
    vim.wait(1000, function()
      return line(state, "init.lua") == file and line(state, "src") == folder
    end, 10),
    vim.inspect(api.nvim_buf_get_lines(state.buf, 0, -1, false))
  )
end
local themes = require("theme_tools")
themes.setup({
  persist = false,
  catppuccin = false,
  dracula = false,
  default = "theme-tools-mocha",
  themes = { "theme-tools-mocha" },
  icons = { default = "ascii" },
})
h.test("late shared provider redraws an existing tree", function()
  expect(first, "  f init.lua", "> d src")
end)
vim.cmd.tabnew()
local second = tree.open({ root = h.root })
local _, folder = line(second, "src")
second.expanded[folder.path] = true
tree.refresh(second, folder.path .. "/子.lua")
local cursor = api.nvim_win_get_cursor(second.win)
h.test("hidden icons refresh every tab without moving the selection", function()
  assert(themes.icons.set("none"))
  expect(first, "  init.lua", "▸ src")
  expect(second, "  init.lua", "▾ src")
  h.eq("    子.lua", line(second, "子.lua"))
  h.eq({ cursor[1], #"    " }, api.nvim_win_get_cursor(second.win))
end)
h.test("ASCII icons restore glyph widths and respect local disabling", function()
  assert(themes.icons.set("ascii"))
  expect(second, "  f init.lua", "v d src")
  local text, node = line(second, "子.lua")
  h.eq("    f 子.lua", text)
  h.eq("子.lua", text:sub(node.name_col + 1))
  require("file_tools").setup({ tree = { icons = false } })
  tree.refresh(second)
  h.eq("    子.lua", line(second, "子.lua"))
end)
tree.close()
vim.cmd.tabclose()
tree.close()
h.finish()
