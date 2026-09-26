use super::strategy_store::{probe_adaptive_flywheel, published_table_columns};
use super::*;

pub(super) fn marker_path(root: &Path, domain_id: &str) -> PathBuf {
    root.join(format!("{domain_id}.json"))
}

pub(super) fn probe_domain(root: &Path, domain: &DomainFrontier) -> Result<u32> {
    let marker = load_domain_marker(root, domain)?;
    let authoritative = probe_authoritative_store(root, &domain.domain_id)?;
    ensure!(
        authoritative.version <= domain.target_schema_version,
        "state_newer_than_binary"
    );
    if authoritative.version > 0 {
        ensure!(
            marker.as_ref().is_none_or(|marker| {
                marker.authoritative_schema_version <= authoritative.version
            }),
            "unsupported_state_shape"
        );
        return Ok(authoritative.version);
    }
    ensure!(
        !authoritative.present
            || marker
                .as_ref()
                .is_none_or(|marker| marker.authoritative_schema_version == 0),
        "unsupported_state_shape"
    );
    Ok(marker
        .map(|marker| marker.authoritative_schema_version)
        .unwrap_or(0))
}

pub(super) fn load_domain_marker(
    root: &Path,
    domain: &DomainFrontier,
) -> Result<Option<DomainMarker>> {
    let path = marker_path(root, &domain.domain_id);
    let Some(raw) =
        crate::platform::file_security::read_existing_private_text_bounded(&path, 16 * 1024)
            .context("unsupported_state_shape")?
    else {
        return Ok(None);
    };
    let marker: DomainMarker = serde_json::from_str(&raw).context("unsupported_state_shape")?;
    ensure!(
        marker.schema_version == DOMAIN_MARKER_SCHEMA && marker.domain_id == domain.domain_id,
        "unsupported_state_shape"
    );
    ensure!(
        marker.authoritative_schema_version <= domain.target_schema_version,
        "state_newer_than_binary"
    );
    Ok(Some(marker))
}

pub(super) fn reconcile_current_marker(root: &Path, domain: &DomainFrontier) -> Result<()> {
    if load_domain_marker(root, domain)?
        .is_some_and(|marker| marker.authoritative_schema_version == domain.target_schema_version)
    {
        return Ok(());
    }
    write_json_atomic(
        &marker_path(root, &domain.domain_id),
        &DomainMarker {
            schema_version: DOMAIN_MARKER_SCHEMA.to_owned(),
            domain_id: domain.domain_id.clone(),
            authoritative_schema_version: domain.target_schema_version,
        },
    )
    .context("migration_step_failed")
}

pub(super) fn apply_marker_step(
    root: &Path,
    domain: &DomainFrontier,
    edge: &MigrationEdge,
) -> Result<()> {
    apply_authoritative_store(root, &domain.domain_id, edge)?;
    let marker = DomainMarker {
        schema_version: DOMAIN_MARKER_SCHEMA.to_owned(),
        domain_id: domain.domain_id.clone(),
        authoritative_schema_version: edge.to_schema_version,
    };
    write_json_atomic(&marker_path(root, &domain.domain_id), &marker)
        .context("migration_step_failed")
}

pub(super) fn portable_root(marker_root: &Path) -> Result<&Path> {
    marker_root
        .parent()
        .and_then(Path::parent)
        .and_then(Path::parent)
        .ok_or_else(|| anyhow!("unsupported_state_shape"))
}

/// Store absence is represented by version 0 so the immutable 0→1 step is
/// still reconciled in the ledger. Presence stays separate from the version:
/// an existing legacy store can never be hidden by an already-current domain
/// marker after an unsupported old writer or external replacement.
pub(super) fn probe_authoritative_store(
    marker_root: &Path,
    domain_id: &str,
) -> Result<AuthoritativeProbe> {
    let root = portable_root(marker_root)?;
    match domain_id {
        "gateway-credential-custody" => Ok(AuthoritativeProbe {
            version: 0,
            present: false,
        }),
        "client-state" => {
            let (version, present) = crate::platform::client_state::probe_collections(root)?;
            Ok(AuthoritativeProbe { version, present })
        }
        "canonical-conversation" => probe_canonical_conversation(root),
        "adaptive-flywheel" => probe_adaptive_flywheel(root),
        "workspace-manifest" => probe_json_schema(
            &root.join(".licoup-workspace.json"),
            1,
            JsonSchemaPolicy::CurrentOnly,
        ),
        "appearance-presentation" => probe_json_schema(
            &root.join("client-state/appearance-preferences.json"),
            1,
            JsonSchemaPolicy::MissingIsLegacy,
        ),
        "mobile-relay" => probe_mobile_relay(&root.join("client-state/mobile-relay/config.json")),
        "agent-tab-order" => probe_agent_tab_order(&root.join("client-state/agent-tab-order.json")),
        "agent-tool-allowlist" => probe_json_schema(
            &root.join("client-state/agent-tool-allowlists.json"),
            1,
            JsonSchemaPolicy::CurrentOnly,
        ),
        "current-view" => probe_json_schema(
            &root.join("client-state/current-client-view.json"),
            1,
            JsonSchemaPolicy::CurrentOnly,
        ),
        "mobile-home-layout" => probe_json_schema(
            &root.join("client-state/mobile-home-layout.json"),
            2,
            JsonSchemaPolicy::CurrentOnly,
        ),
        "skill-hub-preferences" => probe_json_schema(
            &root.join("client-state/skill-hub-preferences.json"),
            1,
            JsonSchemaPolicy::CurrentOnly,
        ),
        _ => bail!("migration_frontier_incomplete"),
    }
}

pub(super) fn probe_agent_tab_order(path: &Path) -> Result<AuthoritativeProbe> {
    if !regular_file_present(path)? {
        return Ok(AuthoritativeProbe {
            version: 0,
            present: false,
        });
    }
    let raw = fs::read(path).context("unsupported_state_shape")?;
    ensure!(raw.len() <= 4 * 1024 * 1024, "unsupported_state_shape");
    let value: serde_json::Value =
        serde_json::from_slice(&raw).context("unsupported_state_shape")?;
    if value.is_array() {
        return Ok(AuthoritativeProbe {
            version: 0,
            present: true,
        });
    }
    probe_json_schema(path, 1, JsonSchemaPolicy::CurrentOnly)
}

/// The table every published conversation store carries, whatever generation
/// wrote it.
///
/// An existing conversation database is admitted as domain version 1 on the
/// strength of its completion marker, so the probe has to say "this is a
/// conversation store at all" from what is physically in the file. The check is
/// the oldest common denominator: `schema_meta` and the conversation identity
/// columns. Every published SQLite generation has both (`conversations.id` and
/// `title` appear in the first versioned fixtures), older inner schemas are
/// upgraded by the store's own open path, and a file that only carries a
/// version row is not a store any reader ever wrote. Without this, a fabricated
/// database that merely declares the current version would be admitted as the
/// canonical conversation owner.
pub(super) fn ensure_conversation_store_shape(connection: &Connection) -> Result<()> {
    for (table, columns) in [
        ("schema_meta", &["key", "value"] as &[&str]),
        ("conversations", &["id", "title"]),
    ] {
        let present = published_table_columns(connection, table)?;
        ensure!(
            !present.is_empty()
                && columns
                    .iter()
                    .all(|column| present.iter().any(|name| name == column)),
            "unsupported_state_shape"
        );
    }
    Ok(())
}

pub(super) fn probe_canonical_conversation(root: &Path) -> Result<AuthoritativeProbe> {
    let database = root.join("client-state/conversations/conversations.sqlite3");
    let completion_marker = root.join("client-state/conversations/migration-v5.complete");
    let database_present = regular_file_present(&database)?;
    let completion_present = regular_file_present(&completion_marker)?;
    let legacy_present = canonical_legacy_state_present(root)?;
    if database_present {
        let connection = Connection::open_with_flags(
            &database,
            rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY | rusqlite::OpenFlags::SQLITE_OPEN_NO_MUTEX,
        )
        .context("unsupported_state_shape")?;
        ensure_conversation_store_shape(&connection)?;
    }
    probe_sqlite_meta(
        &database,
        "schema_meta",
        "version",
        licoup_conversation::store::CURRENT_SCHEMA_VERSION,
    )?;
    if !database_present {
        ensure!(!completion_present, "unsupported_state_shape");
        return Ok(AuthoritativeProbe {
            version: 0,
            present: legacy_present,
        });
    }
    if !completion_present {
        return Ok(AuthoritativeProbe {
            version: 0,
            present: true,
        });
    }
    ensure!(!legacy_present, "unsupported_state_shape");
    let value = fs::read_to_string(completion_marker).context("unsupported_state_shape")?;
    ensure!(
        value == "schema=v5\nstatus=complete\n",
        "unsupported_state_shape"
    );
    // Frontier version 1 means "this conversation store exists". The inner
    // SQLite schema advances through in-store upgrades. Reporting 0 for an
    // older-but-known schema fights the already-written domain marker and
    // blocks startup admission with unsupported_state_shape.
    Ok(AuthoritativeProbe {
        version: 1,
        present: true,
    })
}

/// When the conversation domain is already admitted, still apply a newer
/// inner SQLite schema before `ConversationStore::open` serves the store.
pub(super) fn upgrade_canonical_conversation_schema(root: &Path) -> Result<()> {
    let database = root.join("client-state/conversations/conversations.sqlite3");
    if !regular_file_present(&database)? {
        return Ok(());
    }
    if probe_sqlite_meta(
        &database,
        "schema_meta",
        "version",
        licoup_conversation::store::CURRENT_SCHEMA_VERSION,
    )?
    .version
        == 1
    {
        return Ok(());
    }
    crate::domain::client_conversation::ConversationStore::open_for_migration(root)
        .context("migration_step_failed")?;
    ensure!(
        probe_sqlite_meta(
            &database,
            "schema_meta",
            "version",
            licoup_conversation::store::CURRENT_SCHEMA_VERSION,
        )?
        .version
            == 1,
        "migration_postcondition_failed"
    );
    Ok(())
}

pub(super) fn probe_mobile_relay(path: &Path) -> Result<AuthoritativeProbe> {
    if !regular_file_present(path)? {
        return Ok(AuthoritativeProbe {
            version: 0,
            present: false,
        });
    }
    let raw = fs::read(path).context("unsupported_state_shape")?;
    ensure!(raw.len() <= 4 * 1024 * 1024, "unsupported_state_shape");
    let mut value: serde_json::Value =
        serde_json::from_slice(&raw).context("unsupported_state_shape")?;
    match value.get("schemaVersion").and_then(Value::as_u64) {
        Some(2) => {
            crate::domain::mobile_relay::validate_current_config_document(&value)
                .context("unsupported_state_shape")?;
            Ok(AuthoritativeProbe {
                version: 1,
                present: true,
            })
        }
        Some(0 | 1) => {
            crate::domain::mobile_relay::migrate_config_document(&mut value)
                .context("unsupported_state_shape")?;
            Ok(AuthoritativeProbe {
                version: 0,
                present: true,
            })
        }
        Some(_) => bail!("state_newer_than_binary"),
        None => bail!("unsupported_state_shape"),
    }
}

pub(super) fn probe_sqlite_meta(
    path: &Path,
    table: &str,
    key: &str,
    current: &str,
) -> Result<AuthoritativeProbe> {
    if !regular_file_present(path)? {
        return Ok(AuthoritativeProbe {
            version: 0,
            present: false,
        });
    }
    let connection = Connection::open_with_flags(
        path,
        rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY | rusqlite::OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )
    .context("unsupported_state_shape")?;
    let sql = format!("SELECT value FROM {table} WHERE key=?1");
    let value: Option<String> = connection
        .query_row(&sql, [key], |row| row.get(0))
        .optional()
        .context("unsupported_state_shape")?;
    match value.as_deref() {
        Some(value) if value == current => Ok(AuthoritativeProbe {
            version: 1,
            present: true,
        }),
        Some(value)
            if value.parse::<u32>().is_ok_and(|value| {
                value < current.parse::<u32>().expect("current schema is numeric")
            }) =>
        {
            Ok(AuthoritativeProbe {
                version: 0,
                present: true,
            })
        }
        Some(value)
            if value.parse::<u32>().is_ok_and(|value| {
                value > current.parse::<u32>().expect("current schema is numeric")
            }) =>
        {
            bail!("state_newer_than_binary")
        }
        _ => bail!("unsupported_state_shape"),
    }
}

#[derive(Clone, Copy)]
pub(super) enum JsonSchemaPolicy {
    CurrentOnly,
    MissingIsLegacy,
}

pub(super) fn probe_json_schema(
    path: &Path,
    current: u64,
    policy: JsonSchemaPolicy,
) -> Result<AuthoritativeProbe> {
    if !regular_file_present(path)? {
        return Ok(AuthoritativeProbe {
            version: 0,
            present: false,
        });
    }
    let raw = fs::read(path).context("unsupported_state_shape")?;
    ensure!(raw.len() <= 4 * 1024 * 1024, "unsupported_state_shape");
    let value: serde_json::Value =
        serde_json::from_slice(&raw).context("unsupported_state_shape")?;
    ensure!(value.is_object(), "unsupported_state_shape");
    match value
        .get("schemaVersion")
        .and_then(serde_json::Value::as_u64)
    {
        Some(version) if version == current => Ok(AuthoritativeProbe {
            version: 1,
            present: true,
        }),
        None if matches!(policy, JsonSchemaPolicy::MissingIsLegacy) => Ok(AuthoritativeProbe {
            version: 0,
            present: true,
        }),
        Some(version) if version > current => bail!("state_newer_than_binary"),
        Some(_) => bail!("unsupported_state_shape"),
        None => bail!("unsupported_state_shape"),
    }
}

pub(super) fn regular_file_present(path: &Path) -> Result<bool> {
    match fs::symlink_metadata(path) {
        Ok(metadata) => {
            ensure!(
                metadata.is_file() && !metadata.file_type().is_symlink(),
                "unsupported_state_shape"
            );
            Ok(true)
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(false),
        Err(_) => bail!("unsupported_state_shape"),
    }
}

pub(super) fn canonical_legacy_state_present(root: &Path) -> Result<bool> {
    let state_root = root.join("client-state");
    for path in [
        state_root.join("agent-conversation-projections.json"),
        state_root.join("adaptive-flywheel.toml"),
    ] {
        if regular_file_present(&path)? {
            return Ok(true);
        }
    }
    let group_root = state_root.join("group-conversations");
    match fs::symlink_metadata(group_root) {
        Ok(metadata) => {
            ensure!(
                metadata.is_dir() && !metadata.file_type().is_symlink(),
                "unsupported_state_shape"
            );
            Ok(true)
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(false),
        Err(_) => bail!("unsupported_state_shape"),
    }
}

pub(super) fn apply_authoritative_store(
    marker_root: &Path,
    domain_id: &str,
    edge: &MigrationEdge,
) -> Result<()> {
    ensure!(
        migration_handler_target(domain_id, edge.from_schema_version)
            == Some(edge.to_schema_version),
        "migration_frontier_incomplete"
    );
    let root = portable_root(marker_root)?;
    match domain_id {
        "gateway-credential-custody" => bail!("migration_authorization_required"),
        "client-state" => {
            crate::platform::client_state::migrate_collections(root)
                .context("migration_step_failed")?;
        }
        "canonical-conversation" => {
            let store =
                crate::domain::client_conversation::ConversationStore::open_for_migration(root)
                    .context("migration_step_failed")?;
            crate::domain::client_conversation::migrate_legacy_state(&store, root)
                .context("migration_step_failed")?;
            store.checkpoint().context("migration_step_failed")?;
        }
        "adaptive-flywheel" => {
            // The domain edge names the published store format it produces;
            // `advance_strategy_store` drives the conversion graph to that
            // format, so the earlier edges delegate to the published writer and
            // the newest one is performed here. StrategyStore's own migrations
            // execute in SQLite transactions; a failed process resumes from the
            // format the file declares.
            let target = strategy_format_for_domain_version(edge.to_schema_version)?;
            advance_strategy_store(root, target)?;
        }
        "workspace-manifest" => migrate_json_schema(
            &root.join(".licoup-workspace.json"),
            1,
            JsonSchemaPolicy::CurrentOnly,
        )?,
        "appearance-presentation" => migrate_json_schema(
            &root.join("client-state/appearance-preferences.json"),
            1,
            JsonSchemaPolicy::MissingIsLegacy,
        )?,
        "mobile-relay" => {
            migrate_mobile_relay(&root.join("client-state/mobile-relay/config.json"))?
        }
        "agent-tab-order" => {
            migrate_agent_tab_order(&root.join("client-state/agent-tab-order.json"))?
        }
        "agent-tool-allowlist" => migrate_json_schema(
            &root.join("client-state/agent-tool-allowlists.json"),
            1,
            JsonSchemaPolicy::CurrentOnly,
        )?,
        "current-view" => migrate_json_schema(
            &root.join("client-state/current-client-view.json"),
            1,
            JsonSchemaPolicy::CurrentOnly,
        )?,
        "mobile-home-layout" => migrate_json_schema(
            &root.join("client-state/mobile-home-layout.json"),
            2,
            JsonSchemaPolicy::CurrentOnly,
        )?,
        "skill-hub-preferences" => migrate_json_schema(
            &root.join("client-state/skill-hub-preferences.json"),
            1,
            JsonSchemaPolicy::CurrentOnly,
        )?,
        _ => bail!("migration_frontier_incomplete"),
    }
    Ok(())
}

pub(super) fn migration_handler_target(domain_id: &str, from_schema_version: u32) -> Option<u32> {
    if domain_id == "adaptive-flywheel" && from_schema_version == 1 {
        return Some(2);
    }
    matches!(
        (domain_id, from_schema_version),
        (
            "client-state"
                | "canonical-conversation"
                | "adaptive-flywheel"
                | "workspace-manifest"
                | "appearance-presentation"
                | "mobile-relay"
                | "agent-tab-order"
                | "agent-tool-allowlist"
                | "current-view"
                | "gateway-credential-custody"
                | "mobile-home-layout"
                | "skill-hub-preferences",
            0
        )
    )
    .then_some(1)
}

pub(super) fn migrate_agent_tab_order(path: &Path) -> Result<()> {
    if !path.exists() {
        return Ok(());
    }
    let raw = fs::read(path).context("migration_step_failed")?;
    ensure!(raw.len() <= 4 * 1024 * 1024, "unsupported_state_shape");
    let value: serde_json::Value =
        serde_json::from_slice(&raw).context("unsupported_state_shape")?;
    if let Some(order) = value.as_array() {
        return write_json_atomic(path, &json!({"schemaVersion": 1, "order": order}))
            .context("migration_step_failed");
    }
    migrate_json_schema(path, 1, JsonSchemaPolicy::CurrentOnly)
}

pub(super) fn migrate_mobile_relay(path: &Path) -> Result<()> {
    if !path.exists() {
        return Ok(());
    }
    let raw = fs::read(path).context("migration_step_failed")?;
    ensure!(raw.len() <= 4 * 1024 * 1024, "unsupported_state_shape");
    let mut value: serde_json::Value =
        serde_json::from_slice(&raw).context("unsupported_state_shape")?;
    crate::domain::mobile_relay::migrate_config_document(&mut value)
        .context("unsupported_state_shape")?;
    write_json_atomic(path, &value).context("migration_step_failed")
}

pub(super) fn migrate_json_schema(
    path: &Path,
    current: u64,
    policy: JsonSchemaPolicy,
) -> Result<()> {
    if !path.exists() {
        return Ok(());
    }
    let raw = fs::read(path).context("migration_step_failed")?;
    ensure!(raw.len() <= 4 * 1024 * 1024, "unsupported_state_shape");
    let mut value: serde_json::Value =
        serde_json::from_slice(&raw).context("unsupported_state_shape")?;
    let object = value
        .as_object_mut()
        .ok_or_else(|| anyhow!("unsupported_state_shape"))?;
    match object
        .get("schemaVersion")
        .and_then(serde_json::Value::as_u64)
    {
        None if matches!(policy, JsonSchemaPolicy::MissingIsLegacy) => {}
        Some(version) if version == current => return Ok(()),
        Some(version) if version > current => bail!("state_newer_than_binary"),
        Some(_) => bail!("unsupported_state_shape"),
        None => bail!("unsupported_state_shape"),
    }
    object.insert("schemaVersion".to_owned(), json!(current));
    write_json_atomic(path, &value).context("migration_step_failed")
}
