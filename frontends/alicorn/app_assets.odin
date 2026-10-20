package main

import "core:os"
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

// Load Scratchpad's bundled faces through Alicorn's public app boundary. A
// readable platform fallback is also registered here; if it is unavailable,
// the native host keeps its own fallback behavior.
scratchpad_application_initialize :: proc(state: rawptr, rt: ^alicorn.Runtime) {
    if state == nil || rt == nil { return }
    app := cast(^App)state
    if app.primary_runtime == nil { app.primary_runtime = rt }
    _ = alicorn.font_load_bytes(rt, .UI, SCRATCHPAD_UI_FONT_DATA)
    _ = alicorn.font_load_italic_bytes(rt, .UI, SCRATCHPAD_UI_ITALIC_FONT_DATA)
    _ = alicorn.font_load_bytes(rt, .Monospace, SCRATCHPAD_MONO_FONT_DATA)
    _ = alicorn.font_load_italic_bytes(rt, .Monospace, SCRATCHPAD_MONO_ITALIC_FONT_DATA)

    app.ui_font_fallback_loaded = false
    fallback_path := scratchpad_ui_fallback_path()
    if fallback_path != "" {
        if fallback_bytes, err := os.read_entire_file_from_path(fallback_path, context.temp_allocator); err == nil {
            app.ui_font_fallback_loaded = alicorn.font_load_fallback_bytes(rt, .UI, fallback_bytes)
            delete(fallback_bytes, context.temp_allocator)
        }
    }
    _ = scratchpad_brand_mark_replace(app, rt, app.theme_choice)
}

scratchpad_ui_fallback_path :: proc() -> string {
    when ODIN_OS == .Windows {
        japanese_font := "C:/Windows/Fonts/NotoSansJP-VF.ttf"
        if os.exists(japanese_font) { return japanese_font }
        return "C:/Windows/Fonts/segoeui.ttf"
    } else when ODIN_OS == .Darwin {
        return "/System/Library/Fonts/SFNS.ttf"
    } else {
        return "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"
    }
}

scratchpad_brand_mark_replace :: proc(app: ^App, rt: ^alicorn.Runtime, choice: Scratchpad_Theme_Choice) -> bool {
    if app == nil || rt == nil || (choice != .Warm && choice != .Cool_Light) { return false }
    if app.brand_mark != 0 && app.brand_mark_choice == choice { return true }
    data := SCRATCHPAD_WARM_MARK_DATA
    if choice == .Cool_Light { data = SCRATCHPAD_COOL_MARK_DATA }
    next, err := alicorn.image_load_bytes(rt, data)
    if err != .None { return false }
    if app.brand_mark != 0 {
        append(&app.retired_brand_marks, Scratchpad_Image_Retirement{
            handle=app.brand_mark,
            after_build=app.asset_build_generation+1,
        })
    }
    app.brand_mark = next
    app.brand_mark_choice = choice
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
