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

h.finish()
