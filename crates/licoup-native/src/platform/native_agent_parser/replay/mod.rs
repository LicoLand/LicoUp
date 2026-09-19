//! Replay of recorded adapter transcripts through the real parser boundary.
//!
//! Every frame of every fixture is fed to the same adapter parser the
//! production driver uses, and the recorded projection must equal what that
//! parser actually produced. Nothing here re-implements vendor framing: a
//! fixture can only pass if the real parser still reports the recorded facts,
//! so a protocol regression in an adapter fails its own corpus.
//!
//! Fail-closed properties enforced below: an absent corpus fails instead of
//! passing; a frame without a recorded projection fails instead of skipping;
//! and projections are recorded by the real parsers, never authored by hand.

mod adapters;

use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::path::{Path, PathBuf};

use serde_json::Value;

/// One recorded vendor frame, as it crossed the adapter boundary.
pub(in crate::platform) struct RecordedFrame {
    /// Zero-based position in the recorded transcript.
    pub(in crate::platform) index: usize,
    /// Wire direction. The corpus records what the agent sent us.
    pub(in crate::platform) direction: String,
    /// The adapter's own framing, which must equal `AdapterContract::framing`.
    pub(in crate::platform) channel: String,
    /// The raw vendor frame. PTY-borne frames carry their bytes here verbatim.
    pub(in crate::platform) payload: String,
}

/// A parser that can be replayed from a recorded transcript.
///
/// An arm constructs the same parser the production driver constructs, feeds
/// it recorded frames exactly as the driver feeds live bytes, and reports the
/// parser's real output. The projection is a direct view of the parser's own
/// report: one entry per real output item, each carrying the parser's variant
/// name under `effect`, or a single `error` entry when the parser rejected the
/// frame. `Err` is reserved for frames the boundary cannot consume at all.
pub(in crate::platform) trait FrameReplay {
    fn feed(&mut self, frame: &RecordedFrame) -> Result<Vec<Value>, String>;
}

const SCENARIOS: [&str; 5] = [
    "normal-turn",
    "user-cancel",
    "agent-error",
    "streaming-interruption",
    "native-resume",
];

/// Set only by the projection recorder, which rewrites an out-of-tree corpus
/// copy. The replay test itself always reads the repository corpus.
const RECORD_ROOT_ENV: &str = "LICO_ADAPTER_REPLAY_RECORD_ROOT";

fn registered_adapters() -> Vec<String> {
    let manifest_path =
        Path::new(env!("CARGO_MANIFEST_DIR")).join("resources/agent-conversation-drivers.json");
    let bytes =
        std::fs::read(&manifest_path).expect("registered adapter manifest must be readable");
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

fn fixture_root() -> PathBuf {
    let corpus = corpus_root();
    if corpus.is_dir() {
        corpus
    } else {
        Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../apps/desktop/test/fixtures/adapter-replay")
    }
}

/// Corpus root used by the recorder only. Absent means the recorder has not
/// been pointed at a corpus copy, which is a usage error rather than a pass.
fn recording_root() -> PathBuf {
    match std::env::var(RECORD_ROOT_ENV) {
        Ok(root) if !root.is_empty() => PathBuf::from(root),
        _ => panic!("{RECORD_ROOT_ENV} must name the corpus copy to record projections into"),
    }
}

fn fixture_document(root: &Path, adapter: &str, scenario: &str) -> Value {
    let path = root.join(adapter).join(format!("{scenario}.json"));
    let bytes = fs::read(&path).unwrap_or_else(|error| {
        panic!(
            "replay fixture missing or unreadable for adapter={adapter} scenario={scenario}: {error}"
        )
    });
    serde_json::from_slice(&bytes).unwrap_or_else(|error| {
        panic!("replay fixture invalid for adapter={adapter} scenario={scenario}: {error}")
    })
}

fn recorded_frames(document: &Value, adapter: &str, scenario: &str) -> Vec<RecordedFrame> {
    let frames = document
        .get("frames")
        .and_then(Value::as_array)
        .filter(|frames| !frames.is_empty())
        .unwrap_or_else(|| {
            panic!("adapter={adapter} scenario={scenario}: frames missing or empty")
        });
    frames
        .iter()
        .enumerate()
        .map(|(position, frame)| {
            let index = frame.get("index").and_then(Value::as_u64).unwrap_or(u64::MAX);
            assert_eq!(
                index, position as u64,
                "adapter={adapter} scenario={scenario} frame={position}: non-contiguous recorded index {index}"
            );
            RecordedFrame {
                index: position,
                direction: frame
                    .get("direction")
                    .and_then(Value::as_str)
                    .unwrap_or_else(|| {
                        panic!(
                            "adapter={adapter} scenario={scenario} frame={position}: direction missing"
                        )
                    })
                    .to_owned(),
                channel: frame
                    .get("channel")
                    .and_then(Value::as_str)
                    .unwrap_or_else(|| {
                        panic!(
                            "adapter={adapter} scenario={scenario} frame={position}: channel missing"
                        )
                    })
                    .to_owned(),
                payload: frame
                    .get("payload")
                    .and_then(Value::as_str)
                    .unwrap_or_else(|| {
                        panic!(
                            "adapter={adapter} scenario={scenario} frame={position}: payload missing"
                        )
                    })
                    .to_owned(),
            }
        })
        .collect()
}

fn recorded_projection(
    frame: &Value,
    adapter: &str,
    scenario: &str,
    position: usize,
) -> Vec<Value> {
    frame
        .get("projection")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_else(|| {
            panic!(
                "adapter={adapter} scenario={scenario} frame={position}: projection missing; \
                 run the adapter_replay_record_projections recorder against the real parsers"
            )
        })
}

/// Replay one transcript and return the projection drift, if any.
///
/// Every frame is checked before it is fed, so an unrecorded corpus fails
/// before any parser runs rather than after a partial replay.
fn replay(document: &Value, adapter: &str, scenario: &str) -> Result<(), String> {
    if !document
        .get("frames")
        .and_then(Value::as_array)
        .is_some_and(|frames| !frames.is_empty())
    {
        return Err(format!(
            "adapter={adapter} scenario={scenario}: frames missing or empty"
        ));
    }
    let frames = document["frames"].as_array().expect("checked above");
    let framing = adapters::contract_framing(adapter)
        .unwrap_or_else(|error| panic!("adapter={adapter} scenario={scenario}: {error}"));
    let mut parser = adapters::replay_for(adapter)
        .unwrap_or_else(|error| panic!("adapter={adapter} scenario={scenario}: {error}"));
    for (position, (frame, recorded)) in frames
        .iter()
        .zip(recorded_frames(document, adapter, scenario))
        .enumerate()
    {
        if recorded.channel != framing {
            return Err(format!(
                "adapter={adapter} scenario={scenario} frame={position}: recorded channel {:?} is \
                 not the adapter's real framing {framing:?}",
                recorded.channel
            ));
        }
        let expected = recorded_projection(frame, adapter, scenario, position);
        let actual = parser.feed(&recorded).map_err(|error| {
            format!("adapter={adapter} scenario={scenario} frame={position}: {error}")
        })?;
        if actual != expected {
            return Err(format!(
                "adapter={adapter} scenario={scenario} frame={position}: projection mismatch: \
                 parser produced {actual:?}, corpus recorded {expected:?}"
            ));
        }
    }
    Ok(())
}

/// Projection recorder. Not a check: it rewrites the projections of a corpus
/// copy from the real parsers, and the tool that owns fixture generation runs
/// it before a fixture can be reviewed. It never runs in the normal test set.
#[test]
#[ignore = "recorder: rewrites fixture projections from the real parsers"]
fn adapter_replay_record_projections() {
    let root = recording_root();
    let mut recorded = 0;
    for adapter in registered_adapters() {
        for scenario in SCENARIOS {
            let path = root.join(&adapter).join(format!("{scenario}.json"));
            // A corpus copy may hold only the adapters being worked on. An
            // absent fixture is not recorded and not claimed; the replay test
            // still fails closed on a corpus that is missing any of them.
            if !path.is_file() {
                continue;
            }
            let mut document = fixture_document(&root, &adapter, scenario);
            let frames = recorded_frames(&document, &adapter, scenario);
            let mut parser = adapters::replay_for(&adapter).unwrap_or_else(|error| {
                panic!("adapter={adapter} scenario={scenario}: {error}");
            });
            let mut projections = Vec::with_capacity(frames.len());
            for frame in &frames {
                projections.push(Value::Array(parser.feed(frame).unwrap_or_else(|error| {
                    panic!(
                        "adapter={adapter} scenario={scenario} frame={}: {error}",
                        frame.index
                    )
                })));
            }
            if let Some(stored) = document.get_mut("frames").and_then(Value::as_array_mut) {
                for (slot, projection) in stored.iter_mut().zip(projections) {
                    slot["projection"] = projection;
                }
            }
            let mut encoded = serde_json::to_string_pretty(&document)
                .expect("recorded fixture must serialize")
                .into_bytes();
            encoded.push(b'\n');
            fs::write(&path, encoded)
                .unwrap_or_else(|error| panic!("cannot write recorded fixture {path:?}: {error}"));
            recorded += 1;
        }
    }
    assert!(
        recorded > 0,
        "no replay fixtures found under {root:?}: nothing was recorded"
    );
    println!("recorded projections for {recorded} fixtures under {root:?}");
}

#[test]
fn adapter_replay_corpus_is_complete_and_frame_deterministic() {
    let root = fixture_root();
    assert!(
        root.is_dir(),
        "replay corpus absent at {root:?}: a missing transcript corpus is never a pass"
    );
    let adapters = registered_adapters();
    let mut coverage = BTreeMap::<String, BTreeSet<String>>::new();
    for adapter in &adapters {
        for scenario in SCENARIOS {
            let document = fixture_document(&root, adapter, scenario);
            assert_eq!(document["schemaVersion"], "lico.adapter-transcript.v1");
            assert_eq!(document["adapterId"], adapter.as_str());
            assert_eq!(document["scenario"], scenario);
            assert_eq!(document["provenance"]["redacted"], true);
            assert_eq!(document["invocation"]["readOnly"], true);
            replay(&document, adapter, scenario).unwrap_or_else(|error| panic!("{error}"));
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
fn adapter_replay_rejects_a_projection_the_parser_did_not_produce() {
    let root = fixture_root();
    let mut document = fixture_document(&root, "codex", "streaming-interruption");
    document["frames"][1]["projection"] = serde_json::json!([{"effect": "never-recorded-fact"}]);
    let error = replay(&document, "codex", "streaming-interruption")
        .expect_err("a projection the parser does not produce must fail replay");
    assert!(
        error.contains("adapter=codex scenario=streaming-interruption frame=1"),
        "unexpected projection attribution: {error}"
    );
    assert!(
        error.contains("projection mismatch"),
        "unexpected projection failure: {error}"
    );
}

#[test]
fn adapter_replay_attributes_a_drifted_frame_to_its_exact_index() {
    let root = fixture_root();
    let mut document = fixture_document(&root, "cursor", "normal-turn");
    // The terminal frame is the one whose drift can only show on itself: an
    // earlier frame carries the identity and prompt acknowledgement the later
    // frames are checked against, so a parser that rejects it reports the
    // first frame that no longer matches rather than the frame that was edited.
    let drifted = document["frames"]
        .as_array()
        .expect("fixture frames")
        .len()
        .checked_sub(1)
        .expect("fixture has a frame");
    document["frames"][drifted]["payload"] =
        serde_json::json!(r#"{"type":"unknown-vendor-frame"}"#);
    let error =
        replay(&document, "cursor", "normal-turn").expect_err("a drifted frame must fail replay");
    assert!(
        error.contains(&format!(
            "adapter=cursor scenario=normal-turn frame={drifted}"
        )),
        "unexpected drift attribution: {error}"
    );
}

#[test]
#[should_panic(expected = "replay fixture missing or unreadable")]
fn adapter_replay_fails_closed_on_a_missing_corpus() {
    let _ = fixture_document(
        Path::new("/nonexistent-replay-corpus"),
        "codex",
        "normal-turn",
    );
}

#[test]
#[should_panic(expected = "projection missing")]
fn adapter_replay_fails_closed_on_an_unrecorded_frame() {
    let document = serde_json::json!({
        "frames": [{
            "index": 0,
            "direction": "agent-to-client",
            "channel": "stdio-jsonrpc",
            "payload": "{}",
        }],
    });
    let _ = replay(&document, "codex", "normal-turn");
}

#[test]
fn adapter_replay_refuses_to_replay_an_unregistered_adapter() {
    let error = adapters::replay_for("not-a-registered-adapter")
        .err()
        .expect("an unregistered adapter has no replayable parser");
    assert!(error.contains("not-a-registered-adapter"), "{error}");
}
