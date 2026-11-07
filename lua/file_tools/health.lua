local M = {}

function M.check()
  vim.health.start("file-tools.nvim")
  if vim.fn.has("nvim-0.11") == 0 then
    vim.health.error("Neovim 0.11+ is required", { "Upgrade Neovim" })
  else
    vim.health.ok("File browser runtime requirements are satisfied.")
  end
end

return M
