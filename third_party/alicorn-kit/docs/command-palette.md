# Command Palette

`alikit:command_palette` provides a themed modal palette, while
`alikit:palette_model` contains the filtering and selection rules without a UI
dependency.

## Application-owned items

Each item has a nonzero, unique `Item_ID` that remains stable for the palette
session. The ID is a scalar, so activation does not return a borrowed string or
an index into a temporary filtered list. `title`, `description`, and
`keywords` are borrowed only during `build` or `handle_key`; the application
can rebuild its item slice between turns.

The default `Search_Mode.Substring` filters in caller order and does not impose
application-specific recency, category, or scoring policy. Every
whitespace-separated query token must occur as a contiguous substring in a
title, description, or keyword. ASCII letters compare without case; non-ASCII
UTF-8 bytes compare exactly. Locale-aware matching and Unicode case folding are
outside this first version's built-in matcher.

To preserve an application's existing fuzzy search or ranking, open the palette
with `Search_Mode.Caller_Filtered`. In that mode AliKit treats the supplied item
slice as the already-filtered result set and preserves its order. Use
`command_palette.query_text(&palette)` to obtain the current query when building
that set. Supply a fresh result slice to both `build` and `handle_key`; item IDs
must remain stable and unique across those calls.

```odin
_ = command_palette.open_palette(
    &app.palette,
    rt,
    command_palette.Search_Mode.Caller_Filtered,
)
```

Disabled items remain visible but cannot be selected or activated. Selection
is retained by item ID while that item remains visible and enabled. If it
vanishes, becomes disabled, or stops matching, selection moves to the first
enabled result.

## Owning the component state

Zero-initialize one `State` for each palette instance and initialize it with the
allocator that should own its query and cached match buffer:

```odin
palette: command_palette.State
if !command_palette.init(&palette) {
    // Handle allocation failure.
}
defer command_palette.destroy(&palette)
```

Call `open_palette` from the application command that opens the palette. It
clears the query before changing open/focus state, captures the current focused
node, and requests a redraw. If clearing fails, the palette remains closed and
`state.last_status` reports `Query_Reset_Failed`.

When result-buffer growth fails, the old buffer remains owned and valid, the
current result count is cleared, and `state.last_status` reports
`Match_Buffer_Allocation_Failed`. The modal displays the configurable
`Options.allocation_error_message` and retries on a later description. Query
update failures are also available through `last_status`.

## Native host integration

The palette uses Alicorn's public `Application` callbacks because the simple
`ui.run` helper does not expose application-level key and text callbacks. The
application keeps its existing callback policy and calls the component helpers
from those callbacks:

```odin
on_key :: proc(data: rawptr, rt: ^alicorn.Runtime, key: host.Application_Key) -> bool {
    app := cast(^App)data
    if !app.palette.open && key == .Open_Command_Palette {
        _ = command_palette.open_palette(&app.palette, rt)
        return true
    }
    handled, event := command_palette.handle_key(&app.palette, rt, app.palette_items[:], key)
    if event.kind == .Activated { app.dispatch(event.item_id) }
    return handled
}

on_text_change :: proc(data: rawptr, rt: ^alicorn.Runtime, change: alicorn.Text_Change) {
    app := cast(^App)data
    _ = command_palette.text_change(&app.palette, rt, change)
}
```

Pass a fresh item slice to `handle_key`. In substring mode, AliKit filters it
against its current query. In caller-filtered mode, the application must filter
and rank it against `command_palette.query_text(&app.palette)` before passing
it. This ensures activation is checked against current application data rather
than a stale item snapshot. The text-change callback's `change.text` is borrowed
for the callback only; AliKit copies it into its owned controlled-text buffer.

Describe the ordinary root first. Then call `command_palette.build` while the
frame is open, and call `command_palette.after_frame` after `alicorn.end_frame`.
The returned activation event contains a stable ID. Keep dispatch in the
application so it can apply its own mutation and error policy. For pointer
outside-dismissal, forward application pointer events to
`command_palette.pointer`. The example shows the complete wiring.

The palette declines Up, Down, and Return while Alicorn's public query-field
snapshot reports active composition, allowing the native text host to handle
those keys. Alicorn routes Escape through its native composition handling
before application dismissal. Validate native IME candidate navigation and
commit behavior in the actual host; the headless/runtime snapshot cannot model
the operating system's candidate window. When composition is inactive, the
palette consumes Up, Down, Return, Escape, and its toggle key while open;
unrelated keys continue through the host application's policy.
The modal overlay retains Alicorn's normal focus scope, semantics, hit testing,
and accessibility behavior.

## Presentation options

The default appearance uses Alicorn's ordinary Surface theme role and a neutral
modal backdrop. Applications can provide `Options.appearance` to keep a palette
visually integrated with their own surface treatment. It accepts Alicorn's
surface shape, material, physical height, panel fill, backdrop color, and
backdrop effect, along with overlay/panel spacing. These are borrowed values
for the current build; the component does not register or retain theme
resources.

`Options.hide_title`, `query_prefix`, `query_height`, and `query_text_style`
allow an application to match an existing palette header without replacing the
component's focusable controlled query field. The default options remain
appropriate for consumers that want a conventional titled palette.

## UI-independent model

The model package can be used independently to filter and navigate a command
list. Allocate an output buffer with capacity for the complete item slice,
call `palette_model.filter` for built-in matching or `palette_model.index_all`
for caller-filtered results, then pass the initialized prefix to `reconcile`,
`move`, or `activate`. The model borrows item strings and stores only indexes
and stable IDs.

## Compatibility and dependencies

The package is source-level Odin and imports Alicorn's `runtime`, `ui`, and
`native/sdl_gpu` collections. The palette does not access Alicorn private
runtime storage. The host adapter is intentionally native because it uses
Alicorn's cross-platform `Application_Key` vocabulary and native application
callbacks. Other AliKit packages can remain independent of the native host.
