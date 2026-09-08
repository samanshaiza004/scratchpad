# Integrated terminal research

Status: research complete; Terminal Phase 0 proof added under
`terminal/phase0/`. Sources were checked on 2026-09-01. This note evaluates an
integrated terminal for Scratchpad, not the editor, Markdown, language-service,
or Shirei menu work already in progress. No integrated workbench panel has been
implemented.

## Recommendation

The idea is a good fit for Scratchpad, provided the terminal is treated as an
independent subsystem:

```text
shell process
    ↕
PTY / ConPTY session
    ↕
terminal emulator core
    ↕
terminal screen snapshot
    ↕
specialized Shirei terminal view
```

The preferred first stack is:

1. A small Scratchpad-owned session layer for shell lifecycle, PTY I/O,
   resizing, focus, copy/paste, and teardown.
2. `libghostty-vt` for VT parsing and terminal state, accessed through the
   Go binding `go.mitchellh.com/libghostty` behind a Scratchpad adapter.
3. A fixed-cell renderer in Shirei, separate from `EditableDocumentView` and
   separate from `document.Document` / `editor.Buffer`.

Do not embed the Ghostty GUI. Ghostty describes `libghostty-vt` as the part
that parses terminal sequences and maintains terminal state, while leaving
rendering to the embedding application. The project explicitly lists macOS,
Linux, Windows, and WebAssembly compatibility, but also says that the C API
signatures are still in flux. [Ghostty project README](https://github.com/ghostty-org/ghostty#cross-platform-libghostty-for-embeddable-terminals)

Ghostling is useful as the reference shape: it uses the C API with its own
Raylib renderer, and describes `libghostty-vt` as having no windowing or
renderer code. It also demonstrates that the core supplies cell-oriented
terminal behavior such as reflow, colors, graphemes, keyboard encoding, mouse
tracking, scrollback, and focus reporting. [Ghostling README](https://github.com/ghostty-org/ghostling)

The important qualification is that the Go binding is not a stable official
Go API. The current published module is an untagged pseudo-version,
`v0.0.0-20260824160354-7a5ea4cb990c`; its documentation warns that the Go API
may change. It is MIT-licensed, uses CGO/pkg-config, and exposes the pieces a
host needs: `Terminal.VTWrite`, terminal resizing, cursor/mode state, a
`RenderState`, row/cell access, key and mouse encoders, paste encoding, and
effect callbacks. [Published Go binding](https://pkg.go.dev/go.mitchellh.com/libghostty)

There is also a current toolchain mismatch to resolve: the binding repository
declares Go 1.26, while Scratchpad currently declares Go 1.25. [Binding
toolchain declaration](https://github.com/mitchellh/go-libghostty/blob/main/go.mod)
That favors the pure-Go path for an initial spike if retaining the current
Go-1.25/no-CGO compatibility is a hard requirement.

Therefore the product decision should be:

> Spike and pin the Go binding behind a narrow adapter; do not let its current
> API become Scratchpad's public terminal model.

If the binding fails the release-build or renderer proof—or if raising the
toolchain is not acceptable—keep the same Scratchpad interfaces and substitute
a pure-Go terminal core. Do not begin by shipping two production backends.

## Why the terminal needs its own subsystem

The existing Scratchpad architecture intentionally has one authoritative
document buffer and a virtualized, byte-oriented editor view. That is the
right model for files and the wrong model for a terminal. A terminal screen is
an ephemeral grid with alternate-screen state, scrollback, cursor modes,
colors, attributes, control-sequence effects, and application-generated input
responses. It must not be represented as a `Document`, saved to disk, or fed
through the editor's byte↔rune selection and undo paths. See the existing
[architecture boundary](ARCHITECTURE.md) and [editor contract](EDITOR-CORE-CONTRACT.md).

The terminal view should own only terminal presentation state. A minimal
internal shape is:

```go
type SessionOptions struct {
    Shell string
    Dir   string
    Env   []string
    Cols  int
    Rows  int
}

type TerminalSession interface {
    SendKey(KeyEvent) error
    SendPaste([]byte) error
    Resize(cols, rows int) error
    Snapshot() TerminalSnapshot
    Close() error
}

type TerminalSnapshot struct {
    Cols, Rows int
    Cells      []TerminalCell
    Cursor     TerminalCursor
    Scrollbar  TerminalScrollbar
    Title      string
}
```

The exact types should be shaped by the first spike. The boundary matters more
than these names: no `libghostty` or PTY handles should leak into `ui`, and no
terminal text should enter the document authority.

## Process and concurrency design

For the first product version, keep one application process. A live terminal
session may have a blocking worker, but it should exist only while that
session exists and should sleep on PTY/channel I/O rather than run a ticker.

The safest ownership arrangement is:

```text
UI frame goroutine
    sends key/paste/resize commands
    reads an immutable or locked snapshot

terminal session worker
    owns PTY handles
    owns libghostty Terminal and KeyEncoder
    reads PTY bytes
    feeds VT bytes
    updates RenderState
    publishes copied screen data
```

This follows the binding's concurrency contract: exported handles are not
generally safe for concurrent use; `RenderState.Update` needs exclusive
terminal access; copied `Cell`, `Row`, style, color, and palette values may be
retained after the call. [Go binding concurrency and render-state documentation](https://pkg.go.dev/go.mitchellh.com/libghostty#hdr-Concurrency)

The worker must never call Shirei layout, widget, or `Use` state directly. It
can publish data to Scratchpad-owned state and request a frame. Shirei's
`RequestNextFrame` is an atomic request for another render when input did not
cause one; the current Shirei source also exposes `FrameRequested`. [Shirei frame scheduling source](https://github.com/hasenj/go-shirei/blob/6df9f18e3c2016d780f27f4ed67ff62cb189bf60/shirei.go)

Output bursts should coalesce wakeups, not bytes. The reader may append many
PTY reads before one frame; the emulator must still receive every byte in
order. On the next frame, the view consumes the newest published snapshot and
draws only what changed when the renderer can support that. When the shell is
quiet, no timer or redraw request remains.

VS Code is a useful scale reference rather than a requirement to copy. Its
current source starts a dedicated PTY host service and exposes it over an IPC
channel, separating shell/PTY lifecycle from the workbench UI. For Scratchpad,
an in-process worker is the smaller first step; an external helper is a later
isolation option if multiple sessions, crashes, or platform packaging justify
it. [VS Code PTY host](https://github.com/microsoft/vscode/blob/main/src/vs/platform/terminal/node/ptyHostMain.ts)

## PTY choice

Use a PTY abstraction, not `os/exec.Cmd` with ordinary pipes. A terminal
application needs a controlling terminal so shells and full-screen programs
see terminal modes, window size, signals, and interactive behavior.

`github.com/aymanbagabas/go-pty` is the most direct first candidate for a
cross-platform Go layer. Its current v0.2.3 package states that it supports
Unix PTYs and Windows ConPTY, and its implementation has platform-specific
files for Unix and Windows. It is MIT-licensed. [go-pty README](https://github.com/aymanbagabas/go-pty) · [go-pty package v0.2.3](https://pkg.go.dev/github.com/aymanbagabas/go-pty@v0.2.3)

The Windows case is materially different, not just another filename. Microsoft
documents that the host creates communication channels and the pseudoconsole
before creating the child process, attaches it with an extended startup
attribute, services the channels without deadlocking, resizes it in character
dimensions, and closes the pseudoconsole during teardown. [Microsoft ConPTY session lifecycle](https://learn.microsoft.com/en-us/windows/console/creating-a-pseudoconsole-session)

The PTY adapter should expose only the operations Scratchpad needs:

```text
start(shell, cwd, env, cols, rows)
read output bytes
write input bytes
resize cols × rows
wait for exit
close and reap
```

Initial shell policy can be conservative: the user's default shell on Unix,
the user's configured shell or PowerShell/`cmd.exe` choice on Windows, and the
workspace root as the initial directory. Shell discovery, profiles, login
flags, environment editing, and task integration should come later.

Teardown needs explicit tests. On Unix, close the PTY, terminate/reap the
process group as appropriate, and ensure a shell child cannot remain hidden
after the panel closes. On Windows, drain/close ConPTY channels in the order
required by the API and wait for the child; Microsoft notes that closing the
pseudoconsole terminates attached client processes but can deadlock if its
channels are not serviced during teardown. [Microsoft ConPTY teardown guidance](https://learn.microsoft.com/en-us/windows/console/creating-a-pseudoconsole-session#ending-the-pseudoconsole-session)

## Terminal core options

### Preferred: libghostty-vt

This is the best semantic fit if the binding/build proof passes. The core is
already designed around terminal state rather than a text widget. The Go
binding provides:

- incremental VT writes, including malformed-input handling;
- normal and alternate screens, scrollback, cursor state, modes, colors,
  styles, hyperlinks, and cell content;
- a render-state update boundary with dirty/partial/full state;
- copied row/cell values and borrowed views for efficient renderer reads;
- terminal-aware key, mouse, focus, and paste encoders;
- synchronous effect callbacks for data that the terminal sends back to the
  PTY, such as responses to device queries.

The render state is particularly valuable: it can be updated by the single
terminal owner, then read by a renderer without touching the live terminal
until the next update. [Go render-state API](https://github.com/mitchellh/go-libghostty/blob/main/render_state.go) · [Go row/cell API](https://github.com/mitchellh/go-libghostty/blob/main/render_state_row.go) · [Go terminal API](https://github.com/mitchellh/go-libghostty/blob/main/terminal.go)

The costs are real:

- the Go binding is untagged and explicitly unstable;
- it is a CGO package and needs the libghostty-vt library, headers, and
  pkg-config/build integration;
- the exact static/dynamic linking behavior differs by binding revision, so
  Scratchpad must pin and test one revision rather than copy current README
  commands blindly;
- libghostty-vt's C API is stable in behavior but still described by Ghostty as
  having signatures in flux;
- effect callbacks run synchronously during VT writes and must not re-enter
  the same terminal or block on slow application work.

Scratchpad already made a conscious native-CGO release decision for its
official Tree-sitter backend: official desktop artifacts are built natively
per target, while a no-CGO build is a compatibility path rather than the
release artifact. That makes libghostty technically plausible, but it does not
remove the need to measure binary size, signing, and per-OS packaging. [Gate E packaging contract](GATE-E-RESULTS.md)

### Fallback: xterm-go

`github.com/gitpod-io/xterm-go` is a credible no-CGO escape hatch. Its current
README describes a pure-Go, headless port of xterm.js that parses VT500/ANSI
sequences and maintains terminal buffers without a browser or renderer. It
lists alternate-screen buffers, scrollback, colors, attributes, resize/reflow,
serialization, and conformance tests against xterm.js. [xterm-go README](https://github.com/gitpod-io/xterm-go)

The tradeoff is maturity and parity risk. The published version checked here
is the untagged pseudo-version `v0.0.0-20260828130427-e62e9648055e`, and
pkg.go.dev marks it as lacking a tagged or stable version. Its API is simpler
for screen extraction than the current Ghostty binding, but Scratchpad would
need to supply its own terminal key/mouse mode integration and verify behavior
against the programs it cares about. [xterm-go package metadata](https://pkg.go.dev/github.com/gitpod-io/xterm-go)

Keep this as a backend-compatible fallback, not as an automatic runtime
fallback. Two cores in released builds would create two sets of subtly
different VT, Unicode, scrollback, and keyboard semantics.

### Avoid: writing a parser or embedding the Ghostty GUI

Writing a VT parser, screen model, keyboard protocol encoder, and Unicode cell
width implementation inside Scratchpad would recreate the hardest and most
interoperability-sensitive part of a terminal. Embedding Ghostty's GUI would
also introduce a second windowing/rendering/event system that fights Shirei's
layout, focus, clipboard, and lifecycle model. Use the VT library, not the
standalone terminal application.

## Shirei renderer design

This is the highest-risk Scratchpad-specific part and should be proven before
committing to a dependency.

A terminal view is a fixed grid:

```text
cell (0,0) → x = origin.x + 0 * cellWidth
cell (1,0) → x = origin.x + 1 * cellWidth
cell (0,1) → y = origin.y + 1 * cellHeight
```

It is not an ordinary flowing paragraph. The renderer must preserve the
terminal core's column order, wide-cell continuation cells, combining marks,
background rectangles, cursor location, selection range, and style attributes.
It should render visible rows only, but it must not turn terminal cells into
document lines or use the document editor's hit-testing/selection mapping.

Shirei's ordinary text path is HarfBuzz-based and exposes glyph segments with
advances, offsets, font IDs, and clusters. It also performs bidi paragraph
processing and has script-aware fallback. That is excellent for Scratchpad's
document editor, but it is not proof that a whole terminal row can be shaped
as a normal paragraph without changing cell positions. [Pinned Shirei text source](https://github.com/hasenj/go-shirei/blob/6df9f18e3c2016d780f27f4ed67ff62cb189bf60/text.go)

The initial terminal renderer should therefore be a dedicated cell renderer:

1. Obtain the terminal snapshot and its cell metadata.
2. Measure one selected monospace face for the terminal cell width/height.
3. Paint backgrounds in runs or cell rectangles.
4. Place glyph/grapheme content at explicit cell coordinates, treating a wide
   grapheme as occupying two cells and a continuation cell as non-drawable.
5. Draw the terminal cursor from terminal cursor style/visibility state.
6. Keep mouse hit testing in cell coordinates and return terminal mouse-report
   events when the application has enabled them; otherwise use the view's own
   scroll/select/copy behavior.

For a first Shirei spike, it is acceptable to test a row-at-a-time shaped path
with a known monospace face, but it must be treated as an experiment. It must
pass fixtures containing ASCII punctuation, combining marks, CJK, Arabic,
Hebrew, emoji, wide characters, and full-screen redraws. If ordinary
`ShapeText` changes x positions, reorders cells, or cannot expose explicit
glyph placement, stop and design a small renderer-facing Shirei seam rather
than weakening terminal semantics.

Do not add a `TerminalTextArea` by cloning the editor. A `TerminalView` should
be a specialized Shirei composition with its own focus and pointer handling.
Shirei's custom-widget guidance supports this process-versus-presentation
shape: the application owns the container, processes input for it, and paints
the resulting state. [Shirei custom-widget guidance](https://github.com/hasenj/go-shirei/blob/6df9f18e3c2016d780f27f4ed67ff62cb189bf60/docs/custom-widgets-tutorial.md)

## Font policy and Unicode

The terminal font should be a terminal-specific preference, not the document's
prose or code style. A reasonable preference order is:

```text
CommitMono
→ OCR-B
→ platform monospace
   macOS: SF Mono, Menlo, Monaco
   Windows: Cascadia Mono, Consolas, Lucida Console
   Linux: Noto Sans Mono, DejaVu Sans Mono, Liberation Mono
→ Shirei's script-aware system fallback
```

This is a preference chain, not a promise that every family is installed.
Missing families must be skipped. Shirei's current fallback system probes
registered faces for coverage, chooses script-specific candidates, memoizes
the result, and retains a last-resort path. [Shirei font fallback source](https://github.com/hasenj/go-shirei/blob/6df9f18e3c2016d780f27f4ed67ff62cb189bf60/fonts_fallback.go) · [Shirei font registry](https://github.com/hasenj/go-shirei/blob/6df9f18e3c2016d780f27f4ed67ff62cb189bf60/fonts.go)

For terminal correctness, the font's visual advance is subordinate to the
terminal cell grid. ASCII should use one stable cell width; CJK/wide graphemes
should consume two cells; combining marks should attach without advancing;
emoji and unsupported scripts should use a fallback glyph rather than a
custom approximation or an empty cell. A fallback face may need clipping or a
cell-aware placement rule if its natural advance does not match the base
monospace face.

No font file should be bundled as part of this research. The exact CommitMono
asset and distribution license were not verified here. Configure the family
name and exercise it when locally installed; if bundling becomes desirable,
record the exact source/version, verify redistribution/application-embedding
and commercial-use rights for that asset, and preserve its notices separately
from Scratchpad's MIT license.

## Security and terminal effects

Shell output is not merely display text. VT/OSC sequences can request title
changes, hyperlinks, clipboard operations, working-directory updates, device
reports, notifications, or large graphics. The terminal core may parse these,
but the host decides which effects are allowed.

The first panel should:

- keep OSC 52 clipboard access disabled or explicitly gated until the host has
  a reviewed policy;
- treat OSC 8 hyperlinks as inert metadata until the user clicks, then open
  only validated schemes through Scratchpad's normal URL path;
- keep terminal title changes inside the panel/session rather than renaming
  documents or the application window unexpectedly;
- bound or reject image protocols and large payloads until a renderer and
  memory policy exist;
- never let an effect callback block the VT worker or synchronously re-enter
  `VTWrite`.

Ghostling explicitly lists OSC clipboard support as not properly exposed in
its minimal example, which is a useful reminder that “the core parses it” and
“the host should grant the side effect” are separate decisions. [Ghostling
feature notes](https://github.com/ghostty-org/ghostling#what-is-coming)

## Staged implementation plan

### Phase 0 — dependency and renderer spike

No product UI yet.

- If the release toolchain can move to Go 1.26 and native dependencies are
  acceptable, pin one `go-libghostty` pseudo-version and the matching
  libghostty-vt source/build artifact. Otherwise, run the same spike with
  xterm-go first and keep the adapter boundary identical.
- Build a tiny session fixture that starts a shell, writes commands, resizes,
  receives output, and closes cleanly on macOS.
- Feed canned VT fixtures directly into the adapter: colors, alternate screen,
  cursor modes, scrollback, wide/combining/emoji text, and key responses.
- In a headless Shirei frame, render an 80×24 snapshot and prove fixed cell
  positions before adding any workbench wiring.
- Measure native build, signing, package size, and a second target. If the
  binding or renderer fails, run the same fixtures through xterm-go before any
  production decision.

### Phase 1 — one bottom panel

- Add one terminal session to application/workbench state, not document state.
- Toggle it from a command such as View → Terminal and a platform-appropriate
  shortcut.
- Start one shell in the workspace root.
- Resize the PTY and emulator from the panel's measured cell dimensions,
  preferably after a small resize debounce.
- Support typing, Enter, Ctrl+C, copy/paste, scrollback, exit, and restart.
- Keep terminal focus explicit so editor commands and terminal commands do not
  compete.

### Phase 0 result — 2026-09-02

The isolated proof in [`terminal/phase0/`](../terminal/phase0/) passed on
macOS arm64. The pinned Go binding and matching Ghostty revision built with
Go 1.27, Zig 0.16.0, and AppleClang 21 using static linking, while the root
Scratchpad module remained on Go 1.25. Deterministic VT fixtures, Unicode and
style snapshots, fixed-cell Shirei placement, PTY resize, Ctrl-C, shell exit,
race detection, and vet all passed. A second-OS build and release packaging
proof remain required before the panel go/no-go.

### Phase 2 — hardening

- Add deterministic snapshot tests for the terminal model and renderer.
- Test output floods without dropping bytes or creating one frame per read.
- Test process-group cleanup, shell exit, panel close, application quit, and
  ConPTY teardown.
- Test terminal key encoding under application cursor/keypad modes, bracketed
  paste, mouse reporting, focus reporting, and modifier combinations.
- Test the OSC/security policy and clipboard behavior.
- Add release builds for the supported desktop targets.

### Phase 3 — later features

Only after the single-session panel is reliable: multiple sessions, tabs,
splits, profiles, shell integration, command/task links, search, persistent
session restore, and terminal graphics.

## Decision matrix

| Approach | Strength | Main risk | Position |
| --- | --- | --- | --- |
| `libghostty-vt` through `go-libghostty` | Strong terminal semantics, cell/render state, encoders, scrollback, high-performance core | Unstable Go API, Go 1.26 requirement, and CGO/pkg-config/release integration | Preferred semantic backend if gates pass |
| `xterm-go` | Pure Go, headless, screen state, no CGO | Untagged young dependency; more input/render integration remains | Isolated no-CGO fallback/spike |
| `go-pty` + custom emulator | Cross-platform PTY abstraction | Scratchpad would own all VT correctness | Use `go-pty` only as the PTY layer |
| Standalone Ghostty GUI | Mature complete terminal application | Second window/event/render stack; wrong embedding boundary | Do not use |
| Handwritten VT emulator | No dependency | Very large correctness and interoperability surface | Do not use |
| External terminal process | Strong isolation | IPC, packaging, lifecycle, and snapshot latency | Later option, not MVP |

## Go/no-go gates

Proceed with `libghostty-vt` only if all of these are true:

- the pinned binding and library build on Scratchpad's supported macOS,
  Windows, and Linux release targets;
- the adapter can keep terminal handles single-owner and publish safe copied
  snapshots;
- a Shirei fixed-cell proof keeps ASCII columns stable and displays wide,
  combining, emoji, CJK, Arabic, and Hebrew fixtures without crashes or
  missing/empty layouts;
- resize, key encoding, bracketed paste, scrollback, alternate screen, and
  exit/restart work with a real shell;
- output bursts cause coalesced frame requests, not a redraw loop;
- closing the panel leaves no child process or recurring worker behind;
- the OSC/effect and clipboard policy is explicit;
- native packaging and license notices are reproducible.

If the CGO or binding gate fails, substitute xterm-go behind the same adapter
and repeat the semantic/render proof. If the fixed-cell Shirei gate fails,
pause for a narrowly scoped renderer capability or upstream discussion; do
not route terminal content through the existing editor architecture.

## Bottom line

Scratchpad should add a terminal panel eventually. The best path is not a
Ghostty window inside Scratchpad and not a text widget pretending to be a
terminal. It is a small session subsystem, a real PTY, a terminal core behind
an adapter, and a purpose-built fixed-cell Shirei renderer. `libghostty-vt`
is the preferred semantic core when its Go 1.26/CGO packaging gates pass;
otherwise xterm-go is the sensible Go-1.25-compatible starting point.

The dependency-plus-renderer spike has now answered the first host-local
uncertainty: the pinned binding and Shirei fixed-cell proof are viable together
without changing Scratchpad's root toolchain. The next decision is a second-OS
and release-packaging check; only after that should Scratchpad add the one-panel
workbench integration.
