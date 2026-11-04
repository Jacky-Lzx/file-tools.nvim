local api, uv = vim.api, vim.uv
local path = require("file_tools.path")
local M, states = {}, {}
local ns = api.nvim_create_namespace("file_tools.tree")

local function options()
  return require("file_tools.config").options.tree
end
local function valid(state)
  return state and state.win and api.nvim_win_is_valid(state.win)
end
local function report(err)
  vim.notify("file-tools: " .. tostring(err), vim.log.levels.ERROR)
end
local function label(text)
  return vim.fn.strtrans(text)
end

local function selected(state)
  if not valid(state) then
    return
  end
  return state.nodes[api.nvim_win_get_cursor(state.win)[1]]
end

local function stop_watchers(state)
  for _, watcher in pairs(state.watchers) do
    watcher:stop()
    if not watcher:is_closing() then
      watcher:close()
    end
  end
  state.watchers = {}
end

local function queue_refresh(state)
  if state.pending or not valid(state) then
    return
  end
  state.pending = true
  vim.defer_fn(function()
    state.pending = false
    if valid(state) then
      M.refresh(state)
    end
  end, 60)
end

local function watch(state, directories)
  for name, watcher in pairs(state.watchers) do
    if not directories[name] then
      watcher:stop()
      if not watcher:is_closing() then
        watcher:close()
      end
      state.watchers[name] = nil
    end
  end
  local count = vim.tbl_count(state.watchers)
  for name in pairs(directories) do
    if count >= 64 then
      break
    end
    if not state.watchers[name] then
      local watcher = uv.new_fs_event()
      if watcher then
        local ok = watcher:start(
          name,
          {},
          vim.schedule_wrap(function()
            queue_refresh(state)
          end)
        )
        if ok then
          state.watchers[name], count = watcher, count + 1
        else
          watcher:close()
        end
      end
    end
  end
end

function M.refresh(state, focus_path)
  state = state or states[api.nvim_get_current_tabpage()]
  if not valid(state) then
    return
  end
  local old = selected(state)
  focus_path = focus_path or (old and old.path)
  local lines, nodes, highlights, directories = {}, {}, {}, {}
  local limit, truncated = options().max_entries, false
  local function append(node, text, group)
    nodes[#nodes + 1], lines[#lines + 1] = node, text
    highlights[#highlights + 1] = { #lines - 1, group }
  end
  append({ path = state.root, directory = true, depth = -1 }, label(state.root), "FileToolsRoot")
  local function walk(directory, depth)
    if #nodes >= limit then
      truncated = true
      return
    end
    local scan, err = uv.fs_scandir(directory)
    if not scan then
      append(
        { path = directory, error = true, depth = depth },
        string.rep("  ", depth) .. "! " .. label(err),
        "DiagnosticError"
      )
      return
    end
    directories[directory] = true
    local children = {}
    while true do
      local name, kind = uv.fs_scandir_next(scan)
      if not name then
        break
      end
      if state.show_hidden or name:sub(1, 1) ~= "." then
        if #children >= limit - #nodes then
          truncated = true
          break
        end
        children[#children + 1] = {
          name = name,
          path = vim.fs.joinpath(directory, name),
          directory = kind == "directory",
          link = kind == "link",
          depth = depth,
        }
      end
    end
    table.sort(children, function(a, b)
      if a.directory ~= b.directory then
        return a.directory
      end
      return a.name:lower() == b.name:lower() and a.name < b.name or a.name:lower() < b.name:lower()
    end)
    for _, child in ipairs(children) do
      if #nodes >= limit then
        truncated = true
        break
      end
      local marker = child.directory and (state.expanded[child.path] and "▾ " or "▸ ") or "  "
      append(
        child,
        string.rep("  ", depth) .. marker .. label(child.name) .. (child.link and " →" or ""),
        child.directory and "FileToolsDirectory" or child.link and "FileToolsSymlink" or "FileToolsFile"
      )
      if child.directory and state.expanded[child.path] then
        walk(child.path, depth + 1)
      end
    end
  end
  walk(state.root, 0)
  if truncated then
    append({ error = true }, "… entry limit reached; narrow the root", "DiagnosticWarn")
  end
  state.nodes = nodes
  vim.bo[state.buf].modifiable = true
  api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)
  vim.bo[state.buf].modifiable = false
  api.nvim_buf_clear_namespace(state.buf, ns, 0, -1)
  for _, item in ipairs(highlights) do
    api.nvim_buf_set_extmark(state.buf, ns, item[1], 0, { end_col = #lines[item[1] + 1], hl_group = item[2] })
  end
  local row = math.min(api.nvim_win_get_cursor(state.win)[1], #lines)
  for index, node in ipairs(nodes) do
    if node.path == focus_path then
      row = index
      break
    end
  end
  local node = nodes[row]
  local col = node.depth and node.depth >= 0 and (node.depth * 2 + 2) or 0
  api.nvim_win_set_cursor(state.win, { row, math.min(col, #lines[row]) })
  watch(state, directories)
end

local function reveal(state, name)
  if not name or name == "" or not path.contains(state.root, name) then
    return
  end
  local directory = vim.fs.dirname(name)
  while path.contains(state.root, directory) do
    state.expanded[directory] = true
    if directory == state.root then
      break
    end
    directory = vim.fs.dirname(directory)
  end
  M.refresh(state, name)
end

local function target_window(state)
  if
    state.target_win
    and api.nvim_win_is_valid(state.target_win)
    and state.target_win ~= state.win
    and api.nvim_win_get_tabpage(state.target_win) == state.tab
  then
    return state.target_win
  end
  for _, win in ipairs(api.nvim_tabpage_list_wins(state.tab)) do
    if win ~= state.win and api.nvim_win_get_config(win).relative == "" then
      return win
    end
  end
  api.nvim_set_current_win(state.win)
  vim.cmd("rightbelow vsplit")
  local win = api.nvim_get_current_win()
  api.nvim_win_set_buf(win, api.nvim_create_buf(true, false))
  state.target_win = win
  return win
end

local function open_node(state, mode)
  local node = selected(state)
  if not node or node.error then
    return
  end
  if node.directory then
    state.expanded[node.path] = not state.expanded[node.path]
    M.refresh(state)
    return
  end
  local ok, err = pcall(function()
    api.nvim_set_current_win(target_window(state))
    if mode == "tab" then
      vim.cmd.tabnew()
    elseif mode == "split" then
      vim.cmd.split()
    elseif mode == "vsplit" then
      vim.cmd.vsplit()
    end
    vim.cmd.edit(vim.fn.fnameescape(node.path))
    if mode ~= "tab" then
      state.target_win = api.nvim_get_current_win()
    end
  end)
  if not ok then
    report(err)
  end
end

local function operate(state, action)
  local node = selected(state)
  if not node or node.error then
    return
  end
  local captured = node.path
  local function input(prompt, default, callback)
    vim.ui.input({ prompt = prompt, default = default, completion = "file" }, function(value)
      if not value or value == "" then
        return
      end
      local ok, err = callback(value)
      if not ok then
        report(err)
      end
      if valid(state) then
        M.refresh(state)
      end
    end)
  end
  local ops = require("file_tools.operations")
  if action == "create" then
    local parent = node.directory and captured or vim.fs.dirname(captured)
    input("Create (trailing / for directory): ", parent .. "/", function(value)
      return ops.create(value, { directory = value:sub(-1) == "/" })
    end)
  elseif captured == state.root then
    report("select a child of the root")
  elseif action == "rename" then
    input("Move to: ", captured, function(value)
      local event, err = ops.rename(captured, value)
      if event and valid(state) then
        reveal(state, event.to)
      end
      return event, err
    end)
  elseif action == "delete" then
    vim.ui.select(
      { "Cancel", "Delete permanently" },
      { prompt = "Delete " .. label(captured) .. "?" },
      function(value)
        if value == "Delete permanently" then
          local event, err = ops.delete(captured, { recursive = true })
          if not event then
            report(err)
          end
          if valid(state) then
            M.refresh(state)
          end
        end
      end
    )
  end
end

local function parent_node(state)
  local node = selected(state)
  if not node or node.error then
    return
  end
  if node.directory and state.expanded[node.path] then
    state.expanded[node.path] = nil
    M.refresh(state)
  else
    M.refresh(state, vim.fs.dirname(node.path))
  end
end

local function map(state)
  local keys = {
    ["<CR>"] = function()
      open_node(state)
    end,
    l = function()
      open_node(state)
    end,
    ["<2-LeftMouse>"] = function()
      open_node(state)
    end,
    h = function()
      parent_node(state)
    end,
    q = function()
      M.close(state.tab)
    end,
    s = function()
      open_node(state, "vsplit")
    end,
    S = function()
      open_node(state, "split")
    end,
    t = function()
      open_node(state, "tab")
    end,
    a = function()
      operate(state, "create")
    end,
    r = function()
      operate(state, "rename")
    end,
    d = function()
      operate(state, "delete")
    end,
    R = function()
      M.refresh(state)
    end,
    ["."] = function()
      state.show_hidden = not state.show_hidden
      M.refresh(state)
    end,
    ["-"] = function()
      state.root = vim.fs.dirname(state.root)
      M.refresh(state)
    end,
    C = function()
      local node = selected(state)
      if node and node.directory then
        state.root = node.path
        M.refresh(state)
      end
    end,
    f = function()
      local win = target_window(state)
      reveal(state, api.nvim_buf_get_name(api.nvim_win_get_buf(win)))
    end,
    y = function()
      local node = selected(state)
      if node and node.path then
        state.clipboard = { path = node.path, cut = false }
        vim.notify("file-tools: copied path")
      end
    end,
    x = function()
      local node = selected(state)
      if node and node.path and node.path ~= state.root then
        state.clipboard = { path = node.path, cut = true }
        vim.notify("file-tools: cut path")
      end
    end,
    p = function()
      local node, clip = selected(state), state.clipboard
      if not node or not node.path or not clip then
        return
      end
      local destination = (node.directory and node.path or vim.fs.dirname(node.path))
        .. "/"
        .. vim.fs.basename(clip.path)
      local event, err =
        require("file_tools.operations")[clip.cut and "rename" or "copy"](clip.path, destination)
      if event then
        if clip.cut then
          state.clipboard = nil
        end
        reveal(state, destination)
      else
        report(err)
      end
    end,
    Y = function()
      local node = selected(state)
      if node and node.path then
        vim.fn.setreg('"', node.path)
        vim.fn.setreg("+", node.path)
      end
    end,
    ["?"] = function()
      vim.notify(
        "file-tools tree\nEnter/l open or fold · h parent/fold · s/S split · t tab\na create · r move · d delete · y/x copy/cut · p paste · Y copy path\n. hidden · R refresh · - parent root · C set root · f reveal · q close\n/ search filenames with Neovim's normal search",
        vim.log.levels.INFO
      )
    end,
  }
  for key, callback in pairs(keys) do
    vim.keymap.set(
      "n",
      key,
      callback,
      { buffer = state.buf, silent = true, nowait = true, desc = "File tree: " .. key }
    )
  end
end

function M.open(opts)
  opts = opts or {}
  local tab, current = api.nvim_get_current_tabpage(), api.nvim_get_current_win()
  local state = states[tab]
  if valid(state) then
    if opts.root then
      local root = path.absolute(opts.root)
      assert(uv.fs_stat(root) and uv.fs_stat(root).type == "directory", "invalid tree root: " .. root)
      state.root = root
    end
    if opts.reveal then
      reveal(state, path.absolute(opts.reveal))
    else
      M.refresh(state)
    end
    if opts.focus ~= false then
      api.nvim_set_current_win(state.win)
    end
    return state
  end
  local root = path.absolute(opts.root or vim.fn.getcwd())
  assert(uv.fs_stat(root) and uv.fs_stat(root).type == "directory", "invalid tree root: " .. root)
  state = {
    tab = tab,
    root = root,
    expanded = {},
    watchers = {},
    nodes = {},
    show_hidden = options().show_hidden,
    target_win = current,
  }
  states[tab] = state
  state.buf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_name(state.buf, "file-tools://tree/" .. tab)
  vim.bo[state.buf].bufhidden = "wipe"
  vim.bo[state.buf].filetype = "file-tools"
  vim.bo[state.buf].swapfile = false
  vim.bo[state.buf].undolevels = -1
  state.win =
    api.nvim_open_win(state.buf, true, { split = options().side, win = -1, width = options().width })
  for name, value in pairs({
    number = false,
    relativenumber = false,
    signcolumn = "no",
    wrap = false,
    cursorline = true,
    winfixwidth = true,
    foldcolumn = "0",
    spell = false,
    list = false,
  }) do
    vim.wo[state.win][name] = value
  end
  map(state)
  api.nvim_create_autocmd("BufWipeout", {
    buffer = state.buf,
    once = true,
    callback = function()
      stop_watchers(state)
      if states[tab] == state then
        states[tab] = nil
      end
    end,
  })
  if opts.reveal then
    reveal(state, path.absolute(opts.reveal))
  end
  M.refresh(state)
  if opts.focus == false and api.nvim_win_is_valid(current) then
    api.nvim_set_current_win(current)
  end
  return state
end

function M.close(tab)
  tab = tab or api.nvim_get_current_tabpage()
  local state = states[tab]
  if not state then
    return
  end
  stop_watchers(state)
  states[tab] = nil
  if valid(state) then
    if #api.nvim_tabpage_list_wins(tab) == 1 then
      api.nvim_win_set_buf(state.win, api.nvim_create_buf(true, false))
    else
      api.nvim_win_close(state.win, true)
    end
  end
  if api.nvim_buf_is_valid(state.buf) then
    api.nvim_buf_delete(state.buf, { force = true })
  end
end

function M.toggle(opts)
  if valid(states[api.nvim_get_current_tabpage()]) then
    M.close()
  else
    return M.open(opts)
  end
end

function M.find(opts)
  opts = vim.tbl_extend("force", {}, opts or {}, { reveal = api.nvim_buf_get_name(0) })
  if opts.reveal == "" then
    opts.reveal = nil
  end
  local state = states[api.nvim_get_current_tabpage()]
  if
    opts.reveal
    and not path.contains(
      state and state.root or path.absolute(opts.root or vim.fn.getcwd()),
      path.absolute(opts.reveal)
    )
  then
    opts.root = vim.fs.dirname(opts.reveal)
  end
  return M.open(opts)
end

function M.state()
  return states[api.nvim_get_current_tabpage()]
end

function M.setup()
  local group = api.nvim_create_augroup("FileToolsTree", { clear = true })
  local function highlights()
    for name, link in pairs({ Root = "Title", Directory = "Directory", File = "Normal", Symlink = "Special" }) do
      api.nvim_set_hl(0, "FileTools" .. name, { default = true, link = link })
    end
  end
  highlights()
  api.nvim_create_autocmd("ColorScheme", { group = group, callback = highlights })
  api.nvim_create_autocmd("BufEnter", {
    group = group,
    callback = function(ev)
      local state = states[api.nvim_get_current_tabpage()]
      if valid(state) and vim.bo[ev.buf].buftype == "" then
        state.target_win = api.nvim_get_current_win()
        if options().follow then
          reveal(state, api.nvim_buf_get_name(ev.buf))
        end
      end
    end,
  })
  api.nvim_create_autocmd("User", {
    group = group,
    pattern = "FileToolsChanged",
    callback = function(ev)
      for _, state in pairs(states) do
        if ev.data.kind == "Rename" then
          state.root = path.remap(state.root, ev.data.path, ev.data.to)
          local expanded = {}
          for name, value in pairs(state.expanded) do
            expanded[path.remap(name, ev.data.path, ev.data.to)] = value
          end
          state.expanded = expanded
        end
        queue_refresh(state)
      end
    end,
  })
  api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    callback = function()
      for _, state in pairs(states) do
        stop_watchers(state)
      end
    end,
  })
end

M.setup()
return M
