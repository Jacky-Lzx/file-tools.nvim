local uv, api = vim.uv, vim.api
local path, fs = require("file_tools.path"), require("file_tools.fs")
local buffers, lsp = require("file_tools.buffers"), require("file_tools.lsp")
local M, busy = {}, false

local function validate(event, opts)
  local source = uv.fs_lstat(event.path)
  if event.kind == "Create" then
    assert(not source, "path already exists: " .. event.path)
    buffers.check_destination(event.path)
  else
    assert(source, "path does not exist: " .. event.path)
    event.directory = source.type == "directory"
    assert(event.path ~= "/", "cannot operate on filesystem root")
  end
  if event.to then
    assert(not uv.fs_lstat(event.to), "destination already exists: " .. event.to)
    if event.directory then
      local parent = uv.fs_realpath(vim.fs.dirname(event.to))
      assert(
        parent and not path.contains(assert(uv.fs_realpath(event.path)), parent),
        "destination is inside source"
      )
    end
    buffers.check_rename(event.path, event.to)
  end
  local parent = vim.fs.dirname(event.to or event.path)
  assert(
    uv.fs_stat(parent) and uv.fs_stat(parent).type == "directory",
    "parent directory does not exist: " .. parent
  )
  if event.kind == "Delete" then
    buffers.check_delete(event.path)
    if event.directory and not opts.recursive then
      local scan = assert(uv.fs_scandir(event.path))
      assert(not uv.fs_scandir_next(scan), "directory is not empty; use recursive=true")
    end
  end
end

local function publish(event)
  lsp.notify(event)
  api.nvim_exec_autocmds("User", { pattern = "FileToolsChanged", data = event, modeline = false })
end

local function run(kind, name, to, opts)
  if busy then
    return nil, "another file operation is running"
  end
  busy = true
  opts = opts or {}
  local event, plans, mutated, deleting
  local ok, err = xpcall(function()
    event = {
      kind = kind,
      path = path.absolute(name),
      to = to and path.absolute(to),
      directory = opts.directory or false,
    }
    validate(event, opts)
    plans = lsp.prepare(event)
    -- Requests can process editor events; recheck paths and buffers afterwards.
    validate(event, opts)
    lsp.apply(plans)
    -- A will-delete edit may have just modified the deleted file itself.
    if kind == "Rename" then
      assert(uv.fs_rename(event.path, event.to))
    elseif kind == "Delete" then
      deleting = true
      fs.remove(event.path)
    elseif event.directory then
      assert(uv.fs_mkdir(event.path, 493))
    else
      local fd = assert(uv.fs_open(event.path, "wx", 420))
      assert(uv.fs_close(fd))
    end
    mutated = true
    if kind == "Rename" then
      buffers.rename(event.path, event.to)
    end
    if kind == "Delete" then
      buffers.delete(event.path)
    end
    publish(event)
  end, debug.traceback)
  busy = false
  if not ok then
    if plans and not mutated then
      lsp.rollback(plans)
    end
    return nil,
      (
        mutated and "filesystem changed; synchronization failed: "
        or deleting and "deletion failed and may be partial: "
        or ""
      ) .. err
  end
  return event
end

function M.create(name, opts)
  return run("Create", name, nil, opts)
end
function M.rename(from, to, opts)
  return run("Rename", from, to, opts)
end
function M.delete(name, opts)
  return run("Delete", name, nil, opts)
end

function M.copy(from, to)
  if busy then
    return nil, "another file operation is running"
  end
  busy = true
  local created, staging = false, nil
  local ok, result = xpcall(function()
    from, to = path.absolute(from), path.absolute(to)
    local stat = assert(uv.fs_lstat(from), "source does not exist")
    local event = { kind = "Create", path = to, directory = stat.type == "directory" }
    validate(event, {})
    if event.directory then
      local parent = assert(uv.fs_realpath(vim.fs.dirname(to)))
      assert(not path.contains(assert(uv.fs_realpath(from)), parent), "destination is inside source")
    end
    staging = assert(uv.fs_mkdtemp(vim.fs.dirname(to) .. "/.file-tools-copy-XXXXXX"))
    fs.copy(from, staging .. "/content")
    assert(not uv.fs_lstat(to), "destination appeared during copy")
    assert(uv.fs_rename(staging .. "/content", to))
    created = true
    -- Copy is a new path notification; it does not ask servers to refactor a source.
    publish(event)
    return event
  end, debug.traceback)
  if staging then
    pcall(fs.remove, staging)
  end
  busy = false
  if not ok then
    return nil, (created and "copy created; synchronization failed: " or "") .. result
  end
  return result
end

-- External tools have already changed the filesystem. Never run will-* here.
function M.reconcile(event)
  local ok, err = xpcall(function()
    assert(
      event.kind == "Rename" or event.kind == "Delete" or event.kind == "Create",
      "invalid external event"
    )
    event = vim.deepcopy(event)
    event.external = true
    event.path = path.absolute(event.path)
    if event.kind == "Rename" then
      event.to = path.absolute(event.to)
      assert(not uv.fs_lstat(event.path) and uv.fs_lstat(event.to), "external rename is not complete")
      event.directory = uv.fs_lstat(event.to).type == "directory"
      buffers.check_rename(event.path, event.to)
      buffers.rename(event.path, event.to)
    elseif event.kind == "Delete" then
      assert(not uv.fs_lstat(event.path), "external deletion is not complete")
      for _, item in ipairs(buffers.under(event.path)) do
        if item.name ~= event.path then
          event.directory = true
        end
      end
      buffers.delete(event.path)
    else
      assert(uv.fs_lstat(event.path), "external creation is not complete")
      event.directory = uv.fs_lstat(event.path).type == "directory"
    end
    publish(event)
  end, debug.traceback)
  if not ok then
    return nil, err
  end
  return true
end

return M
