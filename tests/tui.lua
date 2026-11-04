local api = vim.api
local root, fixture = vim.env.FILE_TOOLS_ROOT, vim.env.FILE_TOOLS_FIXTURE
vim.opt.runtimepath:prepend(root)
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
  local value = {
    mode = api.nvim_get_mode().mode,
    current = api.nvim_buf_get_name(0),
    origin = api.nvim_get_current_win() == origin,
    screen = table.concat(screen, "\n"),
    buffers = buffers,
    cwd = vim.fn.getcwd(),
    tree = tree and {
      focus = api.nvim_get_current_win() == tree.win,
      lines = api.nvim_buf_get_lines(tree.buf, 0, -1, false),
      width = api.nvim_win_get_width(tree.win),
      watchers = vim.tbl_count(tree.watchers),
    } or nil,
  }
  vim.fn.writefile({ vim.json.encode(value) }, fixture .. "/snapshot.json")
end
vim.keymap.set({ "n", "i" }, "<F12>", snapshot)
vim.keymap.set("n", "<F6>", function()
  require("file_tools").toggle({ root = fixture })
end)
vim.api.nvim_create_autocmd("VimEnter", {
  once = true,
  callback = function()
    vim.schedule(function()
      vim.fn.writefile({ "ready" }, fixture .. "/ready")
    end)
  end,
})
