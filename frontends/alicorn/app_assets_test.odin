package main

import "core:os"
import "core:testing"
import alicorn "alicorn:runtime"

@(test)
test_scratchpad_assets_use_public_font_and_image_apis_in_empty_editor :: proc(t: ^testing.T) {
    rt := alicorn.new_runtime(alicorn.Rect{0, 0, 960, 640})
    defer alicorn.destroy_runtime(&rt)
    app: App
    app.theme_choice = .Warm
    app.backend.started = true
    app.backend.state.has_workspace = true
    app.backend.state.workspace_root = "C:/scratchpad-assets-fixture"
    app.tree_root_path = app.backend.state.workspace_root
    app.tree_directories = make([dynamic]Tree_Directory, 0, allocator=context.allocator)
    app.retired_brand_marks = make([dynamic]Scratchpad_Image_Retirement, 0, allocator=context.allocator)
    defer {
        delete(app.tree_directories)
        delete(app.retired_brand_marks)
    }
    init_menus(&app)

    scratchpad_application_initialize(rawptr(&app), &rt)
    testing.expect(t, rt.text_engine.application_primary_font[.UI] &&
        rt.text_engine.application_italic_font[.UI] &&
        rt.text_engine.application_primary_font[.Monospace] &&
        rt.text_engine.application_italic_font[.Monospace],
        "Scratchpad should install its bundled UI and editor faces through Alicorn's app font API")
    fallback_path := scratchpad_ui_fallback_path()
    if fallback_path != "" && os.exists(fallback_path) {
        testing.expect(t, app.ui_font_fallback_loaded && rt.text_engine.application_fallback_font[.UI],
            "Scratchpad should register an available platform fallback through the public font API")
    }
    testing.expect(t, app.brand_mark != 0, "app initialization should decode its theme-owned PNG mark")

    _ = build_app(rawptr(&app), &rt, 960, 640, 1)
    mark_node: alicorn.Node_ID
    for id in rt.order {
        node, found := rt.nodes[id]
        if found && node.kind == .Image && node.label == "Scratchpad mark" {
            mark_node = id
            break
        }
    }
    testing.expect(t, mark_node != 0, "the empty editor should dogfood the retained image widget")

    previous := app.brand_mark
    testing.expect(t, scratchpad_theme_select(&app, &rt, .Cool_Light),
        "the app should replace its theme-owned image when switching palettes")
    replacement := app.brand_mark
    _, old_image_still_live := alicorn.image_resolve(&rt, previous)
    testing.expect(t, replacement != 0 && replacement != previous && old_image_still_live,
        "replacement should get a fresh Runtime handle and keep the prior presentation's image alive")

    _ = build_app(rawptr(&app), &rt, 960, 640, 1)
    for id in rt.order {
        node, found := rt.nodes[id]
        if found && node.kind == .Image && node.label == "Scratchpad mark" {
            mark_node = id
            break
        }
    }
    testing.expect(t, mark_node != 0, "the replacement mark should remain in the rebuilt empty-editor presentation")
    _, old_image_still_live = alicorn.image_resolve(&rt, previous)
    testing.expect(t, old_image_still_live,
        "the prior image must stay live through the replacement description")

    // The next callback begins after that replacement presentation completed.
    scratchpad_application_assets_release_retired(&app, &rt)
    _, old_image_still_live = alicorn.image_resolve(&rt, previous)
    _, new_image_still_live := alicorn.image_resolve(&rt, replacement)
    testing.expect(t, !old_image_still_live && new_image_still_live,
        "release should retire the stale handle while retaining the visible replacement")
}
