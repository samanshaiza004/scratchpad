package main

import "core:fmt"
import alicorn "alicorn:runtime"
import gui "alicorn:ui"
import host "alicorn:native/sdl_gpu"
import bridge "./bridge"

ACTION_PIN_SELECTION :: "source.pin_selection"
ACTION_PINNED_FOCUS :: "view.pinned_focus"
ACTION_PINNED_TOGGLE :: "view.pinned_toggle"

Pinned_Page :: struct { window: bridge.Pinned_Window, data: []u8 }
Pinned_Control :: struct { node: alicorn.Node_ID, pin: bridge.Pin_ID }
Pinned_Surface :: struct {
	visible, narrow_source, single_pane, focus_pending, restore_pending, force_refresh: bool,
	context_menu_open: bool,
	runtime: ^alicorn.Runtime,
	snapshot: bridge.Pinned_Snapshot,
	pages: [dynamic]Pinned_Page,
	controls: [dynamic]Pinned_Control,
	selected: bridge.Pin_ID,
	index: alicorn.Virtual_List_Height_Index,
	index_ready: bool,
	width, scale, restore_y: f32,
	owner, focus_target: alicorn.Node_ID,
	// Developer/test observability. No polling or dependency tracking.
	rejected_responses, page_evictions, source_invalidations: u64,
}

pinned_pages_clear :: proc(surface: ^Pinned_Surface) {
	for &page in surface.pages { bridge.Pinned_Window_Destroy(&page.window); delete(page.data) }
	clear(&surface.pages)
}

pinned_destroy :: proc(surface: ^Pinned_Surface) {
	pinned_pages_clear(surface); delete(surface.pages); delete(surface.controls)
	bridge.Pinned_Snapshot_Destroy(&surface.snapshot)
	if surface.index_ready { alicorn.virtual_list_height_index_destroy(&surface.index) }
	surface^={}
}

pinned_index_reset :: proc(surface: ^Pinned_Surface, scale: f32) {
	if surface.index_ready { alicorn.virtual_list_height_index_destroy(&surface.index) }
	surface.index_ready=alicorn.virtual_list_height_index_init(&surface.index,surface.snapshot.total_rows,24*scale)
	for pin in surface.snapshot.ranges {
		_ = alicorn.virtual_list_height_index_set_height(&surface.index,pin.first_row,112*scale)
		if pin.status!="current" { _=alicorn.virtual_list_height_index_set_height(&surface.index,pin.first_row+1,64*scale) }
	}
	surface.scale=scale
}

pinned_pin_at_row :: proc(snapshot: ^bridge.Pinned_Snapshot, row: int) -> (pin: bridge.Pinned_Range, found: bool) {
	for candidate in snapshot.ranges { if candidate.first_row>row { break }; pin=candidate; found=true }
	return
}

pinned_refresh :: proc(app: ^App, rt: ^alicorn.Runtime) {
	if app==nil || !app.backend.started { return }
	s:=&app.pinned
	if !s.visible && s.snapshot.epoch==app.backend.state.pinned_epoch { return }
	if !s.force_refresh && s.snapshot.epoch==app.backend.state.pinned_epoch && s.snapshot.revision==app.backend.state.pinned_revision { return }
	anchor: bridge.Pin_ID; local_row:=0; in_row: f32
	if s.index_ready && s.owner!=0 {
		if info,ok:=alicorn.node_info(rt,s.owner); ok {
			row:=alicorn.virtual_list_height_index_item_at(&s.index,info.scroll_offset_y)
			if pin,found:=pinned_pin_at_row(&s.snapshot,row);found { anchor=pin.id;local_row=row-pin.first_row;in_row=info.scroll_offset_y-alicorn.virtual_list_height_index_item_top(&s.index,row) }
		}
	}
	result:=bridge.backend_command(&app.backend,"pinned_read")
	defer bridge.backend_command_result_destroy(&result,context.allocator)
	if !result.ok || !result.pinned_owned { set_error(app,result.message);return }
	s.force_refresh=false
	if result.pinned.epoch!=s.snapshot.epoch { s.selected=0; anchor=0 }
	when ODIN_DEBUG { if result.pinned.source_invalidations>s.snapshot.source_invalidations { s.source_invalidations+=result.pinned.source_invalidations-s.snapshot.source_invalidations } }
	pinned_pages_clear(s)
	bridge.Pinned_Snapshot_Destroy(&s.snapshot)
	s.snapshot=result.pinned; result.pinned={};result.pinned_owned=false
	pinned_index_reset(s,editor_text_scale_effective(app))
	found_selection:=false
	for pin in s.snapshot.ranges { if pin.id==s.selected {found_selection=true};if pin.id==anchor { target:=pin.first_row+min(local_row,pin.line_count if pin.status=="current" else 1);s.restore_y=alicorn.virtual_list_height_index_item_top(&s.index,target)+in_row;s.restore_pending=true } }
	if !found_selection { s.selected=0;if len(s.snapshot.ranges)>0 {s.selected=s.snapshot.ranges[0].id} }
}

pinned_focus_owned :: proc(app: ^App, rt: ^alicorn.Runtime) -> bool {
	if app==nil || !app.pinned.visible || app.pinned.runtime!=rt {return false}
	focused:=alicorn.focused_node(rt)
	if focused!=0 && focused==app.pinned.owner {return true}
	for item in app.pinned.controls {if focused!=0 && focused==item.node {if item.pin!=0{app.pinned.selected=item.pin};return true}}
	return false
}

pinned_edit_command :: proc(app: ^App, rt: ^alicorn.Runtime, command: host.Application_Command_ID) -> bool {
	if !pinned_focus_owned(app,rt) { return false }
	name:=string_for_action_id(command)
	switch name {
	case ACTION_EDIT_COPY:
		pinned_command(app,rt,"copy")
	case ACTION_EDIT_CUT, ACTION_EDIT_PASTE, ACTION_EDIT_UNDO, ACTION_EDIT_REDO, ACTION_EDIT_SELECT_ALL:
		// The pane is read-only. Consume editor commands so they never leak to
		// the source document while a Pinned control owns focus.
	case:
		return false
	}
	return true
}

pinned_context_pointer :: proc(app: ^App, rt: ^alicorn.Runtime, event: alicorn.Pointer_Event) -> bool {
	if app==nil || rt==nil || event.kind!=.Down || event.button!=alicorn.POINTER_BUTTON_SECONDARY ||
	   !app.backend.started || app.editor_scroll_owner==0 || alicorn.context_menu_is_open(rt) { return false }
	document,found:=find_document(&app.backend.state,app.backend.state.active)
	if !found || (document.view_kind!="" && document.view_kind!="text") { return false }
	index:=editor_view_find(app.editor_views[:],document.id)
	if index<0 { return false }
	view:=app.editor_views[index]
	if view.selection_anchor==view.caret_byte { return false }
	viewport:=alicorn.scroll_region_state(rt,app.editor_scroll_owner).viewport_bounds
	if viewport.w<=0 || viewport.h<=0 || event.x<viewport.x || event.x>=viewport.x+viewport.w || event.y<viewport.y || event.y>=viewport.y+viewport.h { return false }
	if !alicorn.context_menu_open(rt,alicorn.Rect{event.x,event.y,0,0},app.editor_scroll_owner) { return false }
	app.pinned.context_menu_open=true
	return true
}

pinned_context_menu_build :: proc(app: ^App, ui: ^alicorn.UI, rt: ^alicorn.Runtime) {
	if app==nil || ui==nil || rt==nil || !app.pinned.context_menu_open { return }
	if !alicorn.context_menu_is_open(rt) { app.pinned.context_menu_open=false; return }
	if !alicorn.context_menu_begin(ui,alicorn.key_string("scratchpad-pinned-source-context-menu")) { return }
	enabled:=false
	if document,found:=find_document(&app.backend.state,app.backend.state.active);found && len(app.editor_edits)==0 && !editor_active_preedit(app) {
		if index:=editor_view_find(app.editor_views[:],document.id);index>=0 {
			view:=app.editor_views[index]
			enabled=(document.view_kind==""||document.view_kind=="text") && view.selection_anchor!=view.caret_byte
		}
	}
	alicorn.context_menu_item(ui,action_id_for(ACTION_PIN_SELECTION),"Pin Selection",enabled)
	if alicorn.context_menu_end(ui)==action_id_for(ACTION_PIN_SELECTION) { app.pinned.context_menu_open=false;pinned_command(app,rt,"add") }
}

pinned_sync_menu_states :: proc(app: ^App, rt: ^alicorn.Runtime) {
	if app==nil { return }
	selection_available:=false
	if document,found:=find_document(&app.backend.state,app.backend.state.active);found &&
	   (document.view_kind=="" || document.view_kind=="text") && len(app.editor_edits)==0 && !editor_active_preedit(app) {
		if index:=editor_view_find(app.editor_views[:],document.id);index>=0 {
			view:=app.editor_views[index]
			selection_available=view.selection_anchor!=view.caret_byte
		}
	}
	for &item in app.document_items {
		if item.kind==.Command && item.command==action_id_for(ACTION_PIN_SELECTION) {
			item.state=alicorn.Action_State{enabled=selection_available}
		}
	}
	for &item in app.view_items {
		if item.kind!=.Command { continue }
		if item.command==action_id_for(ACTION_PINNED_FOCUS) { item.state=alicorn.Action_State{enabled=app.pinned.visible} }
		if item.command==action_id_for(ACTION_PINNED_TOGGLE) { item.state=alicorn.Action_State{enabled=true,checked=app.pinned.visible} }
	}
	if !pinned_focus_owned(app,rt) { return }
	copy_enabled:=false
	for pin in app.pinned.snapshot.ranges {
		if pin.id==app.pinned.selected && pin.status=="current" && pin.end_byte>=pin.start_byte && pin.end_byte-pin.start_byte<=64*1024 { copy_enabled=true }
	}
	for &item in app.edit_items {
		if item.kind!=.Command { continue }
		switch string_for_action_id(item.command) {
		case ACTION_EDIT_COPY: item.state=alicorn.Action_State{enabled=copy_enabled}
		case ACTION_EDIT_CUT,ACTION_EDIT_PASTE,ACTION_EDIT_UNDO,ACTION_EDIT_REDO,ACTION_EDIT_SELECT_ALL:
			item.state=alicorn.Action_State{enabled=false}
		}
	}
}

pinned_command :: proc(app: ^App, rt: ^alicorn.Runtime, command: string, pin: bridge.Pin_ID=0, delta: int=0) {
	if app==nil || rt==nil || !app.backend.started {return}
	if app.ui_description_runtime==rt { // Owned numeric identities; execute after end_frame.
		if frame_deferred_action_schedule(app,.Pinned_Action,value=command,source_start=u64(pin),source_end=u64(delta+1),editor_revision=app.pinned.snapshot.revision,source_line=app.pinned.snapshot.epoch) {return}
		set_error(app,"Could not queue the pinned action.");return
	}
	if command=="add" {
		view_index:=editor_view_find(app.editor_views[:],app.backend.state.active)
		dragging:=view_index>=0 && app.editor_views[view_index].dragging_selection
		palette_returned_from_editor:=app.command_palette_previous_focus!=0 && app.command_palette_previous_focus==app.editor_scroll_owner
		if (!editor_command_focus_owned(app,rt) && !palette_returned_from_editor) || len(app.editor_edits)>0 || editor_active_preedit(app) || dragging {set_error(app,"Focus the source editor and finish text input before pinning.");alicorn.invalidate_root(rt,"Pinned capture waited for focused, committed source");return}
		document,found:=find_document(&app.backend.state,app.backend.state.active)
		index:=editor_view_find(app.editor_views[:],app.backend.state.active)
		if !found || index<0 {return}
		view:=&app.editor_views[index]
		start,end:=min(view.selection_anchor,view.caret_byte),max(view.selection_anchor,view.caret_byte)
		if start==end {set_error(app,"Select the source passage to pin first.");alicorn.invalidate_root(rt,"Pinned capture needs a selection");return}
		result:=bridge.backend_command(&app.backend,"pinned_add",document_id=document.id,source_instance=document.instance_id,editor_revision=document.editor_revision,start_byte=start,end_byte=end)
		if result.ok {app.pinned.visible=true;app.pinned.narrow_source=false;app.pinned.force_refresh=true} else {set_error(app,result.message)}
		bridge.backend_command_result_destroy(&result,context.allocator)
	} else {
		selected_pin:=pin
		if selected_pin==0 {selected_pin=app.pinned.selected}
		if command=="go_to_source" && (len(app.editor_edits)>0 || editor_active_preedit(app)) {set_error(app,"Finish pending text input before navigating to pinned source.");return}
		result:=bridge.backend_command(&app.backend,fmt.tprintf("pinned_%s",command),pin_id=u64(selected_pin),pin_epoch=app.pinned.snapshot.epoch,pin_revision=app.pinned.snapshot.revision,pin_delta=delta,read_latest_after=command!="copy")
		if !result.ok {set_error(app,result.message);when ODIN_DEBUG {app.pinned.rejected_responses+=1};app.pinned.force_refresh=true} else {
			switch command {
			case "copy":
				if !host.ClipboardSetText(app.services.clipboard,string(result.pinned_data)) {set_error(app,"Could not copy the complete pinned excerpt.")}
			case "go_to_source":
				selection:=result.editor_selection
				if selection.document_id!="" {
					index,ok:=editor_view_ensure(&app.editor_views,selection.document_id)
					if ok {
						view:=&app.editor_views[index];view.selection_anchor=selection.anchor_byte;view.caret_byte=selection.cursor_byte
						semantic_zoom_destroy(&view.zoom)
						_ = editor_reveal_request_set(view,selection.document_id,selection.editor_revision,selection.anchor_byte,selection.cursor_byte,selection.cursor_line,.Center_When_Needed)
						pinned_source_focus_request(app,rt,selection.document_id)
					}
				}
			case "move": app.pinned.force_refresh=true;app.pinned.focus_pending=true
			case "remove":
				for item,i in app.pinned.snapshot.ranges {if item.id==selected_pin {if i+1<len(app.pinned.snapshot.ranges){app.pinned.selected=app.pinned.snapshot.ranges[i+1].id}else if i>0{app.pinned.selected=app.pinned.snapshot.ranges[i-1].id}else{app.pinned.selected=0};break}}
				app.pinned.force_refresh=true;app.pinned.focus_pending=true
			}
		}
		bridge.backend_command_result_destroy(&result,context.allocator)
	}
	alicorn.invalidate_root(rt,"Scratchpad pinned source action")
}

pinned_source_focus_request :: proc(app: ^App, rt: ^alicorn.Runtime, document_id: string) {
	if app==nil {return}
	if floating_window_contains(app,document_id) {
		app.pinned.narrow_source=false
		if floating:=app.floating_window;floating!=nil {
			floating.editor_focus_pending=true
			if floating.runtime!=nil {alicorn.invalidate_root(floating.runtime,"Pinned source navigation to detached document")}
		}
		return
	}
	app.editor_focus_pending=true
	app.pinned.narrow_source=true
}

pinned_apply_deferred :: proc(app: ^App, rt: ^alicorn.Runtime, action: Deferred_Action) {
	if action.value!="add" && (action.editor_revision!=app.pinned.snapshot.revision || action.source_line!=app.pinned.snapshot.epoch) {when ODIN_DEBUG {app.pinned.rejected_responses+=1};app.pinned.force_refresh=true;alicorn.invalidate_root(rt,"Discarded old pinned action");return}
	pinned_command(app,rt,action.value,bridge.Pin_ID(action.source_start),int(action.source_end)-1)
}

pinned_focus_request :: proc(app: ^App, rt: ^alicorn.Runtime) {
	app.pinned.visible=true;app.pinned.narrow_source=false;app.pinned.focus_pending=true;app.pinned.force_refresh=true
	alicorn.invalidate_root(rt,"Scratchpad focused Pinned")
}

pinned_key :: proc(app: ^App, rt: ^alicorn.Runtime, key: host.Application_Key) -> bool {
	if !pinned_focus_owned(app,rt) {return false}
	#partial switch key {
	case .Escape: app.pinned.narrow_source=true;app.editor_focus_pending=true;alicorn.invalidate_root(rt,"Returned from Pinned to source");return true
	case .Up,.Down,.Home,.End:
		count:=len(app.pinned.snapshot.ranges);if count==0{return true}
		index:=0;for pin,i in app.pinned.snapshot.ranges {if pin.id==app.pinned.selected {index=i;break}}
		if key==.Up{index=max(0,index-1)}else if key==.Down{index=min(count-1,index+1)}else if key==.Home{index=0}else{index=count-1}
		app.pinned.selected=app.pinned.snapshot.ranges[index].id;app.pinned.focus_pending=true;alicorn.invalidate_root(rt,"Pinned header keyboard navigation");return true
	case .Return: pinned_command(app,rt,"go_to_source");return true
	}
	return false
}

pinned_button :: proc(app: ^App, ui: ^alicorn.UI, label,key: string, pin: bridge.Pin_ID=0, width:f32=0, disabled:=false) -> bool {
	selected:=pin!=0 && key=="heading" && pin==app.pinned.selected
	id,activated:=alicorn.button_begin(ui,label,key=alicorn.key_string(key),style=alicorn.layout_style(.Row,width=width,height=28,grow=1 if width==0 else 0),state=alicorn.Button_State{disabled=disabled,selected=selected},variant=.Quiet)
	alicorn.text(ui,label,text_style=alicorn.Text_Style{font_size=12,overflow=.Ellipsis});alicorn.button_end(ui)
	append(&app.pinned.controls,Pinned_Control{id,pin})
	if pin!=0 && key=="heading" && pin==app.pinned.selected {app.pinned.focus_target=id}
	if pin==0 && key=="source" && len(app.pinned.snapshot.ranges)==0 {app.pinned.focus_target=id}
	return activated
}

pinned_find_row :: proc(surface: ^Pinned_Surface, row: int) -> (page: ^Pinned_Page, item: bridge.Pinned_Row, found: bool) {
	for i:=len(surface.pages)-1;i>=0;i-=1 {for candidate in surface.pages[i].window.rows {if candidate.row==row {return &surface.pages[i],candidate,true}}}
	return
}

pinned_load_page :: proc(app: ^App, row,limit: int, anchor:u64=0) -> bool {
	s:=&app.pinned
	result:=bridge.backend_command(&app.backend,"pinned_window",pin_epoch=s.snapshot.epoch,pin_revision=s.snapshot.revision,projection_first=u64(row),projection_limit=u64(min(max(limit,1),256)),max_bytes=64*1024,anchor_byte=anchor,read_latest_after=false)
	defer bridge.backend_command_result_destroy(&result,context.allocator)
	if !result.ok || !result.pinned_window_owned || result.pinned_window.epoch!=s.snapshot.epoch || result.pinned_window.revision!=s.snapshot.revision {
		when ODIN_DEBUG{s.rejected_responses+=1};s.force_refresh=true;set_error(app,result.message);return false
	}
	if len(s.pages)>=16 {bridge.Pinned_Window_Destroy(&s.pages[0].window);delete(s.pages[0].data);ordered_remove(&s.pages,0);when ODIN_DEBUG{s.page_evictions+=1}}
	append(&s.pages,Pinned_Page{result.pinned_window,result.pinned_data})
	result.pinned_window_owned=false;result.pinned_window={};result.pinned_data=nil
	return true
}

pinned_surface_build :: proc(app: ^App, ui: ^alicorn.UI, rt: ^alicorn.Runtime) {
	s:=&app.pinned;clear(&s.controls);s.focus_target=0
	s.runtime=rt
	alicorn.container_begin(ui,.Container,key=alicorn.key_string("pinned-pane"),label="Pinned source references, read only",style=alicorn.layout_style(.Column,grow=1,padding=8,gap=4,clip=true))
	alicorn.text(ui,fmt.tprintf("Pinned · %d ranges",len(s.snapshot.ranges)))
	if gui.row(ui,height=30,gap=4) {
		if pinned_button(app,ui,"Back to source","source") {app.editor_focus_pending=true;s.narrow_source=true;alicorn.invalidate_root(rt,"Pinned returned source focus")}
		if pinned_button(app,ui,"Hide Pinned","hide") {s.visible=false;app.editor_focus_pending=true;alicorn.invalidate_root(rt,"Pinned hidden")}
	}
	if len(s.snapshot.ranges)==0 {alicorn.text(ui,"Select a passage in source, then choose Document → Pin Selection.",text_style=alicorn.Text_Style{overflow=.Wrap});alicorn.container_end(ui);return}
	scale:=editor_text_scale_effective(app)
	if !s.index_ready || s.scale!=scale {pinned_index_reset(s,scale)}
	list:=alicorn.virtual_list_begin_variable(ui,&s.index,key=alicorn.key_string("pinned-scroll"),label="Pinned passages, use Up and Down to traverse headers",style=alicorn.layout_style(grow=1,clip=true),focusable=true)
	s.owner=list.scroll.id
	width:=max(80,list.scroll.viewport_width-20)
	if s.width!=width {s.width=width;pinned_index_reset(s,scale);alicorn.invalidate_root(rt,"Pinned width measurement changed")}
	loaded:=false
	for row:=list.first;row<list.last;row+=1 {
		page,item,found:=pinned_find_row(s,row)
		if !found && !loaded {loaded=true;if pinned_load_page(app,row,min(256,list.last-row+16)) {page,item,found=pinned_find_row(s,row)}}
		if !found {alicorn.text(ui,"Loading pinned source…",style=alicorn.layout_style(height=24*scale));if loaded {alicorn.invalidate_root(rt,"Pinned next bounded page")};continue}
		pin,pin_found:=pinned_pin_at_row(&s.snapshot,row);if !pin_found {continue}
		height:=alicorn.virtual_list_height_index_item_height(&s.index,row)
		if item.kind=="header" {
			_ = alicorn.component_begin(ui,alicorn.key_u64(u64(pin.id)))
			alicorn.container_begin(ui,.Container,label="Pinned source header",style=alicorn.layout_style(.Column,height=height,gap=2,padding=4,clip=true))
			status_label:=""
			if pin.status=="stale" {status_label=" · Source changed"} else if pin.status=="missing" {status_label=" · Source closed"}
			display_path:=pin.relative_path if pin.relative_path!="" else document_title(pin.path)
			label:=fmt.tprintf("%s · Lines %d–%d%s",display_path,pin.first_line+1,pin.first_line+pin.line_count,status_label)
			if pinned_button(app,ui,label,"heading",pin.id) {s.selected=pin.id;pinned_command(app,rt,"go_to_source",pin.id)}
			_ = alicorn.tooltip(ui,pin.path)
			if gui.row(ui,height=28,gap=2) {
				if pinned_button(app,ui,"Go to source","go",pin.id,disabled=pin.status!="current") {pinned_command(app,rt,"go_to_source",pin.id)}
				copy_too_large:=pin.end_byte-pin.start_byte>64*1024
				if pinned_button(app,ui,"Copy excerpt","copy",pin.id,disabled=pin.status!="current"||copy_too_large) {pinned_command(app,rt,"copy",pin.id)}
				if copy_too_large { _=alicorn.tooltip(ui,"Copy requires the complete range and is limited to 64 KiB; nothing will be copied for a larger pin.") }
			}
			if gui.row(ui,height=28,gap=2) {
				if pinned_button(app,ui,"Move up","up",pin.id,disabled=pin.first_row==0) {pinned_command(app,rt,"move",pin.id,-1)}
				if pinned_button(app,ui,"Move down","down",pin.id,disabled=pin.id==s.snapshot.ranges[len(s.snapshot.ranges)-1].id) {pinned_command(app,rt,"move",pin.id,1)}
				if pinned_button(app,ui,"Remove pin","remove",pin.id) {pinned_command(app,rt,"remove",pin.id)}
			}
			alicorn.container_end(ui);alicorn.component_end(ui)
		} else if item.kind=="status" {
			message:="Source changed. Select the current passage in source and pin it again."
			if pin.status=="missing" {message="Source closed. Open it and pin the current passage again."}
			alicorn.text(ui,message,style=alicorn.layout_style(height=height,padding=4,clip=true),text_style=alicorn.Text_Style{overflow=.Wrap})
		} else {
			bytes:=page.data[item.offset:item.offset+item.length]
			line,ok:=editor_project_line(bytes,u64(item.start_byte),u64(item.source_line),context.temp_allocator)
			if !ok {continue}
		defer delete(line.display,context.temp_allocator)
		defer delete(line.display_bytes,context.temp_allocator)
			run,built:=alicorn.runtime_text_run_build(rt,line.display,size=16*scale,max_width=width,font=.Monospace,overflow=.Wrap,allocator=context.temp_allocator,scratch_allocator=alicorn.runtime_scratch_allocator(rt))
			text_height:=24*scale
			if built {text_height=max(text_height,run.height+4);alicorn.text_run_destroy(&run)}
			new_height:=text_height
			if item.has_more || item.has_before {new_height+=30}
			if alicorn.virtual_list_height_index_set_height(&s.index,row,new_height) {alicorn.invalidate_root(rt,"Pinned visible source measured")}
			alicorn.container_begin(ui,.Container,key=alicorn.key_pair(u64(pin.id),u64(item.source_line+1)),style=alicorn.layout_style(.Column,height=new_height,gap=0,clip=true))
			alicorn.text(ui,line.display,style=alicorn.layout_style(height=text_height,width=-1,clip=true),font=.Monospace,text_style=alicorn.Text_Style{font_size=16*scale,overflow=.Wrap})
			if item.has_more || item.has_before {
				if gui.row(ui,height=30,gap=4) {
					if item.has_before && pinned_button(app,ui,"Line start","line-start",pin.id) {_=pinned_load_page(app,row,1);alicorn.invalidate_root(rt,"Pinned long line returned to start")}
					if item.has_more && pinned_button(app,ui,"Continue long line…","line-next",pin.id) {_=pinned_load_page(app,row,1,u64(item.end_byte));alicorn.invalidate_root(rt,"Pinned long line continued")}
				}
			}
			alicorn.container_end(ui)
		}
	}
	alicorn.virtual_list_end(ui,list)
	alicorn.container_end(ui)
}

pinned_after_frame :: proc(app: ^App, rt: ^alicorn.Runtime) {
	s:=&app.pinned;if !s.visible{return}
	if s.restore_pending && s.owner!=0 {_=alicorn.scroll_region_set_offset(rt,s.owner,s.restore_y,"Pinned source anchor restored");s.restore_pending=false}
	if s.focus_pending {
		if s.focus_target!=0 {if alicorn.focus(rt,s.focus_target){s.focus_pending=false}} else {
			for pin in s.snapshot.ranges {if pin.id==s.selected && s.owner!=0 {_=alicorn.virtual_list_variable_ensure_visible(rt,&s.index,s.owner,pin.first_row);alicorn.invalidate_root(rt,"Pinned keyboard target revealed")}}
			if len(s.snapshot.ranges)==0 {app.editor_focus_pending=true;s.focus_pending=false;alicorn.invalidate_root(rt,"Pinned collection is empty; source focus can resume")}
		}
	}
}
