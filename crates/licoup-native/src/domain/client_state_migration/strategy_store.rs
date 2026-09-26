use super::*;
use crate::state_machines::strategy_store_artifact;

// ---------------------------------------------------------------------------
// Published strategy-store formats and the conversion graph over them
// ---------------------------------------------------------------------------
//
// The strategy database is one file with more than one published shape. The
// frontier versions a *domain* (0..2 today); the file has shipped further
// shapes under those same domain versions, which is what this section records
// and converts.
//
// The rule for every format below is the same one the plan states for published
// contracts: **a published format is immutable**. Each entry describes a shape
// that already shipped, an entry is never edited into a new shape, and a
// conversion *reads* the old shape and *writes* the next one. Nothing here may
// declare the old shape, which is why the probe opens the file read-only and
// asks `sqlite_master`/`PRAGMA table_info` what is actually there: inspecting an
// old database by running `CREATE TABLE IF NOT EXISTS` against it would answer
// the question with the answer we just wrote.

/// The strategy database, at the path the published writer used.
pub(super) const STRATEGY_STORE_DATABASE: &str =
    "client-state/adaptive-flywheel/strategies.sqlite3";

/// Recovery record for one strategy-store conversion.
///
/// It is written before the first store-format edge runs, one step id is
/// appended after each edge's postcondition holds, and it is marked applied at
/// the end. An interrupted conversion therefore resumes from the physical
/// format the file actually reached — the artifact states what was attempted,
/// the file states what happened, and the next run drives from the file.
pub(super) const STRATEGY_STORE_ARTIFACT: &str =
    "client-state/migrations/artifacts/adaptive-flywheel-strategy-store.json";
pub(super) const STRATEGY_STORE_ARTIFACT_SCHEMA: &str =
    "v0.0.1:strategy-store-conversion-artifact-1";

/// One table of a published store format: the columns a reader of that format
/// relies on, and the statements that create it exactly as published.
pub(super) struct PublishedTable {
    pub(super) name: &'static str,
    pub(super) columns: &'static [&'static str],
    pub(super) statements: &'static [&'static str],
}

/// The delivery-intent tables the current format adds.
///
/// This is the published definition of `licoup-workflow-store`'s own schema,
/// restated here because the conversion has to perform the move itself: the
/// store adds these tables when *it* opens the file, which is a second writer
/// silently changing a format on every open. The migration is the explicit,
/// locked, journalled path to the same shape, and
/// `tools/data-migration/tests/notice-outbox-ddl-parity.test.mjs` holds the two
/// definitions equal, column by column.
pub(super) const NOTICE_OUTBOX_TABLES: &[PublishedTable] = &[
    PublishedTable {
        name: "workflow_notice_intents",
        columns: &[
            "notice_id",
            "run_id",
            "sequence",
            "recipient",
            "kind",
            "status",
            "created_at",
            "accepted_at",
        ],
        statements: &[
            "CREATE TABLE workflow_notice_intents(
               notice_id TEXT PRIMARY KEY,
               run_id TEXT NOT NULL,
               sequence INTEGER NOT NULL,
               recipient TEXT NOT NULL,
               kind TEXT NOT NULL,
               status TEXT NOT NULL CHECK(status IN ('pending', 'accepted')),
               created_at INTEGER NOT NULL,
               accepted_at INTEGER
             )",
            "CREATE INDEX workflow_notice_intents_pending_idx
               ON workflow_notice_intents(status, created_at, run_id, sequence, notice_id)",
        ],
    },
    PublishedTable {
        name: "workflow_notice_acceptances",
        columns: &[
            "notice_id",
            "run_id",
            "sequence",
            "recipient",
            "kind",
            "accept_count",
            "first_accepted_at",
            "last_accepted_at",
        ],
        statements: &["CREATE TABLE workflow_notice_acceptances(
               notice_id TEXT PRIMARY KEY,
               run_id TEXT NOT NULL,
               sequence INTEGER NOT NULL,
               recipient TEXT NOT NULL,
               kind TEXT NOT NULL,
               accept_count INTEGER NOT NULL,
               first_accepted_at INTEGER NOT NULL,
               last_accepted_at INTEGER NOT NULL
             )"],
    },
];

/// A published shape of the strategy database, as data.
pub(super) struct PublishedStrategyFormat {
    pub(super) format_id: &'static str,
    /// Every `strategy_meta.version` this shape shipped under. One published
    /// writer stamped `0` before it stamped `1`; both are the same shape.
    pub(super) meta_versions: &'static [&'static str],
    /// The frontier domain version this shape answers to. A store format that
    /// only adds tables does not move the domain version, because the rows the
    /// frontier versions are unchanged.
    pub(super) domain_schema_version: u32,
    /// Tables that must be present, with the columns a reader relies on.
    pub(super) required: &'static [(&'static str, &'static [&'static str])],
    /// Columns checked only when their table is present: a file that predates
    /// a table is a file of this format, not a file to refuse.
    pub(super) columns: &'static [(&'static str, &'static [&'static str])],
    /// Tables this shape does not have. This is what separates the two shapes
    /// that share `strategy_meta.version = '3'`.
    pub(super) absent: &'static [&'static str],
}

/// The publication history of the strategy database, oldest first.
pub(super) const PUBLISHED_STRATEGY_FORMATS: &[PublishedStrategyFormat] = &[
    PublishedStrategyFormat {
        format_id: "strategy-store-1",
        meta_versions: &["0", "1"],
        domain_schema_version: 0,
        required: &[("strategy_meta", &["key", "value"])],
        columns: &[(
            "strategy_bindings",
            &["revision_digest", "slot_id", "value_id", "revision"],
        )],
        absent: &NOTICE_OUTBOX_TABLE_NAMES,
    },
    PublishedStrategyFormat {
        format_id: "strategy-store-2",
        meta_versions: &["2"],
        domain_schema_version: 1,
        required: &[("strategy_meta", &["key", "value"])],
        columns: &[(
            "strategy_bindings",
            &["ordinal", "value_id", "model", "reasoning_effort"],
        )],
        absent: &NOTICE_OUTBOX_TABLE_NAMES,
    },
    PublishedStrategyFormat {
        format_id: "strategy-store-3",
        meta_versions: &["3"],
        domain_schema_version: 2,
        required: &[("strategy_meta", &["key", "value"])],
        columns: &[(
            "strategy_runs",
            &["snapshot_json", "conversation_id", "terminal"],
        )],
        absent: &NOTICE_OUTBOX_TABLE_NAMES,
    },
    PublishedStrategyFormat {
        format_id: "strategy-store-4",
        meta_versions: &["3"],
        domain_schema_version: 2,
        required: &[
            ("strategy_meta", &["key", "value"]),
            ("workflow_notice_intents", NOTICE_OUTBOX_TABLES[0].columns),
            (
                "workflow_notice_acceptances",
                NOTICE_OUTBOX_TABLES[1].columns,
            ),
        ],
        columns: &[(
            "strategy_runs",
            &["snapshot_json", "conversation_id", "terminal"],
        )],
        absent: &[],
    },
];

pub(super) const NOTICE_OUTBOX_TABLE_NAMES: &[&str] =
    &["workflow_notice_intents", "workflow_notice_acceptances"];

/// Who performs one store-format edge.
#[derive(Clone, Copy, Eq, PartialEq)]
pub(super) enum StrategyStoreMover {
    /// The published writer's own typed migration. Reimplementing it here would
    /// be a second definition of the same published shape, so the edge drives
    /// the owner's migration and reads the result back.
    PublishedWriter,
    /// The conversion this module performs, because the store only reaches this
    /// shape as a side effect of opening the file.
    NoticeOutbox,
}

pub(super) struct StrategyStoreEdge {
    pub(super) step_id: &'static str,
    pub(super) from: &'static str,
    pub(super) to: &'static str,
    pub(super) mover: StrategyStoreMover,
}

/// The conversion graph over the published strategy-store formats.
///
/// Edges are keyed by the shape they move *from*, and a shape has exactly one
/// successor, so a conversion from any published format to the current one is a
/// unique path. `strategy_store_path` refuses a gap instead of guessing a move.
pub(super) const STRATEGY_STORE_EDGES: &[StrategyStoreEdge] = &[
    StrategyStoreEdge {
        step_id: "adaptive-flywheel.strategy-store-ordinal-bindings",
        from: "strategy-store-1",
        to: "strategy-store-2",
        mover: StrategyStoreMover::PublishedWriter,
    },
    StrategyStoreEdge {
        step_id: "adaptive-flywheel.strategy-store-workflow-routing",
        from: "strategy-store-2",
        to: "strategy-store-3",
        mover: StrategyStoreMover::PublishedWriter,
    },
    StrategyStoreEdge {
        step_id: "adaptive-flywheel.strategy-store-notice-outbox",
        from: "strategy-store-3",
        to: "strategy-store-4",
        mover: StrategyStoreMover::NoticeOutbox,
    },
];

/// The published format that answers to one frontier domain version.
pub(super) fn strategy_format_for_domain_version(
    version: u32,
) -> Result<&'static PublishedStrategyFormat> {
    PUBLISHED_STRATEGY_FORMATS
        .iter()
        .find(|format| format.domain_schema_version == version)
        .ok_or_else(|| anyhow!("migration_frontier_incomplete"))
}

/// The current published format: the newest shape in the publication history.
pub(super) fn current_strategy_format() -> &'static PublishedStrategyFormat {
    PUBLISHED_STRATEGY_FORMATS
        .last()
        .expect("the strategy publication history is not empty")
}

pub(super) fn strategy_format_position(format_id: &str) -> Result<usize> {
    PUBLISHED_STRATEGY_FORMATS
        .iter()
        .position(|format| format.format_id == format_id)
        .ok_or_else(|| anyhow!("migration_frontier_incomplete"))
}

/// The unique conversion path from one published format to another.
pub(super) fn strategy_store_path(from: &str, to: &str) -> Result<Vec<&'static StrategyStoreEdge>> {
    let target = strategy_format_position(to)?;
    let mut cursor = strategy_format_position(from)?;
    let mut path = Vec::new();
    while cursor < target {
        let current = PUBLISHED_STRATEGY_FORMATS[cursor].format_id;
        let edge = STRATEGY_STORE_EDGES
            .iter()
            .find(|edge| edge.from == current)
            .ok_or_else(|| anyhow!("migration_frontier_incomplete"))?;
        path.push(edge);
        cursor = strategy_format_position(edge.to)?;
    }
    ensure!(
        cursor == target && path.iter().all(|edge| edge.to != from),
        "migration_frontier_incomplete"
    );
    Ok(path)
}

pub(super) fn published_table_columns(connection: &Connection, table: &str) -> Result<Vec<String>> {
    ensure!(
        table
            .bytes()
            .all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit() || byte == b'_'),
        "unsupported_state_shape"
    );
    let mut statement = connection.prepare(&format!("PRAGMA table_info({table})"))?;
    let names = statement
        .query_map([], |row| row.get::<_, String>(1))?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    Ok(names)
}

pub(super) fn strategy_table_columns(connection: &Connection, table: &str) -> Result<Vec<String>> {
    published_table_columns(connection, table)
}

pub(super) fn strategy_table_has_columns(
    connection: &Connection,
    table: &str,
    required: &[&str],
) -> Result<bool> {
    let present = strategy_table_columns(connection, table)?;
    Ok(required
        .iter()
        .all(|column| present.iter().any(|name| name == column)))
}

/// Read which published format a real file holds.
///
/// Read-only, and by construction unable to declare a shape: the answer comes
/// from the file's own `strategy_meta` row and from the tables and columns that
/// are physically there. A file that matches no published format is refused
/// rather than converted, and a file whose version is ahead of this binary is
/// refused as `state_newer_than_binary` — the same two answers the domain probe
/// gives.
pub(super) fn read_strategy_store_format(path: &Path) -> Result<&'static PublishedStrategyFormat> {
    ensure!(regular_file_present(path)?, "unsupported_state_shape");
    let connection = Connection::open_with_flags(
        path,
        rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY | rusqlite::OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )
    .context("unsupported_state_shape")?;
    read_strategy_store_format_on(&connection)
}

pub(super) fn read_strategy_store_format_on(
    connection: &Connection,
) -> Result<&'static PublishedStrategyFormat> {
    let version: Option<String> = connection
        .query_row(
            "SELECT value FROM strategy_meta WHERE key='version'",
            [],
            |row| row.get(0),
        )
        .optional()
        .context("unsupported_state_shape")?;
    let version = version.ok_or_else(|| anyhow!("unsupported_state_shape"))?;
    if let Ok(numeric) = version.parse::<u32>() {
        ensure!(
            numeric <= current_strategy_meta_version(),
            "state_newer_than_binary"
        );
    }
    for format in PUBLISHED_STRATEGY_FORMATS {
        if !format.meta_versions.contains(&version.as_str()) {
            continue;
        }
        let mut matches = true;
        for (table, columns) in format.required {
            if !strategy_table_has_columns(connection, table, columns)? {
                matches = false;
                break;
            }
        }
        for (table, columns) in format.columns {
            let present = strategy_table_columns(connection, table)?;
            if !present.is_empty()
                && !columns
                    .iter()
                    .all(|column| present.iter().any(|name| name == column))
            {
                matches = false;
                break;
            }
        }
        for table in format.absent {
            if !strategy_table_columns(connection, table)?.is_empty() {
                matches = false;
                break;
            }
        }
        if matches {
            return Ok(format);
        }
    }
    bail!("unsupported_state_shape")
}

pub(super) fn current_strategy_meta_version() -> u32 {
    current_strategy_format()
        .meta_versions
        .iter()
        .filter_map(|version| version.parse::<u32>().ok())
        .max()
        .expect("the current strategy format has a numeric version")
}

pub(super) fn probe_adaptive_flywheel(root: &Path) -> Result<AuthoritativeProbe> {
    let path = root.join(STRATEGY_STORE_DATABASE);
    if !regular_file_present(&path)? {
        return Ok(AuthoritativeProbe {
            version: 0,
            present: false,
        });
    }
    let format = read_strategy_store_format(&path)?;
    Ok(AuthoritativeProbe {
        version: format.domain_schema_version,
        present: true,
    })
}

/// The recovery record of a strategy-store conversion.
#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct StrategyStoreArtifact {
    pub(super) schema_version: String,
    pub(super) domain_id: String,
    pub(super) from_format: String,
    pub(super) target_format: String,
    pub(super) applied_step_ids: Vec<String>,
    pub(super) status: String,
}

pub(super) fn strategy_store_artifact_path(root: &Path) -> PathBuf {
    root.join(STRATEGY_STORE_ARTIFACT)
}

/// Load the artifact for a conversion, or start one that records this chain.
///
/// One record per store, not per step: an admission can drive several
/// store-format edges (a format-1 file reaches the current format through all
/// three), and a record that could only describe one of them would lose the
/// chain exactly when a resume needs it. The `from_format` stays where the
/// first conversion began, `applied_step_ids` accumulates, and the target only
/// ever moves forward — a store cannot be un-converted by a later record.
pub(super) fn begin_strategy_store_artifact(
    root: &Path,
    from: &PublishedStrategyFormat,
    target: &PublishedStrategyFormat,
) -> Result<StrategyStoreArtifact> {
    let path = strategy_store_artifact_path(root);
    let mut artifact = if regular_file_present(&path)? {
        let raw =
            crate::platform::file_security::read_existing_private_text_bounded(&path, 64 * 1024)
                .context("migration_step_failed")?
                .ok_or_else(|| anyhow!("migration_step_failed"))?;
        let existing: StrategyStoreArtifact =
            serde_json::from_str(&raw).context("migration_step_failed")?;
        ensure!(
            existing.schema_version == STRATEGY_STORE_ARTIFACT_SCHEMA
                && existing.domain_id == STRATEGY_STORE_DOMAIN,
            "migration_step_failed"
        );
        ensure!(
            strategy_format_position(&existing.target_format)?
                <= strategy_format_position(target.format_id)?,
            "state_newer_than_binary"
        );
        existing
    } else {
        StrategyStoreArtifact {
            schema_version: STRATEGY_STORE_ARTIFACT_SCHEMA.to_owned(),
            domain_id: STRATEGY_STORE_DOMAIN.to_owned(),
            from_format: from.format_id.to_owned(),
            target_format: target.format_id.to_owned(),
            applied_step_ids: Vec::new(),
            status: strategy_store_artifact::INITIAL.as_str().to_owned(),
        }
    };
    artifact.target_format = target.format_id.to_owned();
    // Written before any edge runs, so a crash inside the conversion leaves a
    // record that claims only what is true: a step is in flight. The caller
    // marks it applied after the last edge's postcondition holds.
    artifact.status = strategy_store_artifact::transition(
        strategy_store_artifact::State::from_name(&artifact.status)
            .context("migration_step_failed")?,
        strategy_store_artifact::Event::Begin,
    )
    .context("migration_step_failed")?
    .as_str()
    .to_owned();
    if let Some(parent) = path.parent() {
        crate::platform::file_security::ensure_private_dir(parent)
            .context("migration_step_failed")?;
    }
    write_json_atomic(&path, &artifact).context("migration_step_failed")?;
    Ok(artifact)
}

pub(super) const STRATEGY_STORE_DOMAIN: &str = "adaptive-flywheel";

/// The conversion this module performs: the current format's delivery-intent
/// tables, created for real on the file that is there.
///
/// What the published format recorded about delivery is a body copy
/// (`workflow_transition_intents` carries `event_json`, `before_json`,
/// `after_json`); what the current format records is a reference to the
/// committed fact, plus the recipient and kind of the obligation. Those two
/// extra fields do not exist in any published row, and a migration may not
/// invent who owes what: fabricating an owner would create delivery work nobody
/// asked for. So the tables are created empty, the legacy rows are left exactly
/// where their owner wrote them, and the test that holds this is "no notice row
/// appears because an old transition intent existed".
pub(super) fn apply_strategy_store_notice_outbox(path: &Path) -> Result<()> {
    let mut connection = Connection::open(path).context("migration_step_failed")?;
    connection
        .execute_batch("PRAGMA foreign_keys=ON; PRAGMA busy_timeout=5000;")
        .context("migration_step_failed")?;
    let transaction = connection
        .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)
        .context("migration_step_failed")?;
    // The absence check and the creation run in one write transaction, so a
    // second writer racing this conversion commits either before the check or
    // after the commit — never in the window where the check has passed and the
    // tables do not exist yet. The statements are the published ones, without
    // `IF NOT EXISTS`: this is the explicit path, and a table that is somehow
    // already there must fail loudly rather than be silently adopted.
    for table in NOTICE_OUTBOX_TABLES {
        ensure!(
            strategy_table_columns(&transaction, table.name)?.is_empty(),
            "migration_step_failed"
        );
        for statement in table.statements {
            transaction
                .execute_batch(statement)
                .context("migration_step_failed")?;
        }
    }
    transaction.commit().context("migration_step_failed")
}

/// The published writer's own migration for one store-format edge.
///
/// The two calls are not interchangeable: one produces the ordinal-bindings
/// shape and leaves the version row at `2`, the other produces the canonical
/// routing shape and moves it to `3`. Naming them by the edge is what keeps
/// this list from quietly becoming a second definition of either shape.
pub(super) fn delegate_strategy_store_edge(edge: &StrategyStoreEdge, root: &Path) -> Result<()> {
    match edge.to {
        "strategy-store-2" => {
            crate::domain::workflow_store::StrategyStore::migrate_to_schema_2(root)
                .context("migration_step_failed")
        }
        "strategy-store-3" => {
            crate::domain::workflow_store::StrategyStore::open_for_migration(root)
                .context("migration_step_failed")
                .map(|_| ())
        }
        _ => bail!("migration_frontier_incomplete"),
    }
}

/// Drive the store from the format the file holds to `target`, one edge at a
/// time, checking the physical format after every edge.
pub(super) fn advance_strategy_store(
    root: &Path,
    target: &'static PublishedStrategyFormat,
) -> Result<Vec<&'static str>> {
    let path = root.join(STRATEGY_STORE_DATABASE);
    if !regular_file_present(&path)? {
        return Ok(Vec::new());
    }
    let observed = read_strategy_store_format(&path)?;
    if observed.format_id == target.format_id {
        // A store already at the target is left alone: this is the path every
        // ordinary start takes, and it must not write.
        return Ok(Vec::new());
    }
    ensure!(
        strategy_format_position(observed.format_id)? < strategy_format_position(target.format_id)?,
        // The published writer is forward-only. A store ahead of this binary is
        // not moved back by admission; that is the migration tool's downgrade
        // path, with its preservation step.
        "state_newer_than_binary"
    );
    let artifact_path = strategy_store_artifact_path(root);
    let mut artifact = begin_strategy_store_artifact(root, observed, target)?;
    let mut applied = Vec::new();
    for edge in strategy_store_path(observed.format_id, target.format_id)? {
        match edge.mover {
            StrategyStoreMover::PublishedWriter => {
                delegate_strategy_store_edge(edge, root)?;
            }
            StrategyStoreMover::NoticeOutbox => {
                migration_failpoint("before-notice-outbox")?;
                apply_strategy_store_notice_outbox(&path)?;
            }
        }
        let reached = read_strategy_store_format(&path)?;
        ensure!(
            reached.format_id == edge.to,
            "migration_postcondition_failed"
        );
        if !artifact
            .applied_step_ids
            .iter()
            .any(|id| id == edge.step_id)
        {
            artifact.applied_step_ids.push(edge.step_id.to_owned());
        }
        write_json_atomic(&artifact_path, &artifact).context("migration_step_failed")?;
        applied.push(edge.step_id);
    }
    // "Applied" means the store is at the shape this binary calls current. A
    // conversion that stopped at an intermediate shape leaves the record
    // pending, because the rest of the path is still owed.
    if target.format_id == current_strategy_format().format_id && artifact.status != "applied" {
        artifact.status = strategy_store_artifact::transition(
            strategy_store_artifact::State::from_name(&artifact.status)
                .context("migration_step_failed")?,
            strategy_store_artifact::Event::Complete,
        )
        .context("migration_step_failed")?
        .as_str()
        .to_owned();
        write_json_atomic(&artifact_path, &artifact).context("migration_step_failed")?;
    }
    Ok(applied)
}
