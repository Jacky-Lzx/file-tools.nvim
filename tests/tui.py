"""Drive the native file tree through PTY input, with rendered-cell checks."""
import fcntl
import json
import os
from pathlib import Path
import pty
import select
import signal
import struct
import subprocess
import tempfile
import termios
import time

root = Path(__file__).resolve().parents[1]
configured = os.environ.get("FILE_TOOLS_CONFIGURED") == "1"
theme_test = os.environ.get("FILE_TOOLS_THEME_TEST") == "1"
integrated = os.environ.get("FILE_TOOLS_INTEGRATED") == "1"
assert not integrated or configured, "Integrated acceptance requires FILE_TOOLS_CONFIGURED=1"
with tempfile.TemporaryDirectory(prefix="file-tools-tui-") as temporary:
    fixture = Path(temporary).resolve()
    (fixture / "src").mkdir()
    (fixture / "src/child.txt").write_text("child\n")
    (fixture / "current.txt").write_text("current\n")
    (fixture / "current.lua").write_text("return {}\n")
    (fixture / ".hidden").write_text("hidden\n")
    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 140, 0, 0))
    env = dict(os.environ, TERM="xterm-256color", FILE_TOOLS_ROOT=str(root),
               FILE_TOOLS_FIXTURE=str(fixture), XDG_STATE_HOME=str(fixture / "state"),
               XDG_CACHE_HOME=str(fixture / "cache"), NVIM_LOG_FILE=str(fixture / "nvim.log"),
               NVIM_SMOKE_TEST="1", NVIM_LAZY_LOCKFILE=str(fixture / "lazy-lock.json"))
    init = str(Path.home() / ".config/nvim/init.lua") if configured else "NONE"
    child = subprocess.Popen(["nvim", "--cmd", "let g:loaded_wakatime=1", "-u", init,
                              "-i", "NONE", "-n", "-c", "luafile " + str(root / "tests/tui.lua")],
                             stdin=slave, stdout=slave, stderr=slave, env=env)
    transcript = bytearray()

    def drain(duration=0.1):
        deadline = time.monotonic() + duration
        while time.monotonic() < deadline:
            if select.select([master], [], [], min(0.02, max(0, deadline - time.monotonic())))[0]:
                try:
                    transcript.extend(os.read(master, 65536))
                except OSError:
                    break

    def send(text):
        os.write(master, text.encode())
        drain()

    def snapshot(predicate, label, timeout=5):
        deadline = time.monotonic() + timeout
        value = None
        while time.monotonic() < deadline:
            (fixture / "snapshot.json").unlink(missing_ok=True)
            send("\x1b[24~")
            if (fixture / "snapshot.json").exists():
                value = json.loads((fixture / "snapshot.json").read_text())
                if predicate(value):
                    if value.get("tree"):
                        assert value["tree"]["textoff"] == 0, "Tree inherited an empty gutter: " + json.dumps(value["tree"])
                        assert value["tree"]["statuscolumn"] == "", "Tree kept a custom status column"
                        if integrated:
                            top, bottom = value["tree_bars"]["top"], value["tree_bars"]["bottom"]
                            assert top.strip() == "Files", "Missing tree title: " + top
                            assert abs(len(top) - len(top.lstrip()) - (len(top) - len(top.rstrip()))) <= 1, top
                            assert bottom.strip() == "file-tools", "Unexpected tree footer: " + bottom
                    return value
        raise AssertionError(label + "\n" + json.dumps(value, ensure_ascii=False) + "\n" + transcript.decode(errors="replace")[-2500:])

    try:
        for _ in range(100):
            drain(0.1)
            if (fixture / "ready").exists():
                break
        assert (fixture / "ready").exists(), transcript.decode(errors="replace")[-3000:]
        send(" e" if integrated else "\x1b[17~")  # Configured leader-e or isolated F6
        opened = snapshot(lambda v: v.get("tree", {}).get("focus"), "Tree did not open")
        assert "▸  src" in opened["screen"] and "current.txt" in opened["screen"]
        icon = opened["file_icon"]
        assert icon["text"] == icon["expected"] == icon["cell"], "File icon did not reach rendered cells"
        if integrated:
            assert icon["provider"], "Configured devicons did not load on first tree use"
            assert icon["icon_attr"] != icon["name_attr"], "File icon lost its own color"
        assert ".hidden" not in "\n".join(opened["tree"]["lines"])
        assert opened["tree"]["watchers"] > 0
        if theme_test:
            frames = []
            for expected in ("theme-tools-mocha", "theme-tools-dracula", "theme-tools-mocha"):
                send("\x1b[18~")  # F7 switches real theme-tools themes
                frame = snapshot(lambda v: v.get("palette", {}).get("name") == expected,
                                 "Shared theme did not reach the tree")
                palette, colors = frame["palette"], frame["colors"]
                assert colors["Root"]["fg"] == int(palette["ui"]["accent"][1:], 16)
                assert colors["Directory"]["fg"] == int(palette["palette"]["blue"][1:], 16)
                assert colors["WinSeparator"]["fg"] == int(palette["ui"]["border"][1:], 16)
                assert frame["tree"]["cursor"] == opened["tree"]["cursor"]
                assert frame["tree"]["buf"] == opened["tree"]["buf"]
                assert "▸  src" in frame["screen"]
                assert frame["file_icon"]["cell"] == frame["file_icon"]["expected"]
                if integrated:
                    assert frame["file_icon"]["icon_attr"] != frame["file_icon"]["name_attr"]
                frames.append(frame)
            assert frames[0]["directory_attr"] != frames[1]["directory_attr"], "Visible directory cells did not change color"
            assert frames[-1]["palette"]["ui"]["bg"] == "NONE"
            assert frames[-1]["colors"]["Normal"].get("bg") is None
        send("/src\rl")  # Expand src using actual l mapping
        expanded = snapshot(lambda v: "child.txt" in "\n".join(v["tree"]["lines"]), "Directory did not expand")
        send("j\r")  # Open child in editor
        snapshot(lambda v: v["current"].endswith("/src/child.txt") and v["origin"], "Tree opened in wrong window")
        send("\x17h")  # Ctrl-w h: back to tree
        send("a")
        drain(0.2)
        send("\x15" + str(fixture / "created.txt") + "\r")
        snapshot(lambda v: (fixture / "created.txt").exists() and v.get("tree", {}).get("focus"), "Create prompt failed")
        # Search selects the newly created node without relying on its row number.
        send("/created.txt\r")
        send("r")
        drain(0.2)
        send("\x15" + str(fixture / "moved.txt") + "\r")
        snapshot(lambda v: (fixture / "moved.txt").exists() and not (fixture / "created.txt").exists(), "Rename prompt failed")
        send(".")
        snapshot(lambda v: ".hidden" in "\n".join(v["tree"]["lines"]), "Hidden toggle failed")
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 30, 100, 0, 0))
        os.kill(child.pid, signal.SIGWINCH)
        send("q")
        snapshot(lambda v: not v.get("tree"), "Tree close leaked state")
        if integrated:
            send(" E")
            snapshot(lambda v: v.get("tree", {}).get("selected") == str(fixture / "src/child.txt"),
                     "Configured reveal mapping did not select the current file")
            send("hC")
            snapshot(lambda v: v.get("tree", {}).get("root") == str(fixture / "src"), "Tree root did not narrow")
            send(" cw")
            snapshot(lambda v: v.get("tree", {}).get("root") == str(fixture), "Working directory mapping did not reset root")
            send(" e")
            snapshot(lambda v: not v.get("tree"), "Configured toggle did not close tree")
        assert len(transcript) > 1000
        print("PTY" + (" (configured)" if configured else "") + ": rendered tree, folding/opening, create/rename prompts, hidden files, resize and cleanup" + (", real shared theme colors and transparency" if theme_test else "") + (", actual configured mappings and LSP dependencies" if integrated else "") + " passed")
    finally:
        send("\x1b:qa!\r")
        try:
            child.wait(timeout=3)
        except subprocess.TimeoutExpired:
            child.kill()
            child.wait()
        os.close(master)
        os.close(slave)
