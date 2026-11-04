if vim.g.loaded_file_tools then
  return
end
vim.g.loaded_file_tools = true
require("file_tools.commands").setup()
