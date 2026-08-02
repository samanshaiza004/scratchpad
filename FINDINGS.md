# Scratchpad Findings

This is the durable evidence record for Scratchpad. Findings do not
automatically authorize new platform features.

| ID | Category | Status | Summary |
| --- | --- | --- | --- |
| SCRATCHPAD-F001 | platform discovery | addressed | Primary+S required modifier-aware shortcut records; delivered in 0.0.7. |
| SCRATCHPAD-F002 | tooling defect | addressed | Editor imports were absent from the validated guest profile. |
| SCRATCHPAD-F003 | platform discovery | addressed | A real file required a narrow single-document capability, not filesystem WASI. |
| SCRATCHPAD-F004 | boundary confirmation | addressed | Content stays host-owned and does not cross the component boundary during edit/save. |
| SCRATCHPAD-F005 | platform discovery | addressed | Dirty transition and save completion have different delivery semantics. |
| SCRATCHPAD-F006 | application convention | addressed | Resync-safe transient status needs a small process-local session model. |
| SCRATCHPAD-F007 | platform limitation | deferred | Gate B has optimistic conflict detection, not merge/reload/overwrite UX. |
| SCRATCHPAD-F008 | platform limitation | deferred | Atomic replacement cannot promise universal metadata or power-loss preservation. |
| SCRATCHPAD-F009 | boundary confirmation | addressed | The supported 1 MiB path is bounded and functional, but large-document local edit latency remains visible evidence. |

## SCRATCHPAD-F001 — Modifier-aware Save shortcut

Gate A proved that a focused Editor should decline Primary+S so the semantic
Save command can receive it, but the old shortcut type could not express the
modifier. Youth `0.0.7` added a general shortcut record with key and modifier
flags. Scratchpad now uses `Shortcut::primary('s')`; the test DSL proves
`key "s" +primary` follows the same command path as the Save button.

## SCRATCHPAD-F002 — Capability imports must be profile-aware

The first external Editor app exposed that `youth check` permitted neither the
Editor import nor later a document-only app that legitimately omitted state
calls. The profile now requires the application UI contract, permits only the
known Youth capabilities, and continues rejecting WASI filesystem imports.
Capabilities unused by a guest are allowed to be absent after component
link-time import elimination.

## SCRATCHPAD-F003 — One document is smaller than a workspace

Gate B needs one existing UTF-8 document. It does not need listing, arbitrary
open, creation, rename, deletion, watching, or multiple resources. The public
contract is therefore `youth:text-document@0.0.1`; “workspace” exists only in
trusted host configuration. The host retains a directory capability and a
validated relative path, rejects traversal and symlinks, and never grants
filesystem WASI to the component.

## SCRATCHPAD-F004 — The ownership boundary survived real persistence

Scratchpad calls `current()`, declares `Editor::document`, and requests Save.
It never snapshots the full buffer and has no file byte API. The host captures
immutable bytes and the edit sequence, commits the guest turn, then dispatches
replacement. This keeps document bytes out of Youth state and ordinary
component-boundary traffic. The remaining boundary traffic is opaque handles,
versions, semantic patches, dirty transitions, and effect outcomes.

## SCRATCHPAD-F005 — Dirty state and effect outcomes are distinct

Clean-to-dirty is a coalesced current-state notification: further edits while
already dirty generate no guest event. Save completion is an external-effect
outcome and must identify the captured sequence and opaque host-issued
version. If later edits exist, the saved bytes are accepted while the live
Editor remains dirty.

## SCRATCHPAD-F006 — Transient status is an app convention

`Saved`, `Saving...`, `Conflict`, and `Save failed` are process-local
presentation state. Persisting them would be wrong, while adding dirty state
to the public Document merely for reconstruction would widen the capability.
A small application-owned thread-local status model keeps ordinary resync
convergent and naturally resets on restart. This is evidence for a future
session-state ergonomic, not authorization for one yet.

## SCRATCHPAD-F007 — Conflict resolution remains intentionally absent

Youth detects every external byte change visible at the final comparison and
does not overwrite it. Scratchpad retains the complete local buffer and shows
`Conflict`, but offers no reload, merge, overwrite confirmation, or Save Copy.
A non-cooperating write after comparison and before replacement can still be
overwritten. Those workflows remain later gates.

## SCRATCHPAD-F008 — Replacement metadata and crash limits

The candidate begins private, is written and synced in the destination
directory, receives supported ordinary destination permissions, and is
atomically replaced. Gate B does not promise universal ACL, xattr, ownership,
resource-fork, or power-loss preservation. A crash after the request commits
but before dispatch may leave disk unchanged; a crash after replacement but
before completion leaves disk updated and restart reconstructs from disk. A
durable effect journal remains Gate D work.

## SCRATCHPAD-F009 — The 1 MiB limit is real, not merely declarative

An optimized end-to-end host test opened a 1 MiB document, performed one
host-local edit, saved exact bytes, and reconstructed the saved file in a new
runtime instance. On the local Apple arm64 evidence machine, initial
spawn/mount took 787.511 ms, the edit 403.938 ms, Save through completion
199.645 ms, and restart 424.979 ms. No measured operation was multi-second.

The result makes the bound credible but does not make large-document editing
fast: a roughly 404 ms character edit is conspicuous. Gate B keeps the current
Parley `PlainEditor` rather than introducing a second Ropey authority. The
measurement remains reporting evidence for a future editor-backend decision,
not a reason to leak file bytes into the guest or widen the capability.

## Raw-WIT exposure

Application authors see zero raw WIT concepts: no generated bindings,
revisions, acknowledgements, patches, numeric IDs, file handles, hashes,
absolute paths, or export plumbing. The vendored WIT directory remains an
inspectable language-neutral contract snapshot and is not a Rust binding
source.
