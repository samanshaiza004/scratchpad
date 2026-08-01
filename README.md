# Scratchpad

The fourth Youth Utility Suite application, and the first proof of Youth's
`Editor` node and `youth:editor` capability (platform Gate A). It targets
protocol `0.0.6` and the exact SDK revision in `Youth.lock`.

```text
youth check
youth test
youth dev
youth build --release
```

## What this app is (Gate A9)

This app declares exactly one `Editor` node and reads/writes it through
`context.editor()` — no raw WIT anywhere in `src/lib.rs`. Everything about
live text editing (the buffer, cursor, selection, IME composition, undo/redo,
clipboard, scrolling, and now the platform's real AccessKit tree) is
host-owned; this repository never touches any of it and could not construct
a byte offset into the document if it wanted to. `youth mount` shows this
directly: a freshly mounted app's Editor node carries whatever text was last
saved, and typing into it (which this repository's own `.youth-test` suite
cannot simulate, since typing never enters the guest at all) never produces
a guest turn — see the Youth workspace's `editor_local_input.rs` for the
10,000-edit, zero-guest-turn proof this app's Editor is built on.

`Save` is the one guest turn this app ever asks the host for on this node.
It performs exactly the boundary Gate A's design settled on: `snapshot()`
reads the host's current buffer without touching it, then `accept()`
acknowledges that buffer under a new `DocumentRevision` — never `replace()`,
since this app never has authoritative content of its own to install, only
whatever the user already typed. Between the snapshot and the turn
committing, further keystrokes are not lost or clobbered: `accept` never
mutates the live buffer, cursor, or selection. The new revision and the
just-accepted text are persisted to guest state (`document_revision`,
`text`), so a real restart reopens the app with exactly what was last
saved — `tests/reopen_restores_saved_content.youth-test` pre-seeds that
state and asserts the reopened Editor's declared text matches; the same
mechanism is why redeclaring the last-saved text on every ordinary turn
never clobbers in-progress typing (a stable node with a matching
`DocumentRevision` preserves the host's live session by construction — see
the platform's Gate A design notes for the exact lifecycle rule).

There is no `Ctrl`/`Cmd`+S binding yet: `Save` is a plain `Button`, an
ordinary semantic activation, not a keyboard shortcut. `youth_tree`'s
`ShortcutKey` has no modifier-aware variant today, so a real Primary+S
binding — which Gate A's own design notes describe as falling through from
a declining, focused Editor to the app's declared Save command — is not
actually reachable yet at the platform level. See `FINDINGS.md`,
SCRATCHPAD-F001.

## The model

One in-memory document. Two pieces of guest state, both plain and both
exactly what a real restart needs to reopen the last save:

- `document_revision` (`integer`) — the guest's own accepted-document
  counter, starting at 1 on first mount and incrementing by exactly 1 on
  every successful `Save`.
- `text` (`text`) — the exact buffer content `Save` last accepted. This is
  also what `view()` declares as the Editor's `initial_text` on every turn,
  which only matters the first time a host session is created for this
  node (see above).

No dirty-state tracking exists on the guest side, deliberately: whether the
live host buffer currently differs from the last-accepted revision
(`locally_dirty`) is a host-owned fact by design, never surfaced to the
guest as a notification or a readable flag. The `status` text this app
shows is exactly "Saved as revision N" for whatever N is currently
accepted — a factual record of the last successful Save, not a claim about
whether there are unsaved changes right now.

## Verification

- `cargo test` (native, this repo) exercises nothing guest-specific today;
  the domain here is thin enough that `tests/*.youth-test` carries the real
  coverage.
- `tests/basic.youth-test`: mount declares an empty document at revision 1;
  activating `save` accepts it, bumps guest state to revision 2, and
  updates the status text; a `restart` reopens with revision 2 still
  declared.
- `tests/reopen_restores_saved_content.youth-test`: pre-seeds
  `document_revision`/`text` state (simulating a previous session's save),
  then asserts a fresh mount's Editor declares exactly that text and the
  status line reflects that revision — the local-first persistence claim
  this app exists to prove.
- `youth check` / `youth mount` / `youth activate --node <id>` were each run
  directly against the built `wasm32-wasip2` component during development
  to confirm the real Editor node, capability calls, and turn accounting
  match what the `.youth-test` suite asserts.
- Smoke-tested via `youth check`/build on macOS only in this pass; see
  `FINDINGS.md`, SCRATCHPAD-F002.

`FINDINGS.md` records what this pass left open, including a real platform
bug this repository's own `youth check` run surfaced and that got fixed
upstream during this work: the Youth Rust Guest Profile didn't actually
permit `youth:editor/session` imports until now, so no editor-capable app
could ever have passed `youth check` before this revision.
