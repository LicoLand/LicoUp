use super::*;
use std::io::{Read, Write};
use std::net::{Shutdown, TcpListener};
use std::sync::{Arc, Condvar, Mutex};

#[test]
fn request_body_keeps_private_values_in_http_json_not_process_metadata() {
    let mut config = test_config("private prompt", "");
    config.model = Some("provider/model".into());
    config.runtime_agent = Some("reviewer".into());
    config.reasoning_effort = Some("high".into());
    config.private_instructions = Some("private system guidance".into());
    let body = build_message_body(&config);
    assert_eq!(body["parts"][0]["text"], "private prompt");
    assert_eq!(body["model"]["providerID"], "provider");
    assert_eq!(body["model"]["modelID"], "model");
    assert_eq!(body["agent"], "reviewer");
    assert_eq!(body["variant"], "high");
    assert_eq!(body["system"], "private system guidance");
}

#[test]
fn free_gateway_routes_keep_the_nested_kilo_model_identifier() {
    let mut config = test_config("probe", "");
    config.model = Some("kilo-auto/free".into());
    let auto = build_message_body(&config);
    assert_eq!(auto["model"]["providerID"], "kilo");
    assert_eq!(auto["model"]["modelID"], "kilo-auto/free");

    config.model = Some("nvidia/nemotron-3-super-120b-a12b:free".into());
    let tagged = build_message_body(&config);
    assert_eq!(tagged["model"]["providerID"], "kilo");
    assert_eq!(
        tagged["model"]["modelID"],
        "nvidia/nemotron-3-super-120b-a12b:free"
    );
}

#[test]
fn expired_deadline_prevents_http_request() {
    let failure =
        wait_post_json("http://invalid.test", &json!({}), Some(Instant::now())).unwrap_err();
    assert_eq!(failure.code, "acp_protocol_timeout");

    // An expired deadline fails before any network I/O; no deadline (timeoutMs
    // 0 contract) must not be mistaken for an expired one and proceeds to the
    // transport instead.
    let failure = wait_post_json("http://invalid.test", &json!({}), None).unwrap_err();
    assert_eq!(failure.code, "acp_protocol_write_failed");
}

#[test]
fn exact_resume_does_not_relabel_terminal_http_output_as_streaming() {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    let server = thread::spawn(move || {
        let (mut stream, _) = listener.accept().unwrap();
        let mut buffer = [0u8; 2048];
        let _ = stream.read(&mut buffer);
        let body = br#"{"id":"existing-kilo-native","title":"t"}"#;
        write_json_response(&mut stream, body);

        let ordering = Arc::new((Mutex::new((false, false)), Condvar::new()));
        let mut handlers = Vec::new();
        for _ in 0..2 {
            let (mut stream, _) = listener.accept().unwrap();
            let ordering = Arc::clone(&ordering);
            handlers.push(thread::spawn(move || {
                let request = read_request_headers(&mut stream);
                if request.contains("GET /event") {
                    stream
                        .write_all(
                            b"HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\n\r\n",
                        )
                        .unwrap();
                    stream.flush().unwrap();
                    let (state, ready) = &*ordering;
                    let mut state = state.lock().unwrap();
                    while !state.0 {
                        state = ready.wait(state).unwrap();
                    }
                    stream.shutdown(Shutdown::Both).unwrap();
                    state.1 = true;
                    ready.notify_all();
                    return;
                }
                assert!(request.contains("POST /session/existing-kilo-native/message"));
                assert!(request.contains("private-kilo-resume-prompt"));
                assert!(request.contains("private-kilo-system-guidance"));
                let body = br#"{"parts":[{"type":"text","text":"kilo resumed"}]}"#;
                let response = json_response(body);
                let final_byte = response.len() - 1;
                stream.write_all(&response[..final_byte]).unwrap();
                stream.flush().unwrap();
                let (state, ready) = &*ordering;
                let mut state = state.lock().unwrap();
                state.0 = true;
                ready.notify_all();
                while !state.1 {
                    state = ready.wait(state).unwrap();
                }
                drop(state);
                stream.write_all(&response[final_byte..]).unwrap();
            }));
        }
        for handler in handlers {
            handler.join().unwrap();
        }
    });

    let captured = Arc::new(Mutex::new(Vec::<Value>::new()));
    let sink_target = Arc::clone(&captured);
    super::super::super::turn_event_emit::install_stream_sink(Box::new(move |event| {
        sink_target.lock().unwrap().push(event);
    }));
    let _guard = super::super::super::turn_event_emit::StreamSinkGuard;

    let endpoint = kilo_code_serve::ServeEndpoint::new("127.0.0.1", port);
    let mut config = test_config("private-kilo-resume-prompt", "existing-kilo-native");
    config.private_instructions = Some("private-kilo-system-guidance".into());
    let outcome = execute_via_serve(
        &endpoint,
        &config,
        Some(Instant::now() + Duration::from_secs(5)),
    )
    .expect("exact resume serve turn");
    assert_eq!(outcome.session_id, "existing-kilo-native");
    assert_eq!(outcome.output, "kilo resumed");
    assert_eq!(outcome.turn_status, "end_turn");
    assert!(!outcome.transitions.iter().any(|transition| matches!(
        transition,
        crate::platform::native_agent_parser::Transition::Text { text, .. }
            if text.contains("private-kilo-system-guidance")
    )));

    let events = captured.lock().unwrap().clone();
    assert!(!events.iter().any(|event| {
        event.get("event").and_then(Value::as_str) == Some("agent.message.chunk")
    }));
    assert!(events.iter().any(|event| {
        event.get("event").and_then(Value::as_str) == Some("agent.message.completed")
            && event.get("sessionId").and_then(Value::as_str) == Some("existing-kilo-native")
    }));
    server.join().unwrap();
}

fn read_request_headers(stream: &mut std::net::TcpStream) -> String {
    let mut request = Vec::new();
    let mut buffer = [0u8; 4096];
    loop {
        match stream.read(&mut buffer) {
            Ok(0) => break,
            Ok(count) => {
                request.extend_from_slice(&buffer[..count]);
                if let Some(header_end) = request.windows(4).position(|part| part == b"\r\n\r\n") {
                    let body_start = header_end + 4;
                    let headers = String::from_utf8_lossy(&request[..body_start]);
                    let content_length = headers
                        .lines()
                        .find_map(|line| {
                            let (name, value) = line.split_once(':')?;
                            name.eq_ignore_ascii_case("content-length")
                                .then(|| value.trim().parse::<usize>().ok())
                                .flatten()
                        })
                        .unwrap_or(0);
                    if request.len() >= body_start.saturating_add(content_length) {
                        break;
                    }
                }
            }
            Err(_) => break,
        }
    }
    String::from_utf8_lossy(&request).into_owned()
}

fn write_json_response(stream: &mut std::net::TcpStream, body: &[u8]) {
    stream.write_all(&json_response(body)).unwrap();
}

fn json_response(body: &[u8]) -> Vec<u8> {
    format!(
        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
        body.len(),
        std::str::from_utf8(body).unwrap()
    )
    .into_bytes()
}
