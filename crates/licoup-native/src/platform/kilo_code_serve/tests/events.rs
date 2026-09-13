use serde_json::json;

use crate::platform::native_agent_parser::adapters::kilo_code::ServeEventParser;

#[test]
fn target_event_lane_projects_only_assistant_text_parts() {
    let mut projection = ServeEventParser::new("kilo-1");
    let assistant_seen = json!({
        "type": "message.updated",
        "properties": {"info": {"id": "msg-agent", "role": "assistant", "sessionID": "kilo-1"}}
    });
    assert_eq!(projection.observe(&assistant_seen.to_string()), Ok(None));
    let event = json!({
        "type": "message.part.updated",
        "properties": {
            "sessionID": "kilo-1",
            "part": {"id": "prt-1", "messageID": "msg-agent", "type": "text", "text": "answer"}
        }
    });
    assert_eq!(
        projection.observe(&event.to_string()),
        Ok(Some("answer".into()))
    );
    assert_eq!(
        ServeEventParser::new("kilo-2").observe(&event.to_string()),
        Ok(None)
    );
    let user_part = json!({
        "type": "message.part.updated",
        "properties": {
            "sessionID": "kilo-1",
            "part": {"id": "prt-2", "messageID": "msg-user", "type": "text", "text": "private"}
        }
    });
    assert_eq!(projection.observe(&user_part.to_string()), Ok(None));
    let missing_session = json!({
        "type": "message.part.updated",
        "properties": {
            "part": {"id": "prt-3", "messageID": "msg-agent", "type": "text", "text": "private"}
        }
    });
    assert_eq!(projection.observe(&missing_session.to_string()), Ok(None));
}

#[test]
fn watcher_captures_complete_target_tool_frame_before_text_projection() {
    use crate::platform::raw_execution::{RawExecutionObserver, RawExecutionScope};
    use std::io::{Read, Write};
    use std::net::TcpListener;
    use std::sync::{Arc, Mutex, atomic::AtomicBool, mpsc};
    let target = ": trace\r\nid: opaque-frame\r\nevent: tool.updated\r\ndata: {\"type\":\"tool.updated\",\"properties\":{\"sessionID\":\"target\",\"arguments\":{\"path\":\"synthetic\"},\"result\":{\"unknown\":[1,2]}}}\r\n\r\n";
    let other = "data: {\"type\":\"tool.updated\",\"properties\":{\"sessionID\":\"other\",\"result\":\"excluded\"}}\n\n";
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let address = listener.local_addr().unwrap();
    let server = std::thread::spawn(move || {
        let (mut stream, _) = listener.accept().unwrap();
        let mut headers = Vec::new();
        let mut byte = [0u8; 1];
        while !headers.ends_with(b"\r\n\r\n") {
            stream.read_exact(&mut byte).unwrap();
            headers.push(byte[0]);
        }
        let body = format!("{other}{target}");
        write!(stream, "HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{body}", body.len()).unwrap();
    });
    let records = Arc::new(Mutex::new(Vec::new()));
    let sink = Arc::clone(&records);
    let observer = RawExecutionObserver::new(move |source, _, raw| {
        sink.lock()
            .unwrap()
            .push((source.to_owned(), raw.to_owned()));
        Ok(())
    });
    let (sender, receiver) = mpsc::sync_channel(4);
    let url = format!("http://{address}");
    let watcher = std::thread::spawn(move || {
        let _scope = RawExecutionScope::enter(Some(observer));
        super::super::watch_session_events(&url, "target", &AtomicBool::new(false), &sender)
    });
    assert_eq!(
        watcher.join().unwrap(),
        Err(super::super::EventStreamFailure::Closed)
    );
    server.join().unwrap();
    assert!(receiver.try_recv().is_err());
    assert_eq!(
        records
            .lock()
            .unwrap()
            .iter()
            .filter(|record| record.0 == "kilo-code.sse")
            .map(|record| record.1.as_str())
            .collect::<Vec<_>>(),
        [target]
    );
}
