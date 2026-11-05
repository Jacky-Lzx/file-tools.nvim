"""Drive the native file tree through PTY input, with rendered-cell checks."""
import base64
import fcntl
import json
import os
from pathlib import Path
import pty
import re
import select
import signal
import shutil
import struct
import subprocess
import sys
import tempfile
import termios
import time

root = Path(__file__).resolve().parents[1]
configured = os.environ.get("FILE_TOOLS_CONFIGURED") == "1"
theme_test = os.environ.get("FILE_TOOLS_THEME_TEST") == "1"
integrated = os.environ.get("FILE_TOOLS_INTEGRATED") == "1"
image_test = os.environ.get("FILE_TOOLS_IMAGE_TEST") == "1"
image_root = Path(os.environ.get("FILE_TOOLS_IMAGE_TOOLS", root.parent / "image-tools.nvim"))
dashboard_test = os.environ.get("FILE_TOOLS_DASHBOARD_TEST")
assert not integrated or configured, "Integrated acceptance requires FILE_TOOLS_CONFIGURED=1"
assert not dashboard_test or integrated, "Dashboard acceptance requires the actual configured integrations"
with tempfile.TemporaryDirectory(prefix="file-tools-tui-") as temporary:
    fixture = Path(temporary).resolve()
    (fixture / "src").mkdir()
    (fixture / "src/child.txt").write_text("child\n")
    (fixture / "current.txt").write_text("current\n")
    (fixture / "current.lua").write_text("return {}\n")
    (fixture / ".hidden").write_text("hidden\n")
    if image_test:
        shutil.copyfile(image_root / "tests/fixtures/fixture.png", fixture / "preview image.PNG")
        shutil.copyfile(image_root / "tests/fixtures/fixture.pdf", fixture / "preview pages.pdf")
    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 140, 0, 0))
    env = dict(os.environ, TERM="xterm-256color", FILE_TOOLS_ROOT=str(root),
               FILE_TOOLS_FIXTURE=str(fixture), XDG_STATE_HOME=str(fixture / "state"),
               XDG_CACHE_HOME=str(fixture / "cache"), NVIM_LOG_FILE=str(fixture / "nvim.log"),
               NVIM_SMOKE_TEST="1", NVIM_LAZY_LOCKFILE=str(fixture / "lazy-lock.json"))
    if image_test:
        env.update(TERM="xterm-kitty", KITTY_WINDOW_ID="file-tools-pty-test")
        for name in ("TMUX", "ZELLIJ", "SSH_CONNECTION", "SSH_TTY"):
            env.pop(name, None)
    init = str(Path.home() / ".config/nvim/init.lua") if configured else "NONE"
    child = subprocess.Popen(["nvim", "--cmd", "let g:loaded_wakatime=1", "-u", init,
                              "-i", "NONE", "-n", "-c", "luafile " + str(root / "tests/tui.lua")],
                             stdin=slave, stdout=slave, stderr=slave, env=env)
    transcript = bytearray()
    pattern = re.compile(rb"\x1b_G([^;\x1b]+)(?:;([^\x1b]*))?\x1b\\")
    offset, pending, uploads, placements = 0, None, [], []
    active_placements = set()

    def respond():
        global offset, pending
        for match in pattern.finditer(transcript, offset):
            offset = match.end()
            fields = dict(part.split(b"=", 1) for part in match[1].split(b","))
            action, identifier = fields.get(b"a"), fields.get(b"i")
            data = None
            if action == b"t":
                if fields.get(b"t") == b"f":
                    data = Path(base64.b64decode(match[2]).decode()).read_bytes()
                else:
                    pending = [fields, [match[2]]]
            elif pending is not None and b"m" in fields:
                pending[1].append(match[2])
            if pending is not None and fields.get(b"m") == b"0":
                fields, chunks = pending
                identifier = fields[b"i"]
                data, pending = base64.b64decode(b"".join(chunks)), None
            if data is not None:
                assert data.startswith(b"\x89PNG\r\n\x1a\n"), "Preview did not upload PNG data"
                uploads.append(data)
            if action == b"p":
                placements.append(fields)
                active_placements.add((identifier, fields.get(b"p")))
            elif action == b"d":
                assert fields.get(b"d") not in (b"A", b"a"), "Preview deleted unrelated terminal images"
                active_placements.difference_update({item for item in active_placements
                    if item[0] == identifier and (b"p" not in fields or item[1] == fields[b"p"])})
            if (data is not None or action == b"p") and fields.get(b"q") != b"2":
                placement = b",p=" + fields[b"p"] if action == b"p" and b"p" in fields else b""
                os.write(master, b"\x1b_Gi=" + identifier + placement + b";OK\x1b\\")

    def drain(duration=0.1):
        deadline = time.monotonic() + duration
        while time.monotonic() < deadline:
            if select.select([master], [], [], min(0.02, max(0, deadline - time.monotonic())))[0]:
                try:
                    transcript.extend(os.read(master, 65536))
                    if image_test:
                        respond()
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
                        assert value["tree"]["winfixbuf"], "Files window lost native buffer protection"
                        if integrated:
                            top, bottom = value["tree_bars"]["top"], value["tree_bars"]["bottom"]
                            assert top.strip() == "Files", "Missing tree title: " + top
                            assert abs(len(top) - len(top.lstrip()) - (len(top) - len(top.rstrip()))) <= 1, top
                            if not value.get("dashboard"):
                                assert bottom.strip() == "file-tools", "Unexpected tree footer: " + bottom
                    return value
        raise AssertionError(label + "\n" + json.dumps(value, ensure_ascii=False) + "\n" + transcript.decode(errors="replace")[-2500:])

    try:
        for _ in range(100):
            drain(0.1)
            if (fixture / "ready").exists():
                break
        assert (fixture / "ready").exists(), transcript.decode(errors="replace")[-3000:]
        if dashboard_test:
            startup = snapshot(lambda v: bool(v.get("dashboard")), "Startup dashboard did not open")
            assert len(startup["windows"]) == 1
            send(" e")
            opened = snapshot(lambda v: bool(v.get("tree")), "Files did not open alongside dashboard")
            assert opened["origin"] and not opened["tree"]["focus"], "Toggle stole dashboard focus"
            # The dashboard recenters its content on WinResized; keep its selected action.
            assert opened["dashboard"]["selected"] == startup["dashboard"]["selected"], "Toggle changed dashboard selection"
            assert len(opened["windows"]) == 2 and opened.get("dashboard")
            send("\x17h")  # Enter Files explicitly for picker/tree interaction
            if dashboard_test == "picker":
                send(" sf")
                snapshot(lambda v: v.get("picker", {}).get("ready"), "File picker did not open")
                send("\x1b")
                cancelled = snapshot(lambda v: not v.get("picker") and v.get("tree", {}).get("focus"), "Cancellation lost Files focus")
                assert len(cancelled["windows"]) == 2 and cancelled["dashboard"] == startup["dashboard"]
                send(" sf")
                snapshot(lambda v: v.get("picker", {}).get("ready"), "File picker did not reopen")
                send("current.lua")
                snapshot(lambda v: v.get("picker", {}).get("query") == "current.lua" and v["picker"]["ready"], "File query did not settle")
                send("\r")
            else:
                send("/current.lua\r\r")
            chosen = snapshot(lambda v: v["origin"] and v["current"] == str(fixture / "current.lua") and not v.get("dashboard"), "Selected file did not replace the dashboard")
            assert len(chosen["windows"]) == 2, "Opening created an extra editor split"
            assert chosen["laststatus"] == 2, "Dashboard did not restore the statusline"
            assert chosen["tree"]["buf"] == opened["tree"]["buf"]
            assert all(b["name"] for b in chosen["listed"]), "Opening left unnamed placeholder buffers"
            assert startup["dashboard"]["buf"] not in [b["id"] for b in chosen["buffers"]]
            assert startup["dashboard"]["source"] not in [b["id"] for b in chosen["buffers"]]
            print("PTY (configured dashboard): Files + " + dashboard_test + " reuses dashboard window, restores bars and removes startup placeholders")
            sys.exit(0)
        send("0lll")
        before = snapshot(lambda v: v["origin"], "Editor did not receive cursor movement")
        toggle = " e" if integrated else "\x1b[17~"  # Configured leader-e or isolated F6
        send(toggle)
        opened = snapshot(lambda v: bool(v.get("tree")), "Tree did not open")
        assert opened["origin"] and not opened["tree"]["focus"], "Toggle stole editor focus"
        assert opened["origin_cursor"] == before["origin_cursor"], "Toggle moved editor cursor"
        assert opened["tree"]["selected"] == before["current"], "Toggle did not reveal current file"
        send(toggle)
        closed = snapshot(lambda v: not v.get("tree"), "Toggle did not close tree from editor")
        assert closed["origin"] and closed["origin_cursor"] == before["origin_cursor"]
        send(toggle)
        reopened = snapshot(lambda v: bool(v.get("tree")), "Toggle did not reopen tree")
        assert reopened["origin"] and not reopened["tree"]["focus"], "Reopening stole editor focus"
        assert reopened["origin_cursor"] == before["origin_cursor"], "Reopening moved editor cursor"
        assert reopened["tree"]["selected"] == before["current"], "Reopening did not reveal current file"
        send("\x17h")  # Enter Files explicitly for tree interaction
        opened = snapshot(lambda v: v.get("tree", {}).get("focus"), "Could not enter Files")
        assert opened["directory_text"] in opened["screen"] and "current.txt" in opened["screen"]
        icon = opened["file_icon"]
        assert icon["text"] == icon["expected"] == icon["cell"], "File icon did not reach rendered cells"
        if integrated:
            assert icon["provider"], "Configured icon provider did not load on first tree use"
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
                assert frame["directory_text"] in frame["screen"]
                assert frame["file_icon"]["cell"] == frame["file_icon"]["expected"]
                if integrated:
                    assert frame["file_icon"]["icon_attr"] != frame["file_icon"]["name_attr"]
                frames.append(frame)
            assert frames[0]["directory_attr"] != frames[1]["directory_attr"], "Visible directory cells did not change color"
            assert frames[-1]["palette"]["ui"]["bg"] == "NONE"
            assert frames[-1]["colors"]["Normal"].get("bg") is None
            for mode, expected_icon in (("ascii", "f"), ("none", ""), ("devicons", "")):
                send("\x1b[19~")  # F8 changes the shared icon policy while Files stays open.
                frame = snapshot(lambda v: v.get("file_icon", {}).get("expected") == expected_icon
                                 and v["file_icon"]["text"] == expected_icon,
                                 "Shared icon mode did not reach the tree: " + mode)
                assert frame["directory_text"] in frame["screen"]
                assert frame["file_icon"]["cell"] == expected_icon
                assert frame["tree"]["selected"] == opened["tree"]["selected"]
        if integrated:
            send(" sf")
            snapshot(lambda v: v.get("picker", {}).get("ready"), "Configured file picker did not open from Files")
            send("\x1b")
            snapshot(lambda v: not v.get("picker") and v.get("tree", {}).get("focus"), "Picker cancellation did not return to Files")
            send(" sf")
            snapshot(lambda v: v.get("picker", {}).get("ready"), "Configured file picker did not reopen")
            send("current.lua")
            snapshot(lambda v: v.get("picker", {}).get("query") == "current.lua" and v["picker"]["ready"], "File query did not settle")
            send("\r")
            chosen = snapshot(lambda v: not v.get("picker") and v["origin"] and v["current"] == str(fixture / "current.lua"), "File picker replaced Files instead of the editor")
            assert chosen["tree"]["buf"] == opened["tree"]["buf"], "File picker destroyed the Files buffer"
            send("\x17h")
        send("/current.txt\r\t")
        previewed = snapshot(lambda v: v.get("preview", {}).get("lines", [None])[0] == "current",
                             "Tab did not show text preview")
        assert previewed["tree"]["focus"] and "current" in previewed["screen"]
        assert not previewed["preview"]["config"]["focusable"]
        send("\t")
        repeated = snapshot(lambda v: bool(v.get("preview")), "Repeated Tab closed the single preview")
        assert repeated["preview"]["win"] == previewed["preview"]["win"]
        send("/current.lua\r")
        snapshot(lambda v: not v.get("preview") and v["tree"]["focus"],
                 "Single preview followed the new selection")
        send("P")
        snapshot(lambda v: v.get("preview", {}).get("lines", [None])[0] == "return {}",
                 "P did not enable following preview")
        send("/current.txt\r")
        snapshot(lambda v: v.get("preview", {}).get("lines", [None])[0] == "current",
                 "Following preview did not update selection")
        send("P")
        snapshot(lambda v: not v.get("preview") and v["tree"]["focus"], "P did not hide preview")
        send("\t\x1b")
        snapshot(lambda v: not v.get("preview") and v["tree"]["focus"], "Escape did not close preview")
        if image_test:
            media_win = None
            for name in ("preview image", "preview pages"):
                send("/" + name + "\r" + ("P" if media_win is None else ""))
                frame = snapshot(lambda v: v.get("preview", {}).get("stage") == "ready"
                                 and v["preview"]["grid"], "Image/PDF did not render: " + name, timeout=15)
                assert frame["tree"]["focus"] and frame["preview"]["path"].startswith(str(fixture))
                assert "Preview:" not in "\n".join(frame["preview"]["lines"])
                if media_win is None:
                    media_win = frame["preview"]["win"]
                assert frame["preview"]["win"] == media_win, "Navigation replaced the preview window"
                if name == "preview pages":
                    before = len(uploads)
                    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 30, 100, 1000, 600))
                    os.kill(child.pid, signal.SIGWINCH)
                    resized = snapshot(lambda v: v.get("preview", {}).get("stage") == "ready"
                                       and v["preview"]["config"]["width"] < frame["preview"]["config"]["width"],
                                       "PDF preview did not adapt to resize")
                    assert len(uploads) == before, "Resize uploaded duplicate pixels"
                    assert resized["tree"]["focus"]
            send("P")
            snapshot(lambda v: not v.get("preview"), "Media preview leaked after P")
            assert not active_placements, "Closing preview left visible image placements"
            assert len(uploads) == 2 and len(placements) >= 3, "Missing image/PDF uploads or resize placement"
            fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 140, 1400, 800))
            os.kill(child.pid, signal.SIGWINCH)
        send("/current.lua\r\t\x17l")
        snapshot(lambda v: not v.get("preview") and v["origin"], "Leaving Files leaked preview")
        send("\x17h")
        send("/src\rl")  # Expand src using actual l mapping
        expanded = snapshot(lambda v: "child.txt" in "\n".join(v["tree"]["lines"]), "Directory did not expand")
        send("j\r")  # Open child in editor
        child_frame = snapshot(lambda v: v["current"].endswith("/src/child.txt") and v["origin"], "Tree opened in wrong window")
        send(toggle)
        snapshot(lambda v: not v.get("tree"), "Toggle did not close tree for nested file")
        send(toggle)
        nested = snapshot(lambda v: bool(v.get("tree")), "Toggle did not reopen tree for nested file")
        assert nested["origin"] and nested["origin_cursor"] == child_frame["origin_cursor"]
        assert nested["tree"]["selected"] == child_frame["current"], "Toggle did not expand and reveal nested current file"
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
        print("PTY" + (" (configured)" if configured else "") + ": rendered tree, folding/opening, create/rename prompts, hidden files, resize and cleanup, Tab single preview, P toggle and Escape" + (", real shared theme colors and transparency" if theme_test else "") + (", actual configured mappings and LSP dependencies" if integrated else "") + (", image/PDF uploads, placements and resize reuse" if image_test else "") + " passed")
    finally:
        send("\x1b:qa!\r")
        try:
            child.wait(timeout=3)
        except subprocess.TimeoutExpired:
            child.kill()
            child.wait()
        os.close(master)
        os.close(slave)
