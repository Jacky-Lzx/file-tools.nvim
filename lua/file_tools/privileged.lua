local M = {}
local api, uv = vim.api, vim.uv
local pending = {}
local file_options = { "binary", "fileencoding", "fileformat", "bomb", "endofline", "fixendofline" }

local function stat(path)
  local s = uv.fs_stat(path)
  return s and { s.dev, s.ino, s.size, s.mtime.sec, s.mtime.nsec } or false
end

local function serialize(buf, path)
  local scratch = api.nvim_create_buf(false, true)
  local ok, err = pcall(function()
    vim.bo[scratch].buftype = ""
    api.nvim_buf_set_lines(scratch, 0, -1, false, api.nvim_buf_get_lines(buf, 0, -1, false))
    for _, option in ipairs(file_options) do
      vim.bo[scratch][option] = vim.bo[buf][option]
    end
    api.nvim_buf_call(scratch, function()
      vim.cmd("silent noautocmd keepalt write! " .. vim.fn.fnameescape(path))
    end)
    assert(uv.fs_chmod(path, 384))
  end)
  api.nvim_buf_delete(scratch, { force = true })
  assert(ok, err)
end

local function deserialize(path)
  local scratch = api.nvim_create_buf(false, true)
  local ok, result = pcall(function()
    vim.bo[scratch].buftype = ""
    api.nvim_buf_set_name(scratch, path)
    api.nvim_buf_call(scratch, function()
      vim.cmd("silent noautocmd keepalt edit! " .. vim.fn.fnameescape(path))
    end)
    local data = { lines = api.nvim_buf_get_lines(scratch, 0, -1, false), options = {} }
    for _, option in ipairs(file_options) do
      data.options[option] = vim.bo[scratch][option]
    end
    return data
  end)
  api.nvim_buf_delete(scratch, { force = true })
  assert(ok, result)
  return result
end

local function operate(kind, path, opts)
  opts = opts or {}
  for _, key in ipairs({ "timeout_ms", "auth_timeout_ms" }) do
    assert(opts[key] == nil or type(opts[key]) == "number" and opts[key] > 0, key .. " must be positive")
  end
  local buf = opts.buf or api.nvim_get_current_buf()
  if buf == 0 then
    buf = api.nvim_get_current_buf()
  end
  assert(api.nvim_buf_is_loaded(buf) and vim.bo[buf].buftype == "", "expected a loaded file buffer")
  assert(not pending[buf], "A privileged operation is already running for this buffer")
  assert(
    kind ~= "read" or not vim.bo[buf].modified or opts.force,
    "Buffer has unsaved changes; use ! to discard them"
  )
  assert(kind ~= "read" or vim.bo[buf].modifiable, "Buffer is not modifiable")
  local name, tick = api.nvim_buf_get_name(buf), api.nvim_buf_get_changedtick(buf)
  assert(not (path or name):match("^%a[%w+.-]*://"), "expected a local file path")
  path = require("file_tools.path").absolute(path or name)
  if kind == "read" then
    local existing = vim.fn.bufnr(path)
    assert(existing == -1 or existing == buf, "Target already has another buffer")
  end
  local sudo = opts.sudo or "sudo"
  assert(type(sudo) == "string" and vim.fn.executable(sudo) == 1, "sudo executable is unavailable")
  local directory = vim.fn.tempname()
  assert(vim.fn.mkdir(directory, "p", 448) == 1, "Cannot create private staging directory")
  local stage = directory .. "/contents"
  local state = { done = false, buf = buf, path = path }
  pending[buf] = state
  local initial_stat = stat(path)
  local function unchanged()
    return api.nvim_buf_is_loaded(buf)
      and api.nvim_buf_get_name(buf) == name
      and api.nvim_buf_get_changedtick(buf) == tick
  end
  local function finish(err)
    if state.done then
      return
    end
    state.done, pending[buf] = true, nil
    if state.timer then
      state.timer:stop()
      state.timer:close()
      state.timer = nil
    end
    if state.process then
      state.process:kill(15)
      state.process = nil
    end
    if state.auth_job then
      vim.fn.jobstop(state.auth_job)
      state.auth_job = nil
    end
    if state.auth_buf and api.nvim_buf_is_valid(state.auth_buf) then
      if
        api.nvim_get_current_buf() == state.auth_buf
        and state.origin_win
        and api.nvim_win_is_valid(state.origin_win)
      then
        api.nvim_set_current_win(state.origin_win)
        vim.cmd.stopinsert()
      end
      api.nvim_buf_delete(state.auth_buf, { force = true })
    end
    if state.group then
      api.nvim_del_augroup_by_id(state.group)
    end
    vim.fn.delete(directory, "rf")
    state.error = err
    if opts.on_done then
      opts.on_done(not err, err)
    else
      vim.notify(
        err and ("file-tools: " .. err) or ("Privileged " .. kind .. ": " .. path),
        err and vim.log.levels.ERROR or vim.log.levels.INFO
      )
    end
  end
  function state.cancel()
    finish("cancelled")
  end
  state.group = api.nvim_create_augroup("FileToolsPrivileged" .. buf, { clear = true })
  api.nvim_create_autocmd({ "BufWipeout", "VimLeavePre" }, {
    group = state.group,
    callback = function(ev)
      if ev.event == "VimLeavePre" or ev.buf == buf or ev.buf == state.auth_buf then
        if ev.buf == state.auth_buf then
          state.auth_buf = nil -- It is already being wiped by the caller.
        end
        finish("cancelled")
      end
    end,
  })
  local function execute(command, callback)
    local ok, process = pcall(vim.system, command, { timeout = opts.timeout_ms or 30000 }, function(result)
      vim.schedule(function()
        if not state.done then
          state.process = nil
          callback(result)
        end
      end)
    end)
    if not ok then
      finish(tostring(process))
    else
      state.process = process
    end
  end
  local function guard()
    assert(unchanged(), "Buffer changed while waiting; retry the operation")
    if kind == "write" then
      assert(
        vim.deep_equal(initial_stat, stat(path)),
        "Target changed while waiting; inspect it before retrying"
      )
    end
  end
  local function completed(code, stderr)
    if code ~= 0 then
      finish((stderr or "sudo transfer failed"):gsub("%s+$", "") .. " (exit " .. code .. ")")
      return
    end
    local ok, err = pcall(function()
      if kind == "read" then
        assert(unchanged(), "Buffer changed during read; contents were not replaced")
        assert(vim.bo[buf].modifiable, "Buffer is no longer modifiable")
        local data = deserialize(stage)
        local existing = vim.fn.bufnr(path)
        assert(existing == -1 or existing == buf, "Target now has another buffer")
        if name ~= path then
          api.nvim_buf_set_name(buf, path)
        end
        api.nvim_buf_set_lines(buf, 0, -1, false, data.lines)
        for _, option in ipairs(file_options) do
          vim.bo[buf][option] = data.options[option]
        end
        vim.bo[buf].modified = false
        api.nvim_buf_call(buf, function()
          if vim.bo[buf].filetype == "" then
            vim.cmd("filetype detect")
          end
          api.nvim_exec_autocmds("BufReadPost", { buffer = buf, modeline = false })
        end)
      elseif unchanged() and name ~= "" and require("file_tools.path").absolute(name) == path then
        vim.bo[buf].modified = false
        api.nvim_exec_autocmds("BufWritePost", { buffer = buf, modeline = false })
      end
    end)
    finish(not ok and tostring(err) or nil)
  end
  local source, destination = kind == "read" and path or stage, kind == "read" and stage or path
  local function transfer()
    local ok, err = pcall(guard)
    if not ok then
      finish(tostring(err))
      return
    end
    execute({ sudo, "-n", "--", "/bin/dd", "if=" .. source, "of=" .. destination }, function(result)
      completed(result.code, result.stderr)
    end)
  end
  local function authenticate()
    state.origin_win = api.nvim_get_current_win()
    vim.cmd("botright 8new")
    state.auth_buf = api.nvim_get_current_buf()
    vim.bo[state.auth_buf].bufhidden, vim.bo[state.auth_buf].swapfile = "wipe", false
    -- Authentication and transfer must share a sudo invocation: credential
    -- caches may be scoped to a PTY or parent process. The fixed helper waits
    -- for a gate so edits made during the password prompt are checked first.
    local ready, gate = directory .. "/ready", directory .. "/go"
    local helper =
      'umask 077; : > "$1"; n=0; while [ ! -f "$2" ]; do n=$((n+1)); [ "$n" -lt 1200 ] || exit 124; sleep 0.1; done; exec /bin/dd "if=$3" "of=$4"'
    local ok, job = pcall(
      vim.fn.jobstart,
      { sudo, "--", "/bin/sh", "-c", helper, "file-tools", ready, gate, source, destination },
      {
        term = true,
        on_exit = function(_, code)
          vim.schedule(function()
            if not state.done then
              state.auth_job = nil
              completed(code)
            end
          end)
        end,
      }
    )
    if not ok or job <= 0 then
      finish("Cannot start sudo authentication: " .. tostring(job))
      return
    end
    state.auth_job = job
    state.timer = uv.new_timer()
    local deadline = uv.hrtime() + (opts.auth_timeout_ms or 120000) * 1e6
    state.timer:start(
      20,
      20,
      vim.schedule_wrap(function()
        if state.done then
          return
        end
        if uv.hrtime() > deadline then
          finish("sudo authentication timed out")
        elseif uv.fs_stat(ready) then
          state.timer:stop()
          state.timer:close()
          state.timer = nil
          local valid, failure = pcall(function()
            guard()
            local fd = assert(uv.fs_open(gate, "wx", 384))
            uv.fs_close(fd)
          end)
          if not valid then
            finish(tostring(failure))
          end
        end
      end)
    )
    vim.cmd.startinsert()
  end
  local prepared, failure = pcall(function()
    if kind == "write" then
      serialize(buf, stage)
    else
      local fd = assert(uv.fs_open(stage, "wx", 384))
      uv.fs_close(fd)
    end
    execute({ sudo, "-n", "-v" }, function(result)
      if result.code == 0 then
        transfer()
      elseif #api.nvim_list_uis() == 0 then
        finish("sudo requires authentication; retry in an interactive Neovim")
      else
        authenticate()
      end
    end)
  end)
  if not prepared then
    finish(tostring(failure))
  end
  return state
end

function M.read(path, opts)
  return operate("read", path, opts)
end

function M.write(path, opts)
  return operate("write", path, opts)
end

return M
