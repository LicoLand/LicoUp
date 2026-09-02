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
    for domain in &frontier.domains {
        let version = probe_domain(&marker_root, domain)?;
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
    crate::platform::file_security::remove_private_state_marker(&handoff_path)
        .context("update_handoff_mismatch")?;
    Ok(AdmissionResult {
        status: "ready",
        running_product_version: running_version.to_owned(),
        running_release_track: ReleaseTrack::running()?.as_str(),
        frontier_id: frontier.frontier_id,
        applied_domain_ids: applied.into_iter().collect(),
        skipped_domain_ids: skipped,
    })
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
        "client-state" => {
            let (version, present) = crate::platform::client_state::probe_collections(root)?;
            Ok(AuthoritativeProbe { version, present })
        }
        "canonical-conversation" => probe_canonical_conversation(root),
        "adaptive-flywheel" => probe_sqlite_meta(
            &root.join("client-state/adaptive-flywheel/strategies.sqlite3"),
            "strategy_meta",
            "version",
            "2",
        ),
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

fn probe_canonical_conversation(root: &Path) -> Result<AuthoritativeProbe> {
    let database = root.join("client-state/conversations/conversations.sqlite3");
    let completion_marker = root.join("client-state/conversations/migration-v5.complete");
    let database_present = regular_file_present(&database)?;
    let completion_present = regular_file_present(&completion_marker)?;
    let legacy_present = canonical_legacy_state_present(root)?;
    let database_version = probe_sqlite_meta(&database, "schema_meta", "version", "11")?.version;
    if !database_present {
        ensure!(!completion_present, "unsupported_state_shape");
        return Ok(AuthoritativeProbe {
            version: 0,
            present: legacy_present,
        });
    }
    if database_version == 0 {
        return Ok(AuthoritativeProbe {
            version: 0,
            present: true,
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
    Ok(AuthoritativeProbe {
        version: 1,
        present: true,
    })
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
            let path = root.join("client-state/adaptive-flywheel/strategies.sqlite3");
            if path.exists() {
                // StrategyStore migrations execute in SQLite transactions; a
                // failed process resumes from the authoritative meta value.
                crate::domain::adaptive_flywheel::StrategyStore::open_for_migration(root)
                    .context("migration_step_failed")?;
            }
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

    #[test]
    fn admission_is_incremental_and_rerun_is_a_noop() {
        let root = std::env::temp_dir().join(format!("licoup-migration-{}", uuid::Uuid::new_v4()));
        fs::create_dir_all(&root).unwrap();
        let first = admit(&root).unwrap();
        assert!(!first.applied_domain_ids.is_empty());
        let second = admit(&root).unwrap();
        assert!(second.applied_domain_ids.is_empty());
        assert_eq!(
            second.skipped_domain_ids.len(),
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
            ledger.domains.len(),
            embedded_frontier().unwrap().domains.len()
        );
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
        for (relative, table, key, version) in [
            (
                "client-state/conversations/conversations.sqlite3",
                "schema_meta",
                "version",
                "11",
            ),
            (
                "client-state/adaptive-flywheel/strategies.sqlite3",
                "strategy_meta",
                "version",
                "2",
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
}
