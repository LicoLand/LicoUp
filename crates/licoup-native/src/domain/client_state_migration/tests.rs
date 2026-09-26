use super::*;
use crate::state_machines::update_handoff;

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
    crate::platform::file_security::ensure_private_dir(&migration_root).unwrap();
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
    crate::platform::file_security::ensure_private_dir(&marker_root).unwrap();
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
fn the_published_store_graph_is_connected_and_the_frontier_agrees_with_it() {
    let current = current_strategy_format();
    assert_eq!(current.format_id, "strategy-store-4");
    // Every published shape reaches the current one along the graph, and
    // every edge leaves a shape exactly once: a shape with two successors
    // would make a conversion ambiguous, which is what `strategy_store_path`
    // refuses rather than guesses.
    for format in PUBLISHED_STRATEGY_FORMATS {
        let path = strategy_store_path(format.format_id, current.format_id).unwrap();
        assert_eq!(
            path.last().map(|edge| edge.to),
            (format.format_id != current.format_id).then_some(current.format_id)
        );
        assert!(
            STRATEGY_STORE_EDGES
                .iter()
                .filter(|edge| edge.from == format.format_id)
                .count()
                <= 1
        );
    }
    // A shape that is not in the history has no path, so a typo in a format
    // id fails closed instead of converting to "the newest thing".
    assert!(strategy_store_path("strategy-store-9", current.format_id).is_err());

    // The frontier's domain versions and the published shapes are one
    // numbering: every domain version the frontier names must have a
    // published shape, and the newest shape must be the frontier's target.
    let frontier = embedded_frontier().unwrap();
    let domain = frontier
        .domains
        .iter()
        .find(|domain| domain.domain_id == STRATEGY_STORE_DOMAIN)
        .unwrap();
    assert_eq!(domain.target_schema_version, current.domain_schema_version);
    for edge in &domain.steps {
        assert!(strategy_format_for_domain_version(edge.to_schema_version).is_ok());
    }
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
    crate::platform::file_security::ensure_private_dir(&root).unwrap();
    crate::platform::file_security::ensure_private_dir(path.parent().unwrap()).unwrap();
    let canary = json!({
        "collection": "settings",
        "items": [{"id": "preserved-canary", "value": 42}]
    });
    write_json_atomic(&path, &canary).unwrap();
    crate::platform::file_security::harden_private_path(&path).unwrap();

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
            state: update_handoff::INITIAL.as_str().to_owned(),
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
            state: update_handoff::INITIAL.as_str().to_owned(),
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
    assert_eq!(claimed.state, "claimed");
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
            state: update_handoff::INITIAL.as_str().to_owned(),
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
    assert_eq!(pending.state, "pending");
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
    // Create the current conversation format through its owner. Admission must
    // preserve a complete store, not repair a partial layout labelled current.
    let conversations = licoup_conversation::ConversationStore::open(&root).unwrap();
    conversations.checkpoint().unwrap();
    drop(conversations);
    let fixtures = [
        (
            "client-state/conversations/conversations.sqlite3",
            "CREATE TABLE preservation_canary(value TEXT NOT NULL);\
                 INSERT INTO preservation_canary(value) VALUES ('must-survive');",
        ),
        (
            "client-state/adaptive-flywheel/strategies.sqlite3",
            "CREATE TABLE strategy_meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);\
                 INSERT INTO strategy_meta(key,value) VALUES ('version','3');\
                 CREATE TABLE preservation_canary(value TEXT NOT NULL);\
                 INSERT INTO preservation_canary(value) VALUES ('must-survive');",
        ),
    ];
    for (relative, statements) in fixtures {
        let path = root.join(relative);
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        let connection = Connection::open(&path).unwrap();
        connection.execute_batch(statements).unwrap();
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
    crate::platform::file_security::ensure_private_dir(&marker_root).unwrap();
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

/// A real file in the shape the published writer left at `strategy_meta`
/// version 3: the state tables, a delivery intent that still carries a copy
/// of the committed body, and a canary row nothing in the migration knows
/// about.
fn published_strategy_store_v3(path: &Path) {
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    let connection = Connection::open(path).unwrap();
    connection
        .execute_batch(
            "CREATE TABLE strategy_meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
                 INSERT INTO strategy_meta(key,value) VALUES ('version','3');
                 CREATE TABLE strategy_runs(
                   run_id TEXT PRIMARY KEY, snapshot_json TEXT NOT NULL,
                   conversation_id TEXT, terminal INTEGER
                 );
                 INSERT INTO strategy_runs(run_id,snapshot_json,conversation_id,terminal)
                   VALUES ('run-1','{\"status\":\"running\"}','conversation-1',0);
                 CREATE TABLE workflow_transition_intents(
                   run_id TEXT NOT NULL, sequence INTEGER NOT NULL, event_json TEXT NOT NULL,
                   before_json TEXT NOT NULL, after_json TEXT NOT NULL, status TEXT NOT NULL,
                   created_at INTEGER NOT NULL, dispatched_at INTEGER,
                   PRIMARY KEY(run_id, sequence)
                 );
                 INSERT INTO workflow_transition_intents VALUES
                   ('run-1', 1, '{\"kind\":\"command-claimed\"}', '{\"sequence\":0}',
                    '{\"sequence\":1}', 'pending', 7, NULL);
                 CREATE TABLE preservation_canary(value TEXT NOT NULL);
                 INSERT INTO preservation_canary(value) VALUES ('must-survive');",
        )
        .unwrap();
}

fn strategy_table_names(path: &Path) -> Vec<String> {
    let connection = Connection::open(path).unwrap();
    let mut statement = connection
        .prepare("SELECT name FROM sqlite_master WHERE type='table' ORDER BY name")
        .unwrap();
    statement
        .query_map([], |row| row.get::<_, String>(0))
        .unwrap()
        .collect::<rusqlite::Result<Vec<_>>>()
        .unwrap()
}

#[test]
fn a_published_store_gains_the_delivery_tables_once_and_keeps_every_row() {
    let root = std::env::temp_dir().join(format!("licoup-notice-outbox-{}", uuid::Uuid::new_v4()));
    let database = root.join(STRATEGY_STORE_DATABASE);
    published_strategy_store_v3(&database);
    assert_eq!(
        read_strategy_store_format(&database).unwrap().format_id,
        "strategy-store-3"
    );

    let first = admit(&root).unwrap();
    assert!(
        first
            .applied_domain_ids
            .iter()
            .any(|domain| domain == "adaptive-flywheel"),
        "the store advanced, so the domain must not be reported as untouched"
    );
    let connection = Connection::open(&database).unwrap();
    for table in NOTICE_OUTBOX_TABLES {
        for column in table.columns {
            assert!(
                strategy_table_columns(&connection, table.name)
                    .unwrap()
                    .iter()
                    .any(|name| name == column),
                "{}.{column} is missing from the created table",
                table.name
            );
        }
    }
    // The published format recorded the obligation as a body copy and never
    // named a recipient or a kind. Neither can be derived, so the migration
    // creates the tables empty and leaves the legacy row with its owner.
    let notices: i64 = connection
        .query_row("SELECT COUNT(*) FROM workflow_notice_intents", [], |row| {
            row.get(0)
        })
        .unwrap();
    let acceptances: i64 = connection
        .query_row(
            "SELECT COUNT(*) FROM workflow_notice_acceptances",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!((notices, acceptances), (0, 0));
    let legacy: String = connection
        .query_row(
            "SELECT event_json FROM workflow_transition_intents WHERE run_id='run-1'",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(legacy, "{\"kind\":\"command-claimed\"}");
    let canary: String = connection
        .query_row("SELECT value FROM preservation_canary", [], |row| {
            row.get(0)
        })
        .unwrap();
    assert_eq!(canary, "must-survive");
    drop(connection);
    assert_eq!(
        read_strategy_store_format(&database).unwrap().format_id,
        "strategy-store-4"
    );

    let artifact: StrategyStoreArtifact =
        serde_json::from_slice(&fs::read(strategy_store_artifact_path(&root)).unwrap()).unwrap();
    assert_eq!(artifact.status, "applied");
    assert_eq!(artifact.from_format, "strategy-store-3");
    assert_eq!(
        artifact.applied_step_ids,
        vec!["adaptive-flywheel.strategy-store-notice-outbox".to_owned()]
    );

    // A second admission is a no-op: the shape is already current, so the
    // ordinary start path does not write.
    let before = strategy_table_names(&database);
    let second = admit(&root).unwrap();
    assert!(second.applied_domain_ids.is_empty());
    assert_eq!(strategy_table_names(&database), before);
    let _ = fs::remove_dir_all(root);
}

#[test]
fn an_interrupted_delivery_table_conversion_resumes_from_its_artifact() {
    let root = std::env::temp_dir().join(format!(
        "licoup-notice-outbox-resume-{}",
        uuid::Uuid::new_v4()
    ));
    let database = root.join(STRATEGY_STORE_DATABASE);
    published_strategy_store_v3(&database);

    {
        let _guard = MigrationFailpointGuard::set("before-notice-outbox");
        assert_eq!(
            admit(&root).unwrap_err().to_string(),
            "migration_step_failed"
        );
    }
    // The crash left the recovery record and nothing else: the store is
    // still the published shape, so the next run converts rather than
    // believing a conversion that never happened.
    let artifact: StrategyStoreArtifact =
        serde_json::from_slice(&fs::read(strategy_store_artifact_path(&root)).unwrap()).unwrap();
    assert_eq!(artifact.status, "pending");
    assert!(artifact.applied_step_ids.is_empty());
    assert_eq!(
        read_strategy_store_format(&database).unwrap().format_id,
        "strategy-store-3"
    );

    admit(&root).unwrap();
    assert_eq!(
        read_strategy_store_format(&database).unwrap().format_id,
        "strategy-store-4"
    );
    let artifact: StrategyStoreArtifact =
        serde_json::from_slice(&fs::read(strategy_store_artifact_path(&root)).unwrap()).unwrap();
    assert_eq!(artifact.status, "applied");
    let _ = fs::remove_dir_all(root);
}

#[test]
fn a_store_whose_delivery_tables_are_not_the_published_shape_is_refused() {
    let root = std::env::temp_dir().join(format!(
        "licoup-notice-outbox-shape-{}",
        uuid::Uuid::new_v4()
    ));
    let database = root.join(STRATEGY_STORE_DATABASE);
    published_strategy_store_v3(&database);
    let connection = Connection::open(&database).unwrap();
    connection
        .execute(
            "CREATE TABLE workflow_notice_intents(notice_id TEXT PRIMARY KEY)",
            [],
        )
        .unwrap();
    drop(connection);

    // No published format has this shape, so the probe refuses it and the
    // migration never runs: papering the difference over with `IF NOT
    // EXISTS` is how a half-migrated store gets adopted as a whole one.
    assert_eq!(
        admit(&root).unwrap_err().to_string(),
        "unsupported_state_shape"
    );
    let connection = Connection::open(&database).unwrap();
    assert_eq!(
        strategy_table_columns(&connection, "workflow_notice_intents").unwrap(),
        vec!["notice_id".to_owned()]
    );
    assert!(
        strategy_table_columns(&connection, "workflow_notice_acceptances")
            .unwrap()
            .is_empty()
    );
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

    assert_eq!(probe_adaptive_flywheel(&root).unwrap().version, 1);
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

/// A database that only declares the current schema version is not a
/// conversation store: the admission reads the completion marker, so a
/// fabricated file would otherwise become the canonical owner's state.
#[test]
fn a_fabricated_conversation_store_is_refused_rather_than_admitted() {
    let root = std::env::temp_dir().join(format!(
        "licoup-conversation-fabricated-{}",
        uuid::Uuid::new_v4()
    ));
    let database = root.join("client-state/conversations/conversations.sqlite3");
    fs::create_dir_all(database.parent().unwrap()).unwrap();
    let connection = Connection::open(&database).unwrap();
    connection
        .execute_batch(
            "CREATE TABLE schema_meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
                 INSERT INTO schema_meta(key,value) VALUES ('version','18');
                 CREATE TABLE conversations(
                   conversation_id TEXT PRIMARY KEY, title TEXT NOT NULL,
                   created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL
                 );
                 CREATE TABLE conversation_messages(
                   message_id TEXT PRIMARY KEY, conversation_id TEXT NOT NULL,
                   role TEXT NOT NULL, content TEXT NOT NULL, created_at INTEGER NOT NULL
                 );",
        )
        .unwrap();
    drop(connection);
    fs::write(
        root.join("client-state/conversations/migration-v5.complete"),
        "schema=v5\nstatus=complete\n",
    )
    .unwrap();

    assert_eq!(
        admit(&root).unwrap_err().to_string(),
        "unsupported_state_shape"
    );
    // The refusal happens before any ledger or domain marker is written, so
    // the root is left exactly as it was found.
    assert!(!root.join("client-state/migrations/ledger.json").exists());
    assert!(
        !root
            .join("client-state/migrations/domain-state/canonical-conversation.json")
            .exists()
    );
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
