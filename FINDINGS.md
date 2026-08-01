# Scratchpad Findings

This is the evidence record for the Scratchpad entry in the Youth Utility
Suite. Findings describe observed application and platform friction; they
do not automatically authorize new platform features.

Scratchpad is Gate A's application proof: an `Editor` node, declared and
read back through `context.editor()` with no raw WIT, whose live buffer,
cursor, selection, IME, undo/redo, clipboard, scrolling, and accessibility
tree are all host-owned. `Save` is the one guest turn this app ever spends
on that node, and it costs exactly `snapshot()` + `accept()` — never
`replace()`, since this app never has authoritative content of its own.
See `README.md` for the current state.

## SCRATCHPAD-F001 — No modifier-aware keyboard shortcuts exist yet

Gate A's own design notes describe `Ctrl`/`Cmd`+S as falling through from a
declining, focused Editor to the app's declared Save command — an ordinary
semantic activation, not a special event. That decline-and-fall-through
path is real and already tested at the platform level (a focused Editor's
`editor_input()` returns `None` for Primary+S, so it never claims the key).
What is missing is the other half: `youth_tree::ShortcutKey` has only a
bare `Character(String)` variant, and `youth_interaction`'s own generic
shortcut matching explicitly excludes any character press with Control or
Super held (`LogicalKey::Character(value) if !modifiers.control &&
!modifiers.super_key`). So a declined Primary+S reaches the fallback
shortcut-matching path and is simply dropped — no app-declared shortcut
can ever be bound to a modified character today, regardless of protocol
version.

This app works around it by binding `Save` to a plain `Button` rather than
a keyboard shortcut, which is a legitimate "ordinary semantic activation"
in its own right and was enough to prove the accept boundary end to end.
A real `Primary+S` (or any modifier-aware shortcut) needs a
`ShortcutKey` variant that carries modifier state and a matching arm in
`youth_interaction::key()`'s non-editor fallback — platform work, not
something this repository can address on its own.

## SCRATCHPAD-F002 — `youth check` could not have accepted any Editor-capable app before this pass

Building this app the first time failed `youth check` with `component
imports interfaces outside the Youth Rust Guest Profile:
["youth:editor/session"]`, even though `youth-runtime`'s own test suite
(`import_profile.rs`) had already anticipated and asserted a
`PERMITTED_V006` list containing exactly that import. The gap was that
`youth-runtime::profile::PERMITTED_GUEST_IMPORTS` — the list
`validate_component` (the function `youth check`/`youth build` actually
call) enforces — had never had `youth:editor/session` added to it, only
`youth:time/scheduler`. Every test that exercised the editor capability
went through `YouthApp::load`/`mount` directly, never through
`profile::validate_component`, so nothing caught the gap until a real
external app tried to pass `youth check`.

Fixed upstream in the Youth workspace (`youth-runtime/src/profile.rs`)
alongside adding the `0.0.6` entry to `youth-project::SUPPORTED_PROFILES`
(protocol, WIT hash, and this repository's pinned SDK revision) — neither
of which had a "real external-SDK release reason" to exist until this app
needed them. `youth-runtime::profile`'s own unit test and
`youth-project`'s `v006_profile_hash_matches_the_canonical_tree` now cover
both directly.

## What this app's own test suite still cannot exercise

`.youth-test` drives the guest through ordinary semantic turns
(`mount`/`activate`/`key`/`state`); it has no hook for host-local typing,
since typing is specifically designed to never reach the guest at all.
That means this repository's own tests can prove the mount-declares,
Save-accepts, and restart-persists shape of the boundary, but not that
real keystrokes land in the buffer, that IME composition behaves, that
undo/redo groups correctly, or that scrolling/selection/AccessKit work —
those are all proven at the platform level (`youth-editor-engine`,
`youth-runtime`'s `editor_local_input.rs`/`editor_accessibility.rs`,
`youth-desktop`'s `access.rs`/`raster.rs`), not here. This repository
proves the guest-side half of the contract; the Youth workspace proves the
host-side half.

Native verification in this pass was `youth check`/`youth build` on macOS
only — no Linux or Windows smoke test, and no real screen reader was
available to exercise the AccessKit tree this app's Editor now exposes.
