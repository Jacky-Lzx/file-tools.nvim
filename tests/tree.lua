local h = dofile("tests/helpers.lua")
local api = vim.api
require("file_tools").setup({ tree = { show_hidden = false } })
local tree = require("file_tools.tree")
h.write(h.root .. "/b.txt")
h.write(h.root .. "/a.txt")
h.write(h.root .. "/.hidden")
h.write(h.root .. "/src/child.lua")

local function key(key)
  local callback = vim.fn.maparg(key, "n", false, true).callback
  assert(callback, "missing mapping: " .. key)
  callback()
end

local function select(state, name)
  for row, node in ipairs(state.nodes) do
    if node.path == name then
      api.nvim_win_set_cursor(state.win, { row, 0 })
      return
    end
  end
  error("missing node " .. name)
end

h.test("toggle preserves editor focus and cursor without entering the tree", function()
  local origin = api.nvim_get_current_win()
  api.nvim_buf_set_lines(0, 0, -1, false, { "first line", "second line", "third line" })
  api.nvim_win_set_cursor(origin, { 2, 4 })
  local entered = {}
  local autocmd = api.nvim_create_autocmd({ "WinEnter", "BufEnter" }, {
    callback = function()
      entered[#entered + 1] = api.nvim_get_current_win()
    end,
  })
  local state = tree.toggle({ root = h.root })
  h.eq(origin, api.nvim_get_current_win())
  h.eq({ 2, 4 }, api.nvim_win_get_cursor(origin))
  h.eq({}, entered)
  h.eq(origin, state.target_win)
  assert(api.nvim_win_is_valid(state.win))
  tree.toggle()
  h.eq(nil, tree.state())
  h.eq(origin, api.nvim_get_current_win())
  h.eq({ 2, 4 }, api.nvim_win_get_cursor(origin))
  api.nvim_del_autocmd(autocmd)

  state = tree.toggle({ root = h.root, focus = true })
  h.eq(state.win, api.nvim_get_current_win())
  tree.close()
  vim.bo.modified = false
end)

h.test("toggle reveals the current file while preserving editor focus", function()
  local origin = api.nvim_get_current_win()
  vim.cmd.edit(h.root .. "/src/child.lua")
  api.nvim_win_set_cursor(origin, { 1, 3 })
  for _ = 1, 2 do
    local state = tree.toggle({ root = h.root })
    h.eq(h.root .. "/src/child.lua", state.nodes[api.nvim_win_get_cursor(state.win)[1]].path)
    h.eq(true, state.expanded[h.root .. "/src"])
    h.eq(origin, api.nvim_get_current_win())
    h.eq({ 1, 3 }, api.nvim_win_get_cursor(origin))
    tree.toggle()
  end

  vim.cmd.edit(h.root .. "/a.txt")
  local state = tree.toggle({ root = h.root .. "/src" })
  h.eq(h.root, state.root)
  h.eq(h.root .. "/a.txt", state.nodes[api.nvim_win_get_cursor(state.win)[1]].path)
  h.eq(origin, api.nvim_get_current_win())
  tree.close()

  require("file_tools").setup({ tree = { follow = false } })
  state = tree.toggle({ root = h.root })
  h.eq(h.root, state.nodes[api.nvim_win_get_cursor(state.win)[1]].path)
  tree.close()
  require("file_tools").setup({})
end)

h.test("tree clears inherited gutters without changing the editor", function()
  local origin = api.nvim_get_current_win()
  local inherited = {
    statuscolumn = "%s%=%l  ",
    number = true,
    relativenumber = true,
    signcolumn = "yes:2",
    foldcolumn = "2",
  }
  for name, value in pairs(inherited) do
    vim.wo[origin][name] = value
  end
  local state = tree.open({ root = h.root })
  h.eq("", vim.wo[state.win].statuscolumn)
  h.eq(false, vim.wo[state.win].number)
  h.eq(false, vim.wo[state.win].relativenumber)
  h.eq("no", vim.wo[state.win].signcolumn)
  h.eq("0", vim.wo[state.win].foldcolumn)
  h.eq(true, vim.wo[state.win].winfixbuf)
  local replacement = api.nvim_create_buf(false, true)
  assert(not pcall(api.nvim_win_set_buf, state.win, replacement), "tree accepted an unrelated buffer")
  h.eq(state.buf, api.nvim_win_get_buf(state.win))
  api.nvim_buf_delete(replacement, { force = true })
  for name, value in pairs(inherited) do
    h.eq(value, vim.wo[origin][name])
  end
  tree.close()
end)

h.test("tree sorts directories first, hides dotfiles and folds lazily", function()
  local state = tree.open({ root = h.root })
  h.eq("src", state.nodes[2].name)
  h.eq("a.txt", state.nodes[3].name)
  h.eq(4, #state.nodes)
  select(state, h.root .. "/src")
  key("l")
  h.eq("child.lua", state.nodes[3].name)
  key("h")
  h.eq(4, #state.nodes)
  key(".")
  h.eq(".hidden", state.nodes[3].name)
end)

h.test("create, rename, delete and cancelled prompts", function()
  local state = tree.state()
  local input, choose = vim.ui.input, vim.ui.select
  vim.ui.input = function(_, callback)
    callback(h.root .. "/created.txt")
  end
  key("a")
  assert(vim.uv.fs_stat(h.root .. "/created.txt"))
  select(state, h.root .. "/created.txt")
  vim.ui.input = function(_, callback)
    callback(nil)
  end
  key("r")
  assert(vim.uv.fs_stat(h.root .. "/created.txt"))
  vim.ui.input = function(_, callback)
    callback(h.root .. "/renamed.txt")
  end
  key("r")
  assert(vim.uv.fs_stat(h.root .. "/renamed.txt"))
  select(state, h.root .. "/renamed.txt")
  vim.ui.select = function(_, _, callback)
    callback("Cancel")
  end
  key("d")
  assert(vim.uv.fs_stat(h.root .. "/renamed.txt"))
  vim.ui.select = function(_, _, callback)
    callback("Delete permanently")
  end
  key("d")
  assert(not vim.uv.fs_stat(h.root .. "/renamed.txt"))
  vim.ui.input, vim.ui.select = input, choose
end)

h.test("filesystem watcher updates the tree", function()
  local state = tree.state()
  h.write(h.root .. "/watched.txt")
  assert(
    vim.wait(1500, function()
      for _, node in ipairs(state.nodes) do
        if node.name == "watched.txt" then
          return true
        end
      end
      return false
    end, 20),
    "watcher did not refresh"
  )
end)

h.test("opening files targets editor and follows current file", function()
  local state = tree.state()
  local origin = state.target_win
  select(state, h.root .. "/a.txt")
  key("<CR>")
  h.eq(origin, api.nvim_get_current_win())
  h.eq(h.root .. "/a.txt", api.nvim_buf_get_name(0))
  vim.cmd.edit(h.root .. "/src/child.lua")
  local selected = state.nodes[api.nvim_win_get_cursor(state.win)[1]]
  h.eq(h.root .. "/src/child.lua", selected.path)
end)

h.test("tab-local trees and close release watchers and buffers", function()
  local first = tree.state()
  vim.cmd.tabnew()
  local second = tree.open({ root = h.root .. "/src" })
  assert(first.buf ~= second.buf)
  tree.close()
  assert(not api.nvim_buf_is_valid(second.buf))
  h.eq({}, second.watchers)
  vim.cmd.tabclose()
  h.eq(first, tree.state())
  tree.close()
  assert(not api.nvim_buf_is_valid(first.buf))
  h.eq({}, first.watchers)
end)

h.test("entry limit bounds tree rendering", function()
  require("file_tools").setup({ tree = { max_entries = 3 } })
  local state = tree.open({ root = h.root })
  assert(#state.nodes <= 4)
  assert(state.nodes[#state.nodes].error)
  tree.close()
end)

h.test("tree skips protected editor targets", function()
  require("file_tools").setup({})
  local origin = api.nvim_get_current_win()
  vim.wo[origin].winfixbuf = true
  local state = tree.open({ root = h.root })
  select(state, h.root .. "/a.txt")
  key("<CR>")
  local target = api.nvim_get_current_win()
  assert(target ~= origin and target ~= state.win)
  h.eq(h.root .. "/a.txt", api.nvim_buf_get_name(0))
  h.eq(state.buf, api.nvim_win_get_buf(state.win))
  tree.close()
  vim.wo[origin].winfixbuf = false
  api.nvim_win_close(target, true)
end)

h.test("closing the only tree releases its native buffer lock", function()
  local state = tree.open({ root = h.root })
  for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
    if win ~= state.win then
      api.nvim_win_close(win, true)
    end
  end
  local win = state.win
  tree.close()
  assert(api.nvim_win_is_valid(win))
  h.eq(false, vim.wo[win].winfixbuf)
  h.eq("", vim.bo[api.nvim_win_get_buf(win)].buftype)
  assert(not api.nvim_buf_is_valid(state.buf))
  h.eq({}, state.watchers)
end)

h.test("opening from the only tree creates only the requested editor", function()
  for _, mapping in ipairs({ "<CR>", "S", "s", "t" }) do
    local state = tree.open({ root = h.root })
    api.nvim_win_close(state.target_win, true)
    select(state, h.root .. "/a.txt")
    key(mapping)
    h.eq(h.root .. "/a.txt", api.nvim_buf_get_name(0))
    h.eq(state.buf, api.nvim_win_get_buf(state.win))
    h.eq(true, vim.wo[state.win].winfixbuf)
    if mapping == "t" then
      h.eq(2, #api.nvim_list_tabpages())
      vim.cmd.tabclose()
    else
      h.eq(2, #api.nvim_tabpage_list_wins(0))
      api.nvim_win_close(api.nvim_get_current_win(), true)
    end
    tree.close()
  end
end)

h.finish()
