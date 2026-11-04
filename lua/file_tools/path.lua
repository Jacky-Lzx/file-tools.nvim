local M = {}

function M.absolute(path)
  assert(type(path) == "string" and path ~= "" and not path:find("\0"), "expected a non-empty path")
  local absolute =
    vim.fs.normalize(vim.fn.fnamemodify(path, ":p"), { expand_env = false }):gsub("/$", ""):gsub("^$", "/")
  if absolute == "/" then
    return absolute
  end
  local parent, suffix = vim.fs.dirname(absolute), vim.fs.basename(absolute)
  while not vim.uv.fs_realpath(parent) and parent ~= "/" do
    suffix = vim.fs.basename(parent) .. "/" .. suffix
    parent = vim.fs.dirname(parent)
  end
  return (vim.uv.fs_realpath(parent) or parent):gsub("/$", "") .. "/" .. suffix
end

function M.contains(root, path)
  return root == path or path:sub(1, #root + (root == "/" and 0 or 1)) == root .. (root == "/" and "" or "/")
end

function M.remap(path, from, to)
  return M.contains(from, path) and (to .. path:sub(#from + 1)) or path
end

return M
