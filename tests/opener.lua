local h = dofile("tests/helpers.lua")
local files = require("file_tools")
local cwd = vim.fn.getcwd()
local project = h.root .. "/project"
vim.fn.mkdir(project .. "/.git", "p")
vim.fn.mkdir(project .. "/src", "p")
vim.fn.mkdir(project .. "/work", "p")
vim.cmd.edit(vim.fn.fnameescape(h.write(project .. "/src/main.txt")))
vim.cmd.cd(vim.fn.fnameescape(project .. "/work"))
local opened
files.setup({
  opener = function(target)
    opened = target
    return true
  end,
})
local function check(target, expected)
  opened = nil
  assert(files.open_external(target))
  h.eq(expected, opened)
end

h.test("current file, cwd and Git root precedence", function()
  h.write(project .. "/src/shared.txt")
  h.write(project .. "/work/shared.txt")
  h.write(project .. "/shared.txt")
  check("shared.txt", project .. "/src/shared.txt")
  vim.fn.delete(project .. "/src/shared.txt")
  check("shared.txt", project .. "/work/shared.txt")
  vim.fn.delete(project .. "/work/shared.txt")
  check("shared.txt", project .. "/shared.txt")
  check("missing.txt", project .. "/work/missing.txt")
end)
h.test("literal paths, URI schemes, whitespace and home", function()
  check("  https://example.com/a?q=x#part  ", "https://example.com/a?q=x#part")
  check("mailto:person@example.com", "mailto:person@example.com")
  check("file:///tmp/a%20file", "file:///tmp/a%20file")
  check("/tmp/missing file.pdf", "/tmp/missing file.pdf")
  check("C:\\Users\\example\\file.pdf", "C:\\Users\\example\\file.pdf")
  check("~/file.pdf", vim.fn.expand("~") .. "/file.pdf")
  local literal = h.write(project .. "/src/a $HOME % # [中].pdf")
  check("a $HOME % # [中].pdf", literal)
end)
h.test("unnamed buffers and paths outside Git", function()
  vim.cmd.enew({ bang = true })
  h.write(project .. "/work/shared.txt")
  check("shared.txt", project .. "/work/shared.txt")
  vim.cmd.cd(vim.fn.fnameescape(h.root))
  check("missing.txt", h.root .. "/missing.txt")
end)
h.test("empty input and backend failure are returned", function()
  for _, target in ipairs({ "", "   ", false }) do
    local ok, err = files.open_external(target)
    assert(not ok and err == "No path or URL found")
  end
  files.setup({
    opener = function()
      return false, "unavailable"
    end,
  })
  local ok, err = files.open_external("https://example.com")
  assert(not ok and err == "unavailable")
  files.setup({
    opener = function()
      error("backend crashed")
    end,
  })
  ok, err = files.open_external("https://example.com")
  assert(not ok and err:find("backend crashed", 1, true))
  assert(not pcall(files.setup, { opener = "invalid" }))
end)
h.test("default vim.ui.open backend works without setup", function()
  files.setup({})
  local original = vim.ui.open
  vim.ui.open = function(target)
    opened = target
    return {}
  end
  check("https://example.com", "https://example.com")
  vim.ui.open = function()
    return nil, "no system opener"
  end
  local ok, err = files.open_external("https://example.com")
  assert(not ok and err == "no system opener")
  vim.ui.open = original
  assert(not package.loaded["file_tools.tree"])
  assert(not package.loaded["lsp-tools"])
end)
vim.cmd.cd(vim.fn.fnameescape(cwd))

vim.opt.runtimepath:prepend(vim.fn.getcwd())
local utils = require("file_tools.opener")
local calls = {}
utils.open_external = function(path)
  calls[#calls + 1] = { path = path, mode = vim.api.nvim_get_mode().mode }
  return true
end

local synchronous
vim.keymap.set({ "n", "x" }, "<F5>", function()
  local before = #calls
  utils.open_at_cursor()
  synchronous = #calls == before + 1
end)

local count = 0
local function check(name, lines, keys, expected, selection)
  vim.cmd.enew({ bang = true })
  vim.o.selection = selection or "inclusive"
  vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
  -- Stale marks must not supply the bounds of the active selection.
  vim.fn.setpos("'<", { 0, 1, 1, 0 })
  vim.fn.setpos("'>", { 0, 1, 1, 0 })
  calls = {}
  synchronous = false
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys .. "<F5>", true, false, true), "xt", false)
  assert(synchronous, name .. ": open_external must run synchronously")
  assert(vim.deep_equal(calls, { { path = expected, mode = "n" } }), name .. ": " .. vim.inspect(calls))
  vim.wait(10, function()
    return false
  end)
  assert(#calls == 1, name .. ": unexpected deferred call")
  count = count + 1
end

check("characterwise", { "xx hello zz" }, "gg03lv4l", "hello")
check("reverse characterwise", { "xx hello zz" }, "gg07lv4h", "hello")
check("exclusive", { "xx hello zz" }, "gg03lv5l", "hello", "exclusive")
check("reverse exclusive", { "xx hello zz" }, "gg08lv5h", "hello", "exclusive")
check("multiline", { "xx hello", "middle", "world zz" }, "gg03lv2j1l", "hello\nmiddle\nworld")
check("linewise", { "xx hello", "world zz" }, "gg03lVj", "xx hello\nworld zz")
check("reverse linewise", { "xx hello", "world zz" }, "G03lVk", "xx hello\nworld zz")
check("exclusive linewise", { "xx hello", "world zz" }, "gg03lVj", "xx hello\nworld zz", "exclusive")
check("blockwise", { "xx hello zz", "yy world zz" }, "gg03l<C-v>j4l", "hello\nworld")
check("reverse blockwise", { "xx hello zz", "yy world zz" }, "G07l<C-v>k4h", "hello\nworld")
check("exclusive blockwise", { "xx hello zz", "yy world zz" }, "gg03l<C-v>j5l", "hello\nworld", "exclusive")
check(
  "reverse exclusive blockwise",
  { "xx hello zz", "yy world zz" },
  "G08l<C-v>k5h",
  "hello\nworld",
  "exclusive"
)
check("short block line", { "xx hello zz", "", "yy world zz" }, "gg03l<C-v>2j4l", "hello\n     \nworld")
check("normal cfile", { "see lua/file_tools/opener.lua here" }, "gg08l", "lua/file_tools/opener.lua")
print("open_at_cursor: " .. count .. " tests passed")

h.finish()
