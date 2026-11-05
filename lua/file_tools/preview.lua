local api, uv = vim.api, vim.uv
local M = {}
local media = {
  png = true,
  jpg = true,
  jpeg = true,
  gif = true,
  webp = true,
  avif = true,
  heic = true,
  bmp = true,
  tif = true,
  tiff = true,
  svg = true,
  pdf = true,
}

local function layout(state)
  local columns, lines = vim.o.columns, math.max(3, vim.o.lines - vim.o.cmdheight - 2)
  local left = api.nvim_win_get_position(state.win)[2]
  local right = left + api.nvim_win_get_width(state.win) + 1
  local start, available = right, columns - right
  if left > available then
    start, available = 0, left
  end
  if available < 16 then
    start, available = 0, columns
  end
  local width = math.max(1, math.min(100, available - 4))
  local height = math.max(1, math.min(40, math.floor(lines * 0.85) - 2))
  return {
    relative = "editor",
    style = "minimal",
    border = "rounded",
    focusable = false,
    width = width,
    height = height,
    row = math.max(0, math.floor((lines - height - 2) / 2)),
    col = math.max(0, start + math.floor((available - width - 2) / 2)),
    title = " " .. vim.fn.strtrans(vim.fs.basename(state.preview and state.preview.path or "Preview")) .. " ",
    title_pos = "center",
    zindex = 50,
  }
end

function M.close(state)
  local preview = state.preview
  if not preview then
    return
  end
  state.preview = nil
  api.nvim_del_augroup_by_id(preview.group)
  if preview.view then
    preview.view:close()
  end
  if api.nvim_win_is_valid(preview.win) then
    api.nvim_win_close(preview.win, true)
  end
  if api.nvim_buf_is_valid(preview.buf) then
    api.nvim_buf_delete(preview.buf, { force = true })
  end
end

function M.update(state, node, force)
  local preview = state.preview
  if not preview or not node then
    return
  end
  if preview.generation > 0 and not preview.follow and preview.path ~= node.path and not force then
    M.close(state)
    return
  end
  local stat = node.path and uv.fs_stat(node.path)
  local revision = stat and { stat.size, stat.mtime, stat.ctime, stat.ino }
  if
    preview.generation > 0
    and preview.path == node.path
    and vim.deep_equal(preview.revision, revision)
    and not force
  then
    return
  end
  preview.path, preview.revision = node.path, revision
  preview.generation = preview.generation + 1
  local generation = preview.generation
  local function current()
    return state.preview == preview
      and preview.generation == generation
      and api.nvim_win_is_valid(preview.win)
      and api.nvim_buf_is_valid(preview.buf)
  end
  if preview.view then
    preview.view:close()
    preview.view = nil
  end
  local function paint(draw)
    if not current() then
      return false
    end
    vim.bo[preview.buf].modifiable = true
    local ok, err = pcall(draw, preview.buf)
    vim.bo[preview.buf].modifiable = false
    if not ok then
      error(err)
    end
    return true
  end
  local function write(lines, syntax)
    paint(function(buf)
      for index, line in ipairs(lines) do
        lines[index] = line:gsub("[\r\n]", " ")
      end
      vim.bo[buf].syntax = syntax or ""
      api.nvim_buf_set_lines(buf, 0, -1, false, lines)
      api.nvim_win_set_cursor(preview.win, { 1, 0 })
    end)
  end
  api.nvim_win_set_config(preview.win, {
    title = " " .. vim.fn.strtrans(vim.fs.basename(node.path or "Preview")) .. " ",
  })
  if node.error or not node.path then
    write({ "No preview available" })
    return
  elseif node.directory then
    write({ "Directory: " .. vim.fn.strtrans(node.path) })
    return
  end
  write({ "Loading preview…" })
  -- Invalidate old work immediately; coalesce rapid navigation before doing I/O.
  vim.defer_fn(function()
    if not current() then
      return
    end
    local extension = node.path:match("%.([^./]+)$")
    if extension and media[extension:lower()] then
      local loaded, image = pcall(require, "image_tools")
      if not loaded then
        write({ "Image/PDF preview requires image-tools.nvim" })
        return
      end
      if type(image.render) ~= "function" or type(image.supports) ~= "function" then
        write({ "image-tools.nvim needs the embedded render API" })
        return
      end
      if not image.supports(node.path) then
        write({ "Unsupported image format" })
        return
      end
      local ok, view, err = pcall(image.render, {
        path = node.path,
        buf = preview.buf,
        win = preview.win,
        page = 1,
        is_valid = current,
        paint = paint,
        on_error = function(message)
          write({ "Preview: " .. tostring(message) })
        end,
      })
      if ok and view then
        if current() then
          preview.view = view
        else
          view:close()
        end
      else
        write({ "Preview: " .. tostring(ok and err or view) })
      end
      return
    end
    -- Bounded asynchronous reads keep large files and slow filesystems off the UI.
    uv.fs_open(node.path, uv.constants.O_RDONLY + uv.constants.O_NONBLOCK, 438, function(open_err, fd)
      if not fd then
        vim.schedule(function()
          write({ "Cannot preview: " .. tostring(open_err) })
        end)
        return
      end
      uv.fs_fstat(fd, function(stat_err, stat)
        if not stat or stat.type ~= "file" then
          uv.fs_close(fd)
          vim.schedule(function()
            write({ "Cannot preview: " .. tostring(stat_err or "not a regular file") })
          end)
          return
        end
        uv.fs_read(fd, math.min(stat.size, 256 * 1024), 0, function(read_err, data)
          uv.fs_close(fd)
          vim.schedule(function()
            if not current() then
              return
            elseif not data then
              write({ "Cannot preview: " .. tostring(read_err) })
            elseif data:find("\0", 1, true) then
              write({ "Binary file — no text preview" })
            else
              local lines = {}
              for line in (data .. "\n"):gmatch("(.-)\n") do
                if #lines >= 500 then
                  break
                end
                lines[#lines + 1] = line:gsub("\r$", ""):sub(1, 2000)
              end
              if stat.size > #data or #lines >= 500 then
                lines[#lines + 1] = "… preview truncated"
              end
              write(lines, vim.filetype.match({ filename = node.path }))
            end
          end)
        end)
      end)
    end)
  end, 35)
end

function M.open(state, node, follow)
  if state.preview then
    state.preview.follow = follow == true
    M.update(state, node, state.preview.path ~= (node and node.path))
    return
  end
  local buf = api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].undolevels = -1
  local win = api.nvim_open_win(buf, false, layout(state))
  local preview = { buf = buf, win = win, generation = 0, follow = follow == true }
  state.preview = preview
  for name, value in pairs({
    wrap = false,
    number = false,
    relativenumber = false,
    signcolumn = "no",
    statuscolumn = "",
    foldcolumn = "0",
    foldenable = false,
    spell = false,
    list = false,
    cursorline = false,
    winbar = "",
    winfixbuf = true,
    winhighlight = "Normal:FileToolsNormal,FloatBorder:FileToolsWinSeparator",
  }) do
    vim.wo[win][name] = value
  end
  preview.group = api.nvim_create_augroup("FileToolsPreview" .. buf, { clear = true })
  api.nvim_create_autocmd({ "WinLeave", "BufLeave", "BufWipeout" }, {
    group = preview.group,
    buffer = state.buf,
    callback = function()
      M.close(state)
    end,
  })
  api.nvim_create_autocmd("WinClosed", {
    group = preview.group,
    pattern = { tostring(win), tostring(state.win) },
    callback = function()
      M.close(state)
    end,
  })
  api.nvim_create_autocmd("BufWipeout", {
    group = preview.group,
    buffer = buf,
    callback = function()
      M.close(state)
    end,
  })
  api.nvim_create_autocmd("VimResized", {
    group = preview.group,
    callback = function()
      if state.preview == preview and api.nvim_win_is_valid(state.win) then
        api.nvim_win_set_config(win, layout(state))
        if preview.view then
          preview.view:resize()
        end
      end
    end,
  })
  M.update(state, node)
end

function M.toggle(state, node)
  if state.preview and state.preview.follow then
    M.close(state)
  else
    M.open(state, node, true)
  end
end

return M
