//! The durable project store.
//!
//! One SQLite database inside the existing client-state root, opened with the
//! rules the workflow store already uses: private directories, a schema version
//! recorded in a meta table, and a connection configured for full synchronous
//! writes. Registered identities and declared dependency inputs share that one
//! database, so a dependency never needs a second store to stay consistent with
//! the projects it names. Neither table has a column that could hold a
//! credential — authority is the reference the caller declared, and a
//! dependency is the reference the caller declared, so there is nothing to
//! duplicate.
//!
//! Registration and admission are each one immediate transaction: the checks and
//! the insert commit together or not at all. An artifact state is never stored;
//! it is read from the declared roots and the declared index each time, so a
//! stored row can never claim a result that has since gone away.

use crate::authority::ProjectAuthorityDirectory;
use crate::dependency::{
    ArtifactReference, ArtifactState, DeclaredDependency, WorkDependency, WorkRef,
    read_local_artifact, render_dependency_path, stays_inside_authorized_root,
};
use crate::failure::ProjectFailure;
use crate::identity::{
    AuthorityKind, AuthorityReference, AuthorizedRoot, PlanId, ProjectId, ProjectRegistration,
    RegisteredProject, WorkItemId, WorkspaceId,
};
use anyhow::{Result, anyhow, ensure};
use licoup_foundation::platform::file_security::{ensure_private_dir, harden_private_path};
use rusqlite::{Connection, ErrorCode, OptionalExtension, TransactionBehavior, params};
use std::collections::{BTreeMap, BTreeSet, VecDeque};
use std::path::{Path, PathBuf};

/// Schema version recorded by this owner.
///
/// The number moves with the shape of the one database this owner keeps. A
/// database written by an earlier unpublished shape is refused by name
/// (`project_identity_schema_migration_required`) rather than opened
/// half-working; it is not a second supported format.
pub const PROJECT_STORE_SCHEMA_VERSION: &str = "2";

/// The state root this owner writes inside, by the same rule the workflow
/// store follows: one durable owner directory under the client-state root.
const CLIENT_STATE_DIR: &str = "client-state";

/// Directory this owner creates under the client-state root.
const PROJECT_STATE_DIR: &str = "project-plan";

/// Database file this owner owns.
const DATABASE_FILE: &str = "project-identities.sqlite3";

/// Columns of `project_identities`, in declaration order.
///
/// The record has no column that could hold a credential: authority is stored
/// as the reference the caller declared. A test asserts this list against the
/// live schema, so a secret-bearing column cannot be added silently.
pub const PROJECT_IDENTITY_COLUMNS: &[&str] = &[
    "registration_sequence",
    "project_id",
    "display_name",
    "authorized_root",
    "authority_kind",
    "authority_reference",
    "workspace_id",
    "plan_id",
];

/// Columns of `project_dependencies`, in declaration order.
///
/// One admitted edge: the consumer (`project_id`, `work_item_id`), the shape of
/// the declared artifact, the producer it names, and the declared location when
/// the reference is local. Empty `local_path` is a cross-project reference, so
/// the unique constraint treats every shape as one comparable tuple rather than
/// letting SQLite's distinct `NULL`s admit the same edge twice. A test asserts
/// this list against the live schema.
pub const PROJECT_DEPENDENCY_COLUMNS: &[&str] = &[
    "dependency_sequence",
    "project_id",
    "work_item_id",
    "artifact_kind",
    "producer_project_id",
    "producer_work_item_id",
    "local_path",
];

/// The durable owner of registered project identities and the dependency inputs
/// those projects declare.
#[derive(Clone, Debug)]
pub struct ProjectIdentityStore {
    state_root: PathBuf,
    db_path: PathBuf,
}

impl ProjectIdentityStore {
    /// Open the store inside one portable data root.
    ///
    /// The location is the existing client-state root plus this owner's
    /// directory, so project identities live in the state root every durable
    /// owner already uses rather than in a second state location.
    pub fn open(portable_root: &Path) -> Result<Self, ProjectFailure> {
        let state_root = portable_root.join(CLIENT_STATE_DIR).join(PROJECT_STATE_DIR);
        ensure_private_dir(&state_root).map_err(|error| {
            ProjectFailure::store("project_identity_store_unavailable")
                .with_detail(error.to_string())
        })?;
        let store = Self {
            db_path: state_root.join(DATABASE_FILE),
            state_root,
        };
        let existed = store.db_path.exists();
        store
            .with_connection(|connection| {
                if existed {
                    validate_current_schema(connection)
                } else {
                    initialize_schema(connection)
                }
            })
            .map_err(|error| {
                ProjectFailure::store("project_identity_store_unavailable")
                    .with_detail(error.to_string())
            })?;
        harden_private_path(&store.db_path).map_err(|error| {
            ProjectFailure::store("project_identity_store_unavailable")
                .with_detail(error.to_string())
        })?;
        Ok(store)
    }

    /// The client-state directory this store owns.
    pub fn state_root(&self) -> &Path {
        &self.state_root
    }

    /// The database file this store owns.
    pub fn database_path(&self) -> &Path {
        &self.db_path
    }

    /// Register one authorized project.
    ///
    /// The declaration is admitted against `authorities` before the store is
    /// reached, and the duplicate checks share the insert's transaction.
    pub fn register(
        &self,
        authorities: &dyn ProjectAuthorityDirectory,
        registration: &ProjectRegistration,
    ) -> Result<RegisteredProject, ProjectFailure> {
        let record = registration.declare(authorities)?;
        let mut connection = self.connect()?;
        let transaction = connection
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(store_error)?;
        if project_exists(&transaction, record.project_id.as_str())? {
            return Err(ProjectFailure::registration("project_identity_duplicate"));
        }
        if plan_exists(
            &transaction,
            record.workspace_id.as_str(),
            record.plan_id.as_str(),
        )? {
            return Err(ProjectFailure::registration(
                "project_plan_identity_duplicate",
            ));
        }
        transaction
            .execute(
                "INSERT INTO project_identities(
                   project_id, display_name, authorized_root, authority_kind,
                   authority_reference, workspace_id, plan_id
                 ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
                params![
                    record.project_id.as_str(),
                    record.display_name,
                    record.authorized_root.as_str(),
                    record.authority.kind().as_str(),
                    record.authority.reference(),
                    record.workspace_id.as_str(),
                    record.plan_id.as_str(),
                ],
            )
            .map_err(|error| match error {
                // The checks above are advisory; the unique constraints are the
                // authority. A registration that loses the race is refused with
                // the same duplicate code rather than admitted twice.
                rusqlite::Error::SqliteFailure(failure, _)
                    if failure.code == ErrorCode::ConstraintViolation =>
                {
                    ProjectFailure::registration("project_identity_duplicate")
                }
                other => store_error(other),
            })?;
        let registration_sequence = transaction.last_insert_rowid().max(0) as u64;
        transaction.commit().map_err(store_error)?;
        Ok(RegisteredProject {
            registration_sequence,
            ..record
        })
    }

    /// Read one registered project, or `None` when it is not registered.
    pub fn read(
        &self,
        project_id: &ProjectId,
    ) -> Result<Option<RegisteredProject>, ProjectFailure> {
        let connection = self.connect()?;
        read_project_row(&connection, project_id.as_str())
    }

    /// Every registered project, in registration order.
    pub fn list(&self) -> Result<Vec<RegisteredProject>, ProjectFailure> {
        let connection = self.connect()?;
        registered_projects(&connection)
    }

    /// Admit one declared dependency edge.
    ///
    /// Every refusal happens before the insert, so a refused edge leaves no row
    /// behind. The rules are the four this owner answers for: the declaring
    /// project must be registered, a local location must stay inside that
    /// project's declared authorized root, a cross-project reference must name a
    /// registered project, and an edge that would close a cycle is refused with
    /// the path that closes it. Admitting the same edge again is idempotent: the
    /// row already stored is returned with its original admission order.
    pub fn admit_dependency(
        &self,
        dependency: &WorkDependency,
    ) -> Result<DeclaredDependency, ProjectFailure> {
        let mut connection = self.connect()?;
        let transaction = connection
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(store_error)?;
        let declaring = read_project_row(&transaction, dependency.project_id.as_str())?
            .ok_or_else(|| ProjectFailure::dependency("project_dependency_project_unauthorized"))?;
        if let ArtifactReference::Local { path, .. } = &dependency.artifact
            && !stays_inside_authorized_root(&declaring.authorized_root, path)
        {
            return Err(ProjectFailure::dependency(
                "project_artifact_reference_escapes_authorized_root",
            )
            .with_detail(format!("{path} is outside {}", declaring.authorized_root)));
        }
        if let ArtifactReference::CrossProject { project_id, .. } = &dependency.artifact
            && !project_exists(&transaction, project_id.as_str())?
        {
            return Err(
                ProjectFailure::dependency("project_artifact_reference_unauthorized")
                    .with_detail(project_id.to_string()),
            );
        }
        let consumer = dependency.consumer();
        let producer = dependency.producer();
        if let Some(cycle) = closing_cycle(&transaction, &consumer, &producer)? {
            return Err(ProjectFailure::dependency("project_dependency_cycle")
                .with_detail(render_dependency_path(&cycle)));
        }
        // Idempotence is decided before the insert so the same edge never
        // consumes an admission order it does not own.
        if let Some(dependency_sequence) = stored_dependency_sequence(&transaction, dependency)? {
            let artifact_state =
                dependency_state(&transaction, &dependency.project_id, &dependency.artifact)?;
            transaction.commit().map_err(store_error)?;
            return Ok(DeclaredDependency {
                dependency_sequence,
                dependency: dependency.clone(),
                artifact_state,
            });
        }
        let inserted = transaction
            .execute(
                "INSERT INTO project_dependencies(
                   project_id, work_item_id, artifact_kind, producer_project_id,
                   producer_work_item_id, local_path
                 ) VALUES (?1, ?2, ?3, ?4, ?5, ?6)
                 ON CONFLICT DO NOTHING",
                params![
                    dependency.project_id.as_str(),
                    dependency.work_item_id.as_str(),
                    dependency.artifact.kind(),
                    producer.project_id.as_str(),
                    producer.work_item_id.as_str(),
                    dependency.artifact.local_path().unwrap_or_default(),
                ],
            )
            .map_err(store_error)?;
        let dependency_sequence = if inserted == 0 {
            // The unique constraint is the authority; the check above is
            // advisory. An edge that still lost the race is the same edge.
            stored_dependency_sequence(&transaction, dependency)?
                .ok_or_else(|| dependency_error("project_dependency_record_invalid"))?
        } else {
            transaction.last_insert_rowid().max(0) as u64
        };
        let artifact_state =
            dependency_state(&transaction, &dependency.project_id, &dependency.artifact)?;
        transaction.commit().map_err(store_error)?;
        Ok(DeclaredDependency {
            dependency_sequence,
            dependency: dependency.clone(),
            artifact_state,
        })
    }

    /// Every dependency one project declares, in admission order.
    ///
    /// Each entry carries the current explicit state of its artifact reference:
    /// the declaration is durable, the answer about the result is not.
    pub fn dependencies(
        &self,
        project_id: &ProjectId,
    ) -> Result<Vec<DeclaredDependency>, ProjectFailure> {
        let connection = self.connect()?;
        if !project_exists(&connection, project_id.as_str())? {
            return Err(ProjectFailure::dependency(
                "project_dependency_project_unauthorized",
            ));
        }
        let mut statement = connection
            .prepare(
                "SELECT dependency_sequence, project_id, work_item_id, artifact_kind,
                        producer_project_id, producer_work_item_id, local_path
                   FROM project_dependencies
                  WHERE project_id = ?1
                  ORDER BY dependency_sequence",
            )
            .map_err(store_error)?;
        let rows = statement
            .query_map(params![project_id.as_str()], decode_dependency_row)
            .map_err(store_error)?
            .collect::<rusqlite::Result<Vec<_>>>()
            .map_err(store_error)?;
        let decoded = rows
            .into_iter()
            .collect::<std::result::Result<Vec<_>, ProjectFailure>>()?;
        let mut declared = Vec::with_capacity(decoded.len());
        for (dependency_sequence, dependency) in decoded {
            let artifact_state =
                dependency_state(&connection, &dependency.project_id, &dependency.artifact)?;
            declared.push(DeclaredDependency {
                dependency_sequence,
                dependency,
                artifact_state,
            });
        }
        Ok(declared)
    }

    /// Every declared reference of one project whose result is not materialized.
    ///
    /// The refusal is never silence: a consumer whose input is gone is reported
    /// here with [`ArtifactState::Missing`] or [`ArtifactState::Unavailable`],
    /// rather than appearing startable or being quietly skipped.
    pub fn unresolved_artifacts(
        &self,
        project_id: &ProjectId,
    ) -> Result<Vec<DeclaredDependency>, ProjectFailure> {
        Ok(self
            .dependencies(project_id)?
            .into_iter()
            .filter(|declared| declared.artifact_state != ArtifactState::Materialized)
            .collect())
    }

    /// The consumers one blocked producer actually blocks, transitively.
    ///
    /// The answer follows the declared edges only, so a blocked producer names
    /// exactly the work items that wait on it — across projects where a
    /// cross-project reference declared one — and never an unrelated branch or
    /// a whole project.
    pub fn blocked_consumers(&self, producer: &WorkRef) -> Result<Vec<WorkRef>, ProjectFailure> {
        let connection = self.connect()?;
        let mut consumers_of: BTreeMap<WorkRef, BTreeSet<WorkRef>> = BTreeMap::new();
        for (consumer, edge_producer) in declared_edges(&connection)? {
            consumers_of
                .entry(edge_producer)
                .or_default()
                .insert(consumer);
        }
        let mut blocked = Vec::new();
        let mut seen = BTreeSet::from([producer.clone()]);
        let mut pending = VecDeque::from([producer.clone()]);
        while let Some(work) = pending.pop_front() {
            for consumer in consumers_of.get(&work).into_iter().flatten() {
                if seen.insert(consumer.clone()) {
                    blocked.push(consumer.clone());
                    pending.push_back(consumer.clone());
                }
            }
        }
        Ok(blocked)
    }

    /// Open one configured connection to this owner's database.
    ///
    /// Every read and every write goes through here, so the connection rules
    /// above hold for a preview exactly as they hold for an admission.
    pub(crate) fn connect(&self) -> Result<Connection, ProjectFailure> {
        let connection = Connection::open(&self.db_path).map_err(|error| {
            ProjectFailure::store("project_identity_store_unavailable")
                .with_detail(error.to_string())
        })?;
        configure_connection(&connection).map_err(store_error)?;
        Ok(connection)
    }

    fn with_connection<T>(
        &self,
        operation: impl FnOnce(&mut Connection) -> Result<T>,
    ) -> Result<T> {
        let mut connection = Connection::open(&self.db_path)
            .map_err(|_| anyhow!("project_identity_database_open_failed"))?;
        configure_connection(&connection)?;
        operation(&mut connection)
    }
}

/// Every registered project, in registration order.
///
/// The query is separate from [`ProjectIdentityStore::list`] so a preview reads
/// the identities and the declarations it compares them against on one
/// connection, rather than from two moments that a concurrent registration
/// could separate.
pub(crate) fn registered_projects(
    connection: &Connection,
) -> Result<Vec<RegisteredProject>, ProjectFailure> {
    let mut statement = connection
        .prepare(&format!(
            "SELECT {} FROM project_identities ORDER BY registration_sequence",
            column_list()
        ))
        .map_err(store_error)?;
    let rows = statement
        .query_map([], decode_row)
        .map_err(store_error)?
        .collect::<rusqlite::Result<Vec<_>>>()
        .map_err(store_error)?;
    rows.into_iter().collect()
}

fn column_list() -> String {
    PROJECT_IDENTITY_COLUMNS.join(", ")
}

fn configure_connection(connection: &Connection) -> Result<()> {
    connection.execute_batch(
        "PRAGMA foreign_keys=ON;
         PRAGMA journal_mode=WAL;
         PRAGMA synchronous=FULL;
         PRAGMA busy_timeout=5000;",
    )?;
    Ok(())
}

fn initialize_schema(connection: &mut Connection) -> Result<()> {
    connection.execute_batch(
        "CREATE TABLE IF NOT EXISTS project_meta(
           key TEXT PRIMARY KEY, value TEXT NOT NULL
         );
         INSERT INTO project_meta(key, value) VALUES ('version', '2')
           ON CONFLICT(key) DO NOTHING;
         CREATE TABLE IF NOT EXISTS project_identities(
           registration_sequence INTEGER PRIMARY KEY AUTOINCREMENT,
           project_id TEXT NOT NULL UNIQUE,
           display_name TEXT NOT NULL,
           authorized_root TEXT NOT NULL,
           authority_kind TEXT NOT NULL,
           authority_reference TEXT NOT NULL,
           workspace_id TEXT NOT NULL,
           plan_id TEXT NOT NULL,
           UNIQUE(workspace_id, plan_id)
         );
         CREATE TABLE IF NOT EXISTS project_dependencies(
           dependency_sequence INTEGER PRIMARY KEY AUTOINCREMENT,
           project_id TEXT NOT NULL,
           work_item_id TEXT NOT NULL,
           artifact_kind TEXT NOT NULL,
           producer_project_id TEXT NOT NULL,
           producer_work_item_id TEXT NOT NULL,
           local_path TEXT NOT NULL DEFAULT '',
           UNIQUE(project_id, work_item_id, artifact_kind, producer_project_id,
                  producer_work_item_id, local_path)
         );
         CREATE INDEX IF NOT EXISTS project_dependencies_producers
           ON project_dependencies(producer_project_id, producer_work_item_id);
         CREATE INDEX IF NOT EXISTS project_dependencies_consumers
           ON project_dependencies(project_id, work_item_id);",
    )?;
    Ok(())
}

fn validate_current_schema(connection: &mut Connection) -> Result<()> {
    configure_connection(connection)?;
    let version: String = connection.query_row(
        "SELECT value FROM project_meta WHERE key='version'",
        [],
        |row| row.get(0),
    )?;
    ensure!(
        version == PROJECT_STORE_SCHEMA_VERSION,
        "project_identity_schema_migration_required"
    );
    // The version says which shape this database declares; the table check says
    // the shape is really there, so a truncated file is refused rather than
    // opened as a store with no dependency index.
    let dependency_table: i64 = connection.query_row(
        "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='project_dependencies'",
        [],
        |row| row.get(0),
    )?;
    ensure!(
        dependency_table == 1,
        "project_identity_schema_migration_required"
    );
    Ok(())
}

/// Whether one project identity is registered, as the preview asks it.
pub(crate) fn project_exists(
    connection: &Connection,
    project_id: &str,
) -> Result<bool, ProjectFailure> {
    connection
        .query_row(
            "SELECT 1 FROM project_identities WHERE project_id = ?1",
            params![project_id],
            |_| Ok(()),
        )
        .optional()
        .map(|found| found.is_some())
        .map_err(store_error)
}

fn plan_exists(
    connection: &Connection,
    workspace_id: &str,
    plan_id: &str,
) -> Result<bool, ProjectFailure> {
    connection
        .query_row(
            "SELECT 1 FROM project_identities WHERE workspace_id = ?1 AND plan_id = ?2",
            params![workspace_id, plan_id],
            |_| Ok(()),
        )
        .optional()
        .map(|found| found.is_some())
        .map_err(store_error)
}

fn decode_row(
    row: &rusqlite::Row<'_>,
) -> rusqlite::Result<Result<RegisteredProject, ProjectFailure>> {
    let registration_sequence: i64 = row.get(0)?;
    let project_id: String = row.get(1)?;
    let display_name: String = row.get(2)?;
    let authorized_root: String = row.get(3)?;
    let authority_kind: String = row.get(4)?;
    let authority_reference: String = row.get(5)?;
    let workspace_id: String = row.get(6)?;
    let plan_id: String = row.get(7)?;
    Ok(decode_record(
        registration_sequence,
        project_id,
        display_name,
        authorized_root,
        authority_kind,
        authority_reference,
        workspace_id,
        plan_id,
    ))
}

#[allow(clippy::too_many_arguments)]
fn decode_record(
    registration_sequence: i64,
    project_id: String,
    display_name: String,
    authorized_root: String,
    authority_kind: String,
    authority_reference: String,
    workspace_id: String,
    plan_id: String,
) -> Result<RegisteredProject, ProjectFailure> {
    let kind = AuthorityKind::parse(&authority_kind)
        .ok_or_else(|| ProjectFailure::store("project_identity_record_invalid"))?;
    Ok(RegisteredProject {
        project_id: ProjectId::declare(project_id)
            .map_err(|_| ProjectFailure::store("project_identity_record_invalid"))?,
        display_name,
        authorized_root: AuthorizedRoot::declare(authorized_root)
            .map_err(|_| ProjectFailure::store("project_identity_record_invalid"))?,
        authority: AuthorityReference::declare(kind, authority_reference)
            .map_err(|_| ProjectFailure::store("project_identity_record_invalid"))?,
        workspace_id: WorkspaceId::declare(workspace_id)
            .map_err(|_| ProjectFailure::store("project_identity_record_invalid"))?,
        plan_id: PlanId::declare(plan_id)
            .map_err(|_| ProjectFailure::store("project_identity_record_invalid"))?,
        registration_sequence: registration_sequence.max(0) as u64,
    })
}

fn store_error(error: impl std::fmt::Display) -> ProjectFailure {
    ProjectFailure::store("project_identity_store_unavailable").with_detail(error.to_string())
}

fn dependency_error(error: impl std::fmt::Display) -> ProjectFailure {
    ProjectFailure::store("project_dependency_store_unavailable").with_detail(error.to_string())
}

/// Read one registered project row, or `None` when it is not registered.
pub(crate) fn read_project_row(
    connection: &Connection,
    project_id: &str,
) -> Result<Option<RegisteredProject>, ProjectFailure> {
    let record = connection
        .query_row(
            &format!(
                "SELECT {} FROM project_identities WHERE project_id = ?1",
                column_list()
            ),
            params![project_id],
            decode_row,
        )
        .optional()
        .map_err(store_error)?;
    record.transpose()
}

/// The admission order of one edge that is already stored, if it is.
fn stored_dependency_sequence(
    connection: &Connection,
    dependency: &WorkDependency,
) -> Result<Option<u64>, ProjectFailure> {
    let producer = dependency.producer();
    connection
        .query_row(
            "SELECT dependency_sequence FROM project_dependencies
              WHERE project_id = ?1 AND work_item_id = ?2 AND artifact_kind = ?3
                AND producer_project_id = ?4 AND producer_work_item_id = ?5 AND local_path = ?6",
            params![
                dependency.project_id.as_str(),
                dependency.work_item_id.as_str(),
                dependency.artifact.kind(),
                producer.project_id.as_str(),
                producer.work_item_id.as_str(),
                dependency.artifact.local_path().unwrap_or_default(),
            ],
            |row| row.get::<_, i64>(0),
        )
        .optional()
        .map_err(store_error)
        .map(|stored| stored.map(|sequence| sequence.max(0) as u64))
}

/// Every declared edge as one consumer and the producer it waits for.
fn declared_edges(connection: &Connection) -> Result<Vec<(WorkRef, WorkRef)>, ProjectFailure> {
    let mut statement = connection
        .prepare(
            "SELECT project_id, work_item_id, producer_project_id, producer_work_item_id
               FROM project_dependencies",
        )
        .map_err(dependency_error)?;
    let rows = statement
        .query_map([], |row| {
            Ok((
                row.get::<_, String>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, String>(2)?,
                row.get::<_, String>(3)?,
            ))
        })
        .map_err(dependency_error)?
        .collect::<rusqlite::Result<Vec<_>>>()
        .map_err(dependency_error)?;
    rows.into_iter()
        .map(
            |(project_id, work_item_id, producer_project_id, producer_work_item_id)| {
                Ok((
                    work_ref(&project_id, &work_item_id)?,
                    work_ref(&producer_project_id, &producer_work_item_id)?,
                ))
            },
        )
        .collect()
}

fn work_ref(project_id: &str, work_item_id: &str) -> Result<WorkRef, ProjectFailure> {
    Ok(WorkRef::new(
        ProjectId::declare(project_id)
            .map_err(|_| dependency_error("project_dependency_record_invalid"))?,
        WorkItemId::declare(work_item_id)
            .map_err(|_| dependency_error("project_dependency_record_invalid"))?,
    ))
}

/// The path that would close a cycle if `consumer` were admitted against
/// `producer`, or `None` when the edge is acyclic.
///
/// The search follows the declared dependency direction, so the rendered path
/// reads as the edges a caller would have to remove: the refused consumer, the
/// producer it named, and every work item between that producer and the
/// consumer again.
fn closing_cycle(
    connection: &Connection,
    consumer: &WorkRef,
    producer: &WorkRef,
) -> Result<Option<Vec<WorkRef>>, ProjectFailure> {
    Ok(cycle_path(&declared_edges(connection)?, consumer, producer))
}

/// The path that would close a cycle in one edge set if `consumer` were admitted
/// against `producer`, or `None` when the edge is acyclic.
///
/// The search follows the declared dependency direction, so the rendered path
/// reads as the edges a caller would have to remove: the refused consumer, the
/// producer it named, and every work item between that producer and the
/// consumer again. The edge set is a parameter because a preview must ask the
/// same question about a declaration that is not stored yet.
pub(crate) fn cycle_path(
    edges: &[(WorkRef, WorkRef)],
    consumer: &WorkRef,
    producer: &WorkRef,
) -> Option<Vec<WorkRef>> {
    if consumer == producer {
        return Some(vec![consumer.clone(), producer.clone()]);
    }
    let mut dependencies_of: BTreeMap<WorkRef, Vec<WorkRef>> = BTreeMap::new();
    for (edge_consumer, edge_producer) in edges {
        dependencies_of
            .entry(edge_consumer.clone())
            .or_default()
            .push(edge_producer.clone());
    }
    let mut parents: BTreeMap<WorkRef, Option<WorkRef>> =
        BTreeMap::from([(producer.clone(), None)]);
    let mut pending = VecDeque::from([producer.clone()]);
    while let Some(work) = pending.pop_front() {
        if &work == consumer {
            let mut path = vec![work.clone()];
            let mut cursor = work;
            while let Some(parent) = parents.get(&cursor).cloned().flatten() {
                path.push(parent.clone());
                cursor = parent;
            }
            path.reverse();
            let mut cycle = vec![consumer.clone()];
            cycle.extend(path);
            return Some(cycle);
        }
        for next in dependencies_of.get(&work).into_iter().flatten() {
            if !parents.contains_key(next) {
                parents.insert(next.clone(), Some(work.clone()));
                pending.push_back(next.clone());
            }
        }
    }
    None
}

/// The explicit state of one declared reference, read from what it names.
pub(crate) fn dependency_state(
    connection: &Connection,
    declaring_project_id: &ProjectId,
    artifact: &ArtifactReference,
) -> Result<ArtifactState, ProjectFailure> {
    match artifact {
        ArtifactReference::Local { path, .. } => {
            match declared_root(connection, declaring_project_id)? {
                Some(root) => Ok(read_local_artifact(&root, path)),
                None => Ok(ArtifactState::Unavailable),
            }
        }
        ArtifactReference::CrossProject {
            project_id,
            work_item_id,
        } => {
            let declared = connection
                .query_row(
                    "SELECT 1 FROM project_dependencies
                      WHERE project_id = ?1
                        AND (work_item_id = ?2
                             OR (artifact_kind = 'local' AND producer_work_item_id = ?2))",
                    params![project_id.as_str(), work_item_id.as_str()],
                    |_| Ok(()),
                )
                .optional()
                .map_err(dependency_error)?;
            Ok(if declared.is_some() {
                ArtifactState::Materialized
            } else {
                ArtifactState::Missing
            })
        }
    }
}

/// The declared authorized root of one registered project, when it is
/// registered and its stored root still parses.
pub(crate) fn declared_root(
    connection: &Connection,
    project_id: &ProjectId,
) -> Result<Option<AuthorizedRoot>, ProjectFailure> {
    let root: Option<String> = connection
        .query_row(
            "SELECT authorized_root FROM project_identities WHERE project_id = ?1",
            params![project_id.as_str()],
            |row| row.get(0),
        )
        .optional()
        .map_err(dependency_error)?;
    Ok(root.and_then(|root| AuthorizedRoot::declare(root).ok()))
}

/// One declared edge as a preview reads it.
///
/// The consumer, the producer it takes a result from, and the declared
/// reference between them: the same three facts the admission rule decides on,
/// in the order the store admits them.
#[derive(Clone, Debug)]
pub(crate) struct EdgeSnapshot {
    pub consumer: WorkRef,
    pub producer: WorkRef,
    pub artifact: ArtifactReference,
}

/// Every declared edge, in admission order, as a preview reads it.
pub(crate) fn edge_snapshot(connection: &Connection) -> Result<Vec<EdgeSnapshot>, ProjectFailure> {
    let mut statement = connection
        .prepare(
            "SELECT dependency_sequence, project_id, work_item_id, artifact_kind,
                    producer_project_id, producer_work_item_id, local_path
               FROM project_dependencies
              ORDER BY dependency_sequence",
        )
        .map_err(dependency_error)?;
    let rows = statement
        .query_map([], decode_dependency_row)
        .map_err(dependency_error)?
        .collect::<rusqlite::Result<Vec<_>>>()
        .map_err(dependency_error)?;
    rows.into_iter()
        .map(|row| row.map(|(_, dependency)| dependency))
        .map(|dependency| {
            let dependency = dependency?;
            Ok(EdgeSnapshot {
                consumer: dependency.consumer(),
                producer: dependency.producer(),
                artifact: dependency.artifact,
            })
        })
        .collect()
}

fn decode_dependency_row(
    row: &rusqlite::Row<'_>,
) -> rusqlite::Result<Result<(u64, WorkDependency), ProjectFailure>> {
    let dependency_sequence: i64 = row.get(0)?;
    let project_id: String = row.get(1)?;
    let work_item_id: String = row.get(2)?;
    let artifact_kind: String = row.get(3)?;
    let producer_project_id: String = row.get(4)?;
    let producer_work_item_id: String = row.get(5)?;
    let local_path: String = row.get(6)?;
    Ok(decode_dependency(
        dependency_sequence,
        project_id,
        work_item_id,
        artifact_kind,
        producer_project_id,
        producer_work_item_id,
        local_path,
    ))
}

#[allow(clippy::too_many_arguments)]
fn decode_dependency(
    dependency_sequence: i64,
    project_id: String,
    work_item_id: String,
    artifact_kind: String,
    producer_project_id: String,
    producer_work_item_id: String,
    local_path: String,
) -> Result<(u64, WorkDependency), ProjectFailure> {
    let invalid = || dependency_error("project_dependency_record_invalid");
    let producer_work_item_id =
        WorkItemId::declare(producer_work_item_id).map_err(|_| invalid())?;
    let declaring_project_id = ProjectId::declare(project_id).map_err(|_| invalid())?;
    let artifact = match artifact_kind.as_str() {
        // A local reference produces inside the declaring project: a row that
        // names another project as the producer of a local location is not a
        // declaration this owner made.
        "local" if producer_project_id == declaring_project_id.as_str() => {
            ArtifactReference::local(producer_work_item_id, local_path).map_err(|_| invalid())?
        }
        "local" => return Err(invalid()),
        "cross-project" if local_path.is_empty() => ArtifactReference::cross_project(
            ProjectId::declare(producer_project_id).map_err(|_| invalid())?,
            producer_work_item_id,
        ),
        _ => return Err(invalid()),
    };
    Ok((
        dependency_sequence.max(0) as u64,
        WorkDependency {
            project_id: declaring_project_id,
            work_item_id: WorkItemId::declare(work_item_id).map_err(|_| invalid())?,
            artifact,
        },
    ))
}
