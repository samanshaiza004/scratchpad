package main

import "core:testing"
import alicorn "alicorn:runtime"

@(test)
test_editor_content_focus_and_offscreen_status_cue :: proc(t: ^testing.T) {
	f: Semantic_Zoom_Test_Editor
	source:=semantic_zoom_test_source("md")
	if !semantic_zoom_test_open(&f,t,"md",source) { semantic_zoom_test_destroy(&f,t); return }
	defer semantic_zoom_test_destroy(&f,t)
	owner:=f.app.editor_scroll_owner
	alicorn.focus(&f.rt,owner)
	semantic_zoom_test_settle(&f)
	testing.expect(t,alicorn.focused_node(&f.rt)==owner && f.rt.nodes[owner].focusable &&
		f.rt.scroll_focus_visuals[owner]==.Content,"the editor should keep real focus while choosing its content focus visuals")
	testing.expect(t,len(f.rt.nodes[owner].paint)==0,"the editor should not paint a rectangular scroll-region focus outline")
	testing.expect(t,f.app.editor_input_anchor_node!=0 && !editor_focus_needs_status_cue(&f.app,&f.rt),
		"a visible caret and active line should provide focus indication without additional status copy")
	state:=alicorn.scroll_region_state(&f.rt,owner)
	testing.expect(t,state.max_scroll_y>300,"the fixture must have enough source to scroll the caret outside the viewport")
	alicorn.scroll_region_set_offset(&f.rt,owner,300,"test reading away from the focused caret")
	semantic_zoom_test_settle(&f)
	testing.expect(t,alicorn.focused_node(&f.rt)==owner && editor_focus_needs_status_cue(&f.app,&f.rt),
		"scrolling away from the caret must preserve editor focus and enable the quiet status fallback")
	testing.expect(t,len(f.rt.nodes[owner].paint)==0,"offscreen caret focus must not restore the perimeter outline")
}
