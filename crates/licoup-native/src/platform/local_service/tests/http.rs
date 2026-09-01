use super::super::http::{self, HttpFailure};
use serde_json::json;
use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::thread;
use std::time::Duration;

#[test]
fn http_policy_allows_loopback_plaintext_and_remote_tls_only() {
    assert!(http::validate_url("http://127.0.0.1:24173/session").is_ok());
    assert!(http::validate_url("http://localhost:4097/session").is_ok());
    assert!(http::validate_url("http://[::1]:4097/session").is_ok());
    assert!(http::validate_url("https://agent.example/session").is_ok());
    assert_eq!(
        http::validate_url("http://agent.example/session").unwrap_err(),
        HttpFailure::InvalidUrl
    );
    assert_eq!(
        http::validate_url("https://token@agent.example/session").unwrap_err(),
        HttpFailure::InvalidUrl
    );
}

fn read_http_request(stream: &mut TcpStream) -> Option<(String, Vec<u8>)> {
    let mut head = Vec::new();
    let mut byte = [0u8; 1];
    while !head.windows(4).any(|window| window == b"\r\n\r\n") {
        if stream.read(&mut byte).map(|read| read == 0).unwrap_or(true) {
            return None;
        }
        head.push(byte[0]);
    }
    let head_text = String::from_utf8_lossy(&head);
    let mut request_line = None;
    let mut content_length = 0usize;
    for (index, line) in head_text.split("\r\n").enumerate() {
        if index == 0 {
            request_line = Some(line.to_owned());
            continue;
        }
        if let Some((name, value)) = line.split_once(':') {
            if name.eq_ignore_ascii_case("content-length") {
                content_length = value.trim().parse().unwrap_or(0);
            }
        }
    }
    let mut body = vec![0u8; content_length];
    if content_length > 0 {
        stream.read_exact(&mut body).ok()?;
    }
    request_line.map(|line| (line, body))
}

fn write_json_response(stream: &mut TcpStream, body: &str) {
    let payload = format!(
        "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: {}\r\nconnection: keep-alive\r\n\r\n{}",
        body.len(),
        body
    );
    stream.write_all(payload.as_bytes()).unwrap();
    stream.flush().unwrap();
}

#[test]
fn shared_control_client_reuses_one_connection_for_sequential_calls() {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let address = listener.local_addr().unwrap();
    let accepts = Arc::new(AtomicUsize::new(0));
    let accepts_for_server = Arc::clone(&accepts);
    let server = thread::spawn(move || {
        let (mut stream, _) = listener.accept().unwrap();
        accepts_for_server.fetch_add(1, Ordering::SeqCst);
        let _ = stream.set_read_timeout(Some(Duration::from_secs(5)));
        let mut served = 0;
        while served < 2 {
            let Some((request_line, _body)) = read_http_request(&mut stream) else {
                break;
            };
            if !request_line.starts_with("POST ") {
                break;
            }
            write_json_response(&mut stream, r#"{"ok":true}"#);
            served += 1;
        }
    });
    let base = format!("http://{address}");
    let first = http::post_json(
        &format!("{base}/session"),
        &json!({"probe": 1}),
        Duration::from_secs(5),
    );
    let second = http::post_json(
        &format!("{base}/session"),
        &json!({"probe": 2}),
        Duration::from_secs(5),
    );
    server.join().unwrap();
    assert_eq!(first.unwrap()["ok"], true);
    assert_eq!(second.unwrap()["ok"], true);
    assert_eq!(accepts.load(Ordering::SeqCst), 1);
}

#[test]
fn http_failure_preserves_the_non_success_status_class() {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let address = listener.local_addr().unwrap();
    let server = thread::spawn(move || {
        let (mut stream, _) = listener.accept().unwrap();
        let _ = read_http_request(&mut stream).unwrap();
        stream
            .write_all(
                b"HTTP/1.1 422 Unprocessable Entity\r\ncontent-length: 0\r\nconnection: close\r\n\r\n",
            )
            .unwrap();
    });
    let failure = http::post_json(
        &format!("http://{address}/session"),
        &json!({}),
        Duration::from_secs(2),
    )
    .unwrap_err();
    server.join().unwrap();
    assert_eq!(failure, HttpFailure::Status(422));
}
