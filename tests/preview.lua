local h = dofile("tests/helpers.lua")
local api = vim.api
require("file_tools").setup({ tree = { follow = false } })
local tree = require("file_tools.tree")
local preview = require("file_tools.preview")
h.write(h.root .. "/a.txt", { "first preview" })
h.write(h.root .. "/b.txt", { "second preview" })
h.write(h.root .. "/中文 image.PNG")
h.write(h.root .. "/pages.pdf")
local binary = assert(vim.uv.fs_open(h.root .. "/binary.bin", "w", 420))
assert(vim.uv.fs_write(binary, "a\0b", 0))
vim.uv.fs_close(binary)
h.write(h.root .. "/large.txt", { string.rep("x", 3000), unpack(vim.fn["repeat"]({ "line" }, 600)) })

local function key(value)
  assert(vim.fn.maparg(value, "n", false, true).callback)()
end
local function select(state, name)
  for row, node in ipairs(state.nodes) do
    if node.path == h.root .. "/" .. name then
      api.nvim_win_set_cursor(state.win, { row, 0 })
      api.nvim_exec_autocmds("CursorMoved", { buffer = state.buf })
      return
    end
  end
  error("missing node " .. name)
end
local function lines(state)
  return api.nvim_buf_get_lines(state.preview.buf, 0, -1, false)
end
local function wait_for(fn)
  assert(vim.wait(2000, fn, 10), "preview did not settle")
end
local function open(name)
  local state = tree.open({ root = h.root })
  select(state, name)
  key("P")
  return state
end

h.test("P toggles a read-only float while preserving Files and editor", function()
  local origin, buf = api.nvim_get_current_win(), api.nvim_get_current_buf()
  local listed = vim.fn.getbufinfo({ buflisted = 1 })
  local state = open("a.txt")
  local cursor, float = api.nvim_win_get_cursor(state.win), state.preview
  wait_for(function()
    return lines(state)[1] == "first preview"
  end)
  h.eq(state.win, api.nvim_get_current_win())
  h.eq(cursor, api.nvim_win_get_cursor(state.win))
  h.eq(buf, api.nvim_win_get_buf(origin))
  h.eq(#listed, #vim.fn.getbufinfo({ buflisted = 1 }))
  h.eq(false, vim.bo[float.buf].modifiable)
  h.eq(false, vim.bo[float.buf].modified)
  h.eq(false, api.nvim_win_get_config(float.win).focusable)
  key("P")
  h.eq(nil, state.preview)
  assert(not api.nvim_win_is_valid(float.win) and not api.nvim_buf_is_valid(float.buf))
  tree.close()
end)

h.test("Tab opens once, repeated Tab stays open and changing selection closes it", function()
  local state = tree.open({ root = h.root })
  select(state, "a.txt")
  key("<Tab>")
  local float = state.preview
  wait_for(function()
    return lines(state)[1] == "first preview"
  end)
  assert(not float.follow)
  key("<Tab>")
  h.eq(float, state.preview)
  tree.refresh(state)
  h.eq(float, state.preview)
  h.eq(state.win, api.nvim_get_current_win())
  select(state, "b.txt")
  assert(not state.preview and not api.nvim_buf_is_valid(float.buf))
  key("<Tab>")
  wait_for(function()
    return lines(state)[1] == "second preview"
  end)
  key("<Esc>")
  h.eq(nil, state.preview)
  tree.close()
end)

h.test("P enables following from a single preview and Tab returns to single preview", function()
  local state = tree.open({ root = h.root })
  select(state, "a.txt")
  key("<Tab>")
  local float = state.preview
  key("P")
  h.eq(float, state.preview)
  assert(float.follow)
  select(state, "b.txt")
  wait_for(function()
    return lines(state)[1] == "second preview"
  end)
  key("<Tab>")
  assert(not float.follow)
  h.eq(float, state.preview)
  select(state, "a.txt")
  h.eq(nil, state.preview)
  tree.close()
end)

h.test("navigation, refresh, binary and bounded text previews", function()
  local state = open("a.txt")
  select(state, "b.txt")
  wait_for(function()
    return lines(state)[1] == "second preview"
  end)
  h.write(h.root .. "/b.txt", { "changed on disk" })
  tree.refresh(state)
  wait_for(function()
    return lines(state)[1] == "changed on disk"
  end)
  select(state, "binary.bin")
  wait_for(function()
    return lines(state)[1]:find("Binary file", 1, true)
  end)
  select(state, "large.txt")
  wait_for(function()
    return lines(state)[1] == string.rep("x", 2000)
  end)
  h.eq(501, #lines(state))
  h.eq("… preview truncated", lines(state)[501])
  tree.close()
end)

h.test("image and PDF rendering is lazy, guarded and released on replacement", function()
  local requests, views, loads = {}, {}, 0
  package.loaded.image_tools = nil
  package.preload.image_tools = function()
    loads = loads + 1
    return {
      supports = function()
        return true
      end,
      render = function(request)
        requests[#requests + 1] = request
        local view = { closed = false, resized = 0 }
        function view:close()
          self.closed = true
        end
        function view:resize()
          self.resized = self.resized + 1
        end
        views[#views + 1] = view
        request.paint(function(buf)
          api.nvim_buf_set_lines(buf, 0, -1, false, { "rendered " .. request.path })
        end)
        return view
      end,
    }
  end
  local state = open("a.txt")
  wait_for(function()
    return lines(state)[1] == "first preview"
  end)
  h.eq(0, loads)
  select(state, "中文 image.PNG")
  wait_for(function()
    return #requests == 1
  end)
  h.eq(1, loads)
  h.eq(state.preview.win, requests[1].win)
  h.eq(state.preview.buf, requests[1].buf)
  tree.refresh(state)
  vim.wait(80, function()
    return false
  end)
  h.eq(1, #requests)
  assert(not views[1].closed, "unrelated tree refresh restarted image rendering")
  select(state, "pages.pdf")
  assert(views[1].closed and not requests[1].is_valid())
  h.eq(
    false,
    requests[1].paint(function()
      error("stale draw")
    end)
  )
  requests[1].on_error("stale error")
  wait_for(function()
    return #requests == 2
  end)
  h.eq(1, requests[2].page)
  assert(requests[2].path:match("pages.pdf$"))
  api.nvim_exec_autocmds("VimResized", {})
  h.eq(1, views[2].resized)
  local before = lines(state)
  requests[1].on_error("late failure")
  h.eq(before, lines(state))
  key("<Esc>")
  assert(views[2].closed and not requests[2].is_valid())
  tree.close()
  package.preload.image_tools, package.loaded.image_tools = nil, nil
end)

h.test("missing renderer and asynchronous render errors stay in the float", function()
  package.preload.image_tools = function()
    error("unavailable")
  end
  local state = open("pages.pdf")
  wait_for(function()
    return lines(state)[1]:find("requires image-tools", 1, true)
  end)
  package.preload.image_tools = nil
  package.loaded.image_tools = {
    supports = function()
      return true
    end,
    render = function(request)
      vim.schedule(function()
        request.on_error("conversion failed")
      end)
      return { close = function() end }
    end,
  }
  preview.update(state, { path = h.root .. "/pages.pdf" }, true)
  wait_for(function()
    return lines(state)[1] == "Preview: conversion failed"
  end)
  tree.close()
  package.loaded.image_tools = nil
end)

h.test("rapid navigation and closing invalidate delayed preview work", function()
  local state = open("pages.pdf")
  select(state, "a.txt")
  select(state, "b.txt")
  wait_for(function()
    return lines(state)[1] == "changed on disk"
  end)
  local float = state.preview
  select(state, "a.txt")
  key("P")
  vim.wait(100, function()
    return false
  end)
  assert(not state.preview and not api.nvim_buf_is_valid(float.buf))
  tree.close()
end)

h.test("late text reads cannot replace a newer selection or revive a closed float", function()
  local read, deliveries = vim.uv.fs_read, {}
  vim.uv.fs_read = function(fd, size, offset, callback)
    return read(fd, size, offset, function(err, data)
      deliveries[#deliveries + 1] = function()
        callback(err, data)
      end
    end)
  end
  local state = open("a.txt")
  wait_for(function()
    return #deliveries == 1
  end)
  select(state, "b.txt")
  wait_for(function()
    return #deliveries == 2
  end)
  deliveries[2]()
  wait_for(function()
    return lines(state)[1] == "changed on disk"
  end)
  deliveries[1]()
  vim.wait(50, function()
    return false
  end)
  h.eq("changed on disk", lines(state)[1])
  select(state, "a.txt")
  wait_for(function()
    return #deliveries == 3
  end)
  local buf = state.preview.buf
  key("P")
  deliveries[3]()
  vim.wait(50, function()
    return false
  end)
  assert(not state.preview and not api.nvim_buf_is_valid(buf))
  vim.uv.fs_read = read
  tree.close()
end)

h.test("leaving Files, closing windows and wiping buffers release previews", function()
  for _, action in ipairs({ "leave", "tree", "float", "buffer", "tab" }) do
    local state = open("a.txt")
    local float = state.preview
    if action == "leave" then
      api.nvim_set_current_win(state.target_win)
    elseif action == "tree" then
      api.nvim_win_close(state.win, true)
    elseif action == "float" then
      api.nvim_win_close(float.win, true)
    elseif action == "buffer" then
      api.nvim_buf_delete(float.buf, { force = true })
    else
      vim.cmd.tabnew()
    end
    assert(not state.preview and not api.nvim_win_is_valid(float.win))
    assert(not api.nvim_buf_is_valid(float.buf))
    if action == "tab" then
      vim.cmd.tabclose()
    end
    tree.close()
  end
end)

h.test("closing the only Files window with a preview releases its lock", function()
  local state = open("a.txt")
  api.nvim_win_close(state.target_win, true)
  -- Entering the remaining Files window may close an existing preview on leave.
  if not state.preview then
    key("P")
  end
  tree.close()
  h.eq(nil, tree.state())
  h.eq(1, #api.nvim_tabpage_list_wins(0))
  h.eq(false, vim.wo.winfixbuf)
end)

h.finish()
