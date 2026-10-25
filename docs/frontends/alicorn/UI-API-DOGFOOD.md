# Alicorn UI API dogfood in Scratchpad

## Question and conclusion

Does `alicorn:ui` make ordinary Scratchpad application code easier to read, maintain, and write, while preserving the runtime's retained behavior?

The migration shows a real authoring improvement, with a modest rather than dramatic reduction in source size. Names such as `gui.row`, `gui.column`, and `gui.button` make the intended structure more visible; callers no longer repeat `.Container`, layout direction, closing calls, or `key_string` for ordinary elements. The line count stayed almost flat because Odin's lexical scopes still need braces. Advanced editor, scrolling, text-input, and native-host work remains direct Alicorn code.

This is evidence from Scratchpad source and four measured UI scenes. It is not a usability study with new developers.

## Revisions and scope

- Scratchpad baseline: `b32cdcd` (merged semantic-zoom fixes).
- Dogfood branch: `codex/ui-api-dogfood`.
- Alicorn: `ec5abb0232205aae0c5f34901a2decede27b058f` (`codex/ui-dogfood-compatibility`), based on merged #112.
- Caliber remained pinned at `197cd964cc7265bc60df599a6b8562eac7c75f3a`.

The production migration covers 13 frontend files. All ordinary production `alicorn.text` and `alicorn.button` calls in those files now use `gui.text` or `gui.button`; simple row, column, and exact-layout scopes use the scoped UI helpers where their contract fits. The domain state and event handlers remain ordinary Scratchpad Odin code.

The small compatibility addition to Alicorn keeps the UI helpers on the existing runtime:

- `ui.layout` scopes an exact `Layout_Style` for layouts that need min/max bounds, compression, or other exact settings.
- `ui.row`, `ui.column`, and `ui.panel` accept labels so migrated nodes can keep their diagnostic identity.
- `ui.text` accepts the existing typed layout, font, and text-style options.
- `ui.button` accepts the existing typed layout, state, text, and content styles, plus width/height/grow shortcuts.

The full runtime package remains available beside `alicorn:ui`. Scratchpad keeps it for root/frame management, text fields, semantic controls, virtual lists, scroll regions, material surfaces, GPU/image work, native services, and controls whose `Node_ID` is consumed by editor or host behavior. Those are explicit lower-level use cases, rather than ordinary label/button composition.

## Source measurements

Counts cover top-level production frontend Odin files. Tests, generated theme source, and the Caliber bridge are excluded. `code_lines` means nonblank physical lines after comments and string contents are masked; it is not a complexity or readability score. Per-file and selected-procedure counts are in [ui-api-authoring-metrics.json](ui-api-authoring-metrics.json), and can be regenerated with `python3 tools/measure_alicorn_authoring.py --base b32cdcd --out docs/frontends/alicorn/ui-api-authoring-metrics.json`.

| Measure | Before | After | Change |
| --- | ---: | ---: | ---: |
| Production source lines | 18,881 | 18,902 | +21 (+0.1%) |
| Nonblank code lines | 17,528 | 17,549 | +21 (+0.1%) |
| Source bytes | 838,900 | 832,625 | −6,275 (−0.7%) |
| `layout_style` expressions | 221 | 125 | −96 (−43%) |
| Explicit `container_end` calls | 63 | 30 | −33 (−52%) |
| Explicit `*_end` scope calls | 120 | 87 | −33 (−28%) |
| Direct runtime text/button calls | 166 | 0 | −166 |
| Calls through `alicorn:ui` | 0 | 199 | +199 |
| `key_string` calls | 148 | 68 | −80 |
| Lines longer than 160 columns | 228 | 192 | −36 (−16%) |

The five selected procedures also became smaller in source bytes while keeping their line count unchanged. `build_start_screen` went from 2,590 to 2,234 bytes and from 8 to 2 layout-style expressions; `build_app` went from 25,392 to 23,570 bytes and from 51 to 22 layout-style expressions. The remaining layout declarations are concentrated in dynamic/advanced layouts, not the common controls migrated here.

The start-screen actions show the authoring change:

```odin
// Before
alicorn.container_begin(ui, .Container, label="scratchpad-start-actions",
    style=alicorn.layout_style(.Row, height=42, gap=8, align=.Center))
if alicorn.button(ui, "Open File…", key=alicorn.key_string("start-open-file"),
    style=alicorn.layout_style(.Row, grow=1, height=38)) {
    dispatch_action(app, rt, ACTION_FILE_OPEN)
}
alicorn.container_end(ui)
```

```odin
// After
if gui.row(ui, label="scratchpad-start-actions", height=42, gap=8, align=.Center) {
    if gui.button(ui, "Open File…", key="start-open-file", grow=1, height=38) {
        dispatch_action(app, rt, ACTION_FILE_OPEN)
    }
}
```

The physical line count is similar, but the second form names the layout intent directly and removes the separate runtime node-kind, style constructor, explicit close, and string-key wrapper. For the root start-screen scope, the migration passes `height=-1` to preserve its old fill-height behavior; the convenience row/column default is fit-content height. Layout sizing defaults therefore remain visible where they affect behavior.

## Retained-work and output comparison

The checked-in `ui_dogfood_test.odin` exercises real builders for Settings → Appearance, Settings → Editor, document status, and the start screen with the recent-workspaces modal. It performs two warmups, 32 root-invalidated rebuilds, and eight idle attempts per scene. It verifies node and semantic identity stability within each version, balanced scopes, deterministic snapshots, and no idle descriptions, presentation work, retained visits, or tracked allocations.

The before and after snapshots were captured from separate Scratchpad trees, using the same Alicorn commit and fixture. [compare_ui_dogfood.py](../../../tools/compare_ui_dogfood.py) compares all 314 records and checks retained node paths, parentage, child counts, paint, semantics, bounds, and order. The only differences are the default layout-direction field on 26 leaf Text/Button nodes: old callers supplied `.Row`; `ui.text` and `ui.button` retain Alicorn's ordinary `.Column` default. These leaves have no retained layout children, and their resolved bounds and complete paint/semantic snapshots match. This makes the difference inert for these real controls; the helper also retains typed style options when a caller needs an exact style.

| Scene | Retained nodes | Display paints | Warm rebuilds | Persistent alloc/free calls (each version) | Layout visits (each version) |
| --- | ---: | ---: | ---: | ---: | ---: |
| Settings · Appearance | 21 | 22 | 32 | 832 / 832 | 0 |
| Settings · Editor | 35 | 38 | 32 | 1,280 / 1,280 | 0 |
| Document status | 14 | 7 | 32 | 640 / 640 | 0 |
| Start screen + recent-workspaces modal | 26 | 24 | 32 | 992 / 992 | 0 |

Each scene had the same 14-byte persistent-live delta in both versions. The helpers added no warm allocations, retained nodes, display paints, or layout visits in these scenes. The local description-time p95 varied between runs and is not used as a general performance claim. The harness has no GPU host; it compares retained output and acknowledges a successful submission at the same boundary used by the native host.

## Validation and limitations

The following completed successfully on macOS:

- Alicorn foundation check on the new compatibility branch: 246 runtime tests, 12 UI tests, 35 theme tests, and example/type checks passed.
- Before and after focused snapshot harness: one test passed on each side; the comparison matched all 96 retained nodes and all 314 records after the documented leaf-direction normalization.
- `CALIBER_CLI=… ALICORN_ODIN=… sh tools/alicorn.sh test`: Go package checks, 13 bridge tests, and all 194 frontend tests passed.
- `git diff --check` and Python syntax checks for both measurement tools passed.

`sh tools/alicorn.sh smoke` built the native artifact, but launch validation could not complete in this execution environment: SDL reported `The video driver did not add any displays`. This is an environment limitation, not a passing native-window smoke result. Physical Mac interaction and Windows validation remain outstanding.

The data supports the claim that the simple UI API makes common composition more explicit and less mechanically repetitive without adding retained work. It does not show a large raw line-count reduction, and the performance comparison covers four representative scenes rather than every Scratchpad interaction.
