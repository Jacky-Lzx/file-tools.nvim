# file-tools.nvim

File operations, buffer paths and language servers under one owner. Requires
Neovim 0.11+; no Lua dependencies. This plugin does not change global mappings,
working directories, netrw, or LSP configuration automatically.

```lua
local files = require("file_tools")
files.setup({})

local event, err = files.create("/project/new.lua")
files.create("/project/assets", { directory = true })
files.rename("/project/new.lua", "/project/main.lua")
files.copy("/project/assets", "/project/assets-copy")
files.delete("/project/assets-copy", { recursive = true })
```

Operations return an event on success or `nil, error`. Parents must already
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

Run `bash tests/run.sh` and `stylua --check lua tests/*.lua` for validation.
