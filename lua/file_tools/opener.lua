local M = {}

local function resolve(target)
  -- Keep URI schemes (including mailto:) and absolute paths literal.
  if target:match("^%a:[/\\]") or target:match("^%a[%w+.-]*:") or target:match("^[/\\]") then
    return target
  end
  if target == "~" or target:match("^~[/\\]") then
    return vim.fn.expand("~") .. target:sub(2)
  end

  local cwd = vim.fn.getcwd()
  local name = vim.api.nvim_buf_get_name(0)
  local directory = name ~= "" and vim.fs.dirname(name) or cwd
  local from_file = vim.fs.joinpath(directory, target)
  local from_cwd = vim.fs.joinpath(cwd, target)
  if vim.uv.fs_stat(from_file) then
    return from_file
  end
  if vim.uv.fs_stat(from_cwd) then
    return from_cwd
  end
  local root = vim.fs.root(0, { ".git" })
  local from_root = root and vim.fs.joinpath(root, target)
  if from_root and vim.uv.fs_stat(from_root) then
    return from_root
  end
  return from_cwd
end

---Open a path or URI with the system application. Returns true or nil, error.
function M.open_external(target)
  if type(target) ~= "string" or vim.trim(target) == "" then
    return nil, "No path or URL found"
  end
  local open = require("file_tools.config").options.opener or vim.ui.open
  local ok, result, err = pcall(open, resolve(vim.trim(target)))
  if not ok then
    return nil, tostring(result)
  end
  if not result or err then
    return nil, err or "Failed to start system opener"
  end
  return true
end

---Open the active Visual selection or the path/URI under the cursor.
function M.open_at_cursor()
  local mode = vim.api.nvim_get_mode().mode
  local target
  if mode == "v" or mode == "V" or mode == "\22" then
    target = table.concat(
      vim.fn.getregion(vim.fn.getpos("v"), vim.fn.getpos("."), {
        type = mode,
        exclusive = vim.o.selection == "exclusive",
      }),
      "\n"
    )
    vim.cmd.normal({ args = { "\27" }, bang = true })
  else
    target = vim.fn.expand("<cfile>")
  end
  local ok, err = M.open_external(target)
  if not ok then
    vim.notify(err, vim.trim(target) == "" and vim.log.levels.WARN or vim.log.levels.ERROR)
  end
  return ok, err
end

return M
