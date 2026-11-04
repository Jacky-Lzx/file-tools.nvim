local h = dofile("tests/helpers.lua")
local api = vim.api
local files = require("file_tools")
local tree = require("file_tools.tree")
local ns = api.nvim_create_namespace("file_tools.tree")
h.write(h.root .. "/src/子.lua")
h.write(h.root .. "/Dockerfile")
h.write(h.root .. "/unknown.file-tools-extension")
assert(vim.uv.fs_symlink(h.root .. "/src/子.lua", h.root .. "/link.lua"))

local function row(state, name)
  for index, node in ipairs(state.nodes) do
    if node.name == name then
      return index, node, api.nvim_buf_get_lines(state.buf, index - 1, index, false)[1]
    end
  end
  error("missing node " .. name)
end

local state = tree.open({ root = h.root })
h.test("standalone tree uses generic icons and open/closed folders", function()
  local index, node, line = row(state, "src")
  h.eq("▸  src", line)
  state.expanded[node.path] = true
  tree.refresh(state, node.path)
  h.eq("▾  src", select(3, row(state, "src")))
  local _, child, child_line = row(state, "子.lua")
  h.eq("     子.lua", child_line)
  h.eq("子.lua", child_line:sub(child.name_col + 1))
  h.eq({ index, #"▾  " }, api.nvim_win_get_cursor(state.win))
  h.eq("   link.lua →", select(3, row(state, "link.lua")))
end)

h.test("icons can be disabled without loading a provider", function()
  files.setup({ tree = { icons = false } })
  package.preload["nvim-web-devicons"] = function()
    error("disabled icons must not load a provider")
  end
  tree.refresh(state, h.root .. "/src")
  h.eq("▾ src", select(3, row(state, "src")))
  h.eq("    子.lua", select(3, row(state, "子.lua")))
  h.eq({ 2, #"▾ " }, api.nvim_win_get_cursor(state.win))
  assert(not package.loaded["nvim-web-devicons"])
end)

h.test("late provider supplies filename icons and separate byte-accurate colors", function()
  package.preload["nvim-web-devicons"] = function()
    return {
      get_icon = function(name, ext, opts)
        h.eq(nil, ext)
        h.eq({ default = true, strict = true }, opts)
        return name == "Dockerfile" and "" or "", "FileToolsTestIcon"
      end,
    }
  end
  api.nvim_set_hl(0, "FileToolsTestIcon", { fg = "#123456" })
  files.setup({})
  tree.refresh(state, h.root .. "/src/子.lua")
  h.eq("   Dockerfile", select(3, row(state, "Dockerfile")))
  local index, node, line = row(state, "子.lua")
  h.eq("     子.lua", line)
  h.eq({ index, #"     " }, api.nvim_win_get_cursor(state.win))
  local found = false
  for _, mark in ipairs(api.nvim_buf_get_extmarks(state.buf, ns, 0, -1, { details = true })) do
    local details = mark[4]
    if mark[2] == index - 1 and details.hl_group == "FileToolsTestIcon" then
      h.eq(#"    ", mark[3])
      h.eq(node.name_col - 1, details.end_col)
      h.eq(110, details.priority)
      found = true
    end
  end
  assert(found, "provider icon must have its own highlight above the filename color")
  h.eq("   link.lua →", select(3, row(state, "link.lua")))
end)

package.loaded["nvim-web-devicons"], package.preload["nvim-web-devicons"] = nil, nil
local provider_root = vim.env.FILE_TOOLS_DEVICONS or vim.fn.stdpath("data") .. "/lazy/nvim-web-devicons"
if vim.uv.fs_stat(provider_root .. "/lua/nvim-web-devicons.lua") then
  vim.opt.runtimepath:append(provider_root)
  h.test("real devicons resolves filenames, extensions and unknown files", function()
    local provider = require("nvim-web-devicons")
    tree.refresh(state)
    for _, name in ipairs({ "Dockerfile", "子.lua", "unknown.file-tools-extension", "link.lua" }) do
      local icon, group = provider.get_icon(name, nil, { default = true, strict = true })
      local _, _, line = row(state, name)
      assert(line:find(icon .. " " .. name, 1, true), "missing real icon for " .. name)
      assert(api.nvim_get_hl(0, { name = group, link = false }).fg)
    end
  end)
else
  assert(not vim.env.FILE_TOOLS_DEVICONS, "FILE_TOOLS_DEVICONS does not contain nvim-web-devicons")
  print("skip real devicons integration: checkout unavailable")
end
tree.close()
h.finish()
