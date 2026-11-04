local M = {}
M.defaults = {
  lsp = { enabled = true, timeout_ms = 1500 },
  tree = { width = 40, side = "left", show_hidden = false, follow = true, max_entries = 5000 },
  yazi = { command = "yazi", bridge = true, width = 0.9, height = 0.85 },
}
M.options = vim.deepcopy(M.defaults)

function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
  assert(M.options.tree.side == "left" or M.options.tree.side == "right", "tree.side must be left or right")
  assert(M.options.tree.width >= 10, "tree.width must be at least 10")
  assert(M.options.lsp.timeout_ms > 0, "lsp.timeout_ms must be positive")
end

return M
