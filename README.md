# file-tools.nvim

File operations, buffer paths and language servers under one owner, with a
tab-local tree. Requires Neovim 0.11+; no mandatory Lua or external program dependencies.
`theme-tools.nvim` provides optional shared palette integration.
`nvim-web-devicons` provides optional file type icons.
`image-tools.nvim` provides optional image and PDF previews.

The plugin does not change global mappings, working directories, netrw, or LSP
configuration automatically. Existing file plugins can stay installed while you
try it; operations performed through those plugins are not intercepted.

## Load locally

Example lazy.nvim spec (add it yourself when ready):

```lua
{
  dir = "/Users/zexili/Documents/Github/nvim_plugins/file-tools.nvim",
  name = "file-tools.nvim",
  main = "file_tools",
  cmd = "FileTools",
  dependencies = {
    { dir = "/Users/zexili/Documents/Github/nvim_plugins/theme-tools.nvim", name = "theme-tools.nvim" },
    "nvim-tree/nvim-web-devicons",
  },
  opts = {},
  keys = {
    { "<leader>e", "<Cmd>FileTools toggle<CR>", desc = "File tree" },
  },
}
```

`:FileTools` toggles the tree while keeping focus and cursor position in the
current window. With `tree.follow` enabled (the default), opening also expands
and selects the current file, using its parent as root if outside the tree root.
`open [directory]` and `find` focus the tree; `close` and `refresh`
manage it. Use `<C-w>h` to enter a tree on the left.
`:FileTools create path` creates a file (trailing `/` creates a directory), and
`:FileTools rename destination` moves the current file. Arguments are literal
paths with spaces supported; no shell quotes are needed.

## Tree

| Keys | Action |
| --- | --- |
| Enter, `l`, double-click | Open a file or fold a directory |
| `h` | Collapse or select parent |
| Tab | Open a single floating preview |
| `P`, Esc | Toggle following preview, close preview |
| `s`, `S`, `t` | Vertical split, horizontal split, tab |
| `a`, `r`, `d` | Create, move/rename, confirmed permanent delete |
| `y`, `x`, `p` | Copy, cut, paste |
| `Y` | Copy absolute path to unnamed and clipboard registers |
| `.`, `R` | Toggle dotfiles, refresh |
| `-`, `C` | Use parent or selected directory as root |
| `f` | Reveal editor file |
| `q`, `?`, `/` | Close, help, native filename search |

Only expanded directories are scanned. Visible directories are watched (up to
64 per tree), with manual refresh available. Large trees stop at an entry limit.
Directory symlinks are displayed without recursive traversal. Files open in the
editing window, and following the current file does not steal focus.

The tree protects its window with Neovim's native `winfixbuf`. Opening a file
prefers an unlocked editor in the same tab, then an unlocked `nofile` start
screen, then creates an editor to the right. Protected, floating/preview,
terminal and quickfix windows are skipped. Explicit splits create an editor
without cloning a start screen. Closing the last tree releases its buffer lock.

When ui-tools manages window bars, the tree declares a centered `Files` title
and a minimal `file-tools` footer through buffer-local bar profiles.

Tab opens a single floating preview beside Files without moving focus. Pressing
Tab again keeps it open; moving to another file closes it. `P` toggles following
preview, which updates as the selection moves. Pressing `P` on a single preview
enables following; Tab returns it to single preview. Esc, leaving Files or
closing the tree releases either preview. Selecting a directory closes any open
preview; Tab and `P` do nothing on directories, including the root row.
The float adapts to terminal resizing. Text previews read at most 256 KiB,
show up to 500 lines and limit each line to 2000 bytes. Other binary files show
a placeholder.
Text highlighting uses the installed Tree-sitter parser and runtime highlight
queries, with Vim syntax as a fallback. The preview sets its filetype without
running FileType handlers or attaching language servers; LSP semantic tokens
and editor-specific decorations are not copied from editing buffers.

Images and the first page of PDFs render through the optional `image-tools.nvim`
embedded API, loaded only for media previews. Add it to your plugin manager
(lazy loading is supported). Rendering requires a Kitty graphics compatible
terminal and `termguicolors`; conversion uses image-tools' configured tools
(ImageMagick, with Ghostscript for PDF). Missing dependencies and rendering
errors appear inside the preview. Source files and editor buffers stay untouched.
PDF previews rasterize vectors to the float's pixel size with 2× sampling,
using measured terminal cell pixels or image-tools' `cell_size` fallback. Small
cropped PDFs therefore gain detail before display instead of being enlarged
from a fixed-DPI image. Targets use 64-pixel buckets and obey image-tools' pixel
and dimension limits. Shrinking reuses pixels; growing upgrades them as needed.
Adaptive PDF previews also require `pdfinfo` (Poppler) for page dimensions.

File and folder icons are enabled by default and require a Nerd Font in your
terminal. When available, `nvim-web-devicons` supplies filename/extension icons
and their colors; otherwise files use a generic icon. Folder icons reflect their
open/closed state. Set `tree.icons = false` to hide icons and skip the provider.

## Lua API

```lua
local files = require("file_tools")
files.setup({})
files.open({ root = "/project", focus = false })
files.find()
files.close()

local event, err = files.create("/project/new.lua")
files.create("/project/assets", { directory = true })
files.rename("/project/new.lua", "/project/main.lua")
files.copy("/project/assets", "/project/assets-copy")
files.delete("/project/assets-copy", { recursive = true })
```

`files.toggle()` opens without taking focus; pass `focus = true` to enter it.
`files.open()` and `files.find()` focus the tree unless `focus = false` is passed.

Create, rename, copy and delete return an event or `nil, error`. Parents must already
exist, destinations must be absent, and deleting a dirty buffer is refused.
Directory renames retain buffer identity, unsaved text and undo history. Renaming
does not save files. Ordinary `:write` works afterwards. Buffers with custom
`BufWriteCmd` handlers cannot be renamed. Copy retains symlinks without traversing
them and stages content before installing the destination. Cross-device moves
are refused by the filesystem; there is no copy-and-delete fallback.

Merge `files.capabilities()` into the capabilities passed to your language
servers **before starting them**. `setup()` does not modify your LSP clients.
Static and dynamic file-operation registrations, workspace roots, URI scheme,
file/folder globs and case options select recipients. Will-file requests are
bounded and fail closed. Their text edits are applied before filesystem changes
and remain unsaved. Resource/annotated edits and multiple responses editing the
same document are refused. A failed mutation restores applied buffer text; a
recursive deletion can still be partially completed if the filesystem fails.
These operations are not filesystem transactions.

`files.reconcile({ kind = "Rename", path = old, to = new })` synchronizes an
already-completed external operation. `Create` and `Delete` use `path`. This sends
only did-file notifications. External deletions preserve dirty text as an unnamed
buffer with `b:file_tools_deleted_path` recording its former name.

Successful operations emit `User FileToolsChanged`, with the event in `ev.data`:
`kind` (`Create`, `Rename`, `Delete`), absolute `path`, optional `to`, `directory`,
and `external` for reconciled operations. Copies emit `Create`.

## Open with a system application

```lua
local files = require("file_tools")
local ok, err = files.open_external("assets/diagram.pdf")
files.open_external("https://neovim.io")
vim.keymap.set({ "n", "x" }, "go", files.open_at_cursor)
```

These APIs use the system application, while `files.open()` opens the file tree.
Relative paths are tried beside the current buffer, then in the working directory,
then at the nearest Git root. Missing paths are passed relative to the working
directory so the system opener can report the error. Absolute paths and URI schemes
are passed through; a leading `~/` expands to the home directory. Other characters
remain literal. `open_at_cursor()` uses `<cfile>` in Normal mode or the active
characterwise, linewise or blockwise Visual selection (including exclusive selection),
leaves Visual mode and opens synchronously.

The default backend is `vim.ui.open`. Set `setup({ opener = function(target) ... end })`
to use a custom backend. It must return a truthy result on launch success, or
`nil/false, error` on failure. Both APIs return `true` or `nil, error`;
`open_at_cursor()` also notifies on failure. No global mappings are installed.
LSP integrations can call `files.open_at_cursor` from their fallback callback;
file-tools itself does not query document links or depend on an LSP plugin.

## Privileged files

`:FileToolsRead[!] [path]` reads a file with sudo. Dirty buffers require `!`.
`:FileToolsWrite [path]` writes a snapshot with sudo; omitted paths use the
current file. An alternate destination keeps the original buffer name and dirty
state. Normal `:write` and tree operations never escalate automatically.

Authentication opens a temporary terminal split only when a noninteractive
sudo credential check fails. Authentication and transfer share one sudo process
so PTY-scoped and process-scoped credential caches also work. Passwords go directly to sudo's terminal;
Lua does not read or retain them. Closing that terminal cancels the operation.
Without an attached UI, an uncached credential fails with an explanatory message.

```lua
local files = require("file_tools")
local operation = files.privileged_write(nil, {
  on_done = function(ok, err) end, -- optional; defaults to a notification
})
-- operation.cancel()
-- files.privileged_read('/etc/hosts', { force = true })
```

Native Neovim serialization preserves file encoding, BOM, line endings and final
newline options. Private staging files are removed on completion/cancellation.
Changed, renamed or deleted buffers are guarded across asynchronous work;
newer edits are never marked as saved. Writes overwrite the destination in place
using sudo and dd; they are not atomic and do not create backups. A changed
snapshot detected before transfer is refused. A disk failure can leave a partial
write. The `sudo` executable and `timeout_ms` can be overridden per API call.

## Shared themes

When `theme-tools.nvim` is loaded, the tree subscribes to its shared semantic
palette using `on_change("file-tools.tree", ...)`. File and directory colors,
symlinks, root title, sidebar background, cursor line, separator and error/warning
rows follow theme switches, transparency and palette overrides. Open trees keep
their buffers, selection and folds while colors update. Later loading through
`ThemeToolsReady` is supported, and repeated setup keeps the subscription.

The dependency declaration above loads the theme service before the tree. If
`theme-tools` is already configured separately, keep that configuration. File-tools
never initializes the theme manager or selects a colorscheme itself. Without the
service, its highlight groups link to standard Neovim groups.

Public highlight definitions from your colorscheme or user overrides take precedence
over shared palette updates. Private default targets are refreshed on theme changes.

## Configuration and checks

```lua
require("file_tools").setup({
  lsp = { enabled = true, timeout_ms = 1500 },
  tree = {
    width = 40, side = "left", show_hidden = false,
    follow = true, max_entries = 5000, icons = true,
  },
})
```

`:help file-tools` documents the APIs, events, safeguards and limitations.
`:checkhealth file_tools` checks dependencies. Run:

```sh
bash tests/run.sh                         # core, tree, icons, themes, preview
stylua --check lua plugin tests/*.lua
python3 tests/tui.py                      # real PTY tree interaction
FILE_TOOLS_CONFIGURED=1 python3 tests/tui.py # current Neovim configuration
FILE_TOOLS_THEME_TEST=1 python3 tests/tui.py # real theme switches in the visible tree
FILE_TOOLS_CONFIGURED=1 FILE_TOOLS_INTEGRATED=1 FILE_TOOLS_THEME_TEST=1 python3 tests/tui.py # actual configured e/E/cw mappings
FILE_TOOLS_IMAGE_TEST=1 python3 tests/tui.py # real image/PDF conversion + Kitty protocol responder
FILE_TOOLS_CONFIGURED=1 FILE_TOOLS_INTEGRATED=1 FILE_TOOLS_IMAGE_TEST=1 python3 tests/tui.py # configured media previews
FILE_TOOLS_CONFIGURED=1 FILE_TOOLS_INTEGRATED=1 FILE_TOOLS_HIGHLIGHT_TEST=1 python3 tests/tui.py # compare rendered TeX highlighting
FILE_TOOLS_CONFIGURED=1 FILE_TOOLS_INTEGRATED=1 FILE_TOOLS_DASHBOARD_TEST=picker python3 tests/tui.py # startup dashboard + Files + Space sf
FILE_TOOLS_CONFIGURED=1 FILE_TOOLS_INTEGRATED=1 FILE_TOOLS_DASHBOARD_TEST=tree python3 tests/tui.py # startup dashboard + Files + Enter
nvim --headless -u NONE -i NONE -n -l tests/real_lsp.lua # installed TypeScript server
```

For a nonstandard TypeScript installation, set `FILE_TOOLS_TSSERVER` to its
`lib/tsserver.js`. Basic tests run in CI on Neovim 0.11.5 and stable; the real
PTY and TypeScript tests are local acceptance checks.
Theme integration tests use the actual sibling `theme-tools.nvim` checkout;
set `FILE_TOOLS_THEME_TOOLS` to use another checkout. Without it, the basic suite
still checks standalone highlighting and reports the integration tests skipped.
Icon tests also use the installed `nvim-web-devicons` checkout when available;
set `FILE_TOOLS_DEVICONS` to use another checkout.
Media PTY checks require the sibling `image-tools.nvim` checkout and its
conversion tools; set `FILE_TOOLS_IMAGE_TOOLS` to use another checkout. They
verify uploads, placements, resize reuse and cleanup through a deterministic
Kitty protocol responder, rather than physical terminal pixels.
Set `FILE_TOOLS_PDF_FIXTURE` to a local PDF to check the same pixel-target and
resize behavior with that document.

## Command ownership

Commands belong to the plugin; choose global entry keys and short aliases in
your configuration. Registration reports same-name conflicts without replacing
user commands. Reconfiguration refreshes only commands still owned by this
plugin, and cleanup preserves subsequent user replacements.
