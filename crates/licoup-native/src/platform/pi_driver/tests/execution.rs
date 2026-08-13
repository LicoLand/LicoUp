use super::*;

#[test]
fn fake_child_completes_rpc_with_bounded_stderr_and_native_session() {
    let (directory, executable) = compile_fake_pi("lico-pi-rpc-fake");
    let result = execute(
        executable.to_string_lossy().as_ref(),
        &json!({}),
        "private-pi-prompt",
        "",
        Some(directory.as_path()),
        10_000,
        Some(1024 * 1024),
        1024,
    );
    assert!(result.ok, "pi rpc failure: {:?}", result.error);
    assert_eq!(result.output, "pi-ok");
    assert_eq!(result.session_id, "pi-native-1");
    assert!(result.stderr_truncated);
    let _ = fs::remove_dir_all(directory);
}

#[test]
fn fake_child_emits_incremental_text_with_bound_session_identity() {
    let (directory, executable) = compile_fake_pi("lico-pi-rpc-stream");
    let captured = std::sync::Arc::new(std::sync::Mutex::new(Vec::<Value>::new()));
    let target = std::sync::Arc::clone(&captured);
    super::super::super::turn_event_emit::install_stream_sink(Box::new(move |event| {
        target.lock().unwrap().push(event);
    }));
    let _guard = super::super::super::turn_event_emit::StreamSinkGuard;
    let result = execute(
        executable.to_string_lossy().as_ref(),
        &json!({}),
        "stream",
        "",
        Some(directory.as_path()),
        10_000,
        Some(1024 * 1024),
        1024,
    );
    assert!(result.ok, "pi rpc failure: {:?}", result.error);
    let events = captured.lock().unwrap();
    let chunks = events
        .iter()
        .filter(|event| event["event"] == "agent.message.chunk")
        .collect::<Vec<_>>();
    assert_eq!(chunks.len(), 2);
    assert!(
        chunks
            .iter()
            .all(|event| event["sessionId"] == "pi-native-1")
    );
    assert_eq!(chunks[0]["payload"]["text"], "one");
    assert_eq!(chunks[1]["payload"]["text"], "-two");
    drop(events);
    let _ = fs::remove_dir_all(directory);
}

#[test]
fn fake_child_acknowledges_native_guidance_during_the_active_turn() {
    let (directory, executable) = compile_fake_pi("lico-pi-rpc-native-steer");
    let (binding_sender, binding_receiver) = std::sync::mpsc::sync_channel(1);
    let working_directory = directory.clone();
    let executable = executable.to_string_lossy().to_string();
    let run = std::thread::spawn(move || {
        super::super::super::turn_event_emit::install_stream_sink(Box::new(move |event| {
            if event["event"] == "dispatch.turn.bound" {
                let _ = binding_sender.try_send((
                    event["sessionId"].as_str().unwrap_or_default().to_string(),
                    event["turnId"].as_str().unwrap_or_default().to_string(),
                ));
            }
        }));
        let _guard = super::super::super::turn_event_emit::StreamSinkGuard;
        execute(
            &executable,
            &json!({}),
            "steer-case",
            "",
            Some(working_directory.as_path()),
            10_000,
            Some(1024 * 1024),
            1024,
        )
    });
    let (session_id, turn_id) = binding_receiver
        .recv_timeout(std::time::Duration::from_secs(5))
        .expect("Pi should publish its exact active turn binding");
    assert_eq!(session_id, "pi-native-steer-1");
    assert_eq!(
        steer(&session_id, &turn_id, "pi-native-steer-guidance"),
        ControlDisposition::Accepted
    );
    let result = run.join().unwrap();
    assert!(result.ok, "Pi RPC failure: {:?}", result.error);
    assert_eq!(result.output, "pi-guided");
    assert_eq!(result.session_id, session_id);
    assert_eq!(result.turn_id, turn_id);
    let _ = fs::remove_dir_all(directory);
}

#[test]
fn stalled_rpc_turn_times_out_and_cleans_up_the_child_tree() {
    let (directory, executable) = compile_fake_pi("lico-pi-rpc-timeout");
    let result = execute(
        executable.to_string_lossy().as_ref(),
        &json!({}),
        "timeout-case",
        "",
        Some(directory.as_path()),
        50,
        Some(1024 * 1024),
        1024,
    );
    assert!(!result.ok);
    assert_eq!(result.error.unwrap().code, "pi_rpc_timeout");
    let _ = fs::remove_dir_all(directory);
}
