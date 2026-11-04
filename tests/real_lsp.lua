local h = dofile("tests/helpers.lua")
local api = vim.api
local integrated = vim.env.FILE_TOOLS_INTEGRATED == "1"
local files
if not integrated then
  files = require("file_tools")
  files.setup({ lsp = { timeout_ms = 10000 } })
end
h.write(
  h.root .. "/tsconfig.json",
  { '{"compilerOptions":{"module":"commonjs","strict":true},"include":["*.ts"]}' }
)
local source = h.write(h.root .. "/before.ts", { "export const value = 1;" })
local reference =
  h.write(h.root .. "/main.ts", { 'import { value } from "./before";', "console.log(value);" })
vim.cmd.edit(source)
files = files or require("file_tools")
local source_buf = api.nvim_get_current_buf()
local start = integrated and assert(_G.config_test_real_lsp_start) or vim.lsp.start
local capabilities = integrated and vim.deepcopy(vim.lsp.config["ts_ls"].capabilities)
  or vim.tbl_deep_extend("force", vim.lsp.protocol.make_client_capabilities(), files.capabilities())
assert(capabilities.workspace.fileOperations.willRename, "Missing configured file-operation capabilities")
if integrated then
  assert(
    capabilities.textDocument.completion.completionItem.snippetSupport,
    "Missing configured completion capabilities"
  )
end
local id = assert(start({
  name = "file-tools-typescript-test",
  cmd = { "typescript-language-server", "--stdio" },
  root_dir = h.root,
  init_options = vim.env.FILE_TOOLS_TSSERVER and { tsserver = { path = vim.env.FILE_TOOLS_TSSERVER } } or nil,
  capabilities = capabilities,
}))
local client = assert(vim.lsp.get_client_by_id(id))
assert(
  vim.wait(15000, function()
    return client.initialized
      and vim.tbl_get(client.server_capabilities, "workspace", "fileOperations", "willRename") ~= nil
  end, 50),
  "TypeScript file operation capability missing"
)
local ref_buf = vim.fn.bufadd(reference)
vim.fn.bufload(ref_buf)
assert(vim.lsp.buf_attach_client(ref_buf, id))
-- Allow tsserver's project initialization to settle before querying references.
assert(
  vim.wait(10000, function()
    local response = client:request_sync("textDocument/definition", {
      textDocument = { uri = vim.uri_from_fname(reference) },
      position = { line = 1, character = 14 },
    }, 1000, ref_buf)
    return response and response.result and #response.result > 0
  end, 100),
  "TypeScript project did not initialize"
)

h.test("real TypeScript rename updates imports and retains dirty source", function()
  api.nvim_buf_set_lines(source_buf, 0, -1, false, { "export const value = 2;" })
  local event, err = files.rename(source, h.root .. "/after.ts")
  assert(event, err)
  local lines = api.nvim_buf_get_lines(ref_buf, 0, -1, false)
  assert(lines[1]:find("./after", 1, true), vim.inspect(lines))
  assert(vim.bo[ref_buf].modified)
  h.eq(h.root .. "/after.ts", api.nvim_buf_get_name(source_buf))
  h.eq({ "export const value = 1;" }, vim.fn.readfile(h.root .. "/after.ts"))
  assert(vim.bo[source_buf].modified)
  assert(client.attached_buffers[source_buf])
  local response = client:request_sync("textDocument/hover", {
    textDocument = { uri = vim.uri_from_fname(h.root .. "/after.ts") },
    position = { line = 0, character = 13 },
  }, 5000, source_buf)
  assert(response and response.result and response.result ~= vim.NIL, "server lost renamed buffer")
  api.nvim_buf_call(source_buf, function()
    vim.cmd("silent write")
  end)
  h.eq({ "export const value = 2;" }, vim.fn.readfile(h.root .. "/after.ts"))
  api.nvim_buf_call(source_buf, function()
    vim.cmd.undo()
  end)
  h.eq({ "export const value = 1;" }, api.nvim_buf_get_lines(source_buf, 0, -1, false))
end)
client:stop(true)
vim.wait(1000, function()
  return client:is_stopped()
end, 10)
h.finish()
