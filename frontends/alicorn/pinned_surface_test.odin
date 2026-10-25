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
	ui, build := alicorn.begin_frame(&f.rt)
	if !build { return }
	_ = alicorn.container_begin(&ui,.Root,label="pinned-surface-test-root",style=alicorn.layout_style(.Column,grow=1,clip=true))
	pinned_surface_build(&f.app,&ui,&f.rt)
	alicorn.container_end(&ui)
	alicorn.end_frame(&ui)
	pinned_after_frame(&f.app,&f.rt)
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
