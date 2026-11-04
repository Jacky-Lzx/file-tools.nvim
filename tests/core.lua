local h = dofile("tests/helpers.lua")
local op, uv = require("file_tools.operations"), vim.uv
local api = vim.api
local original_clients = vim.lsp.get_clients
local clients = {}
vim.lsp.get_clients = function(opts)
  if opts and opts.bufnr then
    return {}
  end
  return clients
end

local function client(id, filters, root)
  local calls = {}
  local server = {
    id = id,
    config = { root_dir = root or h.root },
    offset_encoding = "utf-16",
    server_capabilities = { workspace = { fileOperations = {} } },
    calls = calls,
    request_sync = function(self, method, params)
      calls[#calls + 1] = { method, params }
      return { result = self.edit }
    end,
    notify = function(_, method, params)
      calls[#calls + 1] = { method, params }
    end,
  }
  for _, key in ipairs({ "willCreate", "didCreate", "willRename", "didRename", "willDelete", "didDelete" }) do
    server.server_capabilities.workspace.fileOperations[key] =
      { filters = filters or { { pattern = { glob = "**/*" } } } }
  end
  return server
end

h.test("exclusive create, mkdir and literal names", function()
  local name = h.root .. "/a % # [中].txt"
  assert(op.create(name))
  assert(not op.create(name))
  assert(op.create(h.root .. "/dir", { directory = true }))
  assert(not op.create(h.root .. "/missing/file"))
  h.eq(0, uv.fs_stat(name).size)
end)

h.test("rename dirty descendants without saving and retain buffer identity", function()
  local from = h.root .. "/project"
  local name = h.write(from .. "/child.txt")
  local buf = vim.fn.bufadd(name)
  vim.fn.bufload(buf)
  api.nvim_buf_set_lines(buf, 0, -1, false, { "unsaved" })
  assert(op.rename(from, h.root .. "/moved"))
  h.eq(h.root .. "/moved/child.txt", api.nvim_buf_get_name(buf))
  h.eq({ "unsaved" }, api.nvim_buf_get_lines(buf, 0, -1, false))
  assert(vim.bo[buf].modified)
  h.eq({ "original" }, vim.fn.readfile(h.root .. "/moved/child.txt"))
  api.nvim_buf_call(buf, function()
    vim.cmd.write()
  end)
  h.eq({ "unsaved" }, vim.fn.readfile(h.root .. "/moved/child.txt"))
end)

h.test("destination buffers and path boundaries are protected", function()
  local name = h.write(h.root .. "/source")
  local buf = vim.fn.bufadd(h.root .. "/target")
  vim.fn.bufload(buf)
  local source = vim.fn.bufadd(name)
  vim.fn.bufload(source)
  assert(not op.rename(name, h.root .. "/target"))
  assert(uv.fs_stat(name))
  h.eq(false, require("file_tools.path").contains(h.root .. "/a", h.root .. "/ab"))
end)

h.test("delete refuses unsaved data and preserves split layout", function()
  local name = h.write(h.root .. "/delete.txt")
  vim.cmd.edit(vim.fn.fnameescape(name))
  local buf = api.nvim_get_current_buf()
  api.nvim_buf_set_lines(buf, 0, -1, false, { "dirty" })
  assert(not op.delete(name))
  vim.bo[buf].modified = false
  vim.cmd.vsplit()
  local windows = #api.nvim_list_wins()
  assert(op.delete(name))
  h.eq(windows, #api.nvim_list_wins())
  assert(not api.nvim_buf_is_valid(buf))
  vim.cmd.only()
  local dir = h.root .. "/nonempty"
  h.write(dir .. "/child")
  assert(not op.delete(dir))
  assert(op.delete(dir, { recursive = true }))
end)

h.test("copy retains symlinks and refuses directory cycles", function()
  local dir = h.root .. "/copy"
  h.write(dir .. "/file")
  assert(uv.fs_symlink("file", dir .. "/link"))
  assert(op.copy(dir, h.root .. "/copied"))
  h.eq("file", uv.fs_readlink(h.root .. "/copied/link"))
  assert(not op.copy(dir, dir .. "/nested"))
  assert(uv.fs_symlink(dir, h.root .. "/alias"))
  assert(not op.rename(dir, h.root .. "/alias/child"))
end)

h.test("LSP filters, workspace boundary and operation ordering", function()
  local server = client(1, { { scheme = "file", pattern = { glob = "**/*.lua", matches = "file" } } })
  local unrelated = client(2, nil, h.root .. "/other")
  clients = { server, unrelated }
  local from = h.write(h.root .. "/before.lua")
  local reference = h.write(h.root .. "/ref.lua", { "😀 before" })
  local buf = vim.fn.bufadd(reference)
  vim.fn.bufload(buf)
  server.edit = {
    changes = {
      [vim.uri_from_fname(reference)] = {
        {
          range = { start = { line = 0, character = 3 }, ["end"] = { line = 0, character = 9 } },
          newText = "after",
        },
      },
    },
  }
  assert(op.rename(from, h.root .. "/after.lua"))
  h.eq("workspace/willRenameFiles", server.calls[1][1])
  h.eq("workspace/didRenameFiles", server.calls[2][1])
  h.eq(0, #unrelated.calls)
  h.eq({ "😀 after" }, api.nvim_buf_get_lines(buf, 0, -1, false))
  h.eq({ "😀 before" }, vim.fn.readfile(reference))
  assert(vim.bo[buf].modified)
  server.edit = nil
  assert(op.create(h.root .. "/skip.txt"))
  h.eq(2, #server.calls)
end)

h.test("LSP timeout and unsafe edits abort before filesystem change", function()
  local from = h.write(h.root .. "/abort.lua")
  local server = client(1)
  clients = { server }
  server.request_sync = function()
    return nil, "timeout"
  end
  assert(not op.rename(from, h.root .. "/abort-new.lua"))
  assert(uv.fs_stat(from))
  server = client(1)
  clients = { server }
  server.edit = { documentChanges = { { kind = "delete", uri = vim.uri_from_fname(from) } } }
  assert(not op.rename(from, h.root .. "/abort-new.lua"))
  h.eq(1, #server.calls)
end)

h.test("dynamic registration and case-insensitive filters", function()
  local server = client(1, {})
  server.dynamic_capabilities = {
    get = function(_, method)
      if method == "workspace/didCreateFiles" then
        return {
          {
            registerOptions = {
              filters = { { pattern = { glob = "**/*.LUA", options = { ignoreCase = true } } } },
            },
          },
        }
      end
    end,
  }
  clients = { server }
  assert(op.create(h.root .. "/dynamic.lua"))
  h.eq("workspace/didCreateFiles", server.calls[1][1])
end)

h.test("failed filesystem mutation rolls back will edits", function()
  local name = h.write(h.root .. "/rollback.lua")
  local buf = vim.fn.bufadd(name)
  vim.fn.bufload(buf)
  local server = client(1)
  clients = { server }
  server.edit = {
    changes = {
      [vim.uri_from_fname(name)] = {
        {
          range = { start = { line = 0, character = 0 }, ["end"] = { line = 0, character = 8 } },
          newText = "updated",
        },
      },
    },
  }
  local rename = uv.fs_rename
  uv.fs_rename = function()
    return nil, "injected failure"
  end
  local result = op.rename(name, h.root .. "/rollback-new.lua")
  uv.fs_rename = rename
  assert(not result)
  h.eq({ "original" }, api.nvim_buf_get_lines(buf, 0, -1, false))
  assert(not vim.bo[buf].modified)
  h.eq(1, #server.calls)
end)

h.test("external changes are post-only and preserve dirty deleted buffers", function()
  local name = h.write(h.root .. "/external.lua")
  local buf = vim.fn.bufadd(name)
  vim.fn.bufload(buf)
  local server = client(1)
  clients = { server }
  assert(uv.fs_rename(name, h.root .. "/external-new.lua"))
  assert(op.reconcile({ kind = "Rename", path = name, to = h.root .. "/external-new.lua" }))
  h.eq("workspace/didRenameFiles", server.calls[1][1])
  h.eq(h.root .. "/external-new.lua", api.nvim_buf_get_name(buf))
  api.nvim_buf_set_lines(buf, 0, -1, false, { "keep me" })
  assert(uv.fs_unlink(h.root .. "/external-new.lua"))
  assert(op.reconcile({ kind = "Delete", path = h.root .. "/external-new.lua" }))
  h.eq("", api.nvim_buf_get_name(buf))
  h.eq({ "keep me" }, api.nvim_buf_get_lines(buf, 0, -1, false))
  assert(vim.bo[buf].modified)
end)

vim.lsp.get_clients = original_clients
h.finish()
