//! The durable project-identity store.
//!
//! One SQLite database inside the existing client-state root, opened with the
//! rules the workflow store already uses: private directories, a schema version
//! recorded in a meta table, and a connection configured for full synchronous
//! writes. The table has no column that could hold a credential — authority is
//! the reference the caller declared, so there is nothing to duplicate.
//!
//! Registration is one immediate transaction: the duplicate checks and the
//! insert commit together or not at all.

use crate::authority::ProjectAuthorityDirectory;
use crate::failure::ProjectFailure;
use crate::identity::{
    AuthorityKind, AuthorityReference, AuthorizedRoot, PlanId, ProjectId, ProjectRegistration,
    RegisteredProject, WorkspaceId,
};
use anyhow::{Result, anyhow, ensure};
use licoup_foundation::platform::file_security::{ensure_private_dir, harden_private_path};
use rusqlite::{Connection, ErrorCode, OptionalExtension, TransactionBehavior, params};
use std::path::{Path, PathBuf};

/// Schema version recorded by this owner.
pub const PROJECT_IDENTITY_SCHEMA_VERSION: &str = "1";

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

/// The durable owner of registered project identities.
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
        let record = connection
            .query_row(
                &format!(
                    "SELECT {} FROM project_identities WHERE project_id = ?1",
                    column_list()
                ),
                params![project_id.as_str()],
                decode_row,
            )
            .optional()
            .map_err(store_error)?;
        record.transpose()
    }

    /// Every registered project, in registration order.
    pub fn list(&self) -> Result<Vec<RegisteredProject>, ProjectFailure> {
        let connection = self.connect()?;
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

    fn connect(&self) -> Result<Connection, ProjectFailure> {
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
         INSERT INTO project_meta(key, value) VALUES ('version', '1')
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
         );",
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
        version == PROJECT_IDENTITY_SCHEMA_VERSION,
        "project_identity_schema_migration_required"
    );
    Ok(())
}

fn project_exists(connection: &Connection, project_id: &str) -> Result<bool, ProjectFailure> {
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
