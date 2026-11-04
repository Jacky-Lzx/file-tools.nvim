local M = {}
M.defaults = {
  lsp = { enabled = true, timeout_ms = 1500 },
  tree = { width = 40, side = "left", show_hidden = false, follow = true, max_entries = 5000, icons = true },
}
M.options = vim.deepcopy(M.defaults)

function M.setup(opts)
  local config = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
  assert(config.tree.side == "left" or config.tree.side == "right", "tree.side must be left or right")
  assert(config.tree.width >= 10, "tree.width must be at least 10")
  assert(config.tree.max_entries >= 2, "tree.max_entries must be at least 2")
  assert(config.lsp.timeout_ms > 0, "lsp.timeout_ms must be positive")
  M.options = config
end

return M
