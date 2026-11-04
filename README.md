# file-tools.nvim

File operations, buffer paths and language servers under one owner, with a
tab-local tree. Requires Neovim 0.11+; no mandatory Lua or external program dependencies.
`theme-tools.nvim` provides optional shared palette integration.

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
  },
  opts = {},
  keys = {
    { "<leader>e", "<Cmd>FileTools toggle<CR>", desc = "File tree" },
  },
}
```

`:FileTools` toggles the tree. `open [directory]`, `close`, `find` and `refresh`
manage it.
`:FileTools create path` creates a file (trailing `/` creates a directory), and
`:FileTools rename destination` moves the current file. Arguments are literal
paths with spaces supported; no shell quotes are needed.

## Tree

| Keys | Action |
| --- | --- |
| Enter, `l`, double-click | Open a file or fold a directory |
| `h` | Collapse or select parent |
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

## Configuration and checks

```lua
require("file_tools").setup({
  lsp = { enabled = true, timeout_ms = 1500 },
  tree = {
    width = 40, side = "left", show_hidden = false,
    follow = true, max_entries = 5000,
  },
})
```

`:help file-tools` documents the APIs, events, safeguards and limitations.
`:checkhealth file_tools` checks dependencies. Run:

```sh
bash tests/run.sh                         # core, tree, themes (real sibling checkout when available)
stylua --check lua plugin tests/*.lua
python3 tests/tui.py                      # real PTY tree interaction
FILE_TOOLS_CONFIGURED=1 python3 tests/tui.py # current Neovim configuration
FILE_TOOLS_THEME_TEST=1 python3 tests/tui.py # real theme switches in the visible tree
FILE_TOOLS_CONFIGURED=1 FILE_TOOLS_INTEGRATED=1 FILE_TOOLS_THEME_TEST=1 python3 tests/tui.py # actual configured e/E/cw mappings
nvim --headless -u NONE -i NONE -n -l tests/real_lsp.lua # installed TypeScript server
```

For a nonstandard TypeScript installation, set `FILE_TOOLS_TSSERVER` to its
`lib/tsserver.js`. Basic tests run in CI on Neovim 0.11.5 and stable; the real
PTY and TypeScript tests are local acceptance checks.
Theme integration tests use the actual sibling `theme-tools.nvim` checkout;
set `FILE_TOOLS_THEME_TOOLS` to use another checkout. Without it, the basic suite
still checks standalone highlighting and reports the integration tests skipped.
