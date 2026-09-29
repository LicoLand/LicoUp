use super::*;
use rusqlite::Connection;
use serde_json::{Value, json};
use std::{collections::BTreeMap, fs};

#[cfg(target_os = "macos")]
#[test]
fn protected_custody_upgrade_defers_until_success_and_retries_without_reset() {
    let root =
        std::env::temp_dir().join(format!("licoup-custody-migration-{}", uuid::Uuid::new_v4()));
    admit(&root).unwrap();
    assert!(gateway_credential_migration_pending(&root).unwrap());
    // An installed older frontier has no custody completion receipt.
    let ledger_path = root.join("client-state/migrations/ledger.json");
    let frontier = embedded_frontier().unwrap();
    let mut ledger = load_ledger(&ledger_path, &frontier).unwrap();
    ledger.domains.remove(GATEWAY_CUSTODY_DOMAIN);
    ledger.frontier_id = "licoup-state-0.1.1".to_owned();
    write_json_atomic(&ledger_path, &ledger).unwrap();

    let startup = admit(&root).unwrap();
    assert_eq!(
        startup.pending_authorization_domain_ids,
        [GATEWAY_CUSTODY_DOMAIN]
    );
    assert_eq!(startup.status, "ready");
    assert!(gateway_credential_migration_pending(&root).unwrap());
    let failure =
        migrate_gateway_credentials_with(&root, || Err(anyhow!("synthetic_native_cancellation")));
    assert_eq!(
        failure.unwrap_err().to_string(),
        "synthetic_native_cancellation"
    );
    assert!(gateway_credential_migration_pending(&root).unwrap());
    let inventory = migrate_gateway_credentials_with(&root, || {
        // Native approval can take arbitrarily long. Its dedicated lock
        // must not block unrelated startup admission while waiting.
        assert_eq!(admit(&root)?.status, "ready");
        crate::domain::llm_api_key_vault::LlmApiKeyInventory::new(
            crate::domain::llm_api_key_vault::GatewayCredentialLeaseDays::default(),
            Vec::new(),
        )
    })
    .unwrap();
    assert!(inventory.entries.is_empty());
    assert!(!gateway_credential_migration_pending(&root).unwrap());
    assert!(
        admit(&root)
            .unwrap()
            .pending_authorization_domain_ids
            .is_empty()
    );
    migrate_gateway_credentials_with(&root, || {
        panic!("completed migration must not authenticate again")
    })
    .unwrap();
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn admission_is_incremental_and_rerun_is_a_noop() {
    let root = std::env::temp_dir().join(format!("licoup-migration-{}", uuid::Uuid::new_v4()));
    fs::create_dir_all(&root).unwrap();
    let first = admit(&root).unwrap();
    assert!(!first.applied_domain_ids.is_empty());
    let second = admit(&root).unwrap();
    assert!(second.applied_domain_ids.is_empty());
    assert_eq!(
        second.skipped_domain_ids.len() + second.pending_authorization_domain_ids.len(),
        embedded_frontier().unwrap().domains.len()
    );
    let _ = fs::remove_dir_all(root);
}

#[test]
fn admission_lock_preserves_existing_contents() {
    let root = std::env::temp_dir().join(format!("licoup-migration-{}", uuid::Uuid::new_v4()));
    let migration_root = root.join("client-state/migrations");
    licoup_foundation::platform::file_security::ensure_private_dir(&migration_root).unwrap();
    let lock_path = migration_root.join("admission.lock");
    let canary = b"existing-lock-content";
    fs::write(&lock_path, canary).unwrap();

    admit(&root).unwrap();

    assert_eq!(fs::read(&lock_path).unwrap(), canary);
    let _ = fs::remove_dir_all(root);
}

#[test]
fn ahead_domain_fails_without_advancing_other_domains() {
    let root = std::env::temp_dir().join(format!("licoup-migration-{}", uuid::Uuid::new_v4()));
    let marker_root = root.join("client-state/migrations/domain-state");
    licoup_foundation::platform::file_security::ensure_private_dir(&marker_root).unwrap();
    let domain = &embedded_frontier().unwrap().domains[0];
    write_json_atomic(
        &marker_path(&marker_root, &domain.domain_id),
        &DomainMarker {
            schema_version: DOMAIN_MARKER_SCHEMA.to_owned(),
            domain_id: domain.domain_id.clone(),
            authoritative_schema_version: domain.target_schema_version + 1,
        },
    )
    .unwrap();
    assert_eq!(
        admit(&root).unwrap_err().to_string(),
        "state_newer_than_binary"
    );
    assert!(!root.join("client-state/migrations/ledger.json").exists());
    let _ = fs::remove_dir_all(root);
}

#[cfg(unix)]
#[test]
fn invalid_ledger_entry_is_not_replaced_as_missing_state() {
    use std::os::unix::fs::symlink;

    let root = std::env::temp_dir().join(format!("licoup-migration-{}", uuid::Uuid::new_v4()));
    let migration_root = root.join("client-state/migrations");
    fs::create_dir_all(&migration_root).unwrap();
    let ledger = migration_root.join("ledger.json");
    symlink(root.join("missing-ledger-target"), &ledger).unwrap();

    assert_eq!(
        admit(&root).unwrap_err().to_string(),
        "migration_ledger_invalid"
    );
    assert!(
        fs::symlink_metadata(&ledger)
            .unwrap()
            .file_type()
            .is_symlink()
    );
    let _ = fs::remove_dir_all(root);
}

#[cfg(unix)]
#[test]
fn invalid_domain_marker_is_not_replaced_as_missing_state() {
    use std::os::unix::fs::symlink;

    let root = std::env::temp_dir().join(format!("licoup-migration-{}", uuid::Uuid::new_v4()));
    admit(&root).unwrap();
    let marker = root.join("client-state/migrations/domain-state/adaptive-flywheel.json");
    fs::remove_file(&marker).unwrap();
    symlink(root.join("missing-marker-target"), &marker).unwrap();

    assert_eq!(
        admit(&root).unwrap_err().to_string(),
        "unsupported_state_shape"
    );
    assert!(
        fs::symlink_metadata(&marker)
            .unwrap()
            .file_type()
            .is_symlink()
    );
    let _ = fs::remove_dir_all(root);
}

#[test]
fn current_marker_cannot_hide_a_reintroduced_legacy_store() {
    let root = std::env::temp_dir().join(format!("licoup-migration-{}", uuid::Uuid::new_v4()));
    admit(&root).unwrap();
    let config = root.join("client-state/mobile-relay/config.json");
    write_json_atomic(
        &config,
        &json!({
            "schemaVersion": 1,
            "pcClientId": "preserved-canary"
        }),
    )
    .unwrap();
    let before = fs::read(&config).unwrap();

    assert_eq!(
        admit(&root).unwrap_err().to_string(),
        "unsupported_state_shape"
    );
    assert_eq!(fs::read(&config).unwrap(), before);
    let _ = fs::remove_dir_all(root);
}

#[test]
fn frontier_has_a_direct_unique_edge_registry() {
    let frontier = embedded_frontier().unwrap();
    assert!(!frontier.domains.is_empty());
    assert!(frontier.domains.iter().all(|domain| {
        domain
            .steps
            .first()
            .is_some_and(|step| step.from_schema_version == 0)
    }));
}

#[test]
fn unregistered_frontier_edge_fails_closed() {
    let root = std::env::temp_dir().join(format!(
        "licoup-migration-registry-{}",
        uuid::Uuid::new_v4()
    ));
    let edge = MigrationEdge {
        step_id: "unregistered.absent-to-1".to_owned(),
        from_schema_version: 0,
        to_schema_version: 1,
    };
    assert_eq!(
        apply_authoritative_store(&root, "unregistered", &edge)
            .unwrap_err()
            .to_string(),
        "migration_frontier_incomplete"
    );
}

#[test]
fn json_domain_migrations_preserve_durable_canaries_and_secret_custody() {
    let root = std::env::temp_dir().join(format!("licoup-migration-{}", uuid::Uuid::new_v4()));
    fs::create_dir_all(root.join("client-state/mobile-relay")).unwrap();
    write_json_atomic(
        &root.join("client-state/appearance-preferences.json"),
        &json!({
            "appearancePresetId": "canary-preset",
            "localePreference": "canary-locale"
        }),
    )
    .unwrap();
    write_json_atomic(
        &root.join("client-state/mobile-relay/config.json"),
        &json!({
            "schemaVersion": 1,
            "pcClientId": "synthetic-canary",
            "secretCustodyCanary": "must-survive"
        }),
    )
    .unwrap();

    admit(&root).unwrap();

    let appearance: serde_json::Value = serde_json::from_slice(
        &fs::read(root.join("client-state/appearance-preferences.json")).unwrap(),
    )
    .unwrap();
    assert_eq!(appearance["schemaVersion"], json!(1));
    assert_eq!(appearance["appearancePresetId"], json!("canary-preset"));
    let relay: serde_json::Value = serde_json::from_slice(
        &fs::read(root.join("client-state/mobile-relay/config.json")).unwrap(),
    )
    .unwrap();
    assert_eq!(relay["schemaVersion"], json!(2));
    assert_eq!(relay["secretCustodyCanary"], json!("must-survive"));
    let _ = fs::remove_dir_all(root);
}

#[test]
fn client_state_collection_adoption_preserves_items_and_adds_current_authority() {
    let root = std::env::temp_dir().join(format!("licoup-migration-{}", uuid::Uuid::new_v4()));
    let path = root.join("client-state/settings.json");
    licoup_foundation::platform::file_security::ensure_private_dir(&root).unwrap();
    licoup_foundation::platform::file_security::ensure_private_dir(path.parent().unwrap()).unwrap();
    let canary = json!({
        "collection": "settings",
        "items": [{"id": "preserved-canary", "value": 42}]
    });
    write_json_atomic(&path, &canary).unwrap();
    licoup_foundation::platform::file_security::harden_private_path(&path).unwrap();

    admit(&root).unwrap();

    let migrated: Value = serde_json::from_slice(&fs::read(&path).unwrap()).unwrap();
    assert_eq!(
        migrated["schemaVersion"],
        json!("v0.0.1:schema:definition-1")
    );
    assert_eq!(migrated["collection"], json!("settings"));
    assert_eq!(migrated["items"], canary["items"]);
    let _ = fs::remove_dir_all(root);
}

#[test]
fn incompatible_mobile_relay_protocol_fails_before_mutating_the_store() {
    let root = std::env::temp_dir().join(format!("licoup-migration-{}", uuid::Uuid::new_v4()));
    let path = root.join("client-state/mobile-relay/config.json");
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    let original = json!({
        "schemaVersion": 1,
        "pcClientId": "synthetic-canary",
        "mobileRelayE2ee": {"protocolVersion": "future-protocol"},
        "secretCustodyCanary": "must-survive"
    });
    write_json_atomic(&path, &original).unwrap();

    assert_eq!(
        admit(&root).unwrap_err().to_string(),
        "unsupported_state_shape"
    );
    let after: serde_json::Value = serde_json::from_slice(&fs::read(&path).unwrap()).unwrap();
    assert_eq!(after, original);
    assert!(!root.join("client-state/migrations/ledger.json").exists());
    let _ = fs::remove_dir_all(root);
}

#[test]
fn crash_after_store_commit_reconciles_without_reapplying_user_data() {
    let root = std::env::temp_dir().join(format!("licoup-migration-{}", uuid::Uuid::new_v4()));
    fs::create_dir_all(root.join("client-state")).unwrap();
    write_json_atomic(
        &root.join("client-state/appearance-preferences.json"),
        &json!({"appearancePresetId": "preserved", "localePreference": "en"}),
    )
    .unwrap();
    {
        let _guard = MigrationFailpointGuard::set("after-store");
        assert_eq!(
            admit(&root).unwrap_err().to_string(),
            "migration_step_failed"
        );
    }
    let recovered = admit(&root).unwrap();
    assert_eq!(recovered.status, "ready");
    let value: serde_json::Value = serde_json::from_slice(
        &fs::read(root.join("client-state/appearance-preferences.json")).unwrap(),
    )
    .unwrap();
    assert_eq!(value["appearancePresetId"], json!("preserved"));
    let ledger: Ledger = serde_json::from_slice(
        &fs::read(root.join("client-state/migrations/ledger.json")).unwrap(),
    )
    .unwrap();
    assert_eq!(
        ledger.domains.len() + recovered.pending_authorization_domain_ids.len(),
        embedded_frontier().unwrap().domains.len()
    );
    for pending in &recovered.pending_authorization_domain_ids {
        assert!(!ledger.domains.contains_key(pending));
    }
    let _ = fs::remove_dir_all(root);
}

#[test]
fn crashes_before_store_and_after_ledger_resume_forward() {
    for failpoint in ["before-store", "after-ledger"] {
        let root = std::env::temp_dir().join(format!("licoup-migration-{}", uuid::Uuid::new_v4()));
        {
            let _guard = MigrationFailpointGuard::set(failpoint);
            assert_eq!(
                admit(&root).unwrap_err().to_string(),
                "migration_step_failed"
            );
        }
        assert_eq!(admit(&root).unwrap().status, "ready");
        assert!(admit(&root).unwrap().applied_domain_ids.is_empty());
        let _ = fs::remove_dir_all(root);
    }
}

#[test]
fn mismatched_claim_blocks_before_ledger_or_domain_changes() {
    let root = std::env::temp_dir().join(format!("licoup-migration-{}", uuid::Uuid::new_v4()));
    let handoff = root.join("client-state/migrations/update-handoff.json");
    let receipt_id = format!("sha256:{}", "a".repeat(64));
    let target = root.join("Applications/LicoUp.app");
    let backup = pre_claim_backup_path(&target, &receipt_id).unwrap();
    write_json_atomic(
        &handoff,
        &UpdateHandoff {
            schema_version: UPDATE_HANDOFF_SCHEMA.to_owned(),
            state: update_handoff::State::Pending,
            version: "999.0.0".to_owned(),
            target_release_track: ReleaseTrack::running().unwrap().as_str().to_owned(),
            migration_frontier: frontier_projection().unwrap(),
            receipt_id,
            target_path: target.to_string_lossy().into_owned(),
            backup_path: backup.to_string_lossy().into_owned(),
        },
    )
    .unwrap();
    assert_eq!(
        admit(&root).unwrap_err().to_string(),
        "update_handoff_mismatch"
    );
    assert!(!root.join("client-state/migrations/ledger.json").exists());
    assert!(update_handoff_rejection_path(&handoff).unwrap().exists());
    let _ = fs::remove_dir_all(root);
}

#[cfg(unix)]
#[test]
fn post_claim_cleanup_failure_never_authorizes_rollback() {
    use std::os::unix::fs::symlink;

    let root = std::env::temp_dir().join(format!(
        "licoup-migration-post-claim-{}",
        uuid::Uuid::new_v4()
    ));
    let handoff = root.join("client-state/migrations/update-handoff.json");
    let receipt_id = format!("sha256:{}", "e".repeat(64));
    let target = root.join("Applications/LicoUp.app");
    let backup = pre_claim_backup_path(&target, &receipt_id).unwrap();
    fs::create_dir_all(backup.parent().unwrap()).unwrap();
    symlink(&target, &backup).unwrap();
    write_json_atomic(
        &handoff,
        &UpdateHandoff {
            schema_version: UPDATE_HANDOFF_SCHEMA.to_owned(),
            state: update_handoff::State::Pending,
            version: running_product_version().unwrap().to_owned(),
            target_release_track: ReleaseTrack::running().unwrap().as_str().to_owned(),
            migration_frontier: frontier_projection().unwrap(),
            receipt_id,
            target_path: target.to_string_lossy().into_owned(),
            backup_path: backup.to_string_lossy().into_owned(),
        },
    )
    .unwrap();

    assert_eq!(
        admit(&root).unwrap_err().to_string(),
        "update_handoff_mismatch"
    );
    let claimed: UpdateHandoff = serde_json::from_slice(&fs::read(&handoff).unwrap()).unwrap();
    assert_eq!(claimed.state, update_handoff::State::Claimed);
    assert!(!update_handoff_rejection_path(&handoff).unwrap().exists());
    let _ = fs::remove_dir_all(root);
}

#[test]
fn valid_claim_is_consumed_only_after_successful_admission() {
    let root = std::env::temp_dir().join(format!("licoup-migration-{}", uuid::Uuid::new_v4()));
    let handoff = root.join("client-state/migrations/update-handoff.json");
    let receipt_id = format!("sha256:{}", "b".repeat(64));
    let target = root.join("Applications/LicoUp.app");
    let backup = pre_claim_backup_path(&target, &receipt_id).unwrap();
    fs::create_dir_all(&backup).unwrap();
    fs::write(backup.join("preserved"), b"old-app").unwrap();
    write_json_atomic(
        &handoff,
        &UpdateHandoff {
            schema_version: UPDATE_HANDOFF_SCHEMA.to_owned(),
            state: update_handoff::State::Pending,
            version: running_product_version().unwrap().to_owned(),
            target_release_track: ReleaseTrack::running().unwrap().as_str().to_owned(),
            migration_frontier: frontier_projection().unwrap(),
            receipt_id,
            target_path: target.to_string_lossy().into_owned(),
            backup_path: backup.to_string_lossy().into_owned(),
        },
    )
    .unwrap();
    admit(&root).unwrap();
    assert!(!handoff.exists());
    assert!(!update_handoff_rejection_path(&handoff).unwrap().exists());
    assert!(!backup.exists());
    let _ = fs::remove_dir_all(root);
}

#[test]
fn update_handoff_stays_pending_until_the_candidate_admits_state() {
    let root = std::env::temp_dir().join(format!("licoup-migration-{}", uuid::Uuid::new_v4()));
    let target = root.join("Applications/LicoUp.app");
    let receipt = json!({
        "version": running_product_version().unwrap(),
        "targetReleaseTrack": ReleaseTrack::running().unwrap().as_str(),
        "migrationFrontier": frontier_projection().unwrap(),
        "receiptId": format!("sha256:{}", "c".repeat(64)),
    });
    let prepared = prepare_update_handoff(&root, &receipt, &target).unwrap();
    let pending: UpdateHandoff =
        serde_json::from_slice(&fs::read(&prepared.handoff_path).unwrap()).unwrap();
    assert_eq!(pending.state, update_handoff::State::Pending);
    assert!(prepare_update_handoff(&root, &receipt, &target).is_err());
    let _ = fs::remove_dir_all(root);
}

#[test]
fn update_handoff_carries_a_strictly_extended_candidate_frontier() {
    let root = std::env::temp_dir().join(format!("licoup-migration-{}", uuid::Uuid::new_v4()));
    let target = root.join("Applications/LicoUp.app");
    let mut candidate = frontier_projection().unwrap();
    candidate["frontierId"] = json!("licoup-state-next");
    candidate["domains"].as_array_mut().unwrap().push(json!({
        "domainId": "future-domain",
        "targetSchemaVersion": 1,
        "requiredStepIds": ["future-domain.absent-to-1"]
    }));
    let receipt = json!({
        "version": "999.0.0",
        "targetReleaseTrack": "nightly",
        "migrationFrontier": candidate,
        "receiptId": format!("sha256:{}", "d".repeat(64)),
    });

    let prepared = prepare_update_handoff(&root, &receipt, &target).unwrap();
    let pending: UpdateHandoff =
        serde_json::from_slice(&fs::read(&prepared.handoff_path).unwrap()).unwrap();
    assert_eq!(pending.migration_frontier, receipt["migrationFrontier"]);
    let _ = fs::remove_dir_all(root);
}

#[test]
fn current_sqlite_domains_preserve_canary_rows() {
    let root = std::env::temp_dir().join(format!("licoup-migration-{}", uuid::Uuid::new_v4()));
    for (relative, table, key, version) in [
        (
            "client-state/conversations/conversations.sqlite3",
            "schema_meta",
            "version",
            "12",
        ),
        (
            "client-state/adaptive-flywheel/strategies.sqlite3",
            "strategy_meta",
            "version",
            "3",
        ),
    ] {
        let path = root.join(relative);
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        let connection = Connection::open(&path).unwrap();
        connection
            .execute_batch(&format!(
                "CREATE TABLE {table}(key TEXT PRIMARY KEY, value TEXT NOT NULL);\
                     INSERT INTO {table}(key,value) VALUES ('{key}','{version}');\
                     CREATE TABLE preservation_canary(value TEXT NOT NULL);\
                     INSERT INTO preservation_canary(value) VALUES ('must-survive');"
            ))
            .unwrap();
    }
    admit(&root).unwrap();
    for relative in [
        "client-state/conversations/conversations.sqlite3",
        "client-state/adaptive-flywheel/strategies.sqlite3",
    ] {
        let connection = Connection::open(root.join(relative)).unwrap();
        let canary: String = connection
            .query_row("SELECT value FROM preservation_canary", [], |row| {
                row.get(0)
            })
            .unwrap();
        assert_eq!(canary, "must-survive");
    }
    let _ = fs::remove_dir_all(root);
}

#[test]
fn generated_native_machines_own_handoff_and_strategy_transitions() {
    use update_handoff::{Event as HandoffEvent, State as HandoffState};

    assert_eq!(update_handoff::MACHINE_ID, "native.update-handoff");
    assert_eq!(
        update_handoff::transition(HandoffState::Pending, HandoffEvent::Claim),
        Some(HandoffState::Claimed)
    );
    assert_eq!(
        update_handoff::transition(HandoffState::Claimed, HandoffEvent::Claim),
        None
    );

    use strategy_store_artifact::{Event as StoreEvent, State as StoreState};

    assert_eq!(
        strategy_store_artifact::transition(StoreState::Legacy, StoreEvent::NormalizeStore),
        Some(StoreState::WorkflowRouted)
    );
    assert_eq!(
        strategy_store_artifact::transition(
            StoreState::WorkflowRouted,
            StoreEvent::MaterializeWorkflowRouting
        ),
        Some(StoreState::Current)
    );
    assert_eq!(
        strategy_store_artifact::transition(StoreState::Current, StoreEvent::NormalizeStore),
        None
    );
}

#[test]
fn adaptive_flywheel_probe_recognizes_all_current_store_states_at_the_owner_path() {
    for (schema, expected) in [("0", 0), ("1", 0), ("2", 1), ("3", 2)] {
        let root =
            std::env::temp_dir().join(format!("licoup-adaptive-probe-{}", uuid::Uuid::new_v4()));
        let database = root.join("client-state/adaptive-flywheel/strategies.sqlite3");
        fs::create_dir_all(database.parent().unwrap()).unwrap();
        let connection = Connection::open(&database).unwrap();
        connection
            .execute_batch(&format!(
                "CREATE TABLE strategy_meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
                     INSERT INTO strategy_meta(key,value) VALUES ('version','{schema}');"
            ))
            .unwrap();
        drop(connection);

        let probe = strategy_store::probe(&root).unwrap();
        assert!(probe.present);
        assert_eq!(probe.version, expected, "store schema {schema}");
        let _ = fs::remove_dir_all(root);
    }
}

#[test]
fn unsupported_adaptive_flywheel_schema_refuses_without_writing_database() {
    for (schema, error) in [
        ("4", "state_newer_than_binary"),
        ("malformed", "unsupported_state_shape"),
    ] {
        let root =
            std::env::temp_dir().join(format!("licoup-adaptive-refusal-{}", uuid::Uuid::new_v4()));
        let database = root.join("client-state/adaptive-flywheel/strategies.sqlite3");
        fs::create_dir_all(database.parent().unwrap()).unwrap();
        let connection = Connection::open(&database).unwrap();
        connection
            .execute_batch(&format!(
                "CREATE TABLE strategy_meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
                     INSERT INTO strategy_meta(key,value) VALUES ('version','{schema}');
                     CREATE TABLE preservation_canary(value TEXT NOT NULL);
                     INSERT INTO preservation_canary(value) VALUES ('keep');"
            ))
            .unwrap();
        drop(connection);
        let before = fs::read(&database).unwrap();

        assert_eq!(admit(&root).unwrap_err().to_string(), error);
        assert_eq!(fs::read(&database).unwrap(), before);
        assert!(!root.join("client-state/migrations/ledger.json").exists());
        let connection = Connection::open(&database).unwrap();
        let canary: String = connection
            .query_row("SELECT value FROM preservation_canary", [], |row| {
                row.get(0)
            })
            .unwrap();
        assert_eq!(canary, "keep");
        let _ = fs::remove_dir_all(root);
    }
}

#[test]
fn completed_frontier_one_advances_adaptive_flywheel_ledger_and_marker() {
    let root = std::env::temp_dir().join(format!(
        "licoup-adaptive-frontier-upgrade-{}",
        uuid::Uuid::new_v4()
    ));
    let database = root.join("client-state/adaptive-flywheel/strategies.sqlite3");
    fs::create_dir_all(database.parent().unwrap()).unwrap();
    let connection = Connection::open(&database).unwrap();
    connection
        .execute_batch(
            "CREATE TABLE strategy_meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
                 INSERT INTO strategy_meta(key,value) VALUES ('version','2');
                 CREATE TABLE preservation_canary(value TEXT NOT NULL);
                 INSERT INTO preservation_canary(value) VALUES ('must-survive');",
        )
        .unwrap();
    drop(connection);

    let migration_root = root.join("client-state/migrations");
    let marker_root = migration_root.join("domain-state");
    licoup_foundation::platform::file_security::ensure_private_dir(&marker_root).unwrap();
    write_json_atomic(
        &marker_path(&marker_root, "adaptive-flywheel"),
        &DomainMarker {
            schema_version: DOMAIN_MARKER_SCHEMA.to_owned(),
            domain_id: "adaptive-flywheel".to_owned(),
            authoritative_schema_version: 1,
        },
    )
    .unwrap();
    write_json_atomic(
        &migration_root.join("ledger.json"),
        &Ledger {
            schema_version: LEDGER_SCHEMA.to_owned(),
            highest_admitted_product_version: running_product_version().unwrap().to_owned(),
            frontier_id: "licoup-state-0.2.1".to_owned(),
            domains: BTreeMap::from([(
                "adaptive-flywheel".to_owned(),
                LedgerDomain {
                    schema_version: 1,
                    completed_step_ids: vec!["adaptive-flywheel.absent-to-1".to_owned()],
                },
            )]),
        },
    )
    .unwrap();

    let result = admit(&root).unwrap();
    assert!(
        result
            .applied_domain_ids
            .iter()
            .any(|domain| domain == "adaptive-flywheel")
    );
    let connection = Connection::open(&database).unwrap();
    let version: String = connection
        .query_row(
            "SELECT value FROM strategy_meta WHERE key='version'",
            [],
            |row| row.get(0),
        )
        .unwrap();
    let canary: String = connection
        .query_row("SELECT value FROM preservation_canary", [], |row| {
            row.get(0)
        })
        .unwrap();
    assert_eq!(version, "3");
    assert_eq!(canary, "must-survive");

    let marker = load_domain_marker(
        &marker_root,
        embedded_frontier()
            .unwrap()
            .domains
            .iter()
            .find(|domain| domain.domain_id == "adaptive-flywheel")
            .unwrap(),
    )
    .unwrap()
    .unwrap();
    assert_eq!(marker.authoritative_schema_version, 2);
    let ledger: Ledger =
        serde_json::from_slice(&fs::read(migration_root.join("ledger.json")).unwrap()).unwrap();
    let adaptive = &ledger.domains["adaptive-flywheel"];
    assert_eq!(adaptive.schema_version, 2);
    assert_eq!(
        adaptive.completed_step_ids,
        vec![
            "adaptive-flywheel.absent-to-1".to_owned(),
            "adaptive-flywheel.workflow-routing-to-2".to_owned(),
        ]
    );
    let _ = fs::remove_dir_all(root);
}

#[test]
fn schema_one_adaptive_flywheel_store_advances_through_both_frontier_edges() {
    let root = std::env::temp_dir().join(format!(
        "licoup-adaptive-schema-one-upgrade-{}",
        uuid::Uuid::new_v4()
    ));
    let database = root.join("client-state/adaptive-flywheel/strategies.sqlite3");
    fs::create_dir_all(database.parent().unwrap()).unwrap();
    let connection = Connection::open(&database).unwrap();
    connection
        .execute_batch(
            "CREATE TABLE strategy_meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
                 INSERT INTO strategy_meta(key,value) VALUES ('version','1');
                 CREATE TABLE preservation_canary(value TEXT NOT NULL);
                 INSERT INTO preservation_canary(value) VALUES ('must-survive');",
        )
        .unwrap();
    drop(connection);

    let result = admit(&root).unwrap();
    assert!(
        result
            .applied_domain_ids
            .iter()
            .any(|domain| domain == "adaptive-flywheel")
    );
    let connection = Connection::open(&database).unwrap();
    let (version, canary): (String, String) = connection
        .query_row(
            "SELECT m.value, c.value
                   FROM strategy_meta m CROSS JOIN preservation_canary c
                  WHERE m.key='version'",
            [],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .unwrap();
    assert_eq!(version, "3");
    assert_eq!(canary, "must-survive");
    let ledger: Ledger = serde_json::from_slice(
        &fs::read(root.join("client-state/migrations/ledger.json")).unwrap(),
    )
    .unwrap();
    let adaptive = &ledger.domains["adaptive-flywheel"];
    assert_eq!(adaptive.schema_version, 2);
    assert_eq!(adaptive.completed_step_ids.len(), 2);
    let _ = fs::remove_dir_all(root);
}

#[test]
fn interrupted_multi_step_migration_reconciles_the_committed_prefix() {
    let root = std::env::temp_dir().join(format!(
        "licoup-adaptive-prefix-recovery-{}",
        uuid::Uuid::new_v4()
    ));
    let database = root.join("client-state/adaptive-flywheel/strategies.sqlite3");
    fs::create_dir_all(database.parent().unwrap()).unwrap();
    let connection = Connection::open(&database).unwrap();
    connection
        .execute_batch(
            "CREATE TABLE strategy_meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
                 INSERT INTO strategy_meta(key,value) VALUES ('version','1');",
        )
        .unwrap();
    drop(connection);

    {
        let _guard = MigrationFailpointGuard::set("after-store");
        assert_eq!(
            admit(&root).unwrap_err().to_string(),
            "migration_step_failed"
        );
    }

    assert_eq!(strategy_store::probe(&root).unwrap().version, 1);
    admit(&root).unwrap();
    assert_eq!(admit(&root).unwrap().status, "ready");

    let ledger: Ledger = serde_json::from_slice(
        &fs::read(root.join("client-state/migrations/ledger.json")).unwrap(),
    )
    .unwrap();
    assert_eq!(
        ledger.domains["adaptive-flywheel"].completed_step_ids,
        vec![
            "adaptive-flywheel.absent-to-1".to_owned(),
            "adaptive-flywheel.workflow-routing-to-2".to_owned(),
        ]
    );
    let _ = fs::remove_dir_all(root);
}

#[test]
fn conversation_legacy_import_finishes_during_admission() {
    let root = std::env::temp_dir().join(format!(
        "licoup-conversation-admission-{}",
        uuid::Uuid::new_v4()
    ));
    let legacy = root.join("client-state/agent-conversation-projections.json");
    fs::create_dir_all(legacy.parent().unwrap()).unwrap();
    fs::write(
            &legacy,
            r#"{"schemaVersion":1,"sessionsByAgent":{"agent-one":[{"id":"session-1","title":"Preserved","messages":[{"role":"user","content":"canary"}]}]}}"#,
        )
        .unwrap();

    admit(&root).unwrap();

    assert!(!legacy.exists());
    assert!(
        root.join("client-state/conversations/migration-v5.complete")
            .is_file()
    );
    let store = crate::domain::client_conversation::ConversationStore::open(&root).unwrap();
    let conversations = store.list(false).unwrap();
    assert_eq!(conversations.len(), 1);
    assert_eq!(conversations[0].title, "Preserved");
    let _ = fs::remove_dir_all(root);
}

#[test]
fn admitted_v11_conversation_store_upgrades_without_resetting_the_domain() {
    let root = std::env::temp_dir().join(format!(
        "licoup-conversation-v11-admit-{}",
        uuid::Uuid::new_v4()
    ));
    admit(&root).unwrap();
    let database = root.join("client-state/conversations/conversations.sqlite3");
    let connection = Connection::open(&database).unwrap();
    connection
        .execute("UPDATE schema_meta SET value='11' WHERE key='version'", [])
        .unwrap();
    drop(connection);
    assert_eq!(probe_canonical_conversation(&root).unwrap().version, 1);

    admit(&root).unwrap();

    let version: String = Connection::open(&database)
        .unwrap()
        .query_row(
            "SELECT value FROM schema_meta WHERE key='version'",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(version, licoup_conversation::store::CURRENT_SCHEMA_VERSION);
    let _ = fs::remove_dir_all(root);
}
