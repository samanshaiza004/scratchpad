package main

import alicorn "alicorn:runtime"

SCRATCHPAD_UI_FONT_DATA :: #load("../../.deps/alicorn/assets/fonts/AtkinsonHyperlegibleNext-Variable.ttf")
SCRATCHPAD_UI_ITALIC_FONT_DATA :: #load("../../.deps/alicorn/assets/fonts/AtkinsonHyperlegibleNext-Italic-Variable.ttf")
SCRATCHPAD_MONO_FONT_DATA := #load("../../.deps/alicorn/assets/fonts/AtkinsonHyperlegibleMono-Variable.ttf")
SCRATCHPAD_MONO_ITALIC_FONT_DATA := #load("../../.deps/alicorn/assets/fonts/AtkinsonHyperlegibleMono-Italic-Variable.ttf")
SCRATCHPAD_WARM_MARK_DATA :: #load("assets/scratchpad-mark-warm.png")
SCRATCHPAD_COOL_MARK_DATA :: #load("assets/scratchpad-mark-cool-light.png")

Scratchpad_Image_Retirement :: struct {
    handle: alicorn.Image_Handle,
    after_build: u64,
}

// Load Scratchpad's bundled faces through Alicorn's public app boundary. The
// native host owns optional system fallback discovery after this callback.
scratchpad_application_initialize :: proc(state: rawptr, rt: ^alicorn.Runtime) {
    if state == nil || rt == nil { return }
    app := cast(^App)state
    if app.primary_runtime == nil { app.primary_runtime = rt }
    _ = alicorn.font_load_bytes(rt, .UI, SCRATCHPAD_UI_FONT_DATA)
    _ = alicorn.font_load_italic_bytes(rt, .UI, SCRATCHPAD_UI_ITALIC_FONT_DATA)
    _ = alicorn.font_load_bytes(rt, .Monospace, SCRATCHPAD_MONO_FONT_DATA)
    _ = alicorn.font_load_italic_bytes(rt, .Monospace, SCRATCHPAD_MONO_ITALIC_FONT_DATA)
    _ = scratchpad_brand_mark_replace(app, rt, app.theme_choice)
}

scratchpad_brand_mark_replace :: proc(app: ^App, rt: ^alicorn.Runtime, choice: Scratchpad_Theme_Choice) -> bool {
    if app == nil || rt == nil || (choice < .Warm || choice > .Workbench_Relief) { return false }
    resolved_choice := choice
    if choice == .Flat || choice == .Workbench_Relief { resolved_choice = .Warm }
    if app.brand_mark != 0 && app.brand_mark_choice == resolved_choice { return true }
    data := SCRATCHPAD_WARM_MARK_DATA
    if resolved_choice == .Cool_Light { data = SCRATCHPAD_COOL_MARK_DATA }
    next, err := alicorn.image_load_bytes(rt, data)
    if err != .None { return false }
    if app.brand_mark != 0 {
        append(&app.retired_brand_marks, Scratchpad_Image_Retirement{
            handle=app.brand_mark,
            after_build=app.asset_build_generation+1,
        })
    }
    app.brand_mark = next
    app.brand_mark_choice = resolved_choice
    return true
}

// Called at the start of the next app-build callback. An old image survives
// the replacement description and is released only after that description has
// completed, so retained paint never observes a stale handle.
scratchpad_application_assets_release_retired :: proc(app: ^App, rt: ^alicorn.Runtime) {
    if app == nil || rt == nil { return }
    for index := len(app.retired_brand_marks)-1; index >= 0; index -= 1 {
        item := app.retired_brand_marks[index]
        if item.after_build > app.asset_build_generation { continue }
        _ = alicorn.image_release(rt, item.handle)
        ordered_remove(&app.retired_brand_marks, index)
    }
}

scratchpad_application_assets_build_completed :: proc(app: ^App) {
    if app != nil && app.asset_build_generation < max(u64) { app.asset_build_generation += 1 }
}
