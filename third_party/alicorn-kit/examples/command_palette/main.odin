package main

import "core:fmt"
import alicorn "alicorn:runtime"
import host "alicorn:native/sdl_gpu"
import ui "alicorn:ui"
import palette "alikit:command_palette"
import model "alikit:palette_model"

SAMPLE_ITEMS :: [4]model.Item{
	{ id=model.Item_ID(1), title="Open File", description="Browse the workspace", keywords="file browse" },
	{ id=model.Item_ID(2), title="Search in Files", description="Find text across the workspace", keywords="find grep" },
	{ id=model.Item_ID(3), title="Build Project", description="Run the configured build", keywords="compile" },
	{ id=model.Item_ID(4), title="Publish Release", description="Unavailable in this example", keywords="ship", disabled=true },
}

App :: struct {
	palette:    palette.State,
	items:      [4]model.Item,
	last_action: model.Item_ID,
}

build :: proc(data: rawptr, rt: ^alicorn.Runtime, _width, _height: int, _scale: f32) -> alicorn.Node_ID {
	app := cast(^App)data
	ctx, should_build := alicorn.begin_frame(rt)
	if !should_build { return 0 }
	root := alicorn.container_begin(&ctx, .Root,
		key=alicorn.key_string("alikit-example-root"),
		style=ui.layout_style(.Column, grow=1, padding=24, gap=12))
	if root == 0 {
		alicorn.end_frame(&ctx)
		return 0
	}
	_ = ui.text(&ctx, "AliKit · Command Palette", size=24)
	_ = ui.text(&ctx, "Press the host command-palette shortcut to open it.")
	if app.last_action != 0 {
		_ = ui.text(&ctx, fmt.tprintf("Last activated item ID: %d", model.item_id_value(app.last_action)))
	}
	alicorn.container_end(&ctx)

	if app.palette.open {
		event := palette.build(&ctx, &app.palette, app.items[:],
			alicorn.key_string("alikit-example-palette"),
			palette.Options{title="Example Actions"})
		if event.kind == .Activated { app.last_action = event.item_id }
	}
	alicorn.end_frame(&ctx)
	palette.after_frame(&app.palette, rt)
	return root
}

on_key :: proc(data: rawptr, rt: ^alicorn.Runtime, key: host.Application_Key) -> bool {
	app := cast(^App)data
	if !app.palette.open && key == .Open_Command_Palette {
		_ = palette.open_palette(&app.palette, rt)
		return true
	}
	handled, event := palette.handle_key(&app.palette, rt, app.items[:], key)
	if event.kind == .Activated { app.last_action = event.item_id }
	return handled
}

on_text_change :: proc(data: rawptr, rt: ^alicorn.Runtime, change: alicorn.Text_Change) {
	app := cast(^App)data
	_ = palette.text_change(&app.palette, rt, change)
}

on_pointer :: proc(data: rawptr, rt: ^alicorn.Runtime, event: alicorn.Pointer_Event, target: alicorn.Node_ID) {
	app := cast(^App)data
	_ = palette.pointer(&app.palette, rt, event, target)
}

main :: proc() {
	app := App{items=SAMPLE_ITEMS}
	if !palette.init(&app.palette) {
		fmt.eprintln("Could not initialize the command palette state.")
		return
	}
	defer palette.destroy(&app.palette)
	host.Run(host.Application{
		state=rawptr(&app),
		title="AliKit Command Palette",
		width=760,
		height=520,
		build=build,
		on_key=on_key,
		on_text_change=on_text_change,
		on_pointer=on_pointer,
	})
}
