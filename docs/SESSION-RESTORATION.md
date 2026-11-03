# Session restoration and recent workspaces

Scratchpad keeps three kinds of local state separate because they serve
different recovery needs:

- `session.json` stores the last cleanly closed workspace and document view.
  It is versioned and atomically replaced on shutdown. It contains application
  document paths, tab order and active document, preview state, selection and
  scroll positions, sidebar width, and semantic UI focus. It never stores
  Alicorn node IDs or serialized UI trees.
- `recent-workspaces.json` stores up to ten normalized workspace paths, newest
  first. Its version-1 file is atomically replaced immediately after a
  workspace is opened or recent history is cleared. It is independent of
  `session.json`, so disabling or failing session restoration does not disable
  the recent-workspace list.
- The `recovery/` manifest and byte snapshots preserve unsaved document
  contents after a crash. They are independent of both clean session state
  and recent workspace history.

Older session files may contain an embedded recent-workspace list. Scratchpad
uses that list when the standalone history file is absent, then writes the
standalone format so the two responsibilities are separated. Once the
standalone file exists, it is authoritative, including an explicitly empty
list. This prevents a previously cleared list from returning during a later
session restore.

Both JSON files have bounded input sizes and explicit schema versions.
Unsupported or corrupt session data produces a startup notice and falls back
to a usable empty session; a missing session file is a normal fresh launch.
Missing workspace or document paths are reported while startup continues. If
the standalone history cannot be decoded, Scratchpad preserves that file, uses
compatible session history when available, and reports the problem. It does
not silently replace an unreadable or newer history file; an explicit Clear
Recent action may replace it. Entries that refer to unavailable directories
remain visible so the user can retry them; opening one reports the filesystem
error instead of silently forgetting the path.

Restoring a workspace opens the workspace root and saved document paths only;
it does not eagerly read the entire workspace. Workspace listings and search
continue to use their existing bounded/asynchronous paths.
