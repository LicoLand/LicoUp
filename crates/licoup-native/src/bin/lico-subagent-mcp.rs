//! Thin stdio connector for the desktop-owned Subagent MCP HTTP service.
//!
//! This binary owns no tools, catalog, repeat-attempt policy, provider adaptation, or
//! Conversation state. One stdio frame maps to one authenticated loopback HTTP
//! request and one response frame.

use licoup_native::core::mcp::{
    McpStdioFrame, encode_http_body, encode_stdio_line, read_stdio_frame,
};
use licoup_native::domain::subagent_mcp::MAX_MCP_FRAME_BYTES;
use licoup_native::domain::subagent_mcp::{PROTOCOL_REVISION, server_definition};
use licoup_native::platform::subagent_mcp_supervisor::{
    connector_close_session, connector_exchange, load_connector_discovery,
};
use std::env;
use std::io::{self, Write};
use std::process::ExitCode;
use std::sync::{Arc, Mutex};
use std::thread;

const MAX_IN_FLIGHT_FRAMES: usize = 32;

fn main() -> ExitCode {
    match run() {
        Ok(()) => ExitCode::SUCCESS,
        Err(()) => ExitCode::FAILURE,
    }
}

fn run() -> Result<(), ()> {
    let provider = caller_provider(
        env::args().skip(1),
        env::var("LICOUP_MCP_CALLER_PROVIDER").ok(),
    )?;
    // Missing discovery exits before the first stdio frame. Antigravity IDE
    // then reports EOF on `initialize`. The owned MCP `env` block must bind
    // `LICOUP_PORTABLE_DIR` so this lookup can find the desktop supervisor.
    let discovery = load_connector_discovery(&provider).map_err(|_| ())?;
    let stdin = io::stdin();
    let mut reader = stdin.lock();
    let writer = Arc::new(Mutex::new(io::stdout()));
    let mut session = ConnectorSession {
        discovery: &discovery,
        id: None,
    };
    let mut protocol_revision = PROTOCOL_REVISION.to_owned();
    let mut workers = Vec::<thread::JoinHandle<Result<(), ()>>>::new();
    loop {
        let mut retained = Vec::with_capacity(workers.len());
        for worker in workers.drain(..) {
            if worker.is_finished() {
                worker.join().map_err(|_| ())??;
            } else {
                retained.push(worker);
            }
        }
        workers = retained;
        let message = match read_stdio_frame(&mut reader, MAX_MCP_FRAME_BYTES) {
            McpStdioFrame::Eof => break,
            McpStdioFrame::Invalid(response) => {
                writer
                    .lock()
                    .map_err(|_| ())?
                    .write_all(&encode_stdio_line(&response, MAX_MCP_FRAME_BYTES).map_err(|_| ())?)
                    .map_err(|_| ())?;
                writer.lock().map_err(|_| ())?.flush().map_err(|_| ())?;
                continue;
            }
            McpStdioFrame::Message(message) => message,
        };
        if session.id.is_none()
            && let Some(requested) = initialize_protocol_revision(&message)
            && server_definition().supports_protocol_revision(requested)
        {
            protocol_revision = requested.to_owned();
        }
        if let Some(session_id) = session.id.clone() {
            if workers.len() >= MAX_IN_FLIGHT_FRAMES {
                return Err(());
            }
            let discovery = discovery.clone();
            let protocol_revision = protocol_revision.clone();
            let writer = Arc::clone(&writer);
            workers.push(thread::spawn(move || {
                forward(
                    &discovery,
                    Some(&session_id),
                    None,
                    &protocol_revision,
                    message,
                    &writer,
                )
                .map(|_| ())
            }));
        } else {
            let returned_session = forward(
                &discovery,
                None,
                Some(&mut session.id),
                &protocol_revision,
                message,
                &writer,
            )?;
            session.id = returned_session;
        }
    }
    for worker in workers {
        worker.join().map_err(|_| ())??;
    }
    session.close()?;
    Ok(())
}

struct ConnectorSession<'a> {
    discovery: &'a licoup_native::platform::subagent_mcp_supervisor::ConnectorDiscovery,
    id: Option<String>,
}

impl ConnectorSession<'_> {
    fn close(&mut self) -> Result<(), ()> {
        let Some(session_id) = self.id.take() else {
            return Ok(());
        };
        connector_close_session(self.discovery, &session_id).map_err(|_| ())
    }
}

impl Drop for ConnectorSession<'_> {
    fn drop(&mut self) {
        let _ = self.close();
    }
}

fn forward(
    discovery: &licoup_native::platform::subagent_mcp_supervisor::ConnectorDiscovery,
    session_id: Option<&str>,
    allocated_session: Option<&mut Option<String>>,
    protocol_revision: &str,
    message: licoup_native::core::mcp::McpMessage,
    writer: &Mutex<io::Stdout>,
) -> Result<Option<String>, ()> {
    let body = encode_http_body(&message, MAX_MCP_FRAME_BYTES).map_err(|_| ())?;
    let (status, returned_session, response) =
        connector_exchange(discovery, session_id, protocol_revision, &body).map_err(|_| ())?;
    if session_id.is_none()
        && let Some(allocated_session) = allocated_session
    {
        *allocated_session = returned_session.clone();
    }
    if session_id.is_some() && returned_session.as_deref() != session_id {
        return Err(());
    }
    match status {
        200 => {
            let response =
                licoup_native::core::mcp::decode_http_body(&response, MAX_MCP_FRAME_BYTES)
                    .map_err(|_| ())?;
            let mut writer = writer.lock().map_err(|_| ())?;
            writer
                .write_all(&encode_stdio_line(&response, MAX_MCP_FRAME_BYTES).map_err(|_| ())?)
                .map_err(|_| ())?;
            writer.flush().map_err(|_| ())?;
        }
        202 if response.is_empty() => {}
        _ => return Err(()),
    }
    Ok(returned_session)
}

fn initialize_protocol_revision(message: &licoup_native::core::mcp::McpMessage) -> Option<&str> {
    match message {
        licoup_native::core::mcp::McpMessage::Request { method, params, .. }
            if method == "initialize" =>
        {
            params
                .as_ref()
                .and_then(|params| params.get("protocolVersion"))
                .and_then(serde_json::Value::as_str)
        }
        _ => None,
    }
}

fn caller_provider(
    args: impl IntoIterator<Item = String>,
    environment: Option<String>,
) -> Result<String, ()> {
    let args = args.into_iter().collect::<Vec<_>>();
    let argument = match args.as_slice() {
        [] => None,
        [flag, provider] if flag == "--caller" => Some(provider.as_str()),
        _ => return Err(()),
    };
    let environment = environment.as_deref().filter(|value| !value.is_empty());
    if argument.is_some() && environment.is_some() && argument != environment {
        return Err(());
    }
    let provider = argument.or(environment).ok_or(())?;
    if !matches!(provider, "codex" | "cursor" | "antigravity") {
        return Err(());
    }
    Ok(provider.to_owned())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn caller_identity_is_exact_and_non_ambiguous() {
        assert_eq!(
            caller_provider(["--caller".into(), "cursor".into()], None).unwrap(),
            "cursor"
        );
        assert_eq!(
            caller_provider(std::iter::empty(), Some("codex".into())).unwrap(),
            "codex"
        );
        assert!(
            caller_provider(["--caller".into(), "cursor".into()], Some("codex".into())).is_err()
        );
        assert!(caller_provider(["--caller".into(), "other".into()], None).is_err());
    }

    #[test]
    fn initialize_revision_is_forwarded_from_the_client_handshake() {
        let initialize = licoup_native::core::mcp::McpMessage::request(
            1_i64,
            "initialize",
            serde_json::json!({
                "protocolVersion":"2025-11-25",
                "capabilities":{},
                "clientInfo":{"name":"fixture","version":"1"}
            })
            .as_object()
            .cloned(),
        )
        .unwrap();
        let list = licoup_native::core::mcp::McpMessage::request(
            2_i64,
            "tools/list",
            Some(serde_json::Map::new()),
        )
        .unwrap();

        assert_eq!(
            initialize_protocol_revision(&initialize),
            Some("2025-11-25")
        );
        assert_eq!(initialize_protocol_revision(&list), None);
    }
}
