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
    "Tab image/PDF previews use optional image-tools.nvim with a Kitty graphics compatible terminal and termguicolors; PDF conversion needs ImageMagick with Ghostscript"
  )
  local themes = package.loaded.theme_tools
  if type(themes) == "table" and type(themes.on_change) == "function" then
    vim.health.ok("theme-tools shared palette API available")
  else
    vim.health.info("theme-tools not loaded; tree uses standard highlight links")
  end
  vim.health.info(
    "Merge require('file_tools').capabilities() before starting LSP clients for file-operation registrations"
  )
end
return M
