use scratchpad_gpui::backend::{BackendSession, BackendSessionConfig};
use scratchpad_gpui::protocol::CommandRequest;
use std::fs;
use std::path::PathBuf;
use std::time::Instant;

fn percentile_ns(samples: &[u128], percentile: usize) -> u64 {
    let mut sorted = samples.to_vec();
    sorted.sort_unstable();
    let rank = (sorted.len() * percentile).div_ceil(100).saturating_sub(1);
    sorted[rank] as u64
}

fn latency_summary(samples: &[u128]) -> serde_json::Value {
    serde_json::json!({
        "median_ns": percentile_ns(samples, 50),
        "p95_ns": percentile_ns(samples, 95),
    })
}

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

    const SAMPLE_COUNT: usize = 64;
    let mut visible_total_samples = Vec::with_capacity(SAMPLE_COUNT);
    let mut dispatch_samples = Vec::with_capacity(SAMPLE_COUNT);
    let mut pump_samples = Vec::with_capacity(SAMPLE_COUNT);
    let mut resource_copy_samples = Vec::with_capacity(SAMPLE_COUNT);
    let mut slice_decode_samples = Vec::with_capacity(SAMPLE_COUNT);
    let mut visible_bytes = visible.bytes.len();
    for iteration in 0..SAMPLE_COUNT {
        let request = CommandRequest::read_visible_lines(
            document_id.clone(),
            900 + iteration,
            scratchpad_gpui::protocol::MAX_VISIBLE_LINES,
            scratchpad_gpui::protocol::MAX_VISIBLE_BYTES,
            state.application_revision,
        );
        let total_started = Instant::now();
        let dispatch_started = Instant::now();
        session
            .dispatch(&request)
            .expect("dispatch measured visible range");
        dispatch_samples.push(dispatch_started.elapsed().as_nanos());
        let pump_started = Instant::now();
        let response = session
            .pump()
            .expect("pump measured visible range")
            .expect("measured visible range response");
        pump_samples.push(pump_started.elapsed().as_nanos());
        let descriptor = response.resource.as_ref().expect("measured resource");
        let resource_copy_started = Instant::now();
        let bytes = session
            .read_visible_resource_copy(descriptor)
            .expect("map and copy measured visible range");
        resource_copy_samples.push(resource_copy_started.elapsed().as_nanos());
        let decode_started = Instant::now();
        let slice = scratchpad_gpui::protocol::VisibleTextSlice::decode(&bytes, descriptor)
            .expect("decode measured visible range");
        slice_decode_samples.push(decode_started.elapsed().as_nanos());
        visible_bytes = slice.bytes.len();
        visible_total_samples.push(total_started.elapsed().as_nanos());
    }

    let mut command_to_state_samples = Vec::with_capacity(SAMPLE_COUNT);
    let command_started = Instant::now();
    for _ in 0..SAMPLE_COUNT {
        let sample_started = Instant::now();
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
        command_to_state_samples.push(sample_started.elapsed().as_nanos());
    }
    let command_to_state_ns = command_started.elapsed().as_nanos() / SAMPLE_COUNT as u128;

    if let Some(path) = std::env::var_os("SCRATCHPAD_GPUI_MEASURE_PATH") {
        let measurements = serde_json::json!({
            "command_to_state_ns": command_to_state_ns,
            "latency_ns": {
                "command_to_state": latency_summary(&command_to_state_samples),
                "visible_resource_roundtrip": latency_summary(&visible_total_samples),
                "rust_encode_dispatch": latency_summary(&dispatch_samples),
                "go_pump_and_response_decode": latency_summary(&pump_samples),
                "caliber_map_copy_release": latency_summary(&resource_copy_samples),
                "spvs_decode_cache": latency_summary(&slice_decode_samples),
            },
            "visible_resource_payload_bytes": visible_bytes,
            "visible_resource_max_bytes": scratchpad_gpui::protocol::MAX_VISIBLE_BYTES,
            "sample_count": SAMPLE_COUNT,
            "scope": "Rust test calling the real Go c-shared backend through Caliber; excludes window startup; pump stage includes Go decode/extraction/resource publish and response JSON"
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
