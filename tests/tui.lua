local api = vim.api
local root, fixture = vim.env.FILE_TOOLS_ROOT, vim.env.FILE_TOOLS_FIXTURE
local integrated = vim.env.FILE_TOOLS_INTEGRATED == "1"
local dashboard_test = vim.env.FILE_TOOLS_DASHBOARD_TEST ~= nil
if not integrated then
  vim.opt.runtimepath:prepend(root)
end
local theme_test = vim.env.FILE_TOOLS_THEME_TEST == "1"
if theme_test then
  vim.opt.runtimepath:append(vim.env.FILE_TOOLS_THEME_TOOLS or vim.fs.dirname(root) .. "/theme-tools.nvim")
end
vim.opt.swapfile = false
vim.o.hidden = true
vim.o.laststatus = 2
if integrated then
  local plugins = require("lazy.core.config").plugins
  assert(
    plugins["file-tools.nvim"] and not plugins["file-tools.nvim"]._.loaded,
    "File-tools loaded before first use"
  )
  for _, name in ipairs({ "nvim-tree.lua", "nvim-lsp-file-operations", "yazi.nvim" }) do
    assert(not plugins[name], "Replaced file plugin is still configured: " .. name)
  end
  vim.cmd.cd(vim.fn.fnameescape(fixture))
else
  require("file_tools").setup({ tree = { follow = true } })
end
if not dashboard_test then
  vim.cmd.edit(vim.fn.fnameescape(fixture .. "/current.txt"))
end
if integrated and not dashboard_test then
  assert(
    require("lazy.core.config").plugins["file-tools.nvim"]._.loaded,
    "LSP dependency did not load file-tools"
  )
  assert(not package.loaded["file_tools.tree"], "Capabilities initialized the tree")
  local capabilities = vim.lsp.config["ts_ls"].capabilities
  assert(capabilities.workspace.fileOperations.willRename)
  assert(capabilities.textDocument.completion.completionItem.snippetSupport)
end
local origin = api.nvim_get_current_win()
local picker
if integrated then
  local selection = require("selection_tools")
  local files = selection.files
  selection.files = function(...)
    picker = files(...)
    return picker
  end
end

local function snapshot()
  vim.cmd.redraw()
  local tree = package.loaded["file_tools.tree"] and require("file_tools.tree").state()
  local dashboard = package.loaded["ui_tools.dashboard"] and require("ui_tools.dashboard").state()
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
  local file_icon
  local tree_bars
  if tree then
    local pos = api.nvim_win_get_position(tree.win)
    local function bar_row(row)
      local cells = {}
      for col = pos[2] + 1, pos[2] + api.nvim_win_get_width(tree.win) do
        cells[#cells + 1] = vim.fn.screenstring(row, col)
      end
      return table.concat(cells)
    end
    tree_bars = {
      top = bar_row(pos[1] + 1),
      bottom = bar_row(pos[1] + api.nvim_win_get_height(tree.win) + 1),
    }
    for row, node in ipairs(tree.nodes) do
      if node.name == "current.lua" then
        local line = api.nvim_buf_get_lines(tree.buf, row - 1, row, false)[1]
        local icon_pos = vim.fn.screenpos(tree.win, row, 3)
        local name_pos = vim.fn.screenpos(tree.win, row, node.name_col + 1)
        local provider = package.loaded["nvim-web-devicons"]
        file_icon = {
          expected = provider and provider.get_icon(node.name, nil, { default = true, strict = true })
            or "",
          text = line:sub(3, node.name_col - 1),
          cell = vim.fn.screenstring(icon_pos.row, icon_pos.col),
          icon_attr = vim.fn.screenattr(icon_pos.row, icon_pos.col),
          name_attr = vim.fn.screenattr(name_pos.row, name_pos.col),
          provider = provider ~= nil,
        }
      end
    end
  end
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
    file_icon = file_icon,
    tree_bars = tree_bars,
    dashboard = dashboard and { win = dashboard.win, buf = dashboard.buf, source = dashboard.source } or nil,
    laststatus = vim.o.laststatus,
    windows = vim.tbl_filter(function(win)
      return api.nvim_win_get_config(win).relative == ""
    end, api.nvim_tabpage_list_wins(0)),
    listed = vim.tbl_map(function(info)
      return { id = info.bufnr, name = info.name }
    end, vim.fn.getbufinfo({ buflisted = 1 })),
    picker = picker and not picker.closed and {
      query = picker.query,
      ready = not picker.loading and not picker.matching and #picker.matches > 0,
    } or nil,
    tree = tree and {
      focus = api.nvim_get_current_win() == tree.win,
      lines = api.nvim_buf_get_lines(tree.buf, 0, -1, false),
      width = api.nvim_win_get_width(tree.win),
      textoff = vim.fn.getwininfo(tree.win)[1].textoff,
      statuscolumn = vim.wo[tree.win].statuscolumn,
      winfixbuf = vim.wo[tree.win].winfixbuf,
      watchers = vim.tbl_count(tree.watchers),
      cursor = api.nvim_win_get_cursor(tree.win),
      buf = tree.buf,
      root = tree.root,
      selected = tree.nodes[api.nvim_win_get_cursor(tree.win)[1]].path,
    } or nil,
  }
  vim.fn.writefile({ vim.json.encode(value) }, fixture .. "/snapshot.json")
end
vim.keymap.set({ "n", "i" }, "<F12>", snapshot)
if not integrated then
  vim.keymap.set("n", "<F6>", function()
    require("file_tools").toggle({ root = fixture })
  end)
end
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
