# Tree View

`alikit:tree_view` renders and navigates an application-provided projection of
visible rows. `alikit:tree_model` contains the UI-independent focus, selection,
identity, and keyboard rules. AliKit does not own a filesystem, hierarchy,
loading policy, or item commands.

## Visible rows and identity

The application supplies a preorder slice containing only rows whose ancestors
are expanded. Each row has a nonzero stable `Item_ID`, its `parent_id`, depth,
label, and expansion/disabled state. IDs must be unique in each supplied window
and remain stable while the logical item exists. Keep selection, focus, and any
separate active-document identity distinct.

`Window` can describe all rows (`offset=0`) or a contiguous loaded slice of a
larger logical list. `total_count` is the logical row count; `offset` identifies
the first supplied row; `revision` changes when the projection's membership,
order, or hierarchy changes. A paged consumer should retain its own revision
checks and load policy. When a visible row or keyboard destination is not in
the supplied slice, AliKit returns `Range_Requested` with an absolute logical
index. Load a bounded window around that index, then pass the new window on the
next description. No placeholder is treated as an item or receives an ID.

The component owns fixed-row virtualization, indentation, keyboard traversal,
Tree/Tree_Item semantics, retained focus, visible-row reveal, and optional
single selection. An `icon_proc` may return an Alicorn icon for a row, a
`label_color_proc` receives the current UI context and may provide an
application-specific label color; `row_hook_proc` may attach Alicorn drag/drop behavior to the row, and
`label_paint_proc` receives the realized label node for decorations such as an
active-file underline. Callbacks run synchronously during `build`; they must not
retain the borrowed item, node, or UI context. Set `hide_disclosure` when the application uses its own folder icons
to communicate expanded state. Set `semantic_namespace` to preserve an
application's existing stable semantic identities during migration; otherwise
AliKit derives a namespace from the retained tree root.

## Application-owned behavior

`build` returns row press, activation, and missing-range events. `handle_key`
returns expansion/collapse requests, activation, focus, and range events. The
application updates its visible projection in response to expansion requests,
handles activation, and applies its own selection policy. Right expands a
collapsed item or focuses its first enabled visible child; Left collapses an
expanded item or focuses its visible parent. Up/Down, Home/End, and Page Up/Down
navigate the visible projection while skipping disabled rows.

Pass an Alicorn `Scroll_Restore_Request` in `Options.scroll_restore` when the
application needs to restore a persisted viewport position.

Set `Options.selection_enabled` to select on pointer press. Set
`select_on_focus` when keyboard navigation should also change selection. Focus
is always tracked separately from selection. When a focused item disappears,
reconcile the model against the new revision and preserve the nearest valid
position where the complete projection is available.

## Context menus

Set `context_menu_enabled` and forward secondary pointer input plus Alicorn's
hit-tested target to `tree_view.pointer`. For keyboard invocation, route the
`.Context_Menu` key through `handle_key`. AliKit anchors Alicorn's menu to the
realized row and records its stable target ID; the application supplies menu
content and dispatch. Revalidate that ID and its current availability when the
user invokes a destructive action because the row may have changed while the
menu was open.

## Minimal integration

```odin
window := tree_view.Window{
    total_count=len(app.visible_rows),
    revision=app.tree_revision,
    items=app.visible_rows,
}
event := tree_view.build(&ctx, &app.tree, window, key,
    tree_view.Options{
        accessible_label="Project files",
        selection_enabled=true,
    },
)

if event.kind == .Expand_Requested {
    app.set_expanded(event.id, true)
}
```

Keep the `tree_view.State` with the consuming view instance. Route host key
input to `tree_view.handle_key` only while this tree's logical list owns focus.
Apply the returned event in the application; rebuilding the description with
the updated projection completes expansion and collapse.

The compiling native example in [`examples/tree_view`](../examples/tree_view/main.odin)
shows app-owned hierarchy, expansion state, icon selection, callbacks, and the
full-list case. Headless tests cover model navigation, disabled rows, stable
identity, semantic rows, context-menu targeting, and paged windows. Native OS
accessibility behavior should still be checked on each supported desktop host.
