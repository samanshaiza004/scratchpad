package main

import "core:fmt"
import alicorn "alicorn:runtime"
import gui "alicorn:ui"

Settings_Navigation_Mark :: enum { Bar, Underline, Dot }
SETTINGS_STYLE_STUDY_SCALES :: [4]f32{1, 1.25, 1.5, 2}

// These values describe only the already existing Settings Button owners
// and their visual parts. The category remains owned by Settings.
Settings_Navigation_Style :: struct {
	height, padding, radius: f32,
	font:                    alicorn.Font_Role,
	text:                    alicorn.Text_Style,
	selected_fill, mark_ink: alicorn.Color,
	material:                alicorn.Material_ID,
	optical_height:          f32,
	mark:                    Settings_Navigation_Mark,
}

settings_navigation_style :: proc(
	app: ^App, ui: ^alicorn.UI, control_height: f32,
) -> (style: Settings_Navigation_Style) {
	style = {
		height=control_height, padding=16, radius=4,
		text={font_size=15, font_weight=alicorn.FONT_WEIGHT_MEDIUM, overflow=.Ellipsis},
		selected_fill=alicorn.style_color(ui, .Selection),
		mark_ink=alicorn.style_color(ui, .Text),
	}
	switch app.surface_treatment {
	case .Standard:
		style.mark = .Bar
	case .Flat:
		style.mark = .Underline
		style.radius = 0
	case .Workbench_Relief:
		style.mark = .Dot
		style.radius = 8
		style.material = scratchpad_surface_material(app, app.raised_surface_material)
		style.optical_height = scratchpad_surface_height(app, 0.5)
	}
	return
}

settings_navigation_button :: proc(
	ui: ^alicorn.UI, category: Settings_Category, name: string, selected: bool, width: f32,
	style: Settings_Navigation_Style,
) -> bool {
	height := max(44, style.height)
	owner, activated := alicorn.button_begin(ui, name,
		key=alicorn.key_string(fmt.tprintf("settings-category-%d", category)),
		style=alicorn.layout_style(.Row, width=width, height=height),
		state={selected=selected}, variant=.Quiet, presentation=.Custom)
	if owner == 0 { return false }
	defer alicorn.button_end(ui)

	fill := alicorn.style_color(ui, .Subtle_Surface)
	if selected { fill = style.selected_fill }
	face := alicorn.surface_begin(ui, alicorn.surface_core_color_role(.Subtle_Surface),
		key=gui.key_u64(1), label="settings-category-face",
		style=alicorn.layout_style(.Row, width=width, height=height),
		shape={kind=.Rounded_Rectangle, corner_radius=style.radius},
		fill=fill, material=style.material if selected else alicorn.MATERIAL_FLAT,
		physical_height=style.optical_height if selected else 0)
	if face != 0 {
		_ = alicorn.visual_part_attach(ui, face, owner, alicorn.visual_part_core(.Surface))
		alicorn.surface_end(ui)
	}
	// Draw outlines below the label and mark. Keep the face RGB so Reduce
	// Transparency gives the outline a matching background if it makes it opaque.
	outline_fill := fill
	outline_fill.a = 0
	settings_navigation_outline(ui, owner, width, height, style.radius, 4, .Focus_Indicator,
		.Owner_Focus_Visible, outline_fill, alicorn.style_color(ui, .Focus), 2)
	settings_navigation_outline(ui, owner, width, height, style.radius, 5, .Overlay,
		.Owner_Hovered, outline_fill, alicorn.style_color(ui, .Border), 1)

	label := gui.positioned_text(ui, name, style.padding, height/2,
		key=gui.key_u64(2), width=max(1, width-2*style.padding), vertical=.Middle,
		font=style.font, text_style=style.text, color=alicorn.style_color(ui, .Text), clip=true)
	if label != 0 {
		_ = alicorn.visual_part_attach(ui, label, owner,
			alicorn.visual_part_extension_id("scratchpad.settings.navigation", "label"))
	}
	if selected {
		x, y, w, h, radius := f32(6), (height-16)/2, f32(3), f32(16), f32(1)
		switch style.mark {
		case .Bar:
		case .Underline: x, y, w, h, radius = style.padding, height-8, 32, 2, 0
		case .Dot:       x, y, w, h, radius = 6, (height-6)/2, 6, 6, 3
		}
		// A different mark can have a different extent at the same position.
		// On the pinned runtime, recreate that decorative node so its retained
		// positioned paint cannot keep the old extent.
		mark := gui.box(ui, key=gui.key_pair(3, u64(style.mark)), width=w, height=h, radius=radius, fill=style.mark_ink)
		if mark != 0 {
			_ = alicorn.position_child(ui, mark, alicorn.positioned(x, y))
			_ = alicorn.visual_part_attach(ui, mark, owner,
				alicorn.visual_part_extension_id("scratchpad.settings.navigation", "selection-mark"))
		}
	}
	return activated
}

settings_navigation_outline :: proc(
	ui: ^alicorn.UI, owner: alicorn.Node_ID, width, height, radius: f32, key: u64,
	role: alicorn.Visual_Part_Core_ID, visibility: alicorn.Visual_Part_Visibility,
	fill, stroke_color: alicorn.Color, stroke_width: f32,
) {
	// These keys track decorative extents. The named part and its Button
	// owner stay stable when a resize requires a new positioned outline.
	extent := u64(transmute(u32)width)<<32 | u64(transmute(u32)height)
	outline := alicorn.surface_begin(ui, alicorn.surface_core_color_role(.Surface),
		key=gui.key_pair(key, extent), label="settings-category-outline",
		style=alicorn.layout_style(.Row, width=width, height=height),
		shape={kind=.Rounded_Rectangle, corner_radius=radius},
		fill=fill, stroke={color=stroke_color, width=stroke_width},
		stroke_placement=.Inside)
	if outline == 0 { return }
	alicorn.surface_end(ui)
	_ = alicorn.position_child(ui, outline, alicorn.positioned(0, 0))
	_ = alicorn.visual_part_attach(ui, outline, owner, alicorn.visual_part_core(role), visibility)
}
