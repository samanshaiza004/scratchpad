package main

import "core:fmt"
import "core:strings"
import "core:testing"
import alicorn "alicorn:runtime"
import bridge "./bridge"

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

pinned_surface_test_frame :: proc(f: ^Semantic_Zoom_Test_Editor) {
	if !scratchpad_styles_ensure(&f.app,&f.rt) {return}
	ui, build := alicorn.begin_frame(&f.rt)
	if !build { return }
	_ = alicorn.container_begin(&ui,.Root,label="pinned-surface-test-root",style=alicorn.layout_style(.Column,grow=1,clip=true))
	workbench_scope:=alicorn.style_environment_push(&ui,scratchpad_workbench_style_environment(&f.app))
	pinned_surface_build(&f.app,&ui,&f.rt)
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
			!pinned_surface_test_rects_overlap(go_info.bounds,copy_info.bounds) &&
			!pinned_surface_test_rects_overlap(go_info.bounds,more_info.bounds) &&
			!pinned_surface_test_rects_overlap(copy_info.bounds,more_info.bounds),
			"source-card actions should retain nonoverlapping geometry across Workbench, Cool Light and Relief themes")
	}
	for device_scale in ([4]f32{1,1.25,1.5,2}) {
		_ = alicorn.set_presentation_scale(&f.rt,device_scale,device_scale)
		pinned_surface_test_frame(&f)
		go_info,go_ok:=alicorn.node_info(&f.rt,pinned_surface_test_control(&f.app,pin.id,"go"))
		copy_info,copy_ok:=alicorn.node_info(&f.rt,pinned_surface_test_control(&f.app,pin.id,"copy"))
		more_info,more_ok:=alicorn.node_info(&f.rt,pinned_surface_test_control(&f.app,pin.id,"more"))
		testing.expect(t,go_ok && copy_ok && more_ok &&
			!pinned_surface_test_rects_overlap(go_info.bounds,copy_info.bounds) &&
			!pinned_surface_test_rects_overlap(go_info.bounds,more_info.bounds) &&
			!pinned_surface_test_rects_overlap(copy_info.bounds,more_info.bounds),
			fmt.tprintf("source-card action bounds should remain separate at %.0f%% display scale",device_scale*100))
	}
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
}
