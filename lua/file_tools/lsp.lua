local api, path = vim.api, require("file_tools.path")
local M = {}

function M.capabilities()
  return {
    workspace = {
      fileOperations = {
        dynamicRegistration = true,
        didCreate = true,
        willCreate = true,
        didRename = true,
        willRename = true,
        didDelete = true,
        willDelete = true,
      },
    },
  }
end

local function in_workspace(client, name)
  local roots = {}
  for _, folder in ipairs(client.workspace_folders or {}) do
    roots[#roots + 1] = vim.uri_to_fname(folder.uri)
  end
  if client.config and client.config.root_dir then
    roots[#roots + 1] = client.config.root_dir
  end
  for _, root in ipairs(roots) do
    if path.contains(path.absolute(root), name) then
      return true
    end
  end
  -- Rootless servers are eligible only for their own attached file paths.
  for buf in pairs(client.attached_buffers or {}) do
    if path.contains(name, api.nvim_buf_get_name(buf)) then
      return true
    end
  end
  return false
end

local function match_filter(filter, name, directory)
  if filter.scheme and filter.scheme ~= "file" then
    return false
  end
  local pattern = filter.pattern or {}
  if pattern.matches and pattern.matches ~= (directory and "folder" or "file") then
    return false
  end
  local glob = pattern.glob
  if not glob then
    return false
  end
  if pattern.options and pattern.options.ignoreCase then
    glob, name = glob:lower(), name:lower()
  end
  local matcher = vim.glob.to_lpeg(glob)
  return matcher:match(name) ~= nil
end

local function registrations(client, key)
  local result = {}
  local static = vim.tbl_get(client.server_capabilities or {}, "workspace", "fileOperations", key)
  if type(static) == "table" then
    result[#result + 1] = static
  end
  local dynamic = client.dynamic_capabilities
  if dynamic then
    for _, registration in ipairs(dynamic:get("workspace/" .. key .. "Files") or {}) do
      result[#result + 1] = registration.registerOptions or {}
    end
  end
  return result
end

function M.targets(event, phase)
  local key, result = phase .. event.kind, {}
  for _, client in ipairs(vim.lsp.get_clients()) do
    local names = { event.path, event.to }
    local eligible = false
    for _, name in ipairs(names) do
      if in_workspace(client, name) then
        for _, registration in ipairs(registrations(client, key)) do
          for _, filter in ipairs(registration.filters or {}) do
            eligible = eligible or match_filter(filter, name, event.directory)
          end
        end
      end
    end
    if eligible then
      result[#result + 1] = client
    end
  end
  table.sort(result, function(a, b)
    return a.id < b.id
  end)
  return result
end

local function params(event)
  local file = event.kind == "Rename"
      and { oldUri = vim.uri_from_fname(event.path), newUri = vim.uri_from_fname(event.to) }
    or { uri = vim.uri_from_fname(event.path) }
  return { files = { file } }
end

-- Collect every server response before touching buffers. Resource operations and
-- multiple servers editing the same document are rejected rather than guessed.
function M.prepare(event)
  if not require("file_tools.config").options.lsp.enabled then
    return {}
  end
  local plans, seen = {}, {}
  for _, client in ipairs(M.targets(event, "will")) do
    local response, err = client:request_sync(
      "workspace/will" .. event.kind .. "Files",
      params(event),
      require("file_tools.config").options.lsp.timeout_ms
    )
    assert(
      response and not response.err,
      "LSP file operation failed: " .. vim.inspect(err or (response and response.err))
    )
    local edit = response.result
    if edit and edit ~= vim.NIL then
      local documents = {}
      for uri, edits in pairs(edit.changes or {}) do
        documents[#documents + 1] = { textDocument = { uri = uri }, edits = edits }
      end
      for _, change in ipairs(edit.documentChanges or {}) do
        assert(change.textDocument, "LSP resource operations in will-file edits are unsupported")
        documents[#documents + 1] = change
      end
      for _, document in ipairs(documents) do
        local uri = document.textDocument.uri
        assert(uri:sub(1, 7) == "file://", "LSP edit is not a file URI")
        assert(not seen[uri], "multiple LSP edits target the same document: " .. uri)
        seen[uri] = true
        for _, edit_item in ipairs(document.edits) do
          assert(not edit_item.annotationId, "LSP annotated edits require manual review")
        end
        local buf = vim.uri_to_bufnr(uri)
        vim.fn.bufload(buf)
        local version = document.textDocument.version
        assert(
          not version or version == vim.NIL or version == vim.lsp.util.buf_versions[buf],
          "stale LSP edit: " .. uri
        )
        assert(vim.bo[buf].modifiable, "LSP edit targets a non-modifiable buffer")
        plans[#plans + 1] = {
          buf = buf,
          tick = api.nvim_buf_get_changedtick(buf),
          edits = document.edits,
          encoding = client.offset_encoding or "utf-16",
          lines = api.nvim_buf_get_lines(buf, 0, -1, false),
          modified = vim.bo[buf].modified,
        }
      end
    end
  end
  for _, plan in ipairs(plans) do
    assert(api.nvim_buf_get_changedtick(plan.buf) == plan.tick, "buffer changed during LSP request")
    -- Validate edits using Neovim's own encoding/range implementation.
    local scratch = api.nvim_create_buf(false, true)
    api.nvim_buf_set_lines(scratch, 0, -1, false, plan.lines)
    local ok, err = pcall(vim.lsp.util.apply_text_edits, vim.deepcopy(plan.edits), scratch, plan.encoding)
    api.nvim_buf_delete(scratch, { force = true })
    assert(ok, err)
  end
  return plans
end

function M.apply(plans)
  for _, plan in ipairs(plans) do
    assert(api.nvim_buf_get_changedtick(plan.buf) == plan.tick, "buffer changed before LSP edit")
  end
  for _, plan in ipairs(plans) do
    plan.applied = true
    vim.lsp.util.apply_text_edits(vim.deepcopy(plan.edits), plan.buf, plan.encoding)
  end
end

function M.rollback(plans)
  for _, plan in ipairs(plans) do
    if plan.applied and api.nvim_buf_is_valid(plan.buf) then
      api.nvim_buf_set_lines(plan.buf, 0, -1, false, plan.lines)
      vim.bo[plan.buf].modified = plan.modified
    end
  end
end

function M.notify(event)
  if not require("file_tools.config").options.lsp.enabled then
    return
  end
  for _, client in ipairs(M.targets(event, "did")) do
    client:notify("workspace/did" .. event.kind .. "Files", params(event))
  end
end

return M
