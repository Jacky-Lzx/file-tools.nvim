local h = dofile("tests/helpers.lua")
local api, uv = vim.api, vim.uv
local privileged = require("file_tools.privileged")
local fake = h.root .. "/sudo"
vim.fn.writefile({
  "#!/bin/sh",
  'if [ "$1" = "-n" ] && [ "$2" = "-v" ]; then exit 0; fi',
  'if [ "$1" = "-n" ]; then shift; fi',
  'if [ "$1" = "--" ]; then shift; fi',
  'exec "$@"',
}, fake)
assert(uv.fs_chmod(fake, 448))
local function operation(kind, path, opts)
  local done, success, err
  opts = vim.tbl_extend("force", opts or {}, {
    sudo = fake,
    on_done = function(ok, failure)
      success, err, done = ok, failure, true
    end,
  })
  local state = privileged[kind](path, opts)
  assert(
    vim.wait(5000, function()
      return done
    end, 10),
    "operation timed out"
  )
  return success, err, state
end
local function edit(path)
  vim.cmd("enew!")
  api.nvim_buf_set_name(0, path)
end
h.test("literal paths, native encoding, BOM and CRLF", function()
  local name = h.root .. "/literal $() `quoted` 中.txt"
  edit(name)
  api.nvim_buf_set_lines(0, 0, -1, false, { "héllo", "中文" })
  vim.bo.fileformat, vim.bo.fileencoding, vim.bo.bomb = "dos", "utf-16le", true
  assert(operation("write"))
  assert(not vim.bo.modified)
  local fd = assert(uv.fs_open(name, "r", 0))
  local bytes = assert(uv.fs_read(fd, uv.fs_fstat(fd).size, 0))
  uv.fs_close(fd)
  assert(bytes:sub(1, 2) == "\255\254" and bytes:find("\r\0\n\0", 1, true))
  vim.bo.fileencoding, vim.bo.fileformat, vim.bo.bomb = "utf-8", "unix", false
  assert(operation("read", nil, { force = true }))
  h.eq({ "héllo", "中文" }, api.nvim_buf_get_lines(0, 0, -1, false))
  h.eq("utf-16le", vim.bo.fileencoding)
  h.eq("dos", vim.bo.fileformat)
  assert(vim.bo.bomb and not vim.bo.modified)
end)
h.test("shorter writes truncate and alternate targets retain dirty state", function()
  local name = h.write(h.root .. "/truncate", { string.rep("long", 100) })
  edit(name)
  api.nvim_buf_set_lines(0, 0, -1, false, { "short" })
  vim.bo.fileencoding, vim.bo.fileformat, vim.bo.bomb = "utf-8", "unix", false
  assert(operation("write"))
  h.eq({ "short" }, vim.fn.readfile(name))
  api.nvim_buf_set_lines(0, 0, -1, false, { "other" })
  assert(operation("write", h.root .. "/other"))
  assert(vim.bo.modified and api.nvim_buf_get_name(0) == name)
end)
h.test("no final EOL and empty files round trip", function()
  edit(h.root .. "/noeol")
  api.nvim_buf_set_lines(0, 0, -1, false, { "no newline" })
  vim.bo.endofline, vim.bo.fixendofline = false, false
  assert(operation("write"))
  h.eq("no newline", table.concat(vim.fn.readfile(api.nvim_buf_get_name(0), "b"), "\n"))
  assert(operation("read"))
  assert(not vim.bo.endofline)
  local empty = h.root .. "/empty"
  vim.fn.writefile({}, empty, "b")
  assert(operation("read", empty))
  h.eq({ "" }, api.nvim_buf_get_lines(0, 0, -1, false))
end)
h.test("read dirty guard, errors, busy guard and cancellation preserve text", function()
  api.nvim_buf_set_lines(0, 0, -1, false, { "dirty" })
  assert(not pcall(privileged.read, nil, { sudo = fake }))
  local success = operation("read", h.root .. "/missing", { force = true })
  assert(not success and vim.bo.modified)
  h.eq({ "dirty" }, api.nvim_buf_get_lines(0, 0, -1, false))
  local cancelled
  local state = privileged.write(nil, {
    sudo = fake,
    on_done = function(ok, err)
      assert(not ok)
      cancelled = err
    end,
  })
  assert(not pcall(privileged.write, nil, { sudo = fake }))
  state.cancel()
  assert(cancelled == "cancelled" and vim.bo.modified)
end)
h.test("edits during authentication do not reach disk", function()
  local name = h.root .. "/stale"
  edit(name)
  api.nvim_buf_set_lines(0, 0, -1, false, { "snapshot" })
  local done, failure
  privileged.write(nil, {
    sudo = fake,
    on_done = function(ok, err)
      assert(not ok)
      done, failure = true, err
    end,
  })
  api.nvim_buf_set_lines(0, 0, -1, false, { "newer" })
  assert(vim.wait(3000, function()
    return done
  end, 10))
  assert(failure:find("Buffer changed", 1, true), failure)
  assert(not uv.fs_stat(name) and vim.bo.modified)
end)
h.test("encoding changes during authentication are guarded", function()
  edit(h.root .. "/changed-encoding")
  api.nvim_buf_set_lines(0, 0, -1, false, { "snapshot" })
  local done, failure
  privileged.write(nil, {
    sudo = fake,
    on_done = function(ok, err)
      assert(not ok)
      done, failure = true, err
    end,
  })
  vim.bo.fileformat = vim.bo.fileformat == "dos" and "unix" or "dos"
  assert(vim.wait(3000, function()
    return done
  end, 10))
  assert(failure:find("Buffer changed", 1, true), failure)
  assert(not uv.fs_stat(api.nvim_buf_get_name(0)))
end)
h.test("native save bookkeeping allows the next ordinary write", function()
  edit(h.root .. "/native-save")
  api.nvim_buf_set_lines(0, 0, -1, false, { "first save" })
  local posts = 0
  local id = api.nvim_create_autocmd("BufWritePost", {
    buffer = 0,
    callback = function()
      posts = posts + 1
    end,
  })
  assert(operation("write"))
  h.eq(1, posts)
  api.nvim_buf_set_lines(0, 0, -1, false, { "ordinary save" })
  vim.cmd.write()
  h.eq({ "ordinary save" }, vim.fn.readfile(api.nvim_buf_get_name(0)))
  h.eq(2, posts)
  api.nvim_del_autocmd(id)
end)
h.test("custom writers are rejected before transfer", function()
  local id = api.nvim_create_autocmd("BufWriteCmd", {
    buffer = 0,
    callback = function()
      error("must not run")
    end,
  })
  assert(not pcall(privileged.write, nil, { sudo = fake }))
  api.nvim_del_autocmd(id)
end)
h.test("commands load the implementation only when called", function()
  require("file_tools").setup({})
  assert(vim.fn.exists(":FileToolsRead") == 2 and vim.fn.exists(":FileToolsWrite") == 2)
end)
h.finish()
