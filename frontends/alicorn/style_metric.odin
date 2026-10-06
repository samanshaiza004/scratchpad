package main

import alicorn "alicorn:runtime"

scratchpad_editor_padding_role :: proc() -> alicorn.Style_Extension_Length_Role_ID {
	return alicorn.style_extension_length_role_id("app.scratchpad.editor", "padding")
}

// Resolve the authored editor metric in the paper theme, then apply the
// density inherited from the active Alicorn style environment.
scratchpad_editor_surface_padding :: proc(
	ui: ^alicorn.UI,
	rt: ^alicorn.Runtime,
	theme: alicorn.Style_Theme_ID,
) -> f32 {
	padding := f32(10)
	if authored, found := alicorn.style_extension_length(rt, theme, scratchpad_editor_padding_role()); found {
		padding = authored.logical_units
	}
	return alicorn.style_metric(ui, padding)
}
