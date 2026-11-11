# Alicorn frontend coverage

Alicorn is Scratchpad's supported desktop frontend. This page summarizes the current implementation; it is not a claim that every interaction has been manually certified on every operating system. The latest published release is v0.2.0. See the [roadmap](../../PLAN.md), [changelog](../../../CHANGELOG.md), and date-scoped [validation records](../../validation/README.md).

## Implemented product coverage

| Area | Current implementation |
| --- | --- |
| Editing | One Go-owned document buffer and revision; Alicorn handles caret, selection, text shaping, soft wrapping, clipboard, IME presentation, and bounded optimistic edits. Supports undo/redo, Find/Replace, Go to Line, semantic selection expansion, Markdown commands, and revision-safe folds. |
| Workspace | Keyboard-navigable tree, Quick Open, editable Search and Symbols, file and directory operations, recent workspaces, restored sessions, and detachable text-document windows. |
| Source-connected views | Full, Focus, Skim, and Overview semantic zoom; source-linked tasks, symbols, headings, and links; pinned ranges across documents; safe write-through only when a current range maps unambiguously. |
| Appearance | Persisted Warm and Cool Light themes, editor font family/size and zoom, accessibility appearance preferences, theme-driven syntax/modal colors, and optional Workbench Relief. Live theme replacement is development dogfood, not a general user-facing theme editor. |
| Media and overlays | Read-only PNG/QOI tabs and Quick Open with an opt-in Gaussian backdrop-blur presentation. Image previews do not edit or save image data. |
| Native shell | macOS content titlebar and AppKit menus, Windows integrated caption frame and connected tabs, Linux system decorations and separate-tab fallback; native menu/shortcut handling is platform-specific. |
| Persistence and recovery | Versioned clean-session restoration, independent recent-workspace storage, atomic preferences, crash recovery, and external-file conflict handling. |

The Go application owns document bytes, editing commands, workspace semantics, persistence, conflicts, and recovery. Alicorn owns transient interaction and presentation. Caliber carries bounded commands, resources, and acknowledgements between them. The former Shirei and GPUI experiments are archived at `archive/pre-v0.1.0-frontends`; neither is an active frontend target.

## Known limits and release work

- v0.2.0 release acceptance is recorded in [issue #17](https://github.com/samanshaiza004/scratchpad/issues/17); see the validation records for the exact platform scope and accepted measurement limits.
- The complete semantic-zoom keyboard, mouse, and trackpad acceptance has been confirmed on macOS and Windows; the original October validation matrix predates that follow-up.
- Large semantic-plan construction runs on a cancellable, generation-scoped worker while Full source remains interactive. The historical million-line prose fixture measured about 206 ms before this change; current worker results and cross-platform acceptance are recorded in the [semantic-zoom](../../validation/semantic-zoom.md), [Windows](../../validation/issue-17-windows-2026-11-10.md), and [macOS](../../validation/issue-17-macos-2026-11-11.md) reports. Native UI-to-visible latency and full GUI-process memory high-water were not instrumented and are not release claims.
- Image tabs are read-only PNG/QOI previews; they are not general image editors.
- Live color-theme replacement is an opt-in development dogfood path. It does not enable arbitrary theme-structure or layout replacement.
- The language-aware code presentations are limited to the registered providers in the source tree; unsupported files remain editable as ordinary text.

## Validation guidance

Automated Go, Odin, bridge, and native-host checks establish the contracts they exercise. Package audits and launch smokes establish package loading and startup behavior. They do not prove physical gesture feel, IME candidate behavior, display-scale changes, native dialogs, or visual quality on every device. Consult each [validation record](../../validation/README.md) for its exact commit, platform, and scope; older reports remain historical evidence rather than a current aggregate pass/fail matrix.
