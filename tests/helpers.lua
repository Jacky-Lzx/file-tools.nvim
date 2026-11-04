local M = { count = 0 }
vim.opt.runtimepath:prepend(vim.fn.getcwd())
local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
root = assert(vim.uv.fs_realpath(root))
M.root = root

function M.eq(expected, actual)
  assert(
    vim.deep_equal(expected, actual),
    "expected " .. vim.inspect(expected) .. ", got " .. vim.inspect(actual)
  )
end

function M.write(name, lines)
  vim.fn.mkdir(vim.fs.dirname(name), "p")
  vim.fn.writefile(lines or { "original" }, name)
  return name
end

function M.test(name, fn)
  local ok, err = xpcall(fn, debug.traceback)
  if not ok then
    error(name .. ": " .. err)
  end
  M.count = M.count + 1
  print("ok " .. name)
end

function M.finish()
  vim.fn.delete(root, "rf")
  print(M.count .. " tests passed")
end

return M
