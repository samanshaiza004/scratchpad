use scratchpad_gpui::backend::{BackendSession, BackendSessionConfig};
use scratchpad_gpui::protocol::CommandRequest;
use std::fs;
use std::path::PathBuf;

#[test]
fn rust_calls_go_and_caliber_for_the_gate_one_slice() {
    let Some(backend_library) = std::env::var_os("SCRATCHPAD_GPUI_BACKEND_LIBRARY") else {
        eprintln!("skipping foreign smoke: SCRATCHPAD_GPUI_BACKEND_LIBRARY is not set");
        return;
    };
    let workspace = tempfile::tempdir().expect("temporary workspace");
    let path = workspace.path().join("note.txt");
    fs::write(&path, "hello from the foreign boundary\n").expect("write note");
    let mut session = BackendSession::open(BackendSessionConfig {
        backend_library: Some(PathBuf::from(backend_library)),
        workspace_path: Some(workspace.path().to_path_buf()),
    })
    .expect("start Go backend and Caliber context");
    let start = session.take_start_response().expect("start response");
    assert!(start.ok, "start response: {start:?}");
    let mut state = session.read_state().expect("initial state");

    let list = CommandRequest::list_directory(None, state.application_revision).expect("list");
    session
        .dispatch(&list)
        .expect("dispatch list through Caliber");
    let listing = session.pump().expect("pump list").expect("list response");
    assert!(listing.ok, "list response: {listing:?}");
    state = session.read_state().expect("state after list");

    let open = CommandRequest::open_path(&path, state.application_revision).expect("open");
    session
        .dispatch(&open)
        .expect("dispatch open through Caliber");
    let opened = session.pump().expect("pump open").expect("open response");
    assert!(opened.ok, "open response: {opened:?}");
    state = session.read_state().expect("state after open");
    let document_id = state.active.clone();

    let save = CommandRequest::save_document(document_id.clone(), state.application_revision);
    session
        .dispatch(&save)
        .expect("dispatch save through Caliber");
    let saved = session.pump().expect("pump save").expect("save response");
    assert!(saved.ok, "save response: {saved:?}");
    state = session.read_state().expect("state after save");

    let close = CommandRequest::close_document(document_id, true, state.application_revision);
    session
        .dispatch(&close)
        .expect("dispatch close through Caliber");
    let closed = session.pump().expect("pump close").expect("close response");
    assert!(closed.ok, "close response: {closed:?}");

    let stopped = session
        .shutdown()
        .expect("shutdown")
        .expect("stop response");
    assert!(stopped.ok, "stop response: {stopped:?}");
}
