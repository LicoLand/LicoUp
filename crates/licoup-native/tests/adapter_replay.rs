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
    let manifest_path =
        Path::new(env!("CARGO_MANIFEST_DIR")).join("resources/agent-conversation-drivers.json");
    let bytes = fs::read(&manifest_path).expect("registered adapter manifest must be readable");
    let value: Value =
        serde_json::from_slice(&bytes).expect("registered adapter manifest must be valid JSON");
    let drivers = value
        .get("drivers")
        .and_then(Value::as_array)
        .filter(|drivers| !drivers.is_empty())
        .expect("registered adapter manifest must contain drivers");
    let mut ids: Vec<String> = drivers
        .iter()
        .map(|driver| {
            driver
                .get("agentId")
                .and_then(Value::as_str)
                .filter(|id| !id.is_empty())
                .expect("registered adapter manifest driver must contain agentId")
                .to_owned()
        })
        .collect();
    let count = ids.len();
    ids.sort();
    ids.dedup();
    assert_eq!(
        ids.len(),
        count,
        "registered adapter manifest contains duplicate agentId"
    );
    ids
}

fn corpus_root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../tests/replay-corpus")
}

fn synthetic_fixture_root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../tests/fixtures/adapter-replay")
}

fn fixture_root() -> PathBuf {
    let corpus = corpus_root();
    if corpus.is_dir() {
        corpus
    } else {
        synthetic_fixture_root()
    }
}

fn fixture(adapter: &str, scenario: &str) -> Value {
    let path = fixture_root()
        .join(adapter)
        .join(format!("{scenario}.json"));
    let bytes = fs::read(&path).unwrap_or_else(|error| {
        panic!(
            "replay fixture missing or unreadable for adapter={adapter} scenario={scenario}: {error}"
        )
    });
    serde_json::from_slice(&bytes).unwrap_or_else(|error| {
        panic!("replay fixture invalid for adapter={adapter} scenario={scenario}: {error}")
    })
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
