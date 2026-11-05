local h = dofile("tests/helpers.lua")
local api = vim.api
local preview = require("file_tools.preview")
vim.cmd("syntax enable")
h.write(h.root .. "/sample.lua", { 'return "preview"' })
h.write(h.root .. "/sample.vim", { 'let g:preview = "text"' })
h.write(h.root .. "/script", { "#!/bin/sh", "echo preview" })
h.write(h.root .. "/unknown.file_tools_unknown", { "plain text" })

local function open(name)
  local state = { buf = api.nvim_get_current_buf(), win = api.nvim_get_current_win() }
  preview.open(state, { path = h.root .. "/" .. name }, true)
  return state
end

local function ready(state, first)
  assert(
    vim.wait(2000, function()
      return api.nvim_buf_get_lines(state.preview.buf, 0, 1, false)[1] == first
    end, 10),
    "preview did not settle"
  )
  return state.preview.buf
end

local function update(state, name)
  preview.update(state, { path = h.root .. "/" .. name })
end

local function captures(buf, col)
  vim.treesitter.get_parser(buf):parse()
  local names = {}
  for _, capture in ipairs(vim.treesitter.get_captures_at_pos(buf, 0, col)) do
    names[#names + 1] = capture.capture
  end
  table.sort(names)
  return names
end

h.test("preview shares editor Tree-sitter captures without FileType side effects", function()
  local editor = api.nvim_create_buf(true, false)
  api.nvim_buf_set_lines(editor, 0, -1, false, { 'return "preview"' })
  vim.bo[editor].filetype = "lua"
  vim.treesitter.start(editor)
  local events = 0
  local autocmd = api.nvim_create_autocmd("FileType", {
    callback = function()
      events = events + 1
    end,
  })
  local state = open("sample.lua")
  local buf = ready(state, 'return "preview"')
  h.eq("lua", vim.bo[buf].filetype)
  h.eq("", vim.bo[buf].syntax)
  h.eq(0, events)
  h.eq({}, vim.lsp.get_clients({ bufnr = buf }))
  h.eq(false, vim.bo[buf].buflisted)
  h.eq(false, vim.bo[buf].modifiable)
  h.eq(false, vim.bo[buf].modified)
  assert(#captures(editor, 0) > 0, "editor keyword has no highlight capture")
  h.eq(captures(editor, 0), captures(buf, 0))
  h.eq(captures(editor, 9), captures(buf, 9))

  -- The same scratch buffer must change languages and clear transient frames.
  update(state, "sample.vim")
  h.eq("", vim.bo[buf].filetype)
  h.eq(nil, vim.treesitter.highlighter.active[buf])
  ready(state, 'let g:preview = "text"')
  h.eq("vim", vim.bo[buf].filetype)
  h.eq("vim", vim.treesitter.get_parser(buf):lang())
  assert(#captures(buf, 0) > 0)
  h.eq(0, events)
  update(state, "unknown.file_tools_unknown")
  ready(state, "plain text")
  h.eq("", vim.bo[buf].filetype)
  h.eq("", vim.bo[buf].syntax)
  h.eq(nil, vim.treesitter.highlighter.active[buf])
  update(state, "sample.lua")
  ready(state, 'return "preview"')
  preview.close(state)
  h.eq(nil, vim.treesitter.highlighter.active[buf])
  assert(not api.nvim_buf_is_valid(buf))
  api.nvim_del_autocmd(autocmd)
  api.nvim_buf_delete(editor, { force = true })
end)

h.test("filetype detection includes preview contents for extensionless files", function()
  local state = open("script")
  local buf = ready(state, "#!/bin/sh")
  h.eq("sh", vim.bo[buf].filetype)
  preview.close(state)
end)

h.test("missing parsers or queries fall back to working Vim syntax", function()
  local runtime = h.root .. "/runtime"
  h.write(runtime .. "/syntax/file_tools_missing.vim", { "syntax keyword FileToolsFallback fallback" })
  vim.opt.runtimepath:prepend(runtime)
  vim.filetype.add({ extension = { file_tools_missing = "file_tools_missing" } })
  h.write(h.root .. "/sample.file_tools_missing", { "fallback" })
  local state = open("sample.file_tools_missing")
  local buf = ready(state, "fallback")
  h.eq("file_tools_missing", vim.bo[buf].filetype)
  h.eq("file_tools_missing", vim.bo[buf].syntax)
  h.eq(nil, vim.treesitter.highlighter.active[buf])
  h.eq(
    "FileToolsFallback",
    api.nvim_buf_call(buf, function()
      return vim.fn.synIDattr(vim.fn.synID(1, 1, 1), "name")
    end)
  )
  preview.update(state, { path = h.root, directory = true })
  h.eq(nil, state.preview)
  assert(not api.nvim_buf_is_valid(buf))
  vim.opt.runtimepath:remove(runtime)
end)

h.finish()
