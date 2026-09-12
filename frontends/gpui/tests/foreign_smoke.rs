use scratchpad_gpui::backend::{BackendSession, BackendSessionConfig};
use scratchpad_gpui::protocol::CommandRequest;
use std::fs;
use std::path::PathBuf;
use std::time::Instant;

#[test]
fn rust_calls_go_and_caliber_for_gate_three_slice() {
    let Some(backend_library) = std::env::var_os("SCRATCHPAD_GPUI_BACKEND_LIBRARY") else {
        eprintln!("skipping foreign smoke: SCRATCHPAD_GPUI_BACKEND_LIBRARY is not set");
        return;
    };
    let workspace = tempfile::tempdir().expect("temporary workspace");
    let path = workspace.path().join("note.txt");
    let content = (0..2_000)
        .map(|line| format!("line {line}: immutable visible resource\n"))
        .collect::<String>();
    fs::write(&path, content).expect("write note");
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

    let visible_request = CommandRequest::read_visible_lines(
        document_id.clone(),
        900,
        scratchpad_gpui::protocol::MAX_VISIBLE_LINES,
        scratchpad_gpui::protocol::MAX_VISIBLE_BYTES,
        state.application_revision,
    );
    session
        .dispatch(&visible_request)
        .expect("dispatch visible range through Caliber");
    let visible_response = session
        .pump()
        .expect("pump visible range")
        .expect("visible range response");
    let descriptor = visible_response
        .resource
        .as_ref()
        .expect("visible range resource descriptor");
    assert_eq!(descriptor.document_id, document_id);
    assert!(descriptor.byte_len <= scratchpad_gpui::protocol::MAX_VISIBLE_BYTES);
    let visible = session
        .read_visible_slice(descriptor)
        .expect("map and release immutable visible resource");
    assert_eq!(visible.start_line, 900);
    assert!(visible.end_line > visible.start_line);
    assert!(visible.bytes.len() <= scratchpad_gpui::protocol::MAX_VISIBLE_BYTES);
    assert!(visible.display_text().contains("line 900"));

    let visible_started = Instant::now();
    let mut visible_bytes = visible.bytes.len();
    for iteration in 0..16 {
        let request = CommandRequest::read_visible_lines(
            document_id.clone(),
            900 + iteration,
            scratchpad_gpui::protocol::MAX_VISIBLE_LINES,
            scratchpad_gpui::protocol::MAX_VISIBLE_BYTES,
            state.application_revision,
        );
        session
            .dispatch(&request)
            .expect("dispatch measured visible range");
        let response = session
            .pump()
            .expect("pump measured visible range")
            .expect("measured visible range response");
        let descriptor = response.resource.as_ref().expect("measured resource");
        let slice = session
            .read_visible_slice(descriptor)
            .expect("read measured visible range");
        visible_bytes = slice.bytes.len();
    }
    let visible_latency_ns = visible_started.elapsed().as_nanos() / 16;

    let command_started = Instant::now();
    for _ in 0..16 {
        let request = CommandRequest::snapshot(state.application_revision);
        session
            .dispatch(&request)
            .expect("dispatch measured snapshot");
        let response = session
            .pump()
            .expect("pump measured snapshot")
            .expect("measured snapshot response");
        assert!(response.ok, "measured snapshot response: {response:?}");
        state = session.read_state().expect("read measured state");
    }
    let command_to_state_ns = command_started.elapsed().as_nanos() / 16;

    if let Some(path) = std::env::var_os("SCRATCHPAD_GPUI_MEASURE_PATH") {
        let measurements = serde_json::json!({
            "command_to_state_ns": command_to_state_ns,
            "visible_resource_to_cache_ns": visible_latency_ns,
            "visible_resource_payload_bytes": visible_bytes,
            "visible_resource_max_bytes": scratchpad_gpui::protocol::MAX_VISIBLE_BYTES,
            "sample_count": 16,
            "scope": "Rust test calling the real Go c-shared backend through Caliber; excludes window startup"
        });
        fs::write(
            path,
            serde_json::to_vec_pretty(&measurements).expect("encode measurements"),
        )
        .expect("write measurements");
    }

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
