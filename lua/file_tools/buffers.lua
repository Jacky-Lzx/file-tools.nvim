local api, path = vim.api, require("file_tools.path")
local M = {}

local function check_write_handlers(buf, name)
  local handlers = api.nvim_get_autocmds({ event = "BufWriteCmd" })
  for _, handler in ipairs(handlers) do
    local matches = handler.buffer == buf
    if not handler.buffer then
      local pattern = vim.fn.glob2regpat(handler.pattern)
      matches = vim.fn.match(name, pattern) >= 0 or vim.fn.match(vim.fs.basename(name), pattern) >= 0
    end
    assert(not matches, "cannot rename a buffer with a custom BufWriteCmd handler")
  end
end

local function clear_write_guard(buf)
  -- :file (also nvim_buf_set_name) sets BF_NOTEDITED. A no-op BufWriteCmd
  -- acknowledges the existing disk file without saving unsaved text, so the
  -- next ordinary :write works. Preflight excludes other custom write handlers.
  local modified = vim.bo[buf].modified
  local history
  local levels = vim.bo[buf].undolevels
  if levels == -123456 then
    levels = vim.go.undolevels
  end
  if modified and levels >= 0 then
    history = assert(vim.uv.fs_mkdtemp(vim.fn.tempname() .. "-XXXXXX"))
  end
  local autocmd = api.nvim_create_autocmd("BufWriteCmd", {
    buffer = buf,
    once = true,
    callback = function()
      vim.bo[buf].modified = false
    end,
  })
  local ok, err = pcall(api.nvim_buf_call, buf, function()
    -- Marking the no-op write complete changes undo save points. Retain them
    -- through a private, short-lived native undo file for dirty buffers.
    if history then
      vim.cmd("silent noautocmd wundo! " .. vim.fn.fnameescape(history .. "/undo"))
    end
    local wrote, failure = pcall(vim.cmd, "silent keepalt write!")
    if history then
      vim.cmd("silent noautocmd rundo " .. vim.fn.fnameescape(history .. "/undo"))
    end
    assert(wrote, failure)
  end)
  pcall(api.nvim_del_autocmd, autocmd)
  if history then
    vim.fn.delete(history, "rf")
  end
  vim.bo[buf].modified = modified
  assert(ok, err)
end

function M.under(root)
  local result = {}
  for _, buf in ipairs(api.nvim_list_bufs()) do
    local name = api.nvim_buf_get_name(buf)
    if name ~= "" and vim.bo[buf].buftype == "" and path.contains(root, name) then
      result[#result + 1] = { buf = buf, name = name }
    end
  end
  return result
end

function M.check_destination(to, sources)
  sources = sources or {}
  for _, buf in ipairs(api.nvim_list_bufs()) do
    assert(
      sources[buf] or not path.contains(to, api.nvim_buf_get_name(buf)),
      "destination has an existing buffer: " .. api.nvim_buf_get_name(buf)
    )
  end
end

function M.check_rename(from, to)
  local sources = {}
  for _, item in ipairs(M.under(from)) do
    sources[item.buf] = true
  end
  M.check_destination(to, sources)
  for _, item in ipairs(M.under(from)) do
    local target = path.remap(item.name, from, to)
    if api.nvim_buf_is_loaded(item.buf) then
      check_write_handlers(item.buf, target)
    end
  end
end

-- Public detach/attach APIs send didClose/didOpen without saving a dirty buffer.
function M.rename(from, to)
  for _, item in ipairs(M.under(from)) do
    local clients = vim.lsp.get_clients({ bufnr = item.buf })
    for _, client in ipairs(clients) do
      vim.lsp.buf_detach_client(item.buf, client.id)
    end
    api.nvim_buf_set_name(item.buf, path.remap(item.name, from, to))
    -- :file creates an unloaded alternate buffer under the old name.
    local alternate = vim.fn.bufnr(item.name)
    if alternate > 0 and alternate ~= item.buf and not api.nvim_buf_is_loaded(alternate) then
      api.nvim_buf_delete(alternate, { force = true })
    end
    if api.nvim_buf_is_loaded(item.buf) then
      clear_write_guard(item.buf)
    end
    for _, client in ipairs(clients) do
      vim.lsp.buf_attach_client(item.buf, client.id)
    end
  end
end

function M.check_delete(root)
  for _, item in ipairs(M.under(root)) do
    assert(not vim.bo[item.buf].modified, "unsaved buffer: " .. item.name)
  end
end

function M.delete(root)
  for _, item in ipairs(M.under(root)) do
    if vim.bo[item.buf].modified then
      -- An external deletion must never discard unsaved work.
      for _, client in ipairs(vim.lsp.get_clients({ bufnr = item.buf })) do
        vim.lsp.buf_detach_client(item.buf, client.id)
      end
      api.nvim_buf_set_name(item.buf, "")
      vim.b[item.buf].file_tools_deleted_path = item.name
      vim.notify(
        "file-tools: kept unsaved deleted file as an unnamed buffer: " .. item.name,
        vim.log.levels.WARN
      )
    else
      local replacement
      for _, win in ipairs(vim.fn.win_findbuf(item.buf)) do
        replacement = replacement or api.nvim_create_buf(true, false)
        api.nvim_win_set_buf(win, replacement)
      end
      api.nvim_buf_delete(item.buf, { force = true })
    end
  end
end

return M
