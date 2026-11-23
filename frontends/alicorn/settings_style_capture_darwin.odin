package main

import "core:fmt"
import alicorn "alicorn:runtime"
import host "alicorn:native/sdl_gpu"
import "vendor:sdl3"

// Use the native main thread so SDL can initialize Cocoa. The targets are
// offscreen and have equal logical viewports at each requested pixel density.
settings_style_capture_matrix :: proc(directory: string) -> bool {
	if !sdl3.Init(sdl3.INIT_VIDEO) {
		fmt.eprintln("Settings capture SDL initialization failed", sdl3.GetError())
		return false
	}
	defer sdl3.Quit()
	device := sdl3.CreateGPUDevice({.MSL}, false, "metal")
	if device == nil {
		fmt.eprintln("Settings capture Metal device creation failed", sdl3.GetError())
		return false
	}
	defer sdl3.DestroyGPUDevice(device)
	for treatment in Scratchpad_Surface_Treatment {
		for scale in SETTINGS_STYLE_STUDY_SCALES {
			if !settings_style_capture(device, directory, treatment, scale) {
				fmt.eprintln("Settings capture failed", treatment, scale, sdl3.GetError())
				return false
			}
		}
	}
	return true
}

settings_style_capture :: proc(
	device: ^sdl3.GPUDevice, directory: string, treatment: Scratchpad_Surface_Treatment, scale: f32,
) -> bool {
	rt := alicorn.new_runtime({0, 0, 1000, 720})
	defer alicorn.destroy_runtime(&rt)
	_ = alicorn.set_presentation_scale(&rt, scale, scale)
	if !alicorn.text_engine_load_default_fonts(&rt) { return false }
	app := App{settings_surface_open=true, theme_choice=.Warm, accessibility_appearance_override_enabled=true}
	if !scratchpad_styles_ensure(&app, &rt) ||
	   !scratchpad_surface_treatment_select(&app, &rt, treatment, persist=false) { return false }

	settings_style_capture_build(&app, &rt)
	focus, found := alicorn.node_by_key(&rt, alicorn.key_string("settings-category-1"), .Button)
	if !found || !alicorn.focus(&rt, focus) { return false }
	alicorn.focus_indicator_set(&rt, true)
	settings_style_capture_build(&app, &rt)
	if ui, ready := alicorn.begin_presentation_frame(&rt); ready { alicorn.end_presentation_frame(&ui) }
	display, ok := alicorn.paint_display_list(&rt)
	if !ok { return false }

	format := sdl3.GPUTextureFormat.R8G8B8A8_UNORM
	text, text_ok := host.native_text_make(device, format, &rt)
	defer host.native_text_destroy(&text)
	if !text_ok { return false }
	surface, surface_ok := host.native_surface_make(device, format, &rt)
	defer host.native_surface_destroy(&surface)
	if !surface_ok { return false }
	solid, solid_ok := host.native_solid_make(device, format, &rt)
	defer host.native_solid_destroy(&solid)
	if !solid_ok { return false }
	path := fmt.tprintf("%s/%v-%.2f.ppm", directory, treatment, scale)
	ok = host.native_capture_display_ppm(device, &text, &surface, &solid, display.commands,
		u32(1000*scale), u32(720*scale), scale, scale, path)
	if ok { fmt.println("settings-style-capture", treatment, scale, path) }
	return ok
}

settings_style_capture_build :: proc(app: ^App, rt: ^alicorn.Runtime) {
	for _ in 0..<4 {
		ui, build := alicorn.begin_frame(rt)
		if !build { return }
		alicorn.container_begin(&ui, .Root, label="settings-capture", style=alicorn.layout_style(grow=1))
		alicorn.container_end(&ui)
		scope := alicorn.style_environment_push(&ui, alicorn.Style_Environment{theme=app.workbench_theme, text_scale=1})
		settings_surface_build(app, &ui, rt)
		alicorn.style_environment_pop(&ui, scope)
		alicorn.end_frame(&ui)
		settings_surface_intrinsic_after_frame(app, rt)
	}
}
