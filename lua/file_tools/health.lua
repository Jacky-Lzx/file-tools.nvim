local M = {}
function M.check()
  vim.health.start("file-tools.nvim")
  if vim.fn.has("nvim-0.11") == 1 then
    vim.health.ok("Neovim 0.11+")
  else
    vim.health.error("Neovim 0.11+ required")
  end
  vim.health.ok("No mandatory external dependencies")
  vim.health.info(
    "Merge require('file_tools').capabilities() before starting LSP clients for file-operation registrations"
  )
end
return M
