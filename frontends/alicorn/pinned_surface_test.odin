package main

import "core:fmt"
import "core:strings"
import "core:testing"
import alicorn "alicorn:runtime"
import bridge "./bridge"

@(test)
test_pinned_status_presentation_names_each_source_state :: proc(t: ^testing.T) {
	current := pinned_status_presentation("current")
	stale := pinned_status_presentation("stale")
	missing := pinned_status_presentation("missing")
	testing.expect(t,current.label=="Current" && current.icon==.Check && current.color==.Success,
		"a current pin should have a positive, readable status")
	testing.expect(t,stale.label=="Changed" && stale.icon==.Warning && stale.color==.Accent_Hover &&
		strings.contains(stale.explanation,"frozen") && strings.contains(stale.explanation,"pin it again"),
		"a stale pin should explain why its excerpt stopped tracking source and how to replace it")
	testing.expect(t,missing.label=="Closed" && missing.icon==.Info && missing.color==.Muted_Text &&
		strings.contains(missing.explanation,"document is closed"),
		"a missing pin should explain that the source document is closed")
}

@(test)
test_pinned_source_focus_respects_detached_owner :: proc(t: ^testing.T) {
	app: App
	app.pinned.visible=true
	window:=Floating_Window_State{owner=&app,document_id="detached-document"}
	app.floating_window=&window
	pinned_source_focus_request(&app,nil,"detached-document")
	testing.expect(t,window.editor_focus_pending && !app.editor_focus_pending && !app.pinned.narrow_source,
		"navigating to a pinned detached source should request focus in its existing window")
	app.floating_window=nil
	app.editor_focus_pending=false
	pinned_source_focus_request(&app,nil,"ordinary-document")
	testing.expect(t,app.editor_focus_pending && app.pinned.narrow_source,
		"ordinary pinned source navigation should return to the main editor")
}

pinned_surface_test_frame :: proc(f: ^Semantic_Zoom_Test_Editor, dpi_scale: f32 = 1) {
	if !scratchpad_styles_ensure(&f.app,&f.rt) {return}
	ui, build := alicorn.begin_frame(&f.rt)
	if !build { return }
	_ = alicorn.container_begin(&ui,.Root,label="pinned-surface-test-root",style=alicorn.layout_style(.Column,grow=1,clip=true))
	workbench_scope:=alicorn.style_environment_push(&ui,scratchpad_workbench_style_environment(&f.app))
	pinned_surface_build(&f.app,&ui,&f.rt,dpi_scale)
	alicorn.style_environment_pop(&ui,workbench_scope)
	alicorn.container_end(&ui)
	pinned_context_menu_build(&f.app,&ui,&f.rt)
	alicorn.end_frame(&ui)
	pinned_after_frame(&f.app,&f.rt)
}

pinned_surface_test_control :: proc(app: ^App, pin: bridge.Pin_ID, key: string) -> alicorn.Node_ID {
	for control in app.pinned.controls {if control.pin==pin && control.key==key {return control.node}}
	return 0
}

pinned_surface_test_button_semantics :: proc(rt: ^alicorn.Runtime, node: alicorn.Node_ID, label: string) -> int {
	snapshot:=alicorn.semantic_snapshot(rt,context.temp_allocator)
	defer alicorn.semantic_snapshot_destroy(&snapshot)
	count:=0
	for item in snapshot.nodes {if item.role==.Button && item.visual_node==node && item.label==label {count+=1}}
	return count
}

pinned_surface_test_button_enabled :: proc(rt: ^alicorn.Runtime, label: string) -> bool {
	snapshot:=alicorn.semantic_snapshot(rt,context.temp_allocator)
	defer alicorn.semantic_snapshot_destroy(&snapshot)
	for item in snapshot.nodes {
		if item.role==.Button && item.label==label {
			return !alicorn.semantic_states_has(item.states,.Disabled)
		}
	}
	return false
}

pinned_surface_test_rects_overlap :: proc(a,b: alicorn.Rect) -> bool {
	return a.x<b.x+b.w && b.x<a.x+a.w && a.y<b.y+b.h && b.y<a.y+a.h
}

@(test)
test_pinned_source_card_labels_geometry_and_themes :: proc(t: ^testing.T) {
	f: Semantic_Zoom_Test_Editor
	source:="package demo\nfunc Alpha() { return }\n"
	if !semantic_zoom_test_open(&f,t,"go",source) {semantic_zoom_test_destroy(&f,t);return}
	defer {pinned_destroy(&f.app.pinned);semantic_zoom_test_destroy(&f,t)}
	_,found:=find_document(&f.app.backend.state,f.document_id)
	view_index:=editor_view_find(f.app.editor_views[:],f.document_id)
	if !found || view_index<0 {testing.expect(t,false,"the fixture must retain its source document and selection");return}
	view:=&f.app.editor_views[view_index]
	view.selection_anchor,view.caret_byte=0,7
	_ = alicorn.focus(&f.rt,f.app.editor_scroll_owner)
	pinned_command(&f.app,&f.rt,"add")
	pinned_refresh(&f.app,&f.rt)
	if len(f.app.pinned.snapshot.ranges)!=1 {testing.expect(t,false,"one source selection should create one pin");return}
	pin:=f.app.pinned.snapshot.ranges[0]
	f.app.pinned.visible=true
	f.app.pinned.selected=pin.id
	f.app.pinned.single_pane=false
	pinned_surface_test_frame(&f)
	heading:=pinned_surface_test_control(&f.app,pin.id,"heading")
	go_node:=pinned_surface_test_control(&f.app,pin.id,"go")
	copy_node:=pinned_surface_test_control(&f.app,pin.id,"copy")
	more:=pinned_surface_test_control(&f.app,pin.id,"more")
	filename:=document_title(pin.path)
	for check in ([4]struct {node: alicorn.Node_ID, label: string}{
		{heading,filename},{go_node,"Go to source"},{copy_node,"Copy"},{more,"More actions"},
	}) {
		info,ok:=alicorn.node_info(&f.rt,check.node)
		testing.expect(t,check.node!=0 && ok && info.bounds.w>0 && info.bounds.h>0,
			fmt.tprintf("source-card control %s should have finalized visible geometry (id=%d, found=%t, bounds=%.1fx%.1f)",check.label,check.node,ok,info.bounds.w,info.bounds.h))
		if check.node!=0 {testing.expect(t,pinned_surface_test_button_semantics(&f.rt,check.node,check.label)==1,"each control should expose exactly one accessible button label")}
	}
	go_info,_:=alicorn.node_info(&f.rt,go_node)
	copy_info,_:=alicorn.node_info(&f.rt,copy_node)
	more_info,_:=alicorn.node_info(&f.rt,more)
	testing.expect(t,pinned_surface_test_control(&f.app,pin.id,"edit")==0,
		"current passages should activate by clicking their text, without an Edit button")
	testing.expect(t,!pinned_surface_test_rects_overlap(go_info.bounds,copy_info.bounds) &&
		!pinned_surface_test_rects_overlap(go_info.bounds,more_info.bounds) &&
		!pinned_surface_test_rects_overlap(copy_info.bounds,more_info.bounds),
		"Go, Copy and overflow controls must not overlap in the source-card action row")
	testing.expect(t,pinned_surface_test_control(&f.app,0,"source")==0,
		"Back to source should not occupy the header while the source editor is beside Pinned")
	f.app.pinned.single_pane=true
	pinned_surface_test_frame(&f)
	testing.expect(t,pinned_surface_test_control(&f.app,0,"source")!=0,
		"Back to source should be available when Pinned occupies the only pane")

	text_key:=alicorn.key_pair(u64(pin.id),u64(pin.start_byte))
	text_node,text_found:=alicorn.node_by_key(&f.rt,text_key,.Text)
	text_info,text_valid:=alicorn.node_info(&f.rt,text_node)
	testing.expect(t,text_found && text_valid && text_info.text_geometry_available && !f.app.pinned.measurement_refresh_pending,
		"visible excerpts should retain their shaped text geometry for later measurement reuse")
	when ODIN_DEBUG {
		temporary_before:=f.app.pinned.temporary_text_measurement_builds
		reuse_before:=f.app.pinned.retained_text_measurement_hits
		pinned_surface_test_frame(&f)
		testing.expect(t,f.app.pinned.retained_text_measurement_hits>reuse_before &&
			f.app.pinned.temporary_text_measurement_builds==temporary_before,
			"steady-state descriptions should reuse retained excerpt geometry instead of shaping the same lines again")
	}
	for theme in ([3]Scratchpad_Theme_Choice{.Warm,.Cool_Light,.Workbench_Relief}) {
		f.app.theme_choice=theme
		if theme==.Workbench_Relief {_=scratchpad_styles_ensure(&f.app,&f.rt)}
		scratchpad_theme_apply_registered(&f.app)
		pinned_surface_test_frame(&f)
		go_info,go_ok:=alicorn.node_info(&f.rt,pinned_surface_test_control(&f.app,pin.id,"go"))
		copy_info,copy_ok:=alicorn.node_info(&f.rt,pinned_surface_test_control(&f.app,pin.id,"copy"))
		more_info,more_ok:=alicorn.node_info(&f.rt,pinned_surface_test_control(&f.app,pin.id,"more"))
		testing.expect(t,go_ok && copy_ok && more_ok &&
			pinned_surface_test_control(&f.app,pin.id,"edit")==0 &&
			!pinned_surface_test_rects_overlap(go_info.bounds,copy_info.bounds) &&
			!pinned_surface_test_rects_overlap(go_info.bounds,more_info.bounds) &&
			!pinned_surface_test_rects_overlap(copy_info.bounds,more_info.bounds),
			"source-card actions should remain compact and nonoverlapping across the supported themes")
	}
	for device_scale in ([4]f32{1,1.25,1.5,2}) {
		_ = alicorn.set_presentation_scale(&f.rt,device_scale,device_scale)
		pinned_surface_test_frame(&f,device_scale)
		go_info,go_ok:=alicorn.node_info(&f.rt,pinned_surface_test_control(&f.app,pin.id,"go"))
		copy_info,copy_ok:=alicorn.node_info(&f.rt,pinned_surface_test_control(&f.app,pin.id,"copy"))
		more_info,more_ok:=alicorn.node_info(&f.rt,pinned_surface_test_control(&f.app,pin.id,"more"))
		testing.expect(t,go_ok && copy_ok && more_ok &&
			!pinned_surface_test_rects_overlap(go_info.bounds,copy_info.bounds) &&
			!pinned_surface_test_rects_overlap(go_info.bounds,more_info.bounds) &&
			!pinned_surface_test_rects_overlap(copy_info.bounds,more_info.bounds),
			fmt.tprintf("source-card action bounds should remain separate at %.0f%% display scale",device_scale*100))
	}
	_ = alicorn.set_presentation_scale(&f.rt,1,1)
	more=pinned_surface_test_control(&f.app,pin.id,"more")
	_ = alicorn.focus(&f.rt,more)
	testing.expect(t,pinned_key(&f.app,&f.rt,.Context_Menu),
		"the focused overflow control should expose its move and remove actions to keyboard users")
	pinned_surface_test_frame(&f)
	menu_snapshot:=alicorn.semantic_snapshot(&f.rt,context.temp_allocator)
	move_up_count,move_down_count,remove_count:=0,0,0
	for item in menu_snapshot.nodes {
		if item.role!=.Button {continue}
		if item.label=="Move up" {move_up_count+=1}
		if item.label=="Move down" {move_down_count+=1}
		if item.label=="Remove pin" {remove_count+=1}
	}
	alicorn.semantic_snapshot_destroy(&menu_snapshot)
	testing.expect(t,move_up_count==1 && move_down_count==1 && remove_count==1,
		"the keyboard-opened pin menu should expose Move up, Move down and Remove pin once")
	alicorn.context_menu_close(&f.rt)
	pinned_surface_test_frame(&f)
}

@(test)
test_pinned_menu_remains_available_and_guards_active_edit :: proc(t: ^testing.T) {
	f: Semantic_Zoom_Test_Editor
	source:="package demo\nfunc Alpha() { return }\n"
	if !semantic_zoom_test_open(&f,t,"go",source) {semantic_zoom_test_destroy(&f,t);return}
	defer {
		pinned_destroy(&f.app.pinned)
		semantic_zoom_test_destroy(&f,t)
	}
	view_index:=editor_view_find(f.app.editor_views[:],f.document_id)
	if view_index<0 {testing.expect(t,false,"fixture editor view should exist");return}
	view:=&f.app.editor_views[view_index]
	view.selection_anchor,view.caret_byte=0,7
	_ = alicorn.focus(&f.rt,f.app.editor_scroll_owner)
	pinned_command(&f.app,&f.rt,"add")
	pinned_refresh(&f.app,&f.rt)
	if len(f.app.pinned.snapshot.ranges)!=1 {testing.expect(t,false,"fixture pin should exist");return}
	pin:=f.app.pinned.snapshot.ranges[0]
	pinned_edit_begin(&f.app,&f.rt,pin.id)
	if !f.app.pinned.editing {testing.expect(t,false,"the current pin should enter its editing session");return}
	pinned_surface_test_frame(&f)
	more:=pinned_surface_test_control(&f.app,pin.id,"more")
	testing.expect(t,more!=0 && pinned_surface_test_button_enabled(&f.rt,"More actions"),
		"the overflow control should remain actionable while the pin is being edited")
	testing.expect(t,pinned_surface_test_control(&f.app,pin.id,"go")!=0 &&
		pinned_surface_test_button_enabled(&f.rt,"Go to source"),
		"Go to source should remain available when the active edit can be safely finished")
	testing.expect(t,pinned_surface_test_control(&f.app,pin.id,"copy")!=0 &&
		pinned_surface_test_button_enabled(&f.rt,"Copy"),
		"Copy should remain visible and available for a current pin during editing")

	pinned_open_action_menu(&f.app,&f.rt,pin.id)
	pinned_surface_test_frame(&f)
	testing.expect(t,pinned_surface_test_button_enabled(&f.rt,"Remove pin"),
		"Remove pin should be enabled when no edit acknowledgement or composition is pending")

	append(&f.app.editor_edits,Editor_Edit_Intent{pinned_edit=true,pin_id=u64(pin.id)})
	pinned_surface_test_frame(&f)
	testing.expect(t,!pinned_surface_test_button_enabled(&f.rt,"Remove pin"),
		"structural menu actions should be disabled while this pin has an unacknowledged edit")
	pinned_command(&f.app,&f.rt,"remove",pin.id)
	testing.expect(t,f.app.pinned.editing && len(f.app.pinned.snapshot.ranges)==1,
		"a remove request during a pending acknowledgement must retain the pin and editing session")
	clear(&f.app.editor_edits)

	view.preedit_active=true
	pinned_surface_test_frame(&f)
	testing.expect(t,!pinned_surface_test_button_enabled(&f.rt,"Remove pin"),
		"structural menu actions should be disabled during IME composition")
	pinned_command(&f.app,&f.rt,"remove",pin.id)
	testing.expect(t,f.app.pinned.editing && len(f.app.pinned.snapshot.ranges)==1,
		"a remove request during IME composition must retain the pin and editing session")
	view.preedit_active=false

	alicorn.context_menu_close(&f.rt)
	f.app.pinned.context_menu_open=false
	f.app.pinned.action_menu_pin=0
	document,_:=find_document(&f.app.backend.state,f.document_id)
	before_revision:=document.editor_revision
	pinned_command(&f.app,&f.rt,"remove",pin.id)
	pinned_refresh(&f.app,&f.rt)
	testing.expect(t,!f.app.pinned.editing && len(f.app.pinned.snapshot.ranges)==0 &&
		document.editor_revision==before_revision,
		"removing an active pin should finish editing, remove the pin, and leave source bytes untouched")
}

@(test)
test_pinned_surface_focus_and_read_only_commands :: proc(t: ^testing.T) {
	f: Semantic_Zoom_Test_Editor
	source:="package demo\nfunc Alpha() { return }\nfunc Beta() { return }\n"
	if !semantic_zoom_test_open(&f,t,"go",source) { semantic_zoom_test_destroy(&f,t); return }
	defer {
		pinned_destroy(&f.app.pinned)
		semantic_zoom_test_destroy(&f,t)
	}
	document,found:=find_document(&f.app.backend.state,f.document_id)
	view_index:=editor_view_find(f.app.editor_views[:],f.document_id)
	if !found || view_index<0 || f.app.editor_scroll_owner==0 {testing.expect(t,false,"the fixture must have a real source editor");return}
	view:=&f.app.editor_views[view_index]
	first_start:=0
	first_end:=7
	second_start:=strings.index(source,"Alpha")
	if second_start<0 {testing.expect(t,false,"fixture function should exist");return}
	second_end:=second_start+len("Alpha")
	original_revision:=document.editor_revision
	original_source:=string(f.app.editor_window.source)
	view.selection_anchor,view.caret_byte=u64(first_start),u64(first_end)
	if !alicorn.focus(&f.rt,f.app.editor_scroll_owner) {testing.expect(t,false,"the source editor should receive focus before pinning");return}
	pinned_command(&f.app,&f.rt,"add")
	pinned_refresh(&f.app,&f.rt)
	view.selection_anchor,view.caret_byte=u64(second_start),u64(second_end)
	pinned_command(&f.app,&f.rt,"add")
	pinned_refresh(&f.app,&f.rt)
	testing.expect(t,len(f.app.pinned.snapshot.ranges)==2,"two independent ranges from one source should appear in the pane")
	if len(f.app.pinned.snapshot.ranges)!=2 {return}
	first_id,second_id:=f.app.pinned.snapshot.ranges[0].id,f.app.pinned.snapshot.ranges[1].id
	testing.expect(t,first_id!=second_id && f.app.pinned.snapshot.ranges[0].document_id==f.document_id && f.app.pinned.snapshot.ranges[1].document_id==f.document_id,
		"each captured range should retain independent identity in the same source document")
	testing.expect(t,f.app.editor_window.document_id==f.document_id && string(f.app.editor_window.source)==original_source &&
		document.editor_revision==original_revision && view.selection_anchor==u64(second_start) && view.caret_byte==u64(second_end),
		"pinning should leave the authoritative source and the user's selection unchanged")

	f.app.pinned.focus_pending=true
	pinned_surface_test_frame(&f)
	if f.app.pinned.focus_target==0 || !pinned_focus_owned(&f.app,&f.rt) {testing.expect(t,false,"opening the pane should focus a retained pin control");return}
	before_revision:=document.editor_revision
	before_source:=string(f.app.editor_window.source)
	cut_handled:=pinned_edit_command(&f.app,&f.rt,action_id_for(ACTION_EDIT_CUT))
	undo_handled:=pinned_edit_command(&f.app,&f.rt,action_id_for(ACTION_EDIT_UNDO))
	paste_handled:=pinned_edit_command(&f.app,&f.rt,action_id_for(ACTION_EDIT_PASTE))
	testing.expect(t,cut_handled && undo_handled && paste_handled && document.editor_revision==before_revision && string(f.app.editor_window.source)==before_source,
		"read-only Pinned focus must consume Cut, Undo and Paste without changing the editor")

	testing.expect(t,pinned_key(&f.app,&f.rt,.Down) && f.app.pinned.selected==second_id,
		"Down should move keyboard selection to the next stable pin identity")
	pinned_surface_test_frame(&f)
	// The selected header may be below the current viewport. The first frame
	// scrolls it into view; the next frame can then restore keyboard focus.
	if f.app.pinned.focus_pending {pinned_surface_test_frame(&f)}
	testing.expect(t,f.app.pinned.focus_target!=0 && alicorn.focused_node(&f.rt)==f.app.pinned.focus_target,
		"rebuilding after keyboard navigation should keep focus on the same selected pin")
	testing.expect(t,pinned_key(&f.app,&f.rt,.Escape) && f.app.pinned.narrow_source,
		"Escape should return from the pane to the ordinary source view")
}

@(test)
test_pinned_edit_validation_stays_inside_captured_segment :: proc(t: ^testing.T) {
	f: Semantic_Zoom_Test_Editor
	source:="package demo\nfunc passage() {}\n"
	if !semantic_zoom_test_open(&f,t,"go",source) {semantic_zoom_test_destroy(&f,t);return}
	defer {pinned_destroy(&f.app.pinned);semantic_zoom_test_destroy(&f,t)}
	view_index:=editor_view_find(f.app.editor_views[:],f.document_id)
	if view_index<0 {testing.expect(t,false,"fixture editor view should exist");return}
	view:=&f.app.editor_views[view_index]
	start:=u64(strings.index(source,"passage"))
	end:=start+u64(len("passage"))
	view.selection_anchor=start
	view.caret_byte=end
	_ = alicorn.focus(&f.rt,f.app.editor_scroll_owner)
	pinned_command(&f.app,&f.rt,"add")
	pinned_refresh(&f.app,&f.rt)
	if len(f.app.pinned.snapshot.ranges)!=1 {testing.expect(t,false,"fixture pin should exist");return}
	pin:=f.app.pinned.snapshot.ranges[0]
	view.selection_anchor,view.caret_byte=1,2
	view.scroll_x,view.scroll_y=13,27
	view.preferred_x,view.preferred_x_set=42,true
	pinned_edit_begin(&f.app,&f.rt,pin.id)
	testing.expect(t,f.app.pinned.editing && view.selection_anchor==end && view.caret_byte==end,
		"a new pin-edit session should start at the passage end")
	testing.expect(t,f.app.pinned.edit_return_anchor==1 && f.app.pinned.edit_return_caret==2 &&
		f.app.pinned.edit_return_scroll_x==13 && f.app.pinned.edit_return_scroll_y==27 &&
		f.app.pinned.edit_return_preferred_x==42 && f.app.pinned.edit_return_preferred_x_set,
		"the ordinary source view state should be saved separately from pin-local editing state")
	close_handled:=pinned_edit_command(&f.app,&f.rt,action_id_for(ACTION_DOCUMENT_CLOSE))
	testing.expect(t,close_handled && document_is_open(&f.app.backend.state,pin.document_id),
		"closing the source document must be blocked until pin editing ends")
	pinned_edit_finish(&f.app,&f.rt,false)
	testing.expect(t,!f.app.pinned.editing && view.selection_anchor==1 && view.caret_byte==2 &&
		view.scroll_x==13 && view.scroll_y==27 && view.preferred_x==42 && view.preferred_x_set,
		"leaving pin editing should restore the source editor's prior caret, scroll, and preferred column")
	f.app.pinned.edit_return_anchor=40
	f.app.pinned.edit_return_caret=41
	view.selection_anchor,view.caret_byte=40,41
	pinned_edit_rebase_saved_selection(&f.app,pin.document_id,10,12,15)
	testing.expect(t,view.selection_anchor==43 && view.caret_byte==44,
		"an edit acknowledged after leaving pin mode should keep the saved source caret at the same logical position")
	view.selection_anchor,view.caret_byte=5,6
	pinned_edit_rebase_saved_selection(&f.app,pin.document_id,10,12,15)
	testing.expect(t,view.selection_anchor==5 && view.caret_byte==6,
		"a later explicit source selection must not be overwritten by an old pin edit acknowledgement")
	owned_id,clone_err:=strings.clone(pin.document_id,context.allocator)
	if clone_err!=nil {testing.expect(t,false,"test should retain pin document ID");return}
	f.app.pinned.editing=true
	f.app.pinned.edit_pin=pin.id
	f.app.pinned.edit_document_id=owned_id
	f.app.pinned.edit_start_byte=u64(pin.start_byte)
	f.app.pinned.edit_end_byte=u64(pin.end_byte)
	valid,new_end:=pinned_edit_validate_replacement(&f.app,pin.document_id,end,end,1,end,end,end+1,end+1)
	testing.expect(t,valid && new_end==end+1,"insertion at the pin's trailing boundary should extend only the pin")
	valid,_=pinned_edit_validate_replacement(&f.app,pin.document_id,start-1,start,1,start,start,start,start)
	testing.expect(t,!valid,"replacement beginning before the pin must be refused")
	valid,_=pinned_edit_validate_replacement(&f.app,pin.document_id,start,end,0,start,end,start-1,start-1)
	testing.expect(t,!valid,"selection result outside the post-edit pin must be refused")
	view.selection_anchor=start-1
	view.caret_byte=end+3
	pinned_edit_selection_sync(&f.app)
	testing.expect(t,view.selection_anchor==start && view.caret_byte==end,
		"pin-local source selection must be clamped to captured segment boundaries")
}

@(test)
test_pinned_surface_rejects_old_pages_and_bounds_cache :: proc(t: ^testing.T) {
	f: Semantic_Zoom_Test_Editor
	source:="package demo\nfunc Alpha() { return }\n"
	if !semantic_zoom_test_open(&f,t,"go",source) { semantic_zoom_test_destroy(&f,t); return }
	defer {
		pinned_destroy(&f.app.pinned)
		semantic_zoom_test_destroy(&f,t)
	}
	document,_:=find_document(&f.app.backend.state,f.document_id)
	view_index:=editor_view_find(f.app.editor_views[:],f.document_id)
	if view_index<0 {testing.expect(t,false,"the fixture should retain the source view");return}
	view:=&f.app.editor_views[view_index]
	view.selection_anchor,view.caret_byte=0,7
	_ = alicorn.focus(&f.rt,f.app.editor_scroll_owner)
	pinned_command(&f.app,&f.rt,"add")
	pinned_refresh(&f.app,&f.rt)
	if len(f.app.pinned.snapshot.ranges)!=1 {testing.expect(t,false,"the source selection should be captured");return}
	for _ in 0..<17 { if !pinned_load_page(&f.app,0,16) {testing.expect(t,false,"current bounded page should load");return} }
	testing.expect(t,len(f.app.pinned.pages)==16,"the page cache should stay within sixteen bounded pages")
	when ODIN_DEBUG {testing.expect(t,f.app.pinned.page_evictions>0,"evicting a page should be observable in debug builds")}
	old:=f.app.pinned.snapshot
	replacement:=[1]int{int('P')}
	changed:=bridge.backend_command(&f.app.backend,"replace_document",document_id=f.document_id,editor_revision=document.editor_revision,
		start_byte=0,end_byte=1,replacement=replacement[:])
	if !changed.ok {testing.expect(t,false,fmt.tprintf("fixture source edit should succeed: %s",changed.message));bridge.backend_command_result_destroy(&changed,context.allocator);return}
	bridge.backend_command_result_destroy(&changed,context.allocator)
	testing.expect(t,!pinned_load_page(&f.app,0,1),"a delayed page for an old source revision must be rejected")
	when ODIN_DEBUG {testing.expect(t,f.app.pinned.rejected_responses>0,"rejected stale pages should be observable in debug builds")}
	pinned_refresh(&f.app,&f.rt)
	testing.expect(t,len(f.app.pinned.pages)==0 && len(f.app.pinned.snapshot.ranges)==1 &&
		f.app.pinned.snapshot.ranges[0].status=="stale" && f.app.pinned.snapshot.revision!=old.revision,
		"a source edit should discard cached bytes and preserve a visibly stale pin")
	when ODIN_DEBUG {testing.expect(t,f.app.pinned.source_invalidations>0,"source revision invalidation should be observable in debug builds")}
	f.app.pinned.visible=true
	f.app.theme_choice=.Workbench_Relief
	f.app.editor_text_scale=1.5
	scratchpad_styles_ensure(&f.app,&f.rt)
	f.rt.viewport=alicorn.Rect{0,0,320,600}
	alicorn.set_presentation_scale(&f.rt,1.5,1.5)
	for _ in 0..<3 {alicorn.invalidate_root(&f.rt,"Stale pinned paper fixture");pinned_surface_test_frame(&f,1.5)}
	pin:=f.app.pinned.snapshot.ranges[0]
	go_id:=pinned_surface_test_control(&f.app,pin.id,"go")
	copy_id:=pinned_surface_test_control(&f.app,pin.id,"copy")
	status_found:=false
	for _,node in f.rt.nodes {
		if node.kind==.Text && strings.contains(node.text,"Source changed. Select the current passage") {
			status_found=true
			info,valid:=alicorn.node_info(&f.rt,node.id)
			testing.expect(t,valid && info.text_content_height<=info.bounds.h+1/max(f.rt.presentation_scale_y,1),
				"stale-source guidance should wrap completely inside its paper at narrow width and increased scale")
		}
	}
	testing.expect(t,status_found,"stale sources should explain why their excerpt is no longer current")
	status_label_found := false
	status_semantic_found := false
	for _,node in f.rt.nodes {
		if node.kind==.Text && node.text=="Changed" { status_label_found=true }
	}
	status_snapshot:=alicorn.semantic_snapshot(&f.rt,context.temp_allocator)
	for item in status_snapshot.nodes {
		if item.role==.Status && item.label=="Pinned source status: Changed" && item.value=="Changed" &&
		   strings.contains(item.description,"source changed") && strings.contains(item.description,"pin it again") {
			status_semantic_found=true
		}
	}
	alicorn.semantic_snapshot_destroy(&status_snapshot)
	testing.expect(t,status_label_found && status_semantic_found,
		"the stale card header should visibly and accessibly identify the changed source state")
	testing.expect(t,go_id!=0 && f.rt.nodes[go_id].disabled && copy_id!=0 && f.rt.nodes[copy_id].disabled,
		"stale source cards should keep navigation and copy disabled")
}


pinned_surface_test_paper :: proc(rt: ^alicorn.Runtime, descendant: alicorn.Node_ID) -> alicorn.Node_ID {
	current := descendant
	for current!=0 {
		node,found := rt.nodes[current]
		if !found { return 0 }
		if node.label=="Pinned source paper" { return current }
		current=node.parent
	}
	return 0
}

@(test)
test_pinned_wrapped_rows_keep_distinct_identity_and_continuous_paper :: proc(t: ^testing.T) {
	f: Semantic_Zoom_Test_Editor
	source := "Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files.\n" +
		"    func reference() { preserve_source_indentation_and_wrap_the_long_source_line_without_losing_the_paper_background() }\n" +
		"The final source line stays inside the same reference card.\n"
	if !semantic_zoom_test_open(&f,t,"md",source) { semantic_zoom_test_destroy(&f,t); return }
	defer { pinned_destroy(&f.app.pinned); semantic_zoom_test_destroy(&f,t) }
	view_index := editor_view_find(f.app.editor_views[:],f.document_id)
	if view_index<0 { testing.expect(t,false,"fixture must own a source view"); return }
	view := &f.app.editor_views[view_index]
	alicorn.focus(&f.rt,f.app.editor_scroll_owner)
	view.selection_anchor,view.caret_byte=0,u64(len(source))
	pinned_command(&f.app,&f.rt,"add")
	pinned_refresh(&f.app,&f.rt)
	second_start := strings.index(source,"    func")
	view.selection_anchor,view.caret_byte=u64(second_start),u64(second_start+20)
	pinned_command(&f.app,&f.rt,"add")
	pinned_refresh(&f.app,&f.rt)
	if len(f.app.pinned.snapshot.ranges)!=2 { testing.expect(t,false,"fixture needs two independently identified pins from one source"); return }
	for theme in ([3]Scratchpad_Theme_Choice{.Warm,.Cool_Light,.Workbench_Relief}) {
		f.app.theme_choice=theme
		scratchpad_styles_ensure(&f.app,&f.rt)
		for width in ([2]f32{280,440}) {
		for scale in ([3]f32{1,1.5,2}) {
			f.rt.viewport=alicorn.Rect{0,0,width,4000}
			f.app.editor_text_scale=scale
			alicorn.set_presentation_scale(&f.rt,scale,scale)
			for _ in 0..<3 { alicorn.invalidate_root(&f.rt,"Pinned containment fixture"); pinned_surface_test_frame(&f,scale) }
			testing.expect(t,!f.rt.hard_error,fmt.tprintf("each virtual row must have independent retained identity: %s",f.rt.diagnostic))
			if f.rt.hard_error { return }
			text_count:=0
			previous_card: alicorn.Rect
			for pin,pin_index in f.app.pinned.snapshot.ranges {
				heading:=pinned_surface_test_control(&f.app,pin.id,"heading")
				paper_id:=pinned_surface_test_paper(&f.rt,heading)
				if paper_id==0 { testing.expect(t,false,"every reference should have its own paper header"); return }
				previous:=f.rt.nodes[paper_id].bounds
				if pin_index>0 { testing.expect(t,abs(previous.y-previous_card.y-previous_card.h-PINNED_CARD_GAP)<0.1,"only the space between references should interrupt the paper") }
				for local:=1; local<=pin.line_count; local+=1 {
					_,item,found:=pinned_find_row(&f.app.pinned,pin.first_row+local)
					testing.expect(t,found,"the bounded fixture should realize all selected source rows")
					if !found { return }
					text_id,exists:=alicorn.node_by_key(&f.rt,alicorn.key_pair(u64(pin.id),u64(item.start_byte)),.Text)
					info,valid:=alicorn.node_info(&f.rt,text_id)
					testing.expect(t,exists && valid && info.text_geometry_available,"each source row must retain its own shaped text")
					if !exists || !valid { return }
					text_count+=1
					paper_id=pinned_surface_test_paper(&f.rt,text_id)
					if paper_id==0 { testing.expect(t,false,"every source line needs paper underneath it"); return }
					paper:=f.rt.nodes[paper_id]
					row:=f.rt.nodes[paper.parent]
					testing.expect(t,abs(previous.y+previous.h-paper.bounds.y)<0.1,"adjacent source lines must form one seamless excerpt")
					edge_tolerance:=1/max(f.rt.presentation_scale_x,1)
					testing.expect(t,info.bounds.h+edge_tolerance>=info.text_content_height && info.bounds.x>=paper.bounds.x-edge_tolerance &&
						info.bounds.x+info.bounds.w<=paper.bounds.x+paper.bounds.w+edge_tolerance && info.bounds.y>=paper.bounds.y-edge_tolerance &&
						info.bounds.y+info.bounds.h<=paper.bounds.y+paper.bounds.h+edge_tolerance,
						fmt.tprintf("wrapped text must fit on its paper at width %.0f, scale %.1f (text %.1f, text bounds %.1f %.1f %.1f %.1f, paper %.1f %.1f %.1f %.1f)",width,scale,info.text_content_height,info.bounds.x,info.bounds.y,info.bounds.w,info.bounds.h,paper.bounds.x,paper.bounds.y,paper.bounds.w,paper.bounds.h))
					testing.expect(t,abs(row.bounds.h-alicorn.virtual_list_height_index_item_height(&f.app.pinned.index,pin.first_row+local))<0.1,
						"virtual heights must include text, insets, continuation/actions and inter-card spacing")
					for command in paper.paint {
						if surface,ok:=command.payload.(alicorn.Surface_Paint); ok { testing.expect(t,surface.material==alicorn.MATERIAL_FLAT && surface.physical_height==0,"excerpt paper should stay flat in Relief as well as the light themes") }
					}
					previous=paper.bounds
				}
				previous_card=previous
			}
			testing.expect(t,text_count==4,"three wrapped source lines and a second pin must all survive reconciliation")
		}
		}
	}
}
