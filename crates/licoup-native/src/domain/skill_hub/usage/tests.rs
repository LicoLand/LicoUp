use super::*;
use crate::domain::skill_hub::{SKILL_INSTALLER_PROTOCOL, pair_approve_in, pair_request_in};
use serde_json::json;
use std::sync::{Arc, Barrier};
use std::{env, fs};
use time::format_description::well_known::Rfc3339;
use uuid::Uuid;

#[test]
fn real_conversation_events_record_only_managed_skill_invocations() {
    let store = test_store("runtime-events");
    seed_managed_skill(&store, "codex", "review-helper");
    let occurred_at = OffsetDateTime::parse("2026-07-01T01:00:00Z", &Rfc3339).unwrap();
    let receipt = observe_at(
        &store,
        "codex",
        &json!({
            "ok": true,
            "events": [
                {"event": "skill.invoked", "skillId": "review-helper"},
                {"event": "skill.invoked", "skillId": "review-helper"},
                {"event": "skill.invoked", "skillId": "not-installed"},
                {"sessionUpdate": "tool_call", "skillId": "review-helper"}
            ],
            "output": "must never be retained"
        }),
        occurred_at,
    )
    .unwrap();
    assert_eq!(receipt["recordedCount"], 2);

    let ledger = store.read_collection(ledger::COLLECTION).unwrap();
    assert_eq!(ledger["items"][0]["count"], 2);
    assert!(!ledger.to_string().contains("must never be retained"));
    assert!(!ledger.to_string().contains("not-installed"));
}

#[test]
fn report_supports_custom_windows_and_dimensions() {
    let store = test_store("report");
    for (agent, skill) in [("codex", "review"), ("claude-code", "lint")] {
        seed_managed_skill(&store, agent, skill);
    }
    for (agent, skill, at) in [
        ("codex", "review", "2026-07-01T00:00:00Z"),
        ("claude-code", "lint", "2026-07-02T00:00:00Z"),
    ] {
        observe_at(
            &store,
            agent,
            &json!({"ok": true, "events": [{"event": "skill.invoked", "skillId": skill}]}),
            OffsetDateTime::parse(at, &Rfc3339).unwrap(),
        )
        .unwrap();
    }
    let result = report(&store, &json!({"from": "2026-07-01", "to": "2026-07-02"})).unwrap();
    assert_eq!(result["totalInvocations"], 2);
    assert_eq!(result["byAgent"].as_array().unwrap().len(), 2);
    let filtered = report(
        &store,
        &json!({
            "from": "2026-07-01",
            "to": "2026-07-02",
            "agent": "codex",
            "skill": "review"
        }),
    )
    .unwrap();
    assert_eq!(filtered["totalInvocations"], 1);
}

#[test]
fn concurrent_runtime_events_do_not_lose_daily_counts() {
    let store = test_store("concurrent");
    seed_managed_skill(&store, "codex", "review");
    let barrier = Arc::new(Barrier::new(8));
    let workers = (0..8)
        .map(|_| {
            let store = store.clone();
            let barrier = Arc::clone(&barrier);
            std::thread::spawn(move || {
                barrier.wait();
                observe_at(
                    &store,
                    "codex",
                    &json!({"ok": true, "events": [{"event": "skill.invoked", "skillId": "review"}]}),
                    OffsetDateTime::parse("2026-07-01T00:00:00Z", &Rfc3339).unwrap(),
                )
                .unwrap();
            })
        })
        .collect::<Vec<_>>();
    for worker in workers {
        worker.join().unwrap();
    }
    let result = report(&store, &json!({"from": "2026-07-01", "to": "2026-07-01"})).unwrap();
    assert_eq!(result["totalInvocations"], 8);
}

#[test]
fn day_count_is_selectable_and_bounded() {
    let store = test_store("days");
    let result = report(&store, &json!({"days": 7, "to": "2026-07-16"})).unwrap();
    assert_eq!(result["window"]["from"], "2026-07-10");
    assert_eq!(result["window"]["selectedDays"], 7);
    assert!(report(&store, &json!({"days": 366})).is_err());
}

fn seed_managed_skill(store: &ClientStateStore, agent_id: &str, skill_id: &str) {
    pair_request_in(store, &json!({"agent": agent_id})).unwrap();
    pair_approve_in(store, &json!({"agent": agent_id})).unwrap();
    let mut skills = store.read_collection("skills").unwrap();
    skills["items"].as_array_mut().unwrap().push(json!({
        "kind": "skill",
        "agentId": agent_id,
        "skillId": skill_id,
        "installer": SKILL_INSTALLER_PROTOCOL
    }));
    store.write_collection("skills", skills).unwrap();
}

fn test_store(name: &str) -> ClientStateStore {
    let root = env::temp_dir().join(format!("lico-skill-usage-{name}-{}", Uuid::new_v4()));
    fs::create_dir_all(&root).unwrap();
    ClientStateStore::new(root).unwrap()
}
