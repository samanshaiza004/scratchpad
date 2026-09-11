# Keyboard navigation research

Status: implemented baseline; the keyboard tree contract and tests landed in
the UI after this research snapshot. Snapshot: 2026-09-10.

## Recommendation in one sentence

Treat the Files sidebar as one composite keyboard-focus surface with an explicit
focused path, while keeping focus, selection, expansion, activation, and file
mutations as separate concerns. This matches the W3C tree model and fits the
existing `treeState`/command seams with a small, contained UI change.

## Current repository seam

- The Files sidebar is rendered by [`sidebar`](../../ui/root.go#L621), which
  creates a scrolling viewport, calls `ScrollOnInput`, and then renders the
  workspace tree. The existing scroll hook is wheel/hover based; it is not a
  keyboard reveal mechanism.
- [`treeState`](../../ui/root.go#L1200) stores `Expanded`, multi-selection,
  `AnchorPath`, `LeadPath`, visible paths, and transient row IDs. It has no
  focused path or focus container identity.
- [`renderTreeWithShell`](../../ui/root.go#L1387) creates a keyed container for
  each path, but the row itself is only `Attrs(Expand)` and a custom
  [`WorkstationRow`](../../ui/material.go#L207). The row calls Shirei's
  `ProcessButtonEvents`, which is pointer interaction only and does not take
  keyboard focus in the vendored framework source ([Shirei button source](https://github.com/hasenj/go-shirei/blob/6df9f18e3c2016d780f27f4ed67ff62cb189bf60/widgets/button.go#L31-L40)).
- A normal mouse click selects a row and immediately opens a file or toggles a
  directory; Shift selects a visible range; the platform primary modifier
  toggles a row. Those semantics are implemented in
  [`treeSelectionClick`](../../ui/root.go#L1233) and the row click handler
  ([`renderTreeWithShell`](../../ui/root.go#L1460)).
- The editor is currently the keyboard owner: its viewport is marked
  `Focusable`, calls `AutoFocus` and `FocusOnClick`, and calls `WantKeyboard`
  only while it has focus ([`EditableDocumentView`](../../ui/editor_view.go#L1292)).
  The Files tree has no analogous focus path.
- Global input is processed before the main layout in
  [`handleGlobalInput`](../../ui/root.go#L2311). F2 invokes workspace rename,
  but [`commandPath`](../../ui/root.go#L3104) falls back to the active document
  when no explicit path is supplied. Consequently, a future tree-focused F2
  must pass the focused/selected tree path explicitly or it can rename the
  active document instead. The command registry already names F2 as Rename and
  Delete as Move to Trash ([`commands/registry.go`](../../commands/registry.go#L123)).
- The current mouse selection model is already compatible with a separate
  keyboard focus model: selected paths are ordered through `VisiblePaths`, and
  the anchor/lead pair supports range selection. What is missing is the
  focused-row state and a keyboard dispatch scope.

## Evidence-backed conventions

### VS Code

VS Code exposes “Show Explorer / Toggle Focus” as a first-class command
(`Cmd+Shift+E` on macOS in the published reference), rather than requiring a
mouse click to enter the file tree ([default shortcuts](https://code.visualstudio.com/docs/reference/default-keybindings#_display)).
Its accessibility guidance recommends `F6` / `Shift+F6` for moving between
major workbench parts, and `Tab` / `Shift+Tab` for UI controls. Once a toolbar or
tab list has focus, arrow keys navigate inside that composite control
([accessibility guidance](https://code.visualstudio.com/docs/configure/accessibility/accessibility#_keyboard-navigation)).
That supports one Files-region tab stop with internal tree navigation, rather
than making every visible row a global Tab stop.

VS Code also makes shortcut scope explicit through context conditions (`when`
clauses), which is a useful model for ensuring tree keys do not steal editor,
modal, or text-input keys ([keybinding rules](https://code.visualstudio.com/docs/configure/keybindings#_when-clause-contexts)).

### JetBrains / IntelliJ IDEA

The Project tool window documents the same basic file-tree actions Scratchpad
needs: files can open with one click, directories can expand/collapse with one
click, and the opened editor file can be automatically selected in the Project
tree ([Project tool window](https://www.jetbrains.com/help/idea/project-tool-window.html#title_bar_context_menu)).
JetBrains also documents Speed Search: when focus is on a tree, list, or table,
typing searches for a matching item ([keyboard shortcuts](https://www.jetbrains.com/help/idea/mastering-keyboard-shortcuts.html#advanced-features)).
This is a strong precedent for type-ahead in the tree, and for keeping the
focused tree path synchronized with the active document when navigation reveals
that file.

### General tree and file-browser precedent

The W3C ARIA Authoring Practices tree pattern is the clearest normative-style
keyboard reference for a hierarchical file navigator. It specifies:

- Right Arrow opens a closed parent or moves to its first child; Left Arrow
  closes an open parent or moves to its parent.
- Up/Down move among visible nodes without changing expansion; Home/End move to
  the first/last visible node; Enter activates the focused node.
- Type-ahead moves to the next node whose name starts with the typed string.
- In multi-select trees, focus and selection are distinct; Space toggles the
  focused node, with Shift+Up/Down and Shift+Space available for range behavior.

See the [W3C Tree View Pattern](https://www.w3.org/WAI/ARIA/apg/patterns/treeview/#keyboardinteraction).
This is especially relevant because Scratchpad already supports multi-selection
with an anchor and lead path.

The locally used Shirei file-browser widget independently uses Up/Down for
highlight movement, Enter for directory activation, primary-modifier+Up for
parent navigation, and a staged Escape behavior ([Shirei file browser source](https://github.com/hasenj/go-shirei/blob/6df9f18e3c2016d780f27f4ed67ff62cb189bf60/widgets/filebrowser.go#L120-L131), [key handling](https://github.com/hasenj/go-shirei/blob/6df9f18e3c2016d780f27f4ed67ff62cb189bf60/widgets/filebrowser.go#L241-L295)). It is a useful local framework precedent, though not a requirement for the product tree.

## Recommended key matrix

The following is a proposed tree-local matrix, not current behavior. “Tree
focused” means the Files region owns focus and no modal, picker, text field, or
editor-specific transient surface is active.

| Key | Recommended behavior | Notes |
|---|---|---|
| Up / Down | Move focused row to the previous / next visible path | Keep expansion unchanged; reveal the row if needed. |
| Right | On a collapsed folder, expand it; on an expanded folder, focus its first child; on a file, no-op | Direct W3C tree convention. |
| Left | On an expanded folder, collapse it; otherwise focus the parent folder | Direct W3C tree convention. |
| Enter | Activate the focused row: open a file, toggle a folder | Mirrors the current click outcomes while making activation keyboard-driven. |
| Space | Toggle the focused row's selection | Keeps multi-selection independent from focus. |
| Shift+Up / Shift+Down | Extend selection to the adjacent visible row | Keyboard analogue of the existing Shift-click range model; optional if the product chooses a simpler first pass. |
| Home / End | Focus the first / last visible row | Do not expand folders while jumping. |
| Printable characters | Type-ahead to the next matching visible name | JetBrains Speed Search and the W3C tree pattern support this direction. Define the timeout and whether matching is sibling-only or whole-visible-tree. |
| Tab / Shift+Tab | Leave/enter the Files region as one focus stop | Use internal arrows for rows; do not put every row in the global Tab order. |
| F6 / Shift+F6 | Move to the next / previous major workbench part | VS Code precedent; only adopt if Scratchpad wants an explicit workbench-part focus loop. |
| Primary+Shift+E | Focus or toggle the Files sidebar | Candidate parity with VS Code; not currently bound in Scratchpad. |
| F2 | Rename the focused path | Must pass the tree path explicitly; never fall back to the active document while tree-focused. |
| Delete | Move the selected path(s) to Trash | Reuse the existing command, but resolve its target from tree selection. |
| Escape | First clear a pending range/selection state; otherwise leave tree focus or close the active transient | Preserve the existing global transient-dismissal precedence. |

The key policy should be explicit about selection. The safest accessible default
is the W3C multi-select model: arrow keys move focus, Space changes selection,
and the UI visibly distinguishes focused from selected rows. If product testing
shows that Scratchpad should behave like a conventional single-selection file
manager, plain Up/Down can instead make the focused row the sole selection, with
Shift extending and the primary modifier preserving/toggling selection. That is
a product decision, not a framework constraint.

## Accessibility and focus considerations

- Use one stable, labeled Files tree focus target and an internal focused-path
  state. Shirei's `Focusable` attribute adds a container to the focusable set;
  `Focus`, `FocusImmediateOn`, `ClearFocus`, `AutoFocus`, and
  `CycleFocusOnTab` provide the focus lifecycle ([Shirei focus API](https://github.com/hasenj/go-shirei/blob/6df9f18e3c2016d780f27f4ed67ff62cb189bf60/shirei.go#L1569-L1662)).
  `HasFocus` / `HasFocusWithin` can gate tree-local keyboard handling
  ([focus queries](https://github.com/hasenj/go-shirei/blob/6df9f18e3c2016d780f27f4ed67ff62cb189bf60/shirei.go#L1672-L1698)).
- Keep the focused-row indicator visually separate from the selection fill.
  W3C explicitly distinguishes DOM focus from selected state in multi-select
  trees; Scratchpad's current `Selected` map, `AnchorPath`, and `LeadPath` make
  that separation implementable.
- `WantKeyboard` is a backend text-entry request, not a tree-navigation
  dispatcher ([Shirei input API](https://github.com/hasenj/go-shirei/blob/6df9f18e3c2016d780f27f4ed67ff62cb189bf60/shirei.go#L110-L117)). Call it only while the tree's focus target owns the keyboard, and keep modal/text-input precedence ahead of tree handling.
- `ScrollOnInput` only reacts when its container is hovered
  ([Shirei scroll API](https://github.com/hasenj/go-shirei/blob/6df9f18e3c2016d780f27f4ed67ff62cb189bf60/shirei.go#L933-L950)). Keyboard movement therefore needs an explicit reveal step. Scratchpad already has a geometry-based precedent in
  [`revealPopupSelection`](../../ui/root.go#L440), which uses row render data,
  `SetScrollOffset`, and `RequestNextFrame`.
- Focus must survive row rerenders and filesystem mutations by path identity,
  with a deterministic fallback when the focused path disappears. The existing
  deferred row-ID invalidation in [`resetTreeAfterMutation`](../../ui/root.go#L2994)
  shows that the tree already treats row handles as transient.
- The public Shirei APIs inspected here expose logical focus and keyboard
  ownership, but no product-level tree role, accessible name, expanded-state
  announcement, or screen-reader tree semantics. Native accessibility behavior
  should be tested on the supported backends rather than inferred from
  `Focusable` alone. The W3C pattern gives the semantic target: a labeled tree,
  identifiable tree items, expanded state for parents, and a clear active item.

## Open questions

1. Should Scratchpad adopt the W3C multi-select model (focus moves independently
   and Space toggles selection) or the more familiar desktop model (plain arrow
   movement also changes the sole selection)?
2. Should the tree be one composite focus target, or should individual rows be
   focusable? The evidence favors one composite target, but the choice affects
   Shirei focus bookkeeping and screen-reader exposure.
3. What command should focus the Files tree without toggling sidebar visibility?
   Is VS Code's `Primary+Shift+E` acceptable, or should Scratchpad reserve a
   product-specific command?
4. How should F2, Delete, New File, New Folder, Move, and context-menu actions
   resolve targets when there is a focused path, a multi-selection, and an active
   document that differ?
5. Should type-ahead search visible descendants only, siblings only, or the
   whole workspace? How should it behave with Unicode names, repeated prefixes,
   and a collapsed parent?
6. Does the native Shirei backend expose enough accessibility information for a
   custom composite tree, or will the tree need additional semantic/accessibility
   support before it is considered complete?
7. How should focus and selection behave when a watcher refresh, rename, move,
   trash operation, or collapse removes the current path from `VisiblePaths`?

## Sources

- Repository seam: [`ui/root.go`](../../ui/root.go), [`ui/material.go`](../../ui/material.go), [`ui/editor_view.go`](../../ui/editor_view.go), [`commands/registry.go`](../../commands/registry.go).
- Shirei dependency version: [`go.mod`](../../go.mod#L5); first-party source at [hasenj/go-shirei](https://github.com/hasenj/go-shirei/tree/6df9f18e3c2016d780f27f4ed67ff62cb189bf60).
- [VS Code default keyboard shortcuts](https://code.visualstudio.com/docs/reference/default-keybindings), [VS Code accessibility](https://code.visualstudio.com/docs/configure/accessibility/accessibility), and [VS Code keybinding rules](https://code.visualstudio.com/docs/configure/keybindings).
- [JetBrains Project tool window](https://www.jetbrains.com/help/idea/project-tool-window.html), [JetBrains keyboard shortcuts](https://www.jetbrains.com/help/idea/mastering-keyboard-shortcuts.html), and [predefined Windows keymap](https://www.jetbrains.com/help/idea/reference-keymap-win-default.html).
- [W3C ARIA Authoring Practices: Tree View Pattern](https://www.w3.org/WAI/ARIA/apg/patterns/treeview/).
