#!/usr/bin/env python3
"""Exercise sudo's authentication terminal with a fake sudo and real PTY input."""
import fcntl
import os
from pathlib import Path
import pty
import select
import struct
import subprocess
import tempfile
import termios
import time

ROOT = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="file-tools-privileged-") as temp:
    folder = Path(temp)
    fake = folder / "sudo"
    fake.write_text("""#!/bin/sh
if [ "$1" = "-n" ]; then exit 1; fi
[ "$1" = "--" ] && shift
printf 'Test password: '
stty -echo
IFS= read -r password
stty echo
printf '\\n'
[ "$password" = "testpass" ] || exit 1
exec "$@"
""")
    fake.chmod(0o700)
    script = folder / "test.lua"
    script.write_text(r"""
vim.opt.rtp:prepend(vim.env.FILE_TOOLS_ROOT)
vim.o.swapfile = false
local api = vim.api
local folder = vim.env.FILE_TOOLS_TEST_TMP
local stage = folder .. '/stage'
local results = {}
local cases = { 'success', 'stale', 'cancel', 'failure', 'read' }
local index = 0
local function next_case()
  index = index + 1
  local case = cases[index]
  if not case then
    vim.fn.writefile(results, folder .. '/result')
    vim.cmd('qa!')
    return
  end
  vim.cmd('enew!')
  local buf = api.nvim_get_current_buf()
  local path = folder .. '/' .. case .. '.txt'
  api.nvim_buf_set_name(buf, path)
  api.nvim_buf_set_lines(buf, 0, -1, false, { 'snapshot' })
  local kind = case == 'read' and 'read' or 'write'
  if kind == 'read' then
    vim.fn.writefile({ 'read from disk' }, path)
    vim.bo[buf].modified = false
  end
  local state = require('file_tools.privileged')[kind](nil, {
    sudo = folder .. '/sudo',
    on_done = function(ok, err)
      local checked, failure = xpcall(function()
        if case == 'success' then
          assert(ok, err)
          assert(not vim.bo[buf].modified)
          assert(vim.fn.readfile(path)[1] == 'snapshot')
          assert(api.nvim_get_current_buf() == buf)
        elseif case == 'read' then
          assert(ok, err)
          assert(api.nvim_buf_get_lines(buf, 0, -1, false)[1] == 'read from disk')
          assert(not vim.bo[buf].modified)
        else
          assert(not ok and vim.bo[buf].modified)
          assert(vim.fn.filereadable(path) == 0, 'failed operation wrote to disk')
          if case == 'stale' then
            assert(err:find('Buffer changed', 1, true), err)
          end
        end
      end, debug.traceback)
      if not checked then
        vim.fn.writefile({ failure }, folder .. '/result')
        vim.cmd('cquit')
        return
      end
      results[#results + 1] = 'ok ' .. case
      vim.defer_fn(next_case, 60)
    end,
  })
  vim.defer_fn(function()
    if case == 'stale' then
      api.nvim_buf_set_lines(buf, 0, -1, false, { 'newer edits' })
    end
    vim.fn.writefile({ case }, stage)
  end, 100)
end
vim.defer_fn(next_case, 50)
""")
    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 30, 100, 0, 0))
    env = dict(os.environ, TERM="xterm-256color", FILE_TOOLS_ROOT=str(ROOT),
               FILE_TOOLS_TEST_TMP=temp, NVIM_LOG_FILE=str(folder / "nvim.log"),
               XDG_STATE_HOME=str(folder / "state"))
    proc = subprocess.Popen(["nvim", "-u", "NONE", "-i", "NONE", "-n", "-c", f"luafile {script}"],
                            stdin=slave, stdout=slave, stderr=slave, env=env, cwd=ROOT)
    os.close(slave)
    sent, output = set(), bytearray()
    deadline = time.monotonic() + 20
    try:
        while proc.poll() is None and time.monotonic() < deadline:
            ready, _, _ = select.select([master], [], [], 0.05)
            if ready:
                try:
                    output.extend(os.read(master, 65536))
                except OSError:
                    break
            stage_file = folder / "stage"
            case = stage_file.read_text().strip() if stage_file.exists() else ""
            if case and case not in sent:
                if case == "cancel":
                    os.write(master, b"\x1c\x0e:bd!\r")
                else:
                    os.write(master, b"wrong\r" if case == "failure" else b"testpass\r")
                sent.add(case)
        proc.wait(timeout=3)
        result = (folder / "result").read_text() if (folder / "result").exists() else output.decode(errors="replace")[-3000:]
        assert proc.returncode == 0 and len(result.splitlines()) == 5, result
        print(result, end="")
        print("Real PTY: authentication, stale guards, terminal cancellation, failure and read passed")
    finally:
        if proc.poll() is None:
            proc.kill()
        proc.wait()
        os.close(master)
