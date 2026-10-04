package main

import alicorn "alicorn:runtime"

scratchpad_workbench_theme :: proc() -> alicorn.Style_Theme {
	theme := alicorn.DEFAULT_STYLE_THEME
	theme.colors[int(alicorn.Style_Color_Role.Window_Background)] = alicorn.Color{0.16, 0.16, 0.14, 1}
	theme.colors[int(alicorn.Style_Color_Role.Surface)] = alicorn.Color{0.22, 0.22, 0.19, 1}
	theme.colors[int(alicorn.Style_Color_Role.Subtle_Surface)] = alicorn.Color{0.28, 0.28, 0.24, 1}
	theme.colors[int(alicorn.Style_Color_Role.Editor_Background)] = alicorn.Color{0.92, 0.89, 0.82, 1}
	theme.colors[int(alicorn.Style_Color_Role.Text)] = alicorn.Color{0.87, 0.85, 0.78, 1}
	theme.colors[int(alicorn.Style_Color_Role.Muted_Text)] = alicorn.Color{0.67, 0.65, 0.58, 1}
	theme.colors[int(alicorn.Style_Color_Role.Accent)] = alicorn.Color{0.56, 0.34, 0.18, 1}
	theme.colors[int(alicorn.Style_Color_Role.Accent_Hover)] = alicorn.Color{0.65, 0.41, 0.22, 1}
	theme.colors[int(alicorn.Style_Color_Role.Accent_Pressed)] = alicorn.Color{0.47, 0.27, 0.15, 1}
	theme.colors[int(alicorn.Style_Color_Role.Accent_Text)] = alicorn.Color{0.98, 0.95, 0.87, 1}
	theme.colors[int(alicorn.Style_Color_Role.Selection)] = alicorn.Color{0.72, 0.52, 0.27, 0.38}
	theme.colors[int(alicorn.Style_Color_Role.Focus)] = alicorn.Color{0.83, 0.63, 0.35, 1}
	theme.colors[int(alicorn.Style_Color_Role.Semantic_Focus)] = alicorn.Color{0.47, 0.62, 0.47, 1}
	theme.colors[int(alicorn.Style_Color_Role.Border)] = alicorn.Color{0.39, 0.38, 0.33, 1}
	theme.colors[int(alicorn.Style_Color_Role.Danger)] = alicorn.Color{0.55, 0.24, 0.20, 1}
	theme.colors[int(alicorn.Style_Color_Role.Success)] = alicorn.Color{0.34, 0.48, 0.34, 1}
	theme.colors[int(alicorn.Style_Color_Role.Scrollbar_Track)] = alicorn.Color{0.19, 0.19, 0.17, 1}
	theme.colors[int(alicorn.Style_Color_Role.Scrollbar_Thumb)] = alicorn.Color{0.48, 0.46, 0.39, 1}
	return theme
}

scratchpad_editor_theme :: proc() -> alicorn.Style_Theme {
	theme := scratchpad_workbench_theme()
	theme.colors[int(alicorn.Style_Color_Role.Window_Background)] = alicorn.Color{0.92, 0.89, 0.82, 1}
	theme.colors[int(alicorn.Style_Color_Role.Surface)] = alicorn.Color{0.95, 0.93, 0.87, 1}
	theme.colors[int(alicorn.Style_Color_Role.Subtle_Surface)] = alicorn.Color{0.87, 0.84, 0.76, 1}
	theme.colors[int(alicorn.Style_Color_Role.Editor_Background)] = alicorn.Color{0.94, 0.92, 0.86, 1}
	theme.colors[int(alicorn.Style_Color_Role.Text)] = alicorn.Color{0.17, 0.17, 0.15, 1}
	theme.colors[int(alicorn.Style_Color_Role.Muted_Text)] = alicorn.Color{0.43, 0.42, 0.37, 1}
	theme.colors[int(alicorn.Style_Color_Role.Accent)] = alicorn.Color{0.51, 0.29, 0.14, 1}
	theme.colors[int(alicorn.Style_Color_Role.Accent_Hover)] = alicorn.Color{0.62, 0.36, 0.18, 1}
	theme.colors[int(alicorn.Style_Color_Role.Accent_Pressed)] = alicorn.Color{0.41, 0.23, 0.13, 1}
	theme.colors[int(alicorn.Style_Color_Role.Accent_Text)] = alicorn.Color{0.98, 0.95, 0.88, 1}
	theme.colors[int(alicorn.Style_Color_Role.Selection)] = alicorn.Color{0.76, 0.57, 0.30, 0.42}
	theme.colors[int(alicorn.Style_Color_Role.Focus)] = alicorn.Color{0.65, 0.40, 0.20, 1}
	theme.colors[int(alicorn.Style_Color_Role.Semantic_Focus)] = alicorn.Color{0.28, 0.48, 0.34, 1}
	theme.colors[int(alicorn.Style_Color_Role.Border)] = alicorn.Color{0.70, 0.67, 0.59, 1}
	theme.colors[int(alicorn.Style_Color_Role.Danger)] = alicorn.Color{0.56, 0.22, 0.18, 1}
	theme.colors[int(alicorn.Style_Color_Role.Success)] = alicorn.Color{0.29, 0.46, 0.32, 1}
	theme.colors[int(alicorn.Style_Color_Role.Scrollbar_Track)] = alicorn.Color{0.86, 0.83, 0.76, 1}
	theme.colors[int(alicorn.Style_Color_Role.Scrollbar_Thumb)] = alicorn.Color{0.58, 0.55, 0.48, 1}
	return theme
}

scratchpad_styles_ensure :: proc(app: ^App, rt: ^alicorn.Runtime) -> bool {
	if app == nil || rt == nil { return false }
	if app.style_theme_runtime != rt {
		app.workbench_theme = 0
		app.editor_theme = 0
		app.style_theme_runtime = rt
	}
	if app.workbench_theme == 0 {
		app.workbench_theme = alicorn.style_theme_register(rt, scratchpad_workbench_theme())
	}
	if app.editor_theme == 0 {
		app.editor_theme = alicorn.style_theme_register(rt, scratchpad_editor_theme())
	}
	return app.workbench_theme != 0 && app.editor_theme != 0
}
