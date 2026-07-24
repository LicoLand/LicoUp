use super::*;
use std::io::{Read, Write};
use std::net::TcpListener;
use std::sync::{Arc, Mutex};

#[test]
fn request_body_keeps_private_values_in_http_json_not_process_metadata() {
    let mut config = test_config("private prompt", "");
    config.model = Some("provider/model".into());
    config.runtime_agent = Some("reviewer".into());
    let body = build_message_body(&config);
    assert_eq!(body["parts"][0]["text"], "private prompt");
    assert_eq!(body["model"]["providerID"], "provider");
    assert_eq!(body["model"]["modelID"], "model");
    assert_eq!(body["agent"], "reviewer");
}

#[test]
fn expired_deadline_prevents_http_request() {
    let failure = wait_post_json("http://invalid.test", &json!({}), Instant::now()).unwrap_err();
    assert_eq!(failure.code, "acp_protocol_timeout");
}

#[test]
fn exact_resume_uses_the_requested_native_session_and_projects_stream_event() {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    let server = thread::spawn(move || {
        let (mut stream, _) = listener.accept().unwrap();
        let mut buffer = [0u8; 2048];
        let _ = stream.read(&mut buffer);
        let body = br#"{"id":"existing-kilo-native","title":"t"}"#;
        write_json_response(&mut stream, body);

        listener.set_nonblocking(true).unwrap();
        loop {
            match listener.accept() {
                Ok((mut stream, _)) => {
                    let request = read_request_headers(&mut stream);
                    if request.contains("GET /event") {
                        let _ = stream.write_all(
                            b"HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\n\r\n",
                        );
                        continue;
                    }
                    if request.contains("POST /session/existing-kilo-native/message") {
                        assert!(request.contains("private-kilo-resume-prompt"));
                        let body = br#"{"parts":[{"type":"text","text":"kilo resumed"}]}"#;
                        write_json_response(&mut stream, body);
                        break;
                    }
                }
                Err(_) => thread::sleep(Duration::from_millis(10)),
            }
        }
    });

    let captured = Arc::new(Mutex::new(Vec::<Value>::new()));
    let sink_target = Arc::clone(&captured);
    super::super::super::turn_event_emit::install_stream_sink(Box::new(move |event| {
        sink_target.lock().unwrap().push(event);
    }));
    let _guard = super::super::super::turn_event_emit::StreamSinkGuard;

    let endpoint = kilo_code_serve::ServeEndpoint::new("127.0.0.1", port);
    let config = test_config("private-kilo-resume-prompt", "existing-kilo-native");
    let outcome = execute_via_serve(&endpoint, &config, Instant::now() + Duration::from_secs(5))
        .expect("exact resume serve turn");
    assert_eq!(outcome.session_id, "existing-kilo-native");
    assert_eq!(outcome.output, "kilo resumed");
    assert_eq!(outcome.turn_status, "end_turn");

    let events = captured.lock().unwrap().clone();
    assert!(events.iter().any(|event| {
        event.get("event").and_then(Value::as_str) == Some("agent.message.chunk")
            && event.get("sessionId").and_then(Value::as_str) == Some("existing-kilo-native")
            && event
                .get("payload")
                .and_then(|payload| payload.get("text"))
                .and_then(Value::as_str)
                == Some("kilo resumed")
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
                if request.windows(4).any(|window| window == b"\r\n\r\n") {
                    break;
                }
            }
            Err(_) => break,
        }
    }
    String::from_utf8_lossy(&request).into_owned()
}

fn write_json_response(stream: &mut std::net::TcpStream, body: &[u8]) {
    let response = format!(
        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
        body.len(),
        std::str::from_utf8(body).unwrap()
    );
    stream.write_all(response.as_bytes()).unwrap();
}
