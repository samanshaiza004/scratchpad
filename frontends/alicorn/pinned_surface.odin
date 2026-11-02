package main

import "core:fmt"
import "core:math"
import alicorn "alicorn:runtime"
import gui "alicorn:ui"
import host "alicorn:native/sdl_gpu"
import bridge "./bridge"

ACTION_PIN_SELECTION :: "source.pin_selection"
ACTION_PINNED_FOCUS :: "view.pinned_focus"
ACTION_PINNED_TOGGLE :: "view.pinned_toggle"
ACTION_PINNED_MOVE_UP :: "pinned.move_up"
ACTION_PINNED_MOVE_DOWN :: "pinned.move_down"
ACTION_PINNED_REMOVE :: "pinned.remove"

PINNED_CARD_HEADER_HEIGHT :: f32(72)
PINNED_CARD_INSET :: f32(10)
PINNED_CARD_GAP :: f32(12)
PINNED_CARD_ACTION_HEIGHT :: f32(40)
PINNED_TEXT_SIZE :: f32(14)

pinned_text_allocation_height :: proc(content_height, minimum, device_scale: f32) -> f32 {
	scale := device_scale if device_scale > 0 else 1
	return max(minimum, f32(math.ceil(content_height*scale))/scale)
}

Pinned_Page :: struct { window: bridge.Pinned_Window, data: []u8 }
Pinned_Control :: struct { node: alicorn.Node_ID, pin: bridge.Pin_ID, key: string }
Pinned_Surface :: struct {
	visible, narrow_source, single_pane, focus_pending, restore_pending, force_refresh: bool,
	context_menu_open: bool,
	action_menu_pin: bridge.Pin_ID,
	runtime: ^alicorn.Runtime,
	snapshot: bridge.Pinned_Snapshot,
	pages: [dynamic]Pinned_Page,
	controls: [dynamic]Pinned_Control,
	selected: bridge.Pin_ID,
	index: alicorn.Virtual_List_Height_Index,
	index_ready, measurement_refresh_pending: bool,
	width, scale, restore_y: f32,
	owner, focus_target: alicorn.Node_ID,
	// Developer/test observability. No polling or dependency tracking.
	rejected_responses, page_evictions, source_invalidations: u64,
	temporary_text_measurement_builds, retained_text_measurement_hits: u64,
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
	estimate := 20*scale
	surface.index_ready = alicorn.virtual_list_height_index_init(&surface.index, surface.snapshot.total_rows, estimate)
	for pin in surface.snapshot.ranges {
		alicorn.virtual_list_height_index_set_height(&surface.index, pin.first_row, PINNED_CARD_HEADER_HEIGHT)
		if pin.status != "current" {
			alicorn.virtual_list_height_index_set_height(&surface.index, pin.first_row+1,
				64*scale + 2*PINNED_CARD_INSET + PINNED_CARD_ACTION_HEIGHT + 1 + PINNED_CARD_GAP)
		} else if pin.line_count > 0 {
			alicorn.virtual_list_height_index_set_height(&surface.index, pin.first_row+1, estimate+PINNED_CARD_INSET)
			last := pin.first_row+pin.line_count
			height := estimate+PINNED_CARD_INSET+PINNED_CARD_ACTION_HEIGHT+1+PINNED_CARD_GAP
			if pin.line_count == 1 { height += PINNED_CARD_INSET }
			alicorn.virtual_list_height_index_set_height(&surface.index, last, height)
		}
	}
	surface.scale = scale
	surface.measurement_refresh_pending = true
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
	if !alicorn.context_menu_is_open(rt) { app.pinned.context_menu_open=false;app.pinned.action_menu_pin=0;return }
	if !alicorn.context_menu_begin(ui,alicorn.key_string("scratchpad-pinned-source-context-menu")) { return }
	if pin_id:=app.pinned.action_menu_pin;pin_id!=0 {
		pin_index:=-1
		for pin,i in app.pinned.snapshot.ranges {if pin.id==pin_id {pin_index=i;break}}
		if pin_index<0 {
			_ = alicorn.context_menu_end(ui)
			alicorn.context_menu_close(rt)
			app.pinned.context_menu_open=false;app.pinned.action_menu_pin=0
			return
		}
		alicorn.context_menu_item(ui,action_id_for(ACTION_PINNED_MOVE_UP),"Move up",pin_index>0)
		alicorn.context_menu_item(ui,action_id_for(ACTION_PINNED_MOVE_DOWN),"Move down",pin_index+1<len(app.pinned.snapshot.ranges))
		alicorn.context_menu_item(ui,action_id_for(ACTION_PINNED_REMOVE),"Remove pin")
		action:=alicorn.context_menu_end(ui)
		if action!=0 {
			app.pinned.action_menu_pin=0;app.pinned.context_menu_open=false
			switch action {
			case action_id_for(ACTION_PINNED_MOVE_UP): pinned_command(app,rt,"move",pin_id,-1)
			case action_id_for(ACTION_PINNED_MOVE_DOWN): pinned_command(app,rt,"move",pin_id,1)
			case action_id_for(ACTION_PINNED_REMOVE): pinned_command(app,rt,"remove",pin_id)
			case:
			}
		}
		return
	}
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

pinned_open_action_menu :: proc(app: ^App, rt: ^alicorn.Runtime, pin: bridge.Pin_ID) {
	if app==nil || rt==nil || pin==0 {return}
	for i:=len(app.pinned.controls)-1;i>=0;i-=1 {
		control:=app.pinned.controls[i]
		if control.pin!=pin || control.key!="more" {continue}
		if info,found:=alicorn.node_info(rt,control.node);found && alicorn.context_menu_open(rt,info.bounds,control.node) {
			app.pinned.context_menu_open=true
			app.pinned.action_menu_pin=pin
			app.pinned.selected=pin
		}
		return
	}
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

// Opt-in native capture fixture: pin a few real source lines once the bounded
// editor window is available. The dedicated workspace keeps this out of user
// data and ordinary startup.
pinned_appearance_fixture_prepare :: proc(app: ^App, rt: ^alicorn.Runtime) {
	if app==nil || rt==nil || !app.appearance_fixture_pinned || app.appearance_fixture_pinned_ready ||
		!app.editor_window_ready || app.editor_scroll_owner==0 { return }
	view_index:=editor_view_find(app.editor_views[:],app.backend.state.active)
	if view_index<0 || app.editor_window.document_id!=app.backend.state.active || len(app.editor_window.source)==0 { return }
	window:=&app.editor_window
	end_offset:=min(len(window.source),240)
	for offset in 80..<end_offset {
		if window.source[offset-1]=='\n' {end_offset=offset;break}
	}
	if end_offset<=0 {return}
	view:=&app.editor_views[view_index]
	view.selection_anchor=window.start_byte
	view.caret_byte=window.start_byte+u64(end_offset)
	_ = alicorn.focus(rt,app.editor_scroll_owner)
	pinned_command(app,rt,"add")
	second_end_offset:=min(len(window.source),end_offset+240)
	for offset in end_offset+80..<second_end_offset {
		if window.source[offset-1]=='\n' {second_end_offset=offset;break}
	}
	if second_end_offset>end_offset {
		view.selection_anchor=window.start_byte+u64(end_offset)
		view.caret_byte=window.start_byte+u64(second_end_offset)
		pinned_command(app,rt,"add")
	}
	app.appearance_fixture_pinned_ready=true
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
	case .Context_Menu:
		if app.pinned.selected!=0 {pinned_open_action_menu(app,rt,app.pinned.selected)}
		return true
	case .Return: pinned_command(app,rt,"go_to_source");return true
	}
	return false
}

pinned_button :: proc(app: ^App, ui: ^alicorn.UI, label, key: string, pin: bridge.Pin_ID=0, width: f32=-1, disabled:=false,
	text_style:=alicorn.Text_Style{font_size=13,overflow=.Ellipsis},
	content_style:=alicorn.Button_Content_Style{horizontal=.Start,vertical=.Center,padding_x=7,padding_y=4},
	grow: f32=0) -> bool {
	id, activated := alicorn.button_begin(ui, label, key=key,
		style=alicorn.layout_style(.Row,width=width,height=32,grow=grow,compress_weight=1),
		state=alicorn.Button_State{disabled=disabled}, variant=.Quiet,
		text_style=text_style, content_style=content_style)
	alicorn.button_end(ui)
	append(&app.pinned.controls, Pinned_Control{id,pin,key})
	if pin!=0 && key=="heading" && pin==app.pinned.selected { app.pinned.focus_target=id }
	if pin==0 && key=="source" && len(app.pinned.snapshot.ranges)==0 { app.pinned.focus_target=id }
	return activated
}

pinned_more_button :: proc(app: ^App, ui: ^alicorn.UI, pin: bridge.Pin_ID) -> bool {
	id, clicked := alicorn.button_begin(ui, "⋯", key="pinned-more",
		style=alicorn.layout_style(.Row,width=32,height=32), variant=.Quiet,
		text_style=alicorn.Text_Style{font_size=20},
		content_style=alicorn.button_content_style(.Center,padding_x=0,padding_y=0))
	alicorn.button_end(ui)
	alicorn.semantic_description(ui, .Button, "More actions", actions={.Press,.Focus})
	append(&app.pinned.controls, Pinned_Control{id,pin,"more"})
	if clicked { pinned_open_action_menu(app,ui.runtime,pin) }
	return clicked
}

pinned_hide_button :: proc(app: ^App, ui: ^alicorn.UI, rt: ^alicorn.Runtime) {
	id,clicked:=alicorn.icon_button(ui,"Hide Pinned",.Close,key=alicorn.key_string("pinned-hide"),style=alicorn.layout_style(.Row,width=28,height=28),variant=.Quiet)
	append(&app.pinned.controls,Pinned_Control{id,0,"hide"})
	if clicked {app.pinned.visible=false;app.editor_focus_pending=true;alicorn.invalidate_root(rt,"Pinned hidden")}
	if len(app.pinned.snapshot.ranges)==0 {app.pinned.focus_target=id}
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

// Each logical row keeps its own identity and bounded text product. The flat
// paper and side borders abut across virtual rows, so one pin reads as one card.
pinned_card_row_begin :: proc(app: ^App, ui: ^alicorn.UI, pin: bridge.Pinned_Range, height: f32, last: bool) {
	gap := PINNED_CARD_GAP if last else 0
	alicorn.container_begin(ui, .Container, label="Pinned card row",
		style=alicorn.layout_style(.Column,height=height+gap,clip=true))
	alicorn.surface_begin(ui, alicorn.surface_extension_color_role(scratchpad_editor_paper_surface_role()),
		label="Pinned source paper", style=alicorn.layout_style(.Row,height=height,clip=true))
	rail := alicorn.style_color(ui, .Accent) if pin.id==app.pinned.selected else alicorn.style_color(ui, .Border)
	alicorn.container_begin(ui, .Container, label="Pinned selection edge", style=alicorn.layout_style(width=3,height=height), color=rail)
	alicorn.container_end(ui)
	alicorn.container_begin(ui, .Container, label="Pinned card content", style=alicorn.layout_style(.Column,grow=1,height=height,clip=true))
}

pinned_card_row_end :: proc(ui: ^alicorn.UI, height: f32, last: bool) {
	alicorn.container_end(ui)
	alicorn.container_begin(ui, .Container, label="Pinned card edge", style=alicorn.layout_style(width=1,height=height), color=alicorn.style_color(ui,.Border))
	alicorn.container_end(ui)
	alicorn.surface_end(ui)
	if last {
		alicorn.container_begin(ui, .Container, label="Pinned card spacing", style=alicorn.layout_style(height=PINNED_CARD_GAP))
		alicorn.container_end(ui)
	}
	alicorn.container_end(ui)
}

pinned_card_space :: proc(ui: ^alicorn.UI, height: f32, key: string="space", loc:=#caller_location) {
	alicorn.container_begin(ui, .Container, key=key, style=alicorn.layout_style(height=height,width=height), loc=loc)
	alicorn.container_end(ui)
}

pinned_card_rule :: proc(ui: ^alicorn.UI, loc:=#caller_location) {
	alicorn.container_begin(ui, .Container, label="Pinned card rule", style=alicorn.layout_style(height=1), color=alicorn.style_color(ui,.Border),loc=loc)
	alicorn.container_end(ui)
}

pinned_card_actions :: proc(app: ^App, ui: ^alicorn.UI, pin: bridge.Pinned_Range) {
	pinned_card_space(ui, 8)
	if gui.row(ui, label="Pinned source actions", height=32, gap=4, align=.Center) {
		pinned_card_space(ui, PINNED_CARD_INSET)
		if pinned_button(app,ui,"Go to source","go",pin.id,width=112,disabled=pin.status!="current") { pinned_command(app,ui.runtime,"go_to_source",pin.id) }
		alicorn.container_begin(ui, .Container, style=alicorn.layout_style(grow=1))
		alicorn.container_end(ui)
		copy_too_large := pin.end_byte-pin.start_byte>64*1024
		if pinned_button(app,ui,"Copy","copy",pin.id,width=58,disabled=pin.status!="current"||copy_too_large) { pinned_command(app,ui.runtime,"copy",pin.id) }
		if copy_too_large { alicorn.tooltip(ui,"Copy requires the complete range and is limited to 64 KiB; nothing will be copied for a larger pin.") }
		pinned_card_space(ui, PINNED_CARD_INSET)
	}
}

pinned_surface_build :: proc(app: ^App, ui: ^alicorn.UI, rt: ^alicorn.Runtime, dpi_scale: f32) {
	s := &app.pinned
	clear(&s.controls)
	s.focus_target = 0
	s.runtime = rt
	if gui.layout(ui, alicorn.layout_style(.Column,grow=1,padding=10,gap=8,clip=true),
		key="pinned-pane", label="Pinned source references, read only") {
		if gui.row(ui,label="pinned-pane-header",height=32,gap=6,align=.Center) {
			gui.text(ui,"Pinned",style=alicorn.layout_style(.Row,grow=1),text_style=alicorn.Text_Style{font_size=17,font_weight=alicorn.FONT_WEIGHT_MEDIUM})
			reference_word := "references" if len(s.snapshot.ranges)!=1 else "reference"
			gui.text(ui,fmt.tprintf("%d %s",len(s.snapshot.ranges),reference_word),text_style=alicorn.Text_Style{font_size=12},color=alicorn.style_color(ui,.Muted_Text))
			if s.single_pane && pinned_button(app,ui,"Back to source","source",width=112) { app.editor_focus_pending=true; s.narrow_source=true; alicorn.invalidate_root(rt,"Pinned returned source focus") }
			pinned_hide_button(app,ui,rt)
		}
		if len(s.snapshot.ranges)==0 {
			gui.text(ui,"Select a passage in source, then choose Document → Pin Selection.",style=alicorn.layout_style(padding=8),text_style=alicorn.Text_Style{overflow=.Wrap},color=alicorn.style_color(ui,.Muted_Text))
			return
		}
		scale := editor_text_scale_effective(app)
		if !s.index_ready || s.scale!=scale { pinned_index_reset(s,scale) }
		list := alicorn.virtual_list_begin_variable(ui,&s.index,key="pinned-scroll",label="Pinned passages, use Up and Down to traverse headers",style=alicorn.layout_style(grow=1,clip=true),focusable=true)
		s.owner = list.scroll.id
		// Shape against the actual paper width, including edges and insets.
		width := max(80,list.scroll.viewport_width)
		if s.width!=width { s.width=width; pinned_index_reset(s,scale); alicorn.invalidate_root(rt,"Pinned width measurement changed") }
		content_width := max(width-4-2*PINNED_CARD_INSET,1)
		loaded := false
		for row:=list.first; row<list.last; row+=1 {
			page,item,found := pinned_find_row(s,row)
			if !found && !loaded { loaded=true; if pinned_load_page(app,row,min(256,list.last-row+16)) { page,item,found=pinned_find_row(s,row) } }
			if !found {
				gui.text(ui,"Loading pinned source…",key=u64(row),style=alicorn.layout_style(height=alicorn.virtual_list_height_index_item_height(&s.index,row)))
				if loaded { alicorn.invalidate_root(rt,"Pinned next bounded page") }
				continue
			}
			pin,pin_found := pinned_pin_at_row(&s.snapshot,row)
			if !pin_found { continue }
			// Give every row, surface, action and static text a stable scope.
			alicorn.component_begin(ui,alicorn.key_pair(u64(pin.id),u64(row-pin.first_row)))
			defer alicorn.component_end(ui)
			paper_scope := alicorn.style_environment_push(ui,alicorn.Style_Environment{theme=app.editor_theme})
			defer alicorn.style_environment_pop(ui,paper_scope)
			if item.kind=="header" {
				pinned_card_row_begin(app,ui,pin,PINNED_CARD_HEADER_HEIGHT,false)
				pinned_card_rule(ui)
				if gui.layout(ui,alicorn.layout_style(.Column,height=70,padding=10,gap=2),label="Pinned reference heading") {
					display_name := document_title(pin.path)
					if display_name=="" { display_name=pin.relative_path }
					status_suffix := ""
					if pin.status=="stale" { status_suffix=" · Source changed" } else if pin.status=="missing" { status_suffix=" · Source closed" }
					status_label := fmt.tprintf("Lines %d–%d%s",pin.first_line+1,pin.first_line+pin.line_count,status_suffix)
					if gui.row(ui,height=32,gap=4,align=.Center) {
						gui.icon(ui,.File,size=16)
						if pinned_button(app,ui,display_name,"heading",pin.id,grow=1,
							text_style=alicorn.Text_Style{font_size=14,font_weight=alicorn.FONT_WEIGHT_MEDIUM,overflow=.Ellipsis},
							content_style=alicorn.button_content_style(.Start,padding_x=0,padding_y=0)) { s.selected=pin.id; pinned_command(app,rt,"go_to_source",pin.id) }
						alicorn.semantic_description(ui,.Button,display_name,description=status_label,actions={.Press,.Focus})
						alicorn.tooltip(ui,pin.path)
						if pinned_more_button(app,ui,pin.id) { s.selected=pin.id }
					}
					gui.text(ui,status_label,style=alicorn.layout_style(height=16,clip=true),text_style=alicorn.Text_Style{font_size=12,overflow=.Ellipsis},color=alicorn.style_color(ui,.Muted_Text))
				}
				pinned_card_rule(ui)
				pinned_card_row_end(ui,PINNED_CARD_HEADER_HEIGHT,false)
				continue
			}
			is_status := item.kind=="status"
			last := is_status || row==pin.first_row+pin.line_count
			first := row==pin.first_row+1
			text := "Source changed. Select the current passage in source and pin it again."
			font := alicorn.Font_Role.UI if is_status else alicorn.Font_Role.Monospace
			text_key := alicorn.key_pair(u64(pin.id),u64(item.start_byte))
			line: Editor_Display_Line
			if is_status {
				if pin.status=="missing" { text="Source closed. Open it and pin the current passage again." }
			} else {
				bytes := page.data[item.offset:item.offset+item.length]
				ok: bool
				line,ok = editor_project_line(bytes,u64(item.start_byte),u64(item.source_line),context.temp_allocator)
				if !ok { continue }
				text = line.display
			}
			defer delete(line.display,context.temp_allocator)
			defer delete(line.display_bytes,context.temp_allocator)
			text_height := 20*scale
			used_retained_measurement := false
			if !s.measurement_refresh_pending {
				if text_node,exists := alicorn.node_by_key(rt,text_key,.Text); exists {
					if info,valid := alicorn.node_info(rt,text_node); valid && info.text_geometry_available && abs(info.bounds.w-content_width)<0.5 {
						text_height=pinned_text_allocation_height(info.text_content_height,text_height,dpi_scale)
						used_retained_measurement=true
						when ODIN_DEBUG { s.retained_text_measurement_hits+=1 }
					}
				}
			}
			if !used_retained_measurement {
				when ODIN_DEBUG { s.temporary_text_measurement_builds+=1 }
				run,built := alicorn.runtime_text_run_build(rt,text,size=PINNED_TEXT_SIZE*scale,max_width=content_width,font=font,overflow=.Wrap,allocator=context.temp_allocator,scratch_allocator=alicorn.runtime_scratch_allocator(rt))
				if built { text_height=pinned_text_allocation_height(run.height,text_height,dpi_scale); alicorn.text_run_destroy(&run) }
			}
			top := PINNED_CARD_INSET if first else 0
			bottom := PINNED_CARD_INSET+1 if last else 0
			continuation := f32(36) if item.has_more||item.has_before else 0
			actions := PINNED_CARD_ACTION_HEIGHT if last else 0
			paper_height := top+text_height+continuation+actions+bottom
			row_height := paper_height+(PINNED_CARD_GAP if last else 0)
			if alicorn.virtual_list_height_index_set_height(&s.index,row,row_height) { alicorn.invalidate_root(rt,"Pinned visible source measured") }
			pinned_card_row_begin(app,ui,pin,paper_height,last)
			if first { pinned_card_space(ui,top) }
			if gui.row(ui,label="Pinned excerpt line",height=text_height) {
				pinned_card_space(ui,PINNED_CARD_INSET)
				gui.text(ui,text,key=text_key,style=alicorn.layout_style(grow=1,height=text_height,clip=true),font=font,text_style=alicorn.Text_Style{font_size=PINNED_TEXT_SIZE*scale,overflow=.Wrap})
				pinned_card_space(ui,PINNED_CARD_INSET)
			}
			if continuation>0 {
				pinned_card_space(ui,4)
				if gui.row(ui,height=32,gap=4) {
					pinned_card_space(ui,PINNED_CARD_INSET)
					if item.has_before && pinned_button(app,ui,"Line start","line-start",pin.id,width=80) { pinned_load_page(app,row,1); alicorn.invalidate_root(rt,"Pinned long line returned to start") }
					if item.has_more && pinned_button(app,ui,"Continue line…","line-next",pin.id,width=130) { pinned_load_page(app,row,1,u64(item.end_byte)); alicorn.invalidate_root(rt,"Pinned long line continued") }
				}
			}
			if last {
				pinned_card_actions(app,ui,pin)
				pinned_card_space(ui,PINNED_CARD_INSET)
				pinned_card_rule(ui)
			}
			pinned_card_row_end(ui,paper_height,last)
		}
		alicorn.virtual_list_end(ui,list)
	}
}

pinned_after_frame :: proc(app: ^App, rt: ^alicorn.Runtime) {
	s:=&app.pinned;if !s.visible{return}
	s.measurement_refresh_pending=false
	if s.restore_pending && s.owner!=0 {_=alicorn.scroll_region_set_offset(rt,s.owner,s.restore_y,"Pinned source anchor restored");s.restore_pending=false}
	if s.focus_pending {
		if s.focus_target!=0 {if alicorn.focus(rt,s.focus_target){s.focus_pending=false}} else {
			for pin in s.snapshot.ranges {if pin.id==s.selected && s.owner!=0 {_=alicorn.virtual_list_variable_ensure_visible(rt,&s.index,s.owner,pin.first_row);alicorn.invalidate_root(rt,"Pinned keyboard target revealed")}}
			if len(s.snapshot.ranges)==0 {app.editor_focus_pending=true;s.focus_pending=false;alicorn.invalidate_root(rt,"Pinned collection is empty; source focus can resume")}
		}
	}
}
