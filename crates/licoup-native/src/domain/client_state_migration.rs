//! Forward-only admission for the shared client data root.
//!
//! The frontier and running identity are compiled into the binary. Callers
//! supply only the raw data root and cannot select migration code or targets.

use std::{
    collections::{BTreeMap, BTreeSet},
    fs::{self, File, OpenOptions},
    path::{Path, PathBuf},
};

use anyhow::{Context, Result, anyhow, bail, ensure};
use fs2::FileExt;
use rusqlite::{Connection, OptionalExtension};
use semver::Version;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

const FRONTIER_SCHEMA: &str = "v0.0.1:client-state-migration-frontier-1";
const LEDGER_SCHEMA: &str = "v0.0.1:client-state-migration-ledger-1";
const DOMAIN_MARKER_SCHEMA: &str = "v0.0.1:client-state-domain-marker-1";
const UPDATE_HANDOFF_SCHEMA: &str = "v0.0.1:client-update-handoff-1";
const MAX_MIGRATION_JSON_BYTES: usize = 4 * 1024 * 1024;
const FRONTIER_JSON: &str = include_str!("../../resources/client-state-migration-frontier.json");
const GATEWAY_CUSTODY_DOMAIN: &str = "gateway-credential-custody";

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum ReleaseTrack {
    Nightly,
    Stable,
}

impl ReleaseTrack {
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Nightly => "nightly",
            Self::Stable => "stable",
        }
    }

    pub fn running() -> Result<Self> {
        match option_env!("LICO_CLIENT_RELEASE_TRACK").unwrap_or("nightly") {
            "nightly" => Ok(Self::Nightly),
            "stable" => Ok(Self::Stable),
            _ => bail!("embedded client release track is invalid"),
        }
    }
}

pub fn running_product_version() -> Result<&'static str> {
    let value = option_env!("LICO_CLIENT_PRODUCT_VERSION").unwrap_or("0.0.1-alpha");
    Version::parse(value).context("embedded client product version is invalid")?;
    Ok(value)
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct MigrationFrontier {
    schema_version: String,
    pub frontier_id: String,
    pub domains: Vec<DomainFrontier>,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct DomainFrontier {
    pub domain_id: String,
    durability: Durability,
    pub target_schema_version: u32,
    pub steps: Vec<MigrationEdge>,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq)]
#[serde(rename_all = "lowercase")]
enum Durability {
    Durable,
    Derived,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct MigrationEdge {
    pub step_id: String,
    pub from_schema_version: u32,
    pub to_schema_version: u32,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Ledger {
    schema_version: String,
    highest_admitted_product_version: String,
    frontier_id: String,
    domains: BTreeMap<String, LedgerDomain>,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct LedgerDomain {
    schema_version: u32,
    completed_step_ids: Vec<String>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct DomainMarker {
    schema_version: String,
    domain_id: String,
    authoritative_schema_version: u32,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct UpdateHandoff {
    schema_version: String,
    state: String,
    version: String,
    target_release_track: String,
    migration_frontier: serde_json::Value,
    receipt_id: String,
    target_path: String,
    backup_path: String,
}

pub(crate) struct PreparedUpdateHandoff {
    pub handoff_path: PathBuf,
    pub backup_path: PathBuf,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AdmissionResult {
    pub status: &'static str,
    pub running_product_version: String,
    pub running_release_track: &'static str,
    pub frontier_id: String,
    pub applied_domain_ids: Vec<String>,
    pub skipped_domain_ids: Vec<String>,
    pub pending_authorization_domain_ids: Vec<String>,
}

struct PlannedStep<'a> {
    domain: &'a DomainFrontier,
    edge: &'a MigrationEdge,
}

#[derive(Clone, Copy, Debug)]
struct AuthoritativeProbe {
    version: u32,
    present: bool,
}

/// Admits the root through the immutable embedded frontier. Error text is
/// intentionally a stable privacy-safe code; paths and stored values never
/// cross this boundary.
pub fn admit(data_root: &Path) -> Result<AdmissionResult> {
    admit_inner(data_root).map_err(|error| anyhow!(safe_error_code(&error)))
}

fn admit_inner(data_root: &Path) -> Result<AdmissionResult> {
    ensure!(data_root.is_absolute(), "unsupported_state_shape");
    fs::create_dir_all(data_root).context("migration_lock_unavailable")?;
    let migration_root = data_root.join("client-state").join("migrations");
    crate::platform::file_security::ensure_private_dir(&migration_root)
        .context("migration_lock_unavailable")?;
    let lock = OpenOptions::new()
        .create(true)
        .truncate(false)
        .read(true)
        .write(true)
        .open(migration_root.join("admission.lock"))
        .context("migration_lock_unavailable")?;
    lock.lock_exclusive()
        .context("migration_lock_unavailable")?;

    let frontier = embedded_frontier()?;
    let handoff_path = migration_root.join("update-handoff.json");
    let handoff_exists = fs::symlink_metadata(&handoff_path).is_ok();
    if let Err(error) = claim_update_handoff(&handoff_path, &frontier) {
        // A claimed handoff is the forward-only ownership boundary. Cleanup
        // failures after that durable write must never tell the installer to
        // restore the old application.
        if handoff_exists && !update_handoff_is_claimed(&handoff_path) {
            write_update_handoff_rejection(&handoff_path)?;
        }
        return Err(error);
    }
    let ledger_path = migration_root.join("ledger.json");
    let mut ledger = load_ledger(&ledger_path, &frontier)?;
    let running_version = running_product_version()?;
    reject_older_binary(&ledger, running_version)?;

    // Probe every authoritative marker and construct every exact path before
    // persisting high-water or changing a domain.
    let marker_root = migration_root.join("domain-state");
    let mut observed = BTreeMap::new();
    let mut plan = Vec::new();
    let mut skipped = Vec::new();
    let mut pending_authorization = Vec::new();
    for domain in &frontier.domains {
        let mut version = probe_domain(&marker_root, domain)?;
        // A data root alone cannot prove that this account has no legacy
        // Keychain items. Only the explicit protected operation can complete
        // this domain; startup never reads secrets or opens a native dialog.
        if domain.domain_id == GATEWAY_CUSTODY_DOMAIN && version == 0 {
            if cfg!(target_os = "macos") {
                observed.insert(domain.domain_id.clone(), version);
                pending_authorization.push(domain.domain_id.clone());
                continue;
            }
            version = domain.target_schema_version;
        }
        observed.insert(domain.domain_id.clone(), version);
        if version == domain.target_schema_version {
            skipped.push(domain.domain_id.clone());
            continue;
        }
        let mut cursor = version;
        while cursor < domain.target_schema_version {
            let matches = domain
                .steps
                .iter()
                .filter(|edge| edge.from_schema_version == cursor)
                .collect::<Vec<_>>();
            ensure!(matches.len() == 1, "migration_frontier_incomplete");
            let edge = matches[0];
            ensure!(
                edge.to_schema_version > cursor
                    && edge.to_schema_version <= domain.target_schema_version,
                "migration_frontier_incomplete"
            );
            plan.push(PlannedStep { domain, edge });
            cursor = edge.to_schema_version;
        }
        ensure!(
            cursor == domain.target_schema_version,
            "migration_frontier_incomplete"
        );
    }
    validate_ledger_reconciliation(&ledger, &frontier, &observed)?;
    // An authoritative store may have committed before the process crashed
    // while writing its ledger entry. Rebuild the completed prefix from the
    // store probe before admitting the next edge, otherwise a later edge can
    // be recorded without the earlier one and make the next admission fail.
    reconcile_authoritative_ledger_prefix(&mut ledger, &frontier, &observed);

    // Once persisted, an older binary is permanently denied even if a later
    // domain step fails. Recovery is same/newer forward repair only.
    ledger.highest_admitted_product_version = running_version.to_owned();
    ledger.frontier_id = frontier.frontier_id.clone();
    write_json_atomic(&ledger_path, &ledger).context("migration_ledger_invalid")?;

    crate::platform::file_security::ensure_private_dir(&marker_root)
        .context("migration_step_failed")?;
    let mut reconciled_current_domain = false;
    for domain in &frontier.domains {
        if observed.get(&domain.domain_id) != Some(&domain.target_schema_version) {
            continue;
        }
        if domain.domain_id == "canonical-conversation" {
            upgrade_canonical_conversation_schema(data_root)?;
        }
        reconcile_current_marker(&marker_root, domain)?;
        for edge in &domain.steps {
            reconciled_current_domain |= reconcile_ledger(&mut ledger, domain, edge);
        }
    }
    if reconciled_current_domain {
        write_json_atomic(&ledger_path, &ledger).context("migration_ledger_invalid")?;
    }
    let mut applied = BTreeSet::new();
    for item in plan {
        let authoritative = observed
            .get_mut(&item.domain.domain_id)
            .ok_or_else(|| anyhow!("migration_step_failed"))?;
        if *authoritative == item.edge.to_schema_version {
            reconcile_ledger(&mut ledger, item.domain, item.edge);
            write_json_atomic(&ledger_path, &ledger).context("migration_ledger_invalid")?;
            continue;
        }
        ensure!(
            *authoritative == item.edge.from_schema_version,
            "migration_step_failed"
        );
        migration_failpoint("before-store")?;
        apply_marker_step(&marker_root, item.domain, item.edge)?;
        *authoritative = item.edge.to_schema_version;
        ensure!(
            probe_domain(&marker_root, item.domain)? == *authoritative,
            "migration_postcondition_failed"
        );
        migration_failpoint("after-store")?;
        reconcile_ledger(&mut ledger, item.domain, item.edge);
        write_json_atomic(&ledger_path, &ledger).context("migration_ledger_invalid")?;
        migration_failpoint("after-ledger")?;
        applied.insert(item.domain.domain_id.clone());
    }
    // A store format that only *adds* tables moves no domain version, so a
    // domain already at its frontier target still has a store-side conversion to
    // reach. It runs here — under the same lock, through the same conversion
    // graph, and with the same recovery artifact — instead of being left to the
    // store's own open path on every later start, which would make a published
    // format change on an open rather than under an admitted migration.
    for domain in &frontier.domains {
        if domain.domain_id != STRATEGY_STORE_DOMAIN
            || observed.get(&domain.domain_id) != Some(&domain.target_schema_version)
        {
            continue;
        }
        if !advance_strategy_store(data_root, current_strategy_format())?.is_empty() {
            // The domain's frontier version did not move, but its store did, and
            // reporting that is how a caller learns the file changed at all.
            applied.insert(domain.domain_id.clone());
        }
    }
    crate::platform::file_security::remove_private_state_marker(&handoff_path)
        .context("update_handoff_mismatch")?;
    Ok(AdmissionResult {
        status: "ready",
        running_product_version: running_version.to_owned(),
        running_release_track: ReleaseTrack::running()?.as_str(),
        frontier_id: frontier.frontier_id,
        applied_domain_ids: applied.into_iter().collect(),
        skipped_domain_ids: skipped,
        pending_authorization_domain_ids: pending_authorization,
    })
}

/// Metadata-only projection of the deferred upgrade. The completion marker
/// is written only after the vault confirms every copied item and cleanup.
pub fn gateway_credential_migration_pending(root: &Path) -> Result<bool> {
    let frontier = embedded_frontier()?;
    let domain = frontier
        .domains
        .iter()
        .find(|domain| domain.domain_id == GATEWAY_CUSTODY_DOMAIN)
        .ok_or_else(|| anyhow!("migration_frontier_incomplete"))?;
    let marker_root = root.join("client-state/migrations/domain-state");
    Ok(cfg!(target_os = "macos")
        && probe_domain(&marker_root, domain)? < domain.target_schema_version)
}

/// Explicit protected continuation of the embedded migration frontier.
/// The long native prompt holds only the custody lock, so normal admission
/// and unrelated client state remain available while the user responds.
pub fn migrate_gateway_credentials(
    root: &Path,
) -> Result<crate::domain::llm_api_key_vault::LlmApiKeyInventory> {
    migrate_gateway_credentials_with(root, || {
        crate::platform::llm_api_key_vault::PlatformLlmApiKeyVault::at_state_root(root)?
            .migrate_legacy_credentials()
    })
}

fn migrate_gateway_credentials_with(
    root: &Path,
    migrate: impl FnOnce() -> Result<crate::domain::llm_api_key_vault::LlmApiKeyInventory>,
) -> Result<crate::domain::llm_api_key_vault::LlmApiKeyInventory> {
    admit(root)?;
    let migration_root = root.join("client-state/migrations");
    let custody_lock = OpenOptions::new()
        .create(true)
        .truncate(false)
        .read(true)
        .write(true)
        .open(migration_root.join("gateway-credential-custody.lock"))
        .context("migration_lock_unavailable")?;
    custody_lock
        .lock_exclusive()
        .context("migration_lock_unavailable")?;
    if !gateway_credential_migration_pending(root)? {
        return crate::platform::llm_api_key_vault::PlatformLlmApiKeyVault::at_state_root(root)?
            .list();
    }
    let inventory = migrate()?;
    complete_gateway_custody_migration(root)?;
    Ok(inventory)
}

fn complete_gateway_custody_migration(root: &Path) -> Result<()> {
    let migration_root = root.join("client-state/migrations");
    let admission_lock = OpenOptions::new()
        .create(true)
        .truncate(false)
        .read(true)
        .write(true)
        .open(migration_root.join("admission.lock"))
        .context("migration_lock_unavailable")?;
    admission_lock
        .lock_exclusive()
        .context("migration_lock_unavailable")?;
    let frontier = embedded_frontier()?;
    let domain = frontier
        .domains
        .iter()
        .find(|domain| domain.domain_id == GATEWAY_CUSTODY_DOMAIN)
        .ok_or_else(|| anyhow!("migration_frontier_incomplete"))?;
    let ledger_path = migration_root.join("ledger.json");
    let mut ledger = load_ledger(&ledger_path, &frontier)?;
    reject_older_binary(&ledger, running_product_version()?)?;
    reconcile_current_marker(&migration_root.join("domain-state"), domain)?;
    for edge in &domain.steps {
        reconcile_ledger(&mut ledger, domain, edge);
    }
    write_json_atomic(&ledger_path, &ledger).context("migration_ledger_invalid")
}

fn validate_ledger_reconciliation(
    ledger: &Ledger,
    frontier: &MigrationFrontier,
    observed: &BTreeMap<String, u32>,
) -> Result<()> {
    for (domain_id, entry) in &ledger.domains {
        let domain = frontier
            .domains
            .iter()
            .find(|domain| &domain.domain_id == domain_id)
            .ok_or_else(|| anyhow!("migration_ledger_invalid"))?;
        let authoritative = observed
            .get(domain_id)
            .copied()
            .ok_or_else(|| anyhow!("migration_ledger_invalid"))?;
        ensure!(
            entry.schema_version <= authoritative
                && entry.schema_version <= domain.target_schema_version,
            "migration_ledger_invalid"
        );
        let expected = domain
            .steps
            .iter()
            .filter(|step| step.to_schema_version <= entry.schema_version)
            .map(|step| step.step_id.as_str())
            .collect::<Vec<_>>();
        ensure!(
            entry
                .completed_step_ids
                .iter()
                .map(String::as_str)
                .eq(expected),
            "migration_ledger_invalid"
        );
    }
    Ok(())
}

fn reconcile_authoritative_ledger_prefix(
    ledger: &mut Ledger,
    frontier: &MigrationFrontier,
    observed: &BTreeMap<String, u32>,
) {
    for domain in &frontier.domains {
        let Some(&authoritative) = observed.get(&domain.domain_id) else {
            continue;
        };
        for edge in domain
            .steps
            .iter()
            .filter(|edge| edge.to_schema_version <= authoritative)
        {
            reconcile_ledger(ledger, domain, edge);
        }
    }
}

#[cfg(not(test))]
fn migration_failpoint(_name: &str) -> Result<()> {
    Ok(())
}

#[cfg(test)]
thread_local! {
    static MIGRATION_FAILPOINT: std::cell::RefCell<Option<&'static str>> = const { std::cell::RefCell::new(None) };
}

#[cfg(test)]
fn migration_failpoint(name: &str) -> Result<()> {
    MIGRATION_FAILPOINT.with(|slot| {
        ensure!(
            slot.borrow().as_ref().copied() != Some(name),
            "migration_step_failed"
        );
        Ok(())
    })
}

#[cfg(test)]
struct MigrationFailpointGuard(Option<&'static str>);

#[cfg(test)]
impl MigrationFailpointGuard {
    fn set(name: &'static str) -> Self {
        let previous = MIGRATION_FAILPOINT.with(|slot| slot.replace(Some(name)));
        Self(previous)
    }
}

#[cfg(test)]
impl Drop for MigrationFailpointGuard {
    fn drop(&mut self) {
        MIGRATION_FAILPOINT.with(|slot| {
            slot.replace(self.0.take());
        });
    }
}

fn claim_update_handoff(path: &Path, frontier: &MigrationFrontier) -> Result<()> {
    let Some(raw) =
        crate::platform::file_security::read_existing_private_text_bounded(path, 256 * 1024)
            .context("update_handoff_mismatch")?
    else {
        return Ok(());
    };
    let mut handoff: UpdateHandoff =
        serde_json::from_str(&raw).context("update_handoff_mismatch")?;
    ensure!(
        handoff.schema_version == UPDATE_HANDOFF_SCHEMA
            && matches!(handoff.state.as_str(), "pending" | "claimed")
            && handoff.version == running_product_version()?
            && handoff.target_release_track == ReleaseTrack::running()?.as_str()
            && handoff.migration_frontier == frontier_projection_for(frontier)
            && handoff.receipt_id.starts_with("sha256:")
            && handoff.receipt_id.len() == 71,
        "update_handoff_mismatch"
    );
    let target_path = PathBuf::from(&handoff.target_path);
    let backup_path = PathBuf::from(&handoff.backup_path);
    ensure!(
        target_path.is_absolute()
            && backup_path == pre_claim_backup_path(&target_path, &handoff.receipt_id)?,
        "update_handoff_mismatch"
    );
    if handoff.state == "pending" {
        handoff.state = "claimed".to_owned();
        write_json_atomic(path, &handoff).context("update_handoff_mismatch")?;
    }
    remove_pre_claim_backup(&backup_path)?;
    Ok(())
}

fn update_handoff_is_claimed(path: &Path) -> bool {
    let Ok(Some(raw)) =
        crate::platform::file_security::read_existing_private_text_bounded(path, 256 * 1024)
    else {
        return false;
    };
    serde_json::from_str::<UpdateHandoff>(&raw).is_ok_and(|handoff| handoff.state == "claimed")
}

pub(crate) fn prepare_update_handoff(
    data_root: &Path,
    receipt: &serde_json::Value,
    target_path: &Path,
) -> Result<PreparedUpdateHandoff> {
    ensure!(data_root.is_absolute(), "update_handoff_mismatch");
    ensure!(target_path.is_absolute(), "update_handoff_mismatch");
    let version = receipt
        .get("version")
        .and_then(serde_json::Value::as_str)
        .ok_or_else(|| anyhow!("update_handoff_mismatch"))?;
    Version::parse(version).context("update_handoff_mismatch")?;
    let target_release_track = receipt
        .get("targetReleaseTrack")
        .and_then(serde_json::Value::as_str)
        .ok_or_else(|| anyhow!("update_handoff_mismatch"))?;
    ensure!(
        matches!(target_release_track, "nightly" | "stable"),
        "update_handoff_mismatch"
    );
    let migration_frontier = receipt
        .get("migrationFrontier")
        .cloned()
        .ok_or_else(|| anyhow!("update_handoff_mismatch"))?;
    ensure!(
        migration_frontier
            .get("frontierId")
            .and_then(serde_json::Value::as_str)
            .is_some_and(|value| !value.is_empty())
            && migration_frontier
                .get("domains")
                .and_then(serde_json::Value::as_array)
                .is_some_and(|domains| !domains.is_empty()),
        "update_handoff_mismatch"
    );
    let receipt_id = receipt
        .get("receiptId")
        .and_then(serde_json::Value::as_str)
        .ok_or_else(|| anyhow!("update_handoff_mismatch"))?;
    ensure!(
        receipt_id.starts_with("sha256:") && receipt_id.len() == 71,
        "update_handoff_mismatch"
    );
    let backup_path = pre_claim_backup_path(target_path, receipt_id)?;
    let handoff = UpdateHandoff {
        schema_version: UPDATE_HANDOFF_SCHEMA.to_owned(),
        state: "pending".to_owned(),
        version: version.to_owned(),
        target_release_track: target_release_track.to_owned(),
        migration_frontier,
        receipt_id: receipt_id.to_owned(),
        target_path: target_path.to_string_lossy().into_owned(),
        backup_path: backup_path.to_string_lossy().into_owned(),
    };
    let path = data_root.join("client-state/migrations/update-handoff.json");
    ensure!(!path.exists(), "update_handoff_mismatch");
    let rejected = update_handoff_rejection_path(&path)?;
    if rejected.exists() {
        let metadata = fs::symlink_metadata(&rejected).context("update_handoff_mismatch")?;
        ensure!(
            metadata.is_file() && !metadata.file_type().is_symlink(),
            "update_handoff_mismatch"
        );
        fs::remove_file(&rejected).context("update_handoff_mismatch")?;
    }
    write_json_atomic(&path, &handoff).context("update_handoff_mismatch")?;
    Ok(PreparedUpdateHandoff {
        handoff_path: path,
        backup_path,
    })
}

fn update_handoff_rejection_path(path: &Path) -> Result<PathBuf> {
    let name = path
        .file_name()
        .and_then(|value| value.to_str())
        .ok_or_else(|| anyhow!("update_handoff_mismatch"))?;
    Ok(path.with_file_name(format!("{name}.rejected")))
}

fn write_update_handoff_rejection(path: &Path) -> Result<()> {
    write_json_atomic(
        &update_handoff_rejection_path(path)?,
        &json!({
            "schemaVersion": "v0.0.1:client-update-handoff-rejection-1",
            "status": "rejected"
        }),
    )
    .context("update_handoff_mismatch")
}

fn pre_claim_backup_path(target_path: &Path, receipt_id: &str) -> Result<PathBuf> {
    let parent = target_path
        .parent()
        .ok_or_else(|| anyhow!("update_handoff_mismatch"))?;
    let target_name = target_path
        .file_name()
        .and_then(|name| name.to_str())
        .ok_or_else(|| anyhow!("update_handoff_mismatch"))?;
    let binding = receipt_id
        .strip_prefix("sha256:")
        .filter(|value| value.len() == 64 && value.bytes().all(|byte| byte.is_ascii_hexdigit()))
        .ok_or_else(|| anyhow!("update_handoff_mismatch"))?;
    Ok(parent.join(format!(".{target_name}.{binding}.pre-claim")))
}

fn remove_pre_claim_backup(path: &Path) -> Result<()> {
    let metadata = match fs::symlink_metadata(path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(()),
        Err(error) => return Err(error).context("update_handoff_mismatch"),
    };
    ensure!(
        !metadata.file_type().is_symlink(),
        "update_handoff_mismatch"
    );
    if metadata.is_dir() {
        fs::remove_dir_all(path).context("update_handoff_mismatch")?;
    } else if metadata.is_file() {
        fs::remove_file(path).context("update_handoff_mismatch")?;
    } else {
        bail!("update_handoff_mismatch");
    }
    if let Some(parent) = path.parent() {
        File::open(parent)
            .and_then(|directory| directory.sync_all())
            .context("update_handoff_mismatch")?;
    }
    Ok(())
}

pub fn embedded_frontier() -> Result<MigrationFrontier> {
    let frontier: MigrationFrontier =
        serde_json::from_str(FRONTIER_JSON).context("migration_frontier_incomplete")?;
    ensure!(
        frontier.schema_version == FRONTIER_SCHEMA,
        "migration_frontier_incomplete"
    );
    ensure!(
        !frontier.frontier_id.is_empty(),
        "migration_frontier_incomplete"
    );
    ensure!(
        !frontier.domains.is_empty(),
        "migration_frontier_incomplete"
    );
    let mut domains = BTreeSet::new();
    let mut all_step_ids = BTreeSet::new();
    for domain in &frontier.domains {
        ensure!(
            !domain.domain_id.is_empty()
                && domain
                    .domain_id
                    .bytes()
                    .all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit() || byte == b'-')
                && domains.insert(&domain.domain_id),
            "migration_frontier_incomplete"
        );
        ensure!(
            domain.target_schema_version > 0
                && !domain.steps.is_empty()
                && (domain.durability == Durability::Durable || !domain.steps.is_empty()),
            "migration_frontier_incomplete"
        );
        let mut sources = BTreeSet::new();
        let mut cursor = 0;
        for edge in &domain.steps {
            ensure!(
                edge.from_schema_version == cursor
                    && edge.to_schema_version > edge.from_schema_version
                    && edge.to_schema_version <= domain.target_schema_version
                    && sources.insert(edge.from_schema_version)
                    && !edge.step_id.is_empty()
                    && all_step_ids.insert(&edge.step_id)
                    && migration_handler_target(&domain.domain_id, edge.from_schema_version,)
                        == Some(edge.to_schema_version),
                "migration_frontier_incomplete"
            );
            cursor = edge.to_schema_version;
        }
        ensure!(
            cursor == domain.target_schema_version,
            "migration_frontier_incomplete"
        );
    }
    Ok(frontier)
}

fn load_ledger(path: &Path, frontier: &MigrationFrontier) -> Result<Ledger> {
    let Some(raw) =
        crate::platform::file_security::read_existing_private_text_bounded(path, 256 * 1024)
            .context("migration_ledger_invalid")?
    else {
        return Ok(Ledger {
            schema_version: LEDGER_SCHEMA.to_owned(),
            highest_admitted_product_version: "0.0.0".to_owned(),
            frontier_id: frontier.frontier_id.clone(),
            domains: BTreeMap::new(),
        });
    };
    let ledger: Ledger = serde_json::from_str(&raw).context("migration_ledger_invalid")?;
    ensure!(
        ledger.schema_version == LEDGER_SCHEMA,
        "migration_ledger_invalid"
    );
    Version::parse(&ledger.highest_admitted_product_version).context("migration_ledger_invalid")?;
    Ok(ledger)
}

fn reject_older_binary(ledger: &Ledger, running: &str) -> Result<()> {
    let high = Version::parse(&ledger.highest_admitted_product_version)
        .context("migration_ledger_invalid")?;
    let running = Version::parse(running).context("migration_frontier_incomplete")?;
    ensure!(running >= high, "state_newer_than_binary");
    Ok(())
}

fn marker_path(root: &Path, domain_id: &str) -> PathBuf {
    root.join(format!("{domain_id}.json"))
}

fn probe_domain(root: &Path, domain: &DomainFrontier) -> Result<u32> {
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

fn load_domain_marker(root: &Path, domain: &DomainFrontier) -> Result<Option<DomainMarker>> {
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

fn reconcile_current_marker(root: &Path, domain: &DomainFrontier) -> Result<()> {
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

fn apply_marker_step(root: &Path, domain: &DomainFrontier, edge: &MigrationEdge) -> Result<()> {
    apply_authoritative_store(root, &domain.domain_id, edge)?;
    let marker = DomainMarker {
        schema_version: DOMAIN_MARKER_SCHEMA.to_owned(),
        domain_id: domain.domain_id.clone(),
        authoritative_schema_version: edge.to_schema_version,
    };
    write_json_atomic(&marker_path(root, &domain.domain_id), &marker)
        .context("migration_step_failed")
}

fn portable_root(marker_root: &Path) -> Result<&Path> {
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
fn probe_authoritative_store(marker_root: &Path, domain_id: &str) -> Result<AuthoritativeProbe> {
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

fn probe_agent_tab_order(path: &Path) -> Result<AuthoritativeProbe> {
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
fn ensure_conversation_store_shape(connection: &Connection) -> Result<()> {
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

fn probe_canonical_conversation(root: &Path) -> Result<AuthoritativeProbe> {
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
fn upgrade_canonical_conversation_schema(root: &Path) -> Result<()> {
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

fn probe_mobile_relay(path: &Path) -> Result<AuthoritativeProbe> {
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

fn probe_sqlite_meta(
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
const STRATEGY_STORE_DATABASE: &str = "client-state/adaptive-flywheel/strategies.sqlite3";

/// Recovery record for one strategy-store conversion.
///
/// It is written before the first store-format edge runs, one step id is
/// appended after each edge's postcondition holds, and it is marked applied at
/// the end. An interrupted conversion therefore resumes from the physical
/// format the file actually reached — the artifact states what was attempted,
/// the file states what happened, and the next run drives from the file.
const STRATEGY_STORE_ARTIFACT: &str =
    "client-state/migrations/artifacts/adaptive-flywheel-strategy-store.json";
const STRATEGY_STORE_ARTIFACT_SCHEMA: &str = "v0.0.1:strategy-store-conversion-artifact-1";

/// One table of a published store format: the columns a reader of that format
/// relies on, and the statements that create it exactly as published.
struct PublishedTable {
    name: &'static str,
    columns: &'static [&'static str],
    statements: &'static [&'static str],
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
const NOTICE_OUTBOX_TABLES: &[PublishedTable] = &[
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
struct PublishedStrategyFormat {
    format_id: &'static str,
    /// Every `strategy_meta.version` this shape shipped under. One published
    /// writer stamped `0` before it stamped `1`; both are the same shape.
    meta_versions: &'static [&'static str],
    /// The frontier domain version this shape answers to. A store format that
    /// only adds tables does not move the domain version, because the rows the
    /// frontier versions are unchanged.
    domain_schema_version: u32,
    /// Tables that must be present, with the columns a reader relies on.
    required: &'static [(&'static str, &'static [&'static str])],
    /// Columns checked only when their table is present: a file that predates
    /// a table is a file of this format, not a file to refuse.
    columns: &'static [(&'static str, &'static [&'static str])],
    /// Tables this shape does not have. This is what separates the two shapes
    /// that share `strategy_meta.version = '3'`.
    absent: &'static [&'static str],
}

/// The publication history of the strategy database, oldest first.
const PUBLISHED_STRATEGY_FORMATS: &[PublishedStrategyFormat] = &[
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

const NOTICE_OUTBOX_TABLE_NAMES: &[&str] =
    &["workflow_notice_intents", "workflow_notice_acceptances"];

/// Who performs one store-format edge.
#[derive(Clone, Copy, Eq, PartialEq)]
enum StrategyStoreMover {
    /// The published writer's own typed migration. Reimplementing it here would
    /// be a second definition of the same published shape, so the edge drives
    /// the owner's migration and reads the result back.
    PublishedWriter,
    /// The conversion this module performs, because the store only reaches this
    /// shape as a side effect of opening the file.
    NoticeOutbox,
}

struct StrategyStoreEdge {
    step_id: &'static str,
    from: &'static str,
    to: &'static str,
    mover: StrategyStoreMover,
}

/// The conversion graph over the published strategy-store formats.
///
/// Edges are keyed by the shape they move *from*, and a shape has exactly one
/// successor, so a conversion from any published format to the current one is a
/// unique path. `strategy_store_path` refuses a gap instead of guessing a move.
const STRATEGY_STORE_EDGES: &[StrategyStoreEdge] = &[
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
fn strategy_format_for_domain_version(version: u32) -> Result<&'static PublishedStrategyFormat> {
    PUBLISHED_STRATEGY_FORMATS
        .iter()
        .find(|format| format.domain_schema_version == version)
        .ok_or_else(|| anyhow!("migration_frontier_incomplete"))
}

/// The current published format: the newest shape in the publication history.
fn current_strategy_format() -> &'static PublishedStrategyFormat {
    PUBLISHED_STRATEGY_FORMATS
        .last()
        .expect("the strategy publication history is not empty")
}

fn strategy_format_position(format_id: &str) -> Result<usize> {
    PUBLISHED_STRATEGY_FORMATS
        .iter()
        .position(|format| format.format_id == format_id)
        .ok_or_else(|| anyhow!("migration_frontier_incomplete"))
}

/// The unique conversion path from one published format to another.
fn strategy_store_path(from: &str, to: &str) -> Result<Vec<&'static StrategyStoreEdge>> {
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

fn published_table_columns(connection: &Connection, table: &str) -> Result<Vec<String>> {
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

fn strategy_table_columns(connection: &Connection, table: &str) -> Result<Vec<String>> {
    published_table_columns(connection, table)
}

fn strategy_table_has_columns(
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
fn read_strategy_store_format(path: &Path) -> Result<&'static PublishedStrategyFormat> {
    ensure!(regular_file_present(path)?, "unsupported_state_shape");
    let connection = Connection::open_with_flags(
        path,
        rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY | rusqlite::OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )
    .context("unsupported_state_shape")?;
    read_strategy_store_format_on(&connection)
}

fn read_strategy_store_format_on(
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

fn current_strategy_meta_version() -> u32 {
    current_strategy_format()
        .meta_versions
        .iter()
        .filter_map(|version| version.parse::<u32>().ok())
        .max()
        .expect("the current strategy format has a numeric version")
}

fn probe_adaptive_flywheel(root: &Path) -> Result<AuthoritativeProbe> {
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
struct StrategyStoreArtifact {
    schema_version: String,
    domain_id: String,
    from_format: String,
    target_format: String,
    applied_step_ids: Vec<String>,
    status: String,
}

fn strategy_store_artifact_path(root: &Path) -> PathBuf {
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
fn begin_strategy_store_artifact(
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
            status: "pending".to_owned(),
        }
    };
    artifact.target_format = target.format_id.to_owned();
    // Written before any edge runs, so a crash inside the conversion leaves a
    // record that claims only what is true: a step is in flight. The caller
    // marks it applied after the last edge's postcondition holds.
    artifact.status = "pending".to_owned();
    if let Some(parent) = path.parent() {
        crate::platform::file_security::ensure_private_dir(parent)
            .context("migration_step_failed")?;
    }
    write_json_atomic(&path, &artifact).context("migration_step_failed")?;
    Ok(artifact)
}

const STRATEGY_STORE_DOMAIN: &str = "adaptive-flywheel";

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
fn apply_strategy_store_notice_outbox(path: &Path) -> Result<()> {
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
fn delegate_strategy_store_edge(edge: &StrategyStoreEdge, root: &Path) -> Result<()> {
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
fn advance_strategy_store(
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
        artifact.status = "applied".to_owned();
        write_json_atomic(&artifact_path, &artifact).context("migration_step_failed")?;
    }
    Ok(applied)
}

#[derive(Clone, Copy)]
enum JsonSchemaPolicy {
    CurrentOnly,
    MissingIsLegacy,
}

fn probe_json_schema(
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

fn regular_file_present(path: &Path) -> Result<bool> {
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

fn canonical_legacy_state_present(root: &Path) -> Result<bool> {
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

fn apply_authoritative_store(
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

fn migration_handler_target(domain_id: &str, from_schema_version: u32) -> Option<u32> {
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

fn migrate_agent_tab_order(path: &Path) -> Result<()> {
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

fn migrate_mobile_relay(path: &Path) -> Result<()> {
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

fn migrate_json_schema(path: &Path, current: u64, policy: JsonSchemaPolicy) -> Result<()> {
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

fn reconcile_ledger(ledger: &mut Ledger, domain: &DomainFrontier, edge: &MigrationEdge) -> bool {
    let entry = ledger
        .domains
        .entry(domain.domain_id.clone())
        .or_insert_with(|| LedgerDomain {
            schema_version: edge.from_schema_version,
            completed_step_ids: Vec::new(),
        });
    let before = entry.clone();
    entry.schema_version = edge.to_schema_version;
    if !entry.completed_step_ids.contains(&edge.step_id) {
        entry.completed_step_ids.push(edge.step_id.clone());
    }
    let allowed = domain
        .steps
        .iter()
        .map(|step| step.step_id.as_str())
        .collect::<BTreeSet<_>>();
    entry
        .completed_step_ids
        .retain(|step| allowed.contains(step.as_str()));
    *entry != before
}

fn write_json_atomic(path: &Path, value: &impl Serialize) -> Result<()> {
    let mut serialized = serde_json::to_string(value)?;
    serialized.push('\n');
    ensure!(
        serialized.len() <= MAX_MIGRATION_JSON_BYTES,
        "migration_step_failed"
    );
    crate::platform::file_security::atomic_write_private_text(path, &serialized)
}

fn safe_error_code(error: &anyhow::Error) -> &'static str {
    const CODES: &[&str] = &[
        "migration_lock_unavailable",
        "migration_ledger_invalid",
        "state_newer_than_binary",
        "migration_frontier_incomplete",
        "migration_step_failed",
        "migration_postcondition_failed",
        "update_handoff_mismatch",
        "unsupported_state_shape",
    ];
    for cause in error.chain() {
        if let Some(code) = CODES
            .iter()
            .copied()
            .find(|code| cause.to_string().contains(code))
        {
            return code;
        }
    }
    "migration_step_failed"
}

pub fn admission_json(data_root: &Path) -> Result<serde_json::Value> {
    Ok(serde_json::to_value(admit(data_root)?)?)
}

pub fn frontier_projection() -> Result<serde_json::Value> {
    let frontier = embedded_frontier()?;
    Ok(frontier_projection_for(&frontier))
}

fn frontier_projection_for(frontier: &MigrationFrontier) -> serde_json::Value {
    json!({
        "frontierId": &frontier.frontier_id,
        "domains": frontier.domains.iter().map(|domain| json!({
            "domainId": &domain.domain_id,
            "targetSchemaVersion": domain.target_schema_version,
            "requiredStepIds": domain.steps.iter().map(|step| &step.step_id).collect::<Vec<_>>(),
        })).collect::<Vec<_>>()
    })
}

#[cfg(test)]
mod tests {
    use super::*;

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
        let failure = migrate_gateway_credentials_with(&root, || {
            Err(anyhow!("synthetic_native_cancellation"))
        });
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
            let root =
                std::env::temp_dir().join(format!("licoup-migration-{}", uuid::Uuid::new_v4()));
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
                state: "pending".to_owned(),
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
                state: "pending".to_owned(),
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
                state: "pending".to_owned(),
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
        // Each fixture is a published shape, not just a version row: the
        // conversation probe refuses a database that only declares a version,
        // so the canary test has to start from a store a published writer
        // could have left.
        let fixtures = [
            (
                "client-state/conversations/conversations.sqlite3",
                "CREATE TABLE schema_meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);\
                 INSERT INTO schema_meta(key,value) VALUES ('version','17');\
                 CREATE TABLE conversations(
                   id TEXT PRIMARY KEY, title TEXT NOT NULL,
                   archived INTEGER NOT NULL DEFAULT 0 CHECK(archived IN (0,1)),
                   pinned INTEGER NOT NULL DEFAULT 0 CHECK(pinned IN (0,1)),
                   is_group INTEGER NOT NULL DEFAULT 0 CHECK(is_group IN (0,1)),
                   strategy_revision TEXT, assistant_membership_id TEXT,
                   revision INTEGER NOT NULL DEFAULT 0,
                   created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL
                 );\
                 CREATE TABLE preservation_canary(value TEXT NOT NULL);\
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
        let root =
            std::env::temp_dir().join(format!("licoup-notice-outbox-{}", uuid::Uuid::new_v4()));
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
            serde_json::from_slice(&fs::read(strategy_store_artifact_path(&root)).unwrap())
                .unwrap();
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
            serde_json::from_slice(&fs::read(strategy_store_artifact_path(&root)).unwrap())
                .unwrap();
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
            serde_json::from_slice(&fs::read(strategy_store_artifact_path(&root)).unwrap())
                .unwrap();
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
                 INSERT INTO schema_meta(key,value) VALUES ('version','17');
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
}
