local api = vim.api
local root, fixture = vim.env.FILE_TOOLS_ROOT, vim.env.FILE_TOOLS_FIXTURE
vim.opt.runtimepath:prepend(root)
local theme_test = vim.env.FILE_TOOLS_THEME_TEST == "1"
if theme_test then
  vim.opt.runtimepath:append(vim.env.FILE_TOOLS_THEME_TOOLS or vim.fs.dirname(root) .. "/theme-tools.nvim")
end
vim.opt.swapfile = false
vim.o.hidden = true
vim.o.laststatus = 2
require("file_tools").setup({ tree = { follow = true } })
vim.cmd.edit(vim.fn.fnameescape(fixture .. "/current.txt"))
local origin = api.nvim_get_current_win()

local function snapshot()
  vim.cmd.redraw()
  local tree = package.loaded["file_tools.tree"] and require("file_tools.tree").state()
  local screen = {}
  for row = 1, vim.o.lines do
    local line = {}
    for col = 1, vim.o.columns do
      line[#line + 1] = vim.fn.screenstring(row, col)
    end
    screen[#screen + 1] = table.concat(line)
  end
  local buffers = {}
  for _, buf in ipairs(api.nvim_list_bufs()) do
    buffers[#buffers + 1] = { id = buf, name = api.nvim_buf_get_name(buf), modified = vim.bo[buf].modified }
  end
  local colors, palette, directory_attr
  if theme_test then
    colors = {}
    for _, name in ipairs({ "Root", "Directory", "Normal", "CursorLine", "WinSeparator" }) do
      colors[name] = api.nvim_get_hl(0, { name = "FileTools" .. name, link = false })
    end
    if package.loaded.theme_tools then
      palette = require("theme_tools").palette()
    end
    if tree then
      for row, node in ipairs(tree.nodes) do
        if node.name == "src" then
          local line = api.nvim_buf_get_lines(tree.buf, row - 1, row, false)[1]
          local pos = vim.fn.screenpos(tree.win, row, #line)
          directory_attr = vim.fn.screenattr(pos.row, pos.col)
        end
      end
    end
  end
  local value = {
    mode = api.nvim_get_mode().mode,
    current = api.nvim_buf_get_name(0),
    origin = api.nvim_get_current_win() == origin,
    screen = table.concat(screen, "\n"),
    buffers = buffers,
    cwd = vim.fn.getcwd(),
    colors = colors,
    palette = palette,
    directory_attr = directory_attr,
    tree = tree and {
      focus = api.nvim_get_current_win() == tree.win,
      lines = api.nvim_buf_get_lines(tree.buf, 0, -1, false),
      width = api.nvim_win_get_width(tree.win),
      watchers = vim.tbl_count(tree.watchers),
      cursor = api.nvim_win_get_cursor(tree.win),
      buf = tree.buf,
    } or nil,
  }
  vim.fn.writefile({ vim.json.encode(value) }, fixture .. "/snapshot.json")
end
vim.keymap.set({ "n", "i" }, "<F12>", snapshot)
vim.keymap.set("n", "<F6>", function()
  require("file_tools").toggle({ root = fixture })
end)
if theme_test then
  local index = 0
  vim.keymap.set("n", "<F7>", function()
    local loaded = package.loaded.theme_tools
    local themes = require("theme_tools")
    if not loaded then
      themes.setup({
        catppuccin = false,
        dracula = false,
        persist = false,
        discover = false,
        icons = { default = "none" },
      })
    end
    local entries = {
      "theme-tools-mocha",
      "theme-tools-dracula",
      { name = "file-tools-transparent-test", colorscheme = "theme-tools-mocha", transparent = true },
    }
    for _, entry in ipairs(entries) do
      themes.register(entry)
    end
    index = index % #entries + 1
    local entry = entries[index]
    assert(themes.set(type(entry) == "table" and entry.name or entry))
  end)
end
vim.api.nvim_create_autocmd("VimEnter", {
  once = true,
  callback = function()
    vim.schedule(function()
      vim.fn.writefile({ "ready" }, fixture .. "/ready")
    end)
  end,
})
