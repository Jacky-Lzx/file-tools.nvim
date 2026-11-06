local M = {}

function M.setup(opts)
  assert(opts == nil or type(opts) == "table", "file-tools.nvim: setup expects a table")
  opts = vim.deepcopy(opts or {})
  require("file_tools.config").setup(opts)
  require("file_tools.commands").setup()
end

function M.dispose()
  for _, name in ipairs({ "tree", "privileged", "theme" }) do
    local module = package.loaded["file_tools." .. name]
    if module and module.dispose then
      module.dispose()
    end
  end
  local commands = package.loaded["file_tools.user_command"]
  if commands then
    for _, name in ipairs({ "FileTools", "FileToolsRead", "FileToolsWrite" }) do
      commands.delete(name)
    end
  end
  require("file_tools.config").setup()
end

for _, name in ipairs({ "open_external", "open_at_cursor" }) do
  M[name] = function(...)
    return require("file_tools.opener")[name](...)
  end
end

function M.capabilities()
  return require("file_tools.lsp").capabilities()
end

for _, name in ipairs({ "open", "close", "toggle", "find" }) do
  M[name] = function(...)
    return require("file_tools.tree")[name](...)
  end
end

for _, name in ipairs({ "create", "rename", "copy", "delete", "reconcile" }) do
  M[name] = function(...)
    return require("file_tools.operations")[name](...)
  end
end

for _, name in ipairs({ "read", "write" }) do
  M["privileged_" .. name] = function(...)
    return require("file_tools.privileged")[name](...)
  end
end

return M
