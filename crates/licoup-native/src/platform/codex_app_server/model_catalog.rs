use super::super::process_supervisor::{BoundedStdinWriter, finish_protocol_transport};
use super::io::{TransportEvent, drain_stderr, read_protocol_messages, write_message};
use super::launch::CodexLaunchSpec;
use serde_json::{Map, Value, json};
use std::io::BufReader;
use std::path::Path;
use std::sync::Arc;
use std::sync::atomic::AtomicBool;
use std::sync::mpsc::{self, RecvTimeoutError};
use std::thread;
use std::time::{Duration, Instant};

const INITIALIZE_ID: i64 = 91_001;
const MODEL_LIST_ID: i64 = 91_002;
// Product policy: every model-catalog scan waits up to one minute. On timeout
// the Codex catalog falls back to sparse config/history/cache rows.
const MODEL_SCAN_TIMEOUT: Duration = Duration::from_secs(60);
const MAX_PROTOCOL_BYTES: usize = 2 * 1024 * 1024;
const MAX_STDERR_BYTES: usize = 256 * 1024;
const MAX_MODELS: usize = 256;

/// Reads the exact visible model directory exposed by the installed Codex
/// App Server. Only the model projection crosses this boundary; initialize
/// metadata, installation identity, stderr, and notifications are discarded.
pub(crate) fn list_models(executable: &Path) -> Result<Value, ()> {
    let executable = executable.to_str().ok_or(())?;
    let mut child = CodexLaunchSpec::new(executable, None)
        .spawn()
        .map_err(|_| ())?;
    let stdout = child.stdout().ok_or(())?;
    let stderr = child.stderr().ok_or(())?;
    let stdin = child.stdin().ok_or(())?;
    let mut stdin = BoundedStdinWriter::new(stdin);
    let (sender, receiver) = mpsc::channel();
    let stdout_handle = thread::spawn(move || {
        read_protocol_messages(BufReader::new(stdout), MAX_PROTOCOL_BYTES, sender)
    });
    let stderr_truncated = Arc::new(AtomicBool::new(false));
    let stderr_flag = Arc::clone(&stderr_truncated);
    let stderr_handle = thread::spawn(move || drain_stderr(stderr, MAX_STDERR_BYTES, &stderr_flag));

    let result = (|| {
        write_message(
            &mut stdin,
            &json!({
                "id": INITIALIZE_ID,
                "method": "initialize",
                "params": {
                    "clientInfo": {
                        "name": "lico-up-model-catalog",
                        "title": "LicoUp",
                        "version": env!("CARGO_PKG_VERSION")
                    },
                    "capabilities": {"experimentalApi": true}
                }
            }),
        )
        .map_err(|_| ())?;
        let deadline = Instant::now() + MODEL_SCAN_TIMEOUT;
        wait_for_response(&receiver, INITIALIZE_ID, deadline)?;
        write_message(&mut stdin, &json!({"method": "initialized", "params": {}}))
            .map_err(|_| ())?;
        write_message(
            &mut stdin,
            &json!({
                "id": MODEL_LIST_ID,
                "method": "model/list",
                "params": {"includeHidden": false, "limit": MAX_MODELS}
            }),
        )
        .map_err(|_| ())?;
        let response = wait_for_response(&receiver, MODEL_LIST_ID, deadline)?;
        project_model_list_response(&response)
    })();

    let cleanup = finish_protocol_transport(&mut child, &mut stdin, stdout_handle, stderr_handle);
    if cleanup.is_err() {
        return Err(());
    }
    result
}

fn wait_for_response(
    receiver: &mpsc::Receiver<TransportEvent>,
    request_id: i64,
    deadline: Instant,
) -> Result<Value, ()> {
    loop {
        let now = Instant::now();
        if now >= deadline {
            return Err(());
        }
        match receiver.recv_timeout(deadline - now) {
            Ok(TransportEvent::Message(message))
                if message.get("id").and_then(Value::as_i64) == Some(request_id) =>
            {
                return message.get("result").cloned().ok_or(());
            }
            Ok(TransportEvent::Message(_)) => {}
            Ok(_) | Err(RecvTimeoutError::Disconnected | RecvTimeoutError::Timeout) => {
                return Err(());
            }
        }
    }
}

fn project_model_list_response(result: &Value) -> Result<Value, ()> {
    let models = result.get("data").and_then(Value::as_array).ok_or(())?;
    let projected = models
        .iter()
        .filter_map(project_model)
        .take(MAX_MODELS)
        .collect::<Vec<_>>();
    if projected.is_empty() {
        return Err(());
    }
    let default_model = projected
        .iter()
        .find(|model| model.get("isDefault").and_then(Value::as_bool) == Some(true))
        .and_then(|model| model.get("name"))
        .cloned()
        .unwrap_or_else(|| Value::String(String::new()));
    Ok(json!({
        "schemaVersion": 1,
        "status": "available",
        "source": "codex-app-server",
        "defaultModel": default_model,
        "models": projected,
        "diagnostics": []
    }))
}

fn project_model(model: &Value) -> Option<Value> {
    if model.get("hidden").and_then(Value::as_bool) == Some(true) {
        return None;
    }
    let name = model.get("model")?.as_str()?.trim();
    if name.is_empty() || name.len() > 256 {
        return None;
    }
    let display_name = model
        .get("displayName")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty() && value.len() <= 256)
        .unwrap_or(name);
    let efforts = model
        .get("supportedReasoningEfforts")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|effort| effort.get("reasoningEffort").and_then(Value::as_str))
        .map(str::trim)
        .filter(|effort| !effort.is_empty() && effort.len() <= 32)
        .map(Value::from)
        .collect::<Vec<_>>();
    let mut projected = Map::new();
    projected.insert("name".into(), Value::String(name.to_owned()));
    projected.insert("displayName".into(), Value::String(display_name.to_owned()));
    projected.insert("reasoningEfforts".into(), Value::Array(efforts));
    projected.insert(
        "isDefault".into(),
        Value::Bool(model.get("isDefault").and_then(Value::as_bool) == Some(true)),
    );
    Some(Value::Object(projected))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn projects_visible_native_models_without_collapsing_duplicate_labels() {
        let result = project_model_list_response(&json!({
            "data": [
                {"model":"first","displayName":"Same","hidden":false,"isDefault":true,
                 "supportedReasoningEfforts":[{"reasoningEffort":"low"}]},
                {"model":"second","displayName":"Same","hidden":false,"isDefault":false,
                 "supportedReasoningEfforts":[{"reasoningEffort":"high"}]},
                {"model":"hidden","displayName":"Hidden","hidden":true}
            ]
        }))
        .unwrap();
        assert_eq!(result["defaultModel"], "first");
        assert_eq!(result["models"].as_array().unwrap().len(), 2);
        assert_eq!(result["models"][0]["displayName"], "Same");
        assert_eq!(result["models"][1]["displayName"], "Same");
    }
}
