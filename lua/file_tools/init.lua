local M = {}

function M.setup(opts)
  require("file_tools.config").setup(opts)
end

function M.capabilities()
  return require("file_tools.lsp").capabilities()
end

for _, name in ipairs({ "create", "rename", "copy", "delete", "reconcile" }) do
  M[name] = function(...)
    return require("file_tools.operations")[name](...)
  end
end

return M
