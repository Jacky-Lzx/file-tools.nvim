local api, uv = vim.api, vim.uv
local M, session, last_directory = {}, nil, nil

local function options()
  return require("file_tools.config").options.yazi
end
local function report(message)
  vim.notify("file-tools: " .. tostring(message), vim.log.levels.WARN)
end

-- The last comma-delimited field is JSON and can itself contain commas.
function M.parse(line, id)
  local kind, _, sender, body = line:match("^([^,]+),([^,]+),([^,]+),(.*)$")
  if not kind then
    return {}
  end
  local ok, data = pcall(vim.json.decode, body)
  if not ok or type(data) ~= "table" then
    return {}
  end
  if kind == "hey" then
    return {}, data.peers and data.peers[tostring(id)] ~= nil
  end
  if sender ~= tostring(id) then
    return {}
  end
  local events = {}
  local function add(operation, from, to)
    if type(from) ~= "string" or (to ~= nil and type(to) ~= "string") then
      return
    end
    -- Archive/search/SFTP URLs do not name local filesystem entries.
    if from:find("://", 1, true) or (to and to:find("://", 1, true)) then
      return
    end
    if from:sub(1, 1) ~= "/" or (to and to:sub(1, 1) ~= "/") then
      return
    end
    events[#events + 1] = { kind = operation, path = from, to = to }
  end
  if kind == "rename" then
    add("Rename", data.from, data.to)
  elseif kind == "move" then
    for _, item in ipairs(data.items or {}) do
      add("Rename", item.from, item.to)
    end
  elseif kind == "bulk-rename" or kind == "bulk" then
    for from, to in pairs(data.changes or {}) do
      add("Rename", from, to)
    end
  elseif kind == "delete" or kind == "trash" then
    for _, name in ipairs(data.urls or {}) do
      add("Delete", name)
    end
  end
  return events
end

local function feed(state, data)
  state.partial = state.partial .. data
  while true do
    local newline = state.partial:find("\n", 1, true)
    if not newline then
      break
    end
    local line = state.partial:sub(1, newline - 1)
    state.partial = state.partial:sub(newline + 1)
    local ok, events, ready = pcall(M.parse, line, state.id)
    if ok then
      if ready then
        state.bridge_ready = true
      end
      for _, event in ipairs(events) do
        local success, err = require("file_tools.operations").reconcile(event)
        if not success then
          report(err)
        end
      end
    end
  end
  -- Do not retain arbitrary output forever if an unexpected peer sends junk.
  if #state.partial > 1024 * 1024 then
    state.partial = ""
  end
end

local function subscribe(state, attempt)
  if session ~= state or state.exited then
    return
  end
  local stderr = ""
  local ok, process = pcall(vim.system, { "ya", "sub", "hey,rename,move,delete,trash,bulk-rename" }, {
    text = true,
    stdout = function(_, data)
      if data then
        vim.schedule(function()
          if session == state then
            feed(state, data)
          end
        end)
      end
    end,
    stderr = function(_, data)
      if data and #stderr < 4096 then
        stderr = stderr .. data
      end
    end,
  }, function(result)
    vim.schedule(function()
      if session ~= state or state.exited then
        return
      end
      state.subscriber, state.bridge_ready = nil, false
      if result.code ~= 0 and attempt < 20 and stderr:find("No running Yazi instance found", 1, true) then
        vim.defer_fn(function()
          subscribe(state, attempt + 1)
        end, 50)
      elseif result.code ~= 0 then
        report("Yazi event bridge stopped: " .. stderr)
      end
    end)
  end)
  if ok then
    state.subscriber = process
  else
    report(process)
  end
end

local function dimensions()
  local width = math.max(1, math.min(vim.o.columns - 2, math.floor(vim.o.columns * options().width)))
  local height = math.max(1, math.min(vim.o.lines - 4, math.floor(vim.o.lines * options().height)))
  return {
    relative = "editor",
    width = width,
    height = height,
    row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    style = "minimal",
    border = "rounded",
    title = " Yazi · <C-\\><C-n> then q to hide ",
    title_pos = "center",
  }
end

local function show(state)
  if state.win and api.nvim_win_is_valid(state.win) then
    api.nvim_set_current_win(state.win)
  else
    state.win = api.nvim_open_win(state.buf, true, dimensions())
  end
  vim.cmd.startinsert()
end

local function dispose(state)
  state.exited = true
  if state.subscriber then
    pcall(state.subscriber.kill, state.subscriber, "sigterm")
    state.subscriber = nil
  end
  if state.group then
    pcall(api.nvim_del_augroup_by_id, state.group)
  end
  if state.win and api.nvim_win_is_valid(state.win) then
    api.nvim_win_close(state.win, true)
  end
  if api.nvim_buf_is_valid(state.buf) then
    api.nvim_buf_delete(state.buf, { force = true })
  end
  vim.fn.delete(state.temp, "rf")
  if session == state then
    session = nil
  end
end

local function finish(state, code)
  if session ~= state then
    return
  end
  -- Drain any final queued DDS messages before closing the subscriber.
  local chosen, cwd = {}, nil
  if vim.fn.filereadable(state.chooser) == 1 then
    chosen = vim.fn.readfile(state.chooser)
  end
  if vim.fn.filereadable(state.cwd_file) == 1 then
    cwd = vim.fn.readfile(state.cwd_file)[1]
  end
  if cwd and uv.fs_stat(cwd) then
    last_directory = cwd
  end
  local target = state.origin_win
  dispose(state)
  vim.cmd.stopinsert()
  if target and api.nvim_win_is_valid(target) then
    api.nvim_set_current_win(target)
  end
  if code ~= 0 then
    report("Yazi exited with code " .. code)
    return
  end
  for index, name in ipairs(chosen) do
    if uv.fs_stat(name) and uv.fs_stat(name).type ~= "directory" then
      local ok, err = pcall(function()
        if index > 1 then
          vim.cmd.tabnew()
        end
        vim.cmd.edit(vim.fn.fnameescape(name))
      end)
      if not ok then
        report(err)
      end
    end
  end
  -- Never :checktime all buffers: external changes must not trigger surprise reloads.
end

function M.open(opts)
  opts = opts or {}
  if session then
    if session.exited then
      finish(session, session.exit_code or 0)
    else
      show(session)
      return session
    end
  end
  assert(vim.fn.executable(options().command) == 1, "Yazi executable not found: " .. options().command)
  local selected, origin
  if package.loaded["file_tools.tree"] then
    selected, origin = require("file_tools.tree").context()
  end
  local name = opts.path
    or (opts.cwd and vim.fn.getcwd())
    or (opts.resume and last_directory)
    or selected
    or api.nvim_buf_get_name(0)
  if not name or name == "" or name:find("://", 1, true) then
    name = vim.fn.getcwd()
  end
  name = require("file_tools.path").absolute(name)
  -- A new unsaved file is revealed through its existing parent directory.
  while not uv.fs_stat(name) and name ~= "/" do
    name = vim.fs.dirname(name)
  end
  local temp = assert(uv.fs_mkdtemp(vim.fn.tempname() .. "-XXXXXX"))
  local state = {
    temp = temp,
    chooser = temp .. "/chosen",
    cwd_file = temp .. "/cwd",
    id = tostring(uv.os_getpid()) .. tostring(math.floor(uv.hrtime() % 1000000000)),
    partial = "",
    bridge_ready = false,
    origin_win = origin or api.nvim_get_current_win(),
  }
  session = state
  state.buf = api.nvim_create_buf(false, true)
  state.group = api.nvim_create_augroup("FileToolsYazi", { clear = true })
  vim.bo[state.buf].bufhidden = "hide"
  state.win = api.nvim_open_win(state.buf, true, dimensions())
  local argv = {
    options().command,
    name,
    "--chooser-file",
    state.chooser,
    "--cwd-file",
    state.cwd_file,
    "--client-id",
    state.id,
  }
  local ok, job = pcall(vim.fn.jobstart, argv, {
    term = true,
    on_exit = function(_, code)
      state.exited, state.exit_code = true, code
      vim.defer_fn(function()
        finish(state, code)
      end, 50)
    end,
  })
  if not ok or job <= 0 then
    dispose(state)
    error("failed to start Yazi: " .. tostring(job))
  end
  state.job = job
  vim.keymap.set("n", "q", function()
    M.hide()
  end, { buffer = state.buf, desc = "Hide Yazi" })
  vim.keymap.set("n", "<Esc>", function()
    M.hide()
  end, { buffer = state.buf, desc = "Hide Yazi" })
  api.nvim_create_autocmd("VimResized", {
    group = state.group,
    callback = function()
      if session == state and state.win and api.nvim_win_is_valid(state.win) then
        local config = dimensions()
        api.nvim_win_set_config(state.win, config)
      end
    end,
  })
  api.nvim_create_autocmd("VimLeavePre", {
    group = state.group,
    once = true,
    callback = function()
      pcall(vim.fn.jobstop, state.job)
      dispose(state)
    end,
  })
  if options().bridge and vim.fn.executable("ya") == 1 then
    subscribe(state, 0)
  elseif options().bridge then
    report("ya is unavailable; file-operation events will not be synchronized")
  end
  vim.cmd.startinsert()
  return state
end

function M.hide()
  if not session then
    return
  end
  vim.cmd.stopinsert()
  if session.win and api.nvim_win_is_valid(session.win) then
    api.nvim_win_close(session.win, true)
  end
  session.win = nil
  if session.origin_win and api.nvim_win_is_valid(session.origin_win) then
    api.nvim_set_current_win(session.origin_win)
  end
end

function M.toggle(opts)
  if session and session.win and api.nvim_win_is_valid(session.win) then
    M.hide()
  else
    return M.open(opts)
  end
end

function M.close()
  if not session then
    return
  end
  local state = session
  pcall(vim.fn.jobstop, state.job)
  dispose(state)
  vim.cmd.stopinsert()
  if state.origin_win and api.nvim_win_is_valid(state.origin_win) then
    api.nvim_set_current_win(state.origin_win)
  end
end

function M.state()
  return session
end
return M
