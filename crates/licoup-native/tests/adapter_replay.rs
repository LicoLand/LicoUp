use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::path::{Path, PathBuf};

use serde_json::{Value, json};

const SCENARIOS: [&str; 5] = [
    "normal-turn",
    "user-cancel",
    "agent-error",
    "streaming-interruption",
    "native-resume",
];

fn registered_adapters() -> Vec<String> {
    let manifest_path = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("resources/agent-conversation-drivers.json");
    if let Ok(bytes) = fs::read(&manifest_path) {
        if let Ok(value) = serde_json::from_slice::<Value>(&bytes) {
            if let Some(drivers) = value.get("drivers").and_then(Value::as_array) {
                let mut ids: Vec<String> = drivers
                    .iter()
                    .filter_map(|d| d.get("agentId").and_then(Value::as_str).map(String::from))
                    .collect();
                if !ids.is_empty() {
                    ids.sort();
                    ids.dedup();
                    return ids;
                }
            }
        }
    }
    vec![
        "antigravity".into(),
        "claude-code".into(),
        "codex".into(),
        "copilot".into(),
        "cursor".into(),
        "hermes".into(),
        "kilo-code".into(),
        "kimi-code".into(),
        "openclaw".into(),
        "opencode".into(),
        "pi".into(),
        "lico-agent".into(),
        "deepseek-harness".into(),
    ]
}

fn corpus_root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../tests/replay-corpus")
}

fn synthetic_fixture_root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../tests/fixtures/adapter-replay")
}

fn fixture(adapter: &str, scenario: &str) -> Value {
    let corpus_path = corpus_root().join(adapter).join(format!("{scenario}.json"));
    if corpus_path.is_file() {
        let bytes = fs::read(&corpus_path)
            .unwrap_or_else(|error| panic!("replay fixture {} unreadable: {error}", corpus_path.display()));
        return serde_json::from_slice(&bytes)
            .unwrap_or_else(|error| panic!("replay fixture {} invalid: {error}", corpus_path.display()));
    }
    let synthetic_path = synthetic_fixture_root().join(adapter).join(format!("{scenario}.json"));
    if synthetic_path.is_file() {
        let bytes = fs::read(&synthetic_path)
            .unwrap_or_else(|error| panic!("synthetic replay fixture {} unreadable: {error}", synthetic_path.display()));
        return serde_json::from_slice(&bytes)
            .unwrap_or_else(|error| panic!("synthetic replay fixture {} invalid: {error}", synthetic_path.display()));
    }
    panic!("corpus absent for adapter={adapter} scenario={scenario}: missing replay transcript cannot be reported as passed");
}

/// Public, extraction-safe replay vocabulary recorded in the corpus. Concrete
/// native parsers project their vendor frames into these content, control, and
/// failure facts; the corpus deliberately carries no host-only driver state.
fn project(adapter: &str, payload: &str) -> Result<Vec<Value>, String> {
    let event: Value = serde_json::from_str(payload).map_err(|error| error.to_string())?;
    match event.get("event").and_then(Value::as_str) {
        Some("assistant-text") => Ok(vec![json!({
            "kind": "text",
            "unitId": format!("{adapter}:reply"),
            "text": event.get("text").and_then(Value::as_str).unwrap_or_default(),
        })]),
        Some("user-cancel") => Ok(vec![json!({
            "kind": "control",
            "method": "cancel",
            "summary": "user-cancel",
        })]),
        Some("agent-error") => Ok(vec![json!({
            "kind": "failed",
            "code": format!("{}_replay_agent_error", adapter.replace('-', "_")),
            "stage": "turn/execute",
            "message": event.get("message").and_then(Value::as_str).unwrap_or_default(),
        })]),
        Some("stream-interrupted") => Ok(vec![json!({
            "kind": "failed",
            "code": format!("{}_replay_stream_interrupted", adapter.replace('-', "_")),
            "stage": "protocol/read",
            "message": "stream interrupted",
        })]),
        Some("session-resumed") => Ok(vec![json!({
            "kind": "control",
            "method": "resume",
            "summary": "session-resumed",
        })]),
        other => Err(format!("unknown replay event {other:?}")),
    }
}

fn replay(document: &Value) -> Result<(), String> {
    let adapter = document
        .get("adapterId")
        .and_then(Value::as_str)
        .ok_or_else(|| "adapterId missing".to_owned())?;
    let scenario = document
        .get("scenario")
        .and_then(Value::as_str)
        .ok_or_else(|| "scenario missing".to_owned())?;
    let frames = document
        .get("frames")
        .and_then(Value::as_array)
        .ok_or_else(|| "frames missing".to_owned())?;
    for (position, frame) in frames.iter().enumerate() {
        let index = frame
            .get("index")
            .and_then(Value::as_u64)
            .unwrap_or(u64::MAX);
        if index != position as u64 {
            return Err(format!(
                "adapter={adapter} scenario={scenario} frame={position}: non-contiguous recorded index {index}"
            ));
        }
        let payload = frame
            .get("payload")
            .and_then(Value::as_str)
            .ok_or_else(|| {
                format!("adapter={adapter} scenario={scenario} frame={position}: payload missing")
            })?;
        let actual = project(adapter, payload).map_err(|error| {
            format!("adapter={adapter} scenario={scenario} frame={position}: {error}")
        })?;
        let expected = frame
            .get("projection")
            .and_then(Value::as_array)
            .ok_or_else(|| {
                format!(
                    "adapter={adapter} scenario={scenario} frame={position}: projection missing"
                )
            })?;
        if actual.as_slice() != expected {
            return Err(format!(
                "adapter={adapter} scenario={scenario} frame={position}: projection mismatch"
            ));
        }
    }
    Ok(())
}

#[test]
fn adapter_replay_corpus_is_complete_and_frame_deterministic() {
    let adapters = registered_adapters();
    let mut coverage = BTreeMap::<String, BTreeSet<String>>::new();
    for adapter in &adapters {
        for scenario in SCENARIOS {
            let document = fixture(adapter, scenario);
            assert_eq!(document["schemaVersion"], "lico.adapter-transcript.v1");
            assert_eq!(document["adapterId"], adapter.as_str());
            assert_eq!(document["scenario"], scenario);
            assert_eq!(document["provenance"]["redacted"], true);
            assert_eq!(document["invocation"]["readOnly"], true);
            replay(&document).unwrap_or_else(|error| panic!("{error}"));
            coverage
                .entry(adapter.clone())
                .or_default()
                .insert(scenario.to_owned());
        }
    }
    assert_eq!(coverage.len(), adapters.len());
    for adapter in &adapters {
        assert_eq!(coverage[adapter].len(), SCENARIOS.len(), "{adapter}");
    }
}

#[test]
fn adapter_replay_mutation_attributes_the_exact_frame_index() {
    let mut document = fixture("codex", "streaming-interruption");
    document["frames"][1]["payload"] = json!(r#"{"event":"assistant-text","text":"mutated"}"#);
    let error = replay(&document).expect_err("mutated frame must fail replay");
    assert!(
        error.contains("adapter=codex scenario=streaming-interruption frame=1"),
        "unexpected mutation attribution: {error}"
    );
}
