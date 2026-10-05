package main

import alicorn "alicorn:runtime"

scratchpad_styles_ensure :: proc(app: ^App, rt: ^alicorn.Runtime) -> bool {
	if app == nil || rt == nil { return false }
	if app.style_theme_runtime != rt {
		app.workbench_theme = 0
		app.editor_theme = 0
		app.style_theme_runtime = rt
	}
	if app.workbench_theme == 0 {
		theme := scratchpad_workbench_theme()
		app.workbench_theme = alicorn.style_theme_register(rt, theme)
		scratchpad_generated_theme_destroy(&theme)
	}
	if app.editor_theme == 0 {
		theme := scratchpad_editor_theme()
		app.editor_theme = alicorn.style_theme_register(rt, theme)
		scratchpad_generated_theme_destroy(&theme)
	}
	return app.workbench_theme != 0 && app.editor_theme != 0
}

scratchpad_editor_paper_surface :: proc(rt: ^alicorn.Runtime, theme: alicorn.Style_Theme_ID) -> alicorn.Color {
	if color, found := alicorn.style_extension_color(rt, theme, SCRATCHPAD_EDITOR_PAPER_SURFACE_ROLE); found {
		return color
	}
	return alicorn.style_theme_color(rt, theme, .Editor_Background)
}
