local uv = vim.uv
local M = {}

function M.remove(path)
  local stat = assert(uv.fs_lstat(path))
  if stat.type ~= "directory" then
    assert(uv.fs_unlink(path))
    return
  end
  local scan = assert(uv.fs_scandir(path))
  while true do
    local name = uv.fs_scandir_next(scan)
    if not name then
      break
    end
    M.remove(path .. "/" .. name)
  end
  assert(uv.fs_rmdir(path))
end

function M.copy(from, to)
  local stat = assert(uv.fs_lstat(from))
  if stat.type == "link" then
    assert(uv.fs_symlink(assert(uv.fs_readlink(from)), to))
  elseif stat.type == "directory" then
    assert(uv.fs_mkdir(to, stat.mode % 512))
    local scan = assert(uv.fs_scandir(from))
    while true do
      local name = uv.fs_scandir_next(scan)
      if not name then
        break
      end
      M.copy(from .. "/" .. name, to .. "/" .. name)
    end
  elseif stat.type == "file" then
    assert(uv.fs_copyfile(from, to, { excl = true }))
  else
    error("unsupported file type: " .. stat.type)
  end
end

return M
