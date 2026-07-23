use super::*;

#[derive(Default)]
struct DrainWriterState {
    bytes: Vec<u8>,
    parsed_through: usize,
    cleanup_ack_after_drain: bool,
    shutdown_ack_after_drain: bool,
}

#[derive(Clone)]
pub(super) struct CleanupDrainProbe {
    pub(super) directory: std::path::PathBuf,
}

impl CleanupDrainProbe {
    fn path(&self, leaf: &str) -> std::path::PathBuf {
        self.directory.join(leaf)
    }

    fn pid(&self, leaf: &str) -> u32 {
        std::fs::read_to_string(self.path(leaf))
            .unwrap_or_else(|_| panic!("missing cleanup lifecycle PID marker: {leaf}"))
            .trim()
            .parse::<u32>()
            .unwrap_or_else(|_| panic!("invalid cleanup lifecycle PID marker: {leaf}"))
    }

    fn assert_fully_drained_at_ack(&self) {
        assert!(
            self.path("fake-claude-io-worker.waiting").exists(),
            "cleanup acknowledgement preceded the deterministic I/O join gate"
        );
        assert!(
            self.path("fake-claude-io-source.closed").exists(),
            "cleanup acknowledgement preceded stdout/stderr source closure"
        );
        assert!(
            self.path("fake-claude-descendant.pipe-closed").exists(),
            "cleanup acknowledgement preceded retained descendant pipe closure"
        );
        self.assert_transport_workers_joined();
        assert!(
            self.path("fake-claude-child.closed").exists(),
            "cleanup acknowledgement preceded the root child's close boundary"
        );
        assert!(
            !rpc_process_exists(self.pid("fake-claude-root.pid")),
            "cleanup acknowledgement preceded root process exit"
        );
        assert!(
            !rpc_process_exists(self.pid("fake-claude-descendant.pid")),
            "cleanup acknowledgement preceded descendant process exit"
        );
    }

    pub(super) fn assert_transport_workers_joined(&self) {
        assert!(
            self.path("fake-claude-transport-workers.joined").exists(),
            "RPC completion preceded the actual transport-worker join seam"
        );
    }
}

#[derive(Clone)]
pub(super) struct DrainAssertingWriter {
    state: std::sync::Arc<std::sync::Mutex<DrainWriterState>>,
    cleanup_request_id: Option<String>,
    shutdown_probe: Option<CleanupDrainProbe>,
    cleanup_probe: Option<CleanupDrainProbe>,
}

impl DrainAssertingWriter {
    pub(super) fn new(
        cleanup_request_id: Option<&str>,
        shutdown_probe: Option<CleanupDrainProbe>,
        cleanup_probe: Option<CleanupDrainProbe>,
    ) -> Self {
        Self {
            state: std::sync::Arc::new(std::sync::Mutex::new(DrainWriterState::default())),
            cleanup_request_id: cleanup_request_id.map(str::to_string),
            shutdown_probe,
            cleanup_probe,
        }
    }

    pub(super) fn frames(&self) -> Vec<Value> {
        let bytes = self.state.lock().unwrap().bytes.clone();
        rpc_output(bytes)
    }

    pub(super) fn cleanup_ack_after_drain(&self) -> bool {
        self.state.lock().unwrap().cleanup_ack_after_drain
    }

    pub(super) fn shutdown_ack_after_drain(&self) -> bool {
        self.state.lock().unwrap().shutdown_ack_after_drain
    }

    fn inspect_complete_frames(&self, state: &mut DrainWriterState) {
        while let Some(relative_end) = state.bytes[state.parsed_through..]
            .iter()
            .position(|byte| *byte == b'\n')
        {
            let end = state.parsed_through + relative_end;
            let frame = serde_json::from_slice::<Value>(&state.bytes[state.parsed_through..end])
                .expect("RPC writer emitted valid JSON");
            state.parsed_through = end + 1;
            if frame.pointer("/result/status") == Some(&json!("cleaned")) {
                assert_eq!(
                    frame["id"],
                    self.cleanup_request_id
                        .as_deref()
                        .expect("cleanup acknowledgement was expected")
                );
                self.cleanup_probe
                    .as_ref()
                    .expect("cleanup acknowledgement requires a drain probe")
                    .assert_fully_drained_at_ack();
                state.cleanup_ack_after_drain = true;
            }
            if frame.pointer("/result/status") == Some(&json!("shutdown")) {
                if let Some(probe) = self.shutdown_probe.as_ref() {
                    let pid = probe.pid("fake-claude-descendant.pid");
                    assert!(
                        !rpc_process_exists(pid),
                        "shutdown acknowledgement preceded descendant process exit"
                    );
                    probe.assert_transport_workers_joined();
                }
                state.shutdown_ack_after_drain = true;
            }
        }
    }
}

#[cfg(unix)]
pub(super) fn arm_cleanup_io_join_gate(
    probe: CleanupDrainProbe,
    writer: &DrainAssertingWriter,
) -> std::thread::JoinHandle<()> {
    std::fs::write(probe.path("fake-claude-io-join.enabled"), "enabled").unwrap();
    let writer_state = std::sync::Arc::clone(&writer.state);
    std::thread::spawn(move || {
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
        while !(probe.path("fake-claude-io-worker.waiting").exists()
            && probe.path("fake-claude-descendant.pipe-open").exists())
        {
            assert!(
                std::time::Instant::now() < deadline,
                "cleanup fixture did not reach its deterministic I/O gate"
            );
            std::thread::sleep(std::time::Duration::from_millis(2));
        }
        assert!(
            !writer_state.lock().unwrap().cleanup_ack_after_drain,
            "cleanup_early_ack mutation crossed the I/O gate"
        );
        std::fs::write(probe.path("fake-claude-io-join.release"), "release").unwrap();
        while !(probe.path("fake-claude-io-source.closed").exists()
            && probe.path("fake-claude-descendant.pipe-closed").exists())
        {
            assert!(
                std::time::Instant::now() < deadline,
                "cleanup fixture did not close every retained I/O source"
            );
            std::thread::sleep(std::time::Duration::from_millis(2));
        }
    })
}

impl std::io::Write for DrainAssertingWriter {
    fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
        let state_handle = std::sync::Arc::clone(&self.state);
        let mut state = state_handle.lock().unwrap();
        state.bytes.extend_from_slice(bytes);
        self.inspect_complete_frames(&mut state);
        Ok(bytes.len())
    }

    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

pub(super) fn assert_stream_contract(
    frames: &[Value],
    request_id: &str,
    session_id: &str,
    expected_output: &str,
) -> String {
    let request_frames = frames
        .iter()
        .filter(|frame| frame["id"] == request_id)
        .collect::<Vec<_>>();
    assert!(request_frames.len() >= 5);
    for (index, frame) in request_frames.iter().enumerate() {
        assert_eq!(frame["sequence"], json!(index + 1));
    }
    let terminal = request_frames.last().unwrap();
    assert_eq!(terminal["kind"], "terminal");
    assert_eq!(terminal["result"]["nativeSessionId"], session_id);
    assert_eq!(terminal["result"]["sessionId"], session_id);
    assert_eq!(terminal["result"]["threadId"], session_id);
    assert_eq!(terminal["result"]["output"], expected_output);
    let turn_id = terminal["result"]["turnId"]
        .as_str()
        .filter(|value| !value.trim().is_empty() && value.len() <= 512)
        .expect("bounded terminal turn ID")
        .to_string();
    let events = request_frames[..request_frames.len() - 1]
        .iter()
        .map(|frame| frame.get("event").expect("stream event frame"))
        .collect::<Vec<_>>();
    assert_eq!(events.first().unwrap()["event"], "dispatch.turn.started");
    assert_eq!(events.last().unwrap()["event"], "dispatch.turn.completed");
    let mut chunks = String::new();
    let mut completed = None;
    for event in events {
        assert_eq!(event["sessionId"], session_id);
        assert_eq!(event["turnId"], turn_id);
        assert!(event["sessionId"].as_str().unwrap().len() <= 512);
        if event["event"] == "agent.message.chunk" {
            let text = event["payload"]["text"]
                .as_str()
                .filter(|text| !text.is_empty())
                .expect("non-empty public chunk");
            chunks.push_str(text);
        }
        if event["event"] == "agent.message.completed" {
            assert!(completed.is_none(), "duplicate completed event");
            completed = event["payload"]["text"].as_str().map(str::to_string);
        }
    }
    assert_eq!(chunks, expected_output);
    assert_eq!(completed.as_deref(), Some(expected_output));
    turn_id
}
