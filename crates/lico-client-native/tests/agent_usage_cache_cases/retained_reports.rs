use super::support::*;

#[test]
fn retained_reports_keep_only_current_contract_and_sort_by_timestamp() {
    let state_root = temp_dir("usage-report-current-contract-state");
    let store = ClientStateStore::new(state_root.clone()).unwrap();
    store
        .write_collection(
            "agent-usage-reports",
            json!({
                "items": [
                    {
                        "schemaVersion": 6,
                        "mode": "local-token-usage",
                        "tokenSourceMode": "native-metadata-first-incremental",
                        "generatedAt": "2026-07-10T12:00:00Z",
                        "summary": {"totalTokens": 12},
                        "agents": []
                    },
                    {
                        "schemaVersion": 6,
                        "mode": "invalid-mode",
                        "tokenSourceMode": "native-metadata-first-incremental",
                        "generatedAt": "2026-07-11T12:00:00Z",
                        "summary": {"totalTokens": 999},
                        "agents": []
                    },
                    {
                        "schemaVersion": 6,
                        "mode": "local-token-usage",
                        "tokenSourceMode": "native-metadata-first-incremental",
                        "generatedAt": "2026-07-09T12:00:00Z",
                        "summary": {"totalTokens": 9},
                        "agents": []
                    }
                ]
            }),
        )
        .unwrap();

    let listed = agent_usage::report(&json!({
        "stateRoot": state_root.to_string_lossy(),
        "limit": 10
    }))
    .unwrap();
    let reports = listed["reports"].as_array().unwrap();
    assert_eq!(reports.len(), 2);
    assert_eq!(reports[0]["summary"]["totalTokens"], 12);
    assert_eq!(reports[1]["summary"]["totalTokens"], 9);

    let retained = store.read_collection("agent-usage-reports").unwrap();
    let items = retained["items"].as_array().unwrap();
    assert_eq!(items.len(), 2);
    assert!(items.iter().all(|item| item["schemaVersion"] == 6));
    assert!(items.iter().all(|item| item["mode"] == "local-token-usage"));
    assert!(
        items
            .iter()
            .all(|item| { item["tokenSourceMode"] == "native-metadata-first-incremental" })
    );
    assert_eq!(items[0]["summary"]["totalTokens"], 9);
    assert_eq!(items[1]["summary"]["totalTokens"], 12);
    assert!(!retained.to_string().contains("invalid-mode"));
}
