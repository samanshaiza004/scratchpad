package main

import "core:fmt"

// smoke_session_validate runs in the real frontend stop callback, before the
// Go backend writes the next clean session. The expected values are seeded by
// the Go smoke harness in an isolated per-run profile.
smoke_session_validate :: proc(app: ^App) -> bool {
	if app == nil || !app.backend.started ||
	   (app.smoke_session_mode != "clean" && app.smoke_session_mode != "recovery") {
		fmt.eprintln("session smoke: invalid mode or backend state")
		return false
	}
	state := app.backend.state
	if !state.has_workspace || state.workspace_root != app.smoke_session_expected_workspace ||
	   state.active != app.smoke_session_expected_active || len(state.documents) != 2 ||
	   len(state.recent_workspaces) != 1 || state.recent_workspaces[0] != app.smoke_session_expected_workspace ||
	   state.sidebar_width != 328 || state.pinned_pane_width != 416 ||
	   state.session_ui.focus != "editor" {
		fmt.eprintln("session smoke: workspace, active document, tab count, split widths, or focus did not restore")
		return false
	}
	if state.documents[0].id != app.smoke_session_expected_first ||
	   state.documents[1].id != app.smoke_session_expected_second {
		fmt.eprintln("session smoke: document order did not restore")
		return false
	}
	for document in state.documents {
		expected_preview := document.id == app.smoke_session_expected_preview
		expected_dirty := app.smoke_session_mode == "recovery" && document.id == app.smoke_session_expected_active
		if document.preview != expected_preview || document.dirty != expected_dirty {
			fmt.eprintln("session smoke: preview or recovery dirty state did not restore for", document.path)
			return false
		}
	}
	if app.smoke_session_mode == "clean" {
		second := state.documents[0]
		first := state.documents[1]
		if first.anchor_byte != 1 || first.cursor_byte != 8 || first.affinity != 1 ||
		   !first.scroll_x_initialized || first.scroll_x != 12 ||
		   !first.scroll_y_initialized || first.scroll_y != 36 ||
		   second.anchor_byte != 6 || second.cursor_byte != 11 ||
		   !second.scroll_x_initialized || second.scroll_x != 8 ||
		   !second.scroll_y_initialized || second.scroll_y != 240 {
			fmt.eprintln("session smoke: per-document selection or scroll state did not restore")
			return false
		}
	}
	return true
}
