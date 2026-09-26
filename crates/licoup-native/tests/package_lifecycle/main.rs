//! V7-U1 acceptance at `component-integration` level: optional discovery, offline
//! local import, and the install/uninstall transaction, exercised against a real
//! managed root.
//!
//! What is real here: a real managed root on disk, real package archives built
//! from real manifests, the production `PackageStore` (staging directory, install
//! journal, atomic publication, recovery), the real bounded extractor
//! (`crate::core::safe_archive`), the real state machines, and the real storage
//! accounting and GC planner.
//!
//! What is synthetic, stated plainly: the "directory" is a hundred generated
//! catalogue entries and the packages are small generated archives. A36 is about
//! the *cost* of a hundred candidates, not about a hundred real vendors, and the
//! plan says so explicitly. Nothing here is fetched: the bytes handed to the
//! installer stand in for what a host fetcher would have returned, which is why
//! the trust record that goes with them is built from their digest.
//!
//! What is deliberately not here: no network, no marketplace, no account, no
//! process launch. A local import has to work with the machine offline, and this
//! harness would fail if anything on these paths needed to reach out.

use std::collections::BTreeMap;
use std::io::Write;
use std::path::{Path, PathBuf};

use licoup_extension_contracts::deployment::{
    CORE_PACKAGE, LocalCatalogue, PackageEntry, PackageLifecycle, PackageSource, install_closure,
};
use licoup_extension_contracts::manifest::{Dependency, PermissionRequest};
use licoup_extension_contracts::wire;
use licoup_native::platform::extension_packages::{
    Admission, ArtifactLimits, CatalogEntry, CatalogIndex, DependentsDecision, Detector,
    DiscoveryEnvironment, Drained, FaultPlan, InFlightPins, InstallPhase, InstallRequest,
    InstanceIdentity, InstanceLifecycle, InstanceMachine, InstanceRegistry, OffFrameLane,
    PackageMachine, PackageStore, RecommendationLog, RemainingWork, StorageKind, TrustRecord,
    UninstallTransaction, account_store, close_surface, plan_gc, preview, scan,
};

// ---------------------------------------------------------------------------
// Fixtures: a real archive, a real store, a real root
// ---------------------------------------------------------------------------

fn root(tag: &str) -> PathBuf {
    std::env::temp_dir().join(format!(
        "licoup-v71-package-lifecycle-{tag}-{}-{}",
        std::process::id(),
        uuid_v4ish()
    ))
}

/// A locally unique suffix. The harness has no uuid dependency, and this only
/// needs to not collide between test processes.
fn uuid_v4ish() -> String {
    use std::time::{SystemTime, UNIX_EPOCH};
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_nanos())
        .unwrap_or_default();
    format!("{nanos:x}")
}

fn manifest_json(
    id: &str,
    version: &str,
    entry: &str,
    permissions: &[(&str, &str)],
    runtime_ref: Option<&str>,
    requires: &[(&str, &str)],
) -> String {
    let mut runtime = serde_json::json!({ "mode": "process", "entry": entry });
    if let Some(reference) = runtime_ref {
        runtime["runtimeRef"] = serde_json::Value::String(reference.to_owned());
    }
    let permissions: Vec<serde_json::Value> = permissions
        .iter()
        .map(|(capability, scope)| serde_json::json!({ "capability": capability, "scope": scope }))
        .collect();
    let requires: Vec<serde_json::Value> = requires
        .iter()
        .map(|(package_id, range)| serde_json::json!({ "packageId": package_id, "range": range }))
        .collect();
    serde_json::json!({
        "schema": wire::MANIFEST,
        "id": id,
        "version": version,
        "displayName": format!("Fixture {id}"),
        "hostProtocol": { "major": 1, "minimumMinor": 0 },
        "profiles": [],
        "runtime": runtime,
        "activation": "on-demand",
        "requires": requires,
        "optionalRequires": [],
        "permissions": permissions,
        "contributions": [],
    })
    .to_string()
}

/// One package archive, built the way a user-built package would be.
fn package_bytes(id: &str, version: &str, runtime_ref: Option<&str>) -> Vec<u8> {
    archive(&[
        (
            "manifest.json",
            manifest_json(
                id,
                version,
                "agent.py",
                &[("example.fixture/net", "self")],
                runtime_ref,
                &[],
            )
            .into_bytes(),
        ),
        ("agent.py", b"print('fixture')\n".to_vec()),
    ])
}

fn archive(files: &[(&str, Vec<u8>)]) -> Vec<u8> {
    let mut writer = zip::ZipWriter::new(std::io::Cursor::new(Vec::new()));
    let options = zip::write::SimpleFileOptions::default();
    for (name, content) in files {
        writer.start_file(*name, options).expect("start file");
        writer.write_all(content).expect("write");
    }
    writer.finish().expect("finish").into_inner()
}

fn trust_for(bytes: &[u8]) -> TrustRecord {
    TrustRecord::local_approved(
        content_digest_of(bytes),
        [PermissionRequest::new("example.fixture/net", "self")],
    )
    .expect("trust")
}

/// The module's own digest, reached through the public surface as a user would.
fn content_digest_of(bytes: &[u8]) -> String {
    licoup_native::platform::extension_packages::content_digest(bytes)
}

fn store(tag: &str) -> (PathBuf, PackageStore) {
    let root = root(tag);
    std::fs::create_dir_all(&root).expect("root");
    let store = PackageStore::open(&root).expect("store");
    (root, store)
}

fn install_local(
    store: &PackageStore,
    id: &str,
    version: &str,
    runtime_ref: Option<&str>,
) -> Vec<u8> {
    let bytes = package_bytes(id, version, runtime_ref);
    store
        .install_local_import(id, version, trust_for(&bytes), &bytes)
        .expect("local import");
    bytes
}

fn active_instance(package_id: &str, version: &str, generation: u64) -> InstanceMachine {
    let identity = InstanceIdentity::new(
        format!("instance-{package_id}-{generation}"),
        package_id,
        version,
        generation,
        11,
        Vec::<String>::new(),
    )
    .expect("identity");
    let mut machine = InstanceMachine::discovered(identity).expect("instance");
    machine
        .advance(InstanceLifecycle::Preparing)
        .expect("preparing");
    machine.advance(InstanceLifecycle::Active).expect("active");
    machine
}

fn cleanup(root: &Path) {
    let _ = std::fs::remove_dir_all(root);
}

// ---------------------------------------------------------------------------
// A37 — optional discovery and offline local import
// ---------------------------------------------------------------------------

#[test]
fn discovery_recommends_without_installing_and_a_local_import_needs_no_directory() {
    let (root, store) = store("a37-local-import");

    // A directory of candidate metadata: no payload, no runtime handle.
    let index = CatalogIndex::from_entries((0..100).map(|index| {
        let id = format!("example.fixture.adapter{index:03}");
        CatalogEntry::new(
            id.clone(),
            "1.0.0",
            format!("Fixture adapter {index}"),
            PackageSource::ThirdPartyDirectory,
        )
        .with_rules([
            licoup_native::platform::extension_packages::DiscoveryRule::new(
                id,
                Detector::PathEntry {
                    name: format!("fixture-agent-{index:03}"),
                },
            ),
        ])
    }));
    assert_eq!(index.len(), 100);
    assert_eq!(
        index.payload_paths(),
        0,
        "an available entry has no payload"
    );

    let environment = DiscoveryEnvironment::new(["fixture-agent-003".to_owned()]);
    let lane = OffFrameLane::new_on_frame_thread();
    assert_eq!(
        lane.scan(&index, &environment)
            .expect_err("a scan on the GUI frame thread is refused")
            .code,
        "agent_scan_on_frame_thread"
    );
    let scanned = lane.scan_off_frame(index, environment).expect("off frame");
    assert_eq!(scanned.package_ids(), vec!["example.fixture.adapter003"]);
    assert_eq!(scanned.processes_spawned, 0, "detection is metadata");
    assert!(!scanned.code_loaded);

    // The user declines. Nothing is installed, nothing runs, and the decision is
    // recorded rather than re-offered.
    let mut log = RecommendationLog::new();
    scanned.recommendations[0].decline(&mut log, "not needed on this machine");
    assert!(log.was_declined("example.fixture.adapter003"));
    assert!(store.installed().expect("installed").is_empty());

    // A package the user built and never published imports offline, with no
    // account: the trust record is bound to the content it was made about.
    assert!(!PackageSource::LocalImport.requires_network());
    assert!(!PackageSource::LocalImport.requires_account());
    let bytes = package_bytes("example.fixture.echo", "1.0.0", None);
    let outcome = store
        .install_local_import("example.fixture.echo", "1.0.0", trust_for(&bytes), &bytes)
        .expect("offline import");
    assert_eq!(outcome.installed.source, PackageSource::LocalImport);
    assert_eq!(
        outcome.installed.trust_channel,
        PackageLifecycle::LocalApproved
    );
    assert_eq!(outcome.processes_spawned, 0);

    // A directory that is unreachable does not affect what is already installed:
    // the local view is a lookup, not a service.
    let unavailable = LocalCatalogue::new();
    assert!(!unavailable.contains("example.fixture.echo"));
    assert_eq!(store.installed().expect("installed").len(), 1);
    let facts = licoup_extension_contracts::deployment::PackageFacts::local_import(true);
    assert_eq!(
        licoup_extension_contracts::deployment::availability("agent-execution.v1", facts)
            .describe(),
        "served",
        "an imported package serves its capability without any directory"
    );
    assert_eq!(
        licoup_extension_contracts::deployment::availability("model-gateway.v1", facts).describe(),
        "served",
        "and the capability list is the contract's, not this module's"
    );
    assert_eq!(
        licoup_extension_contracts::deployment::availability(
            "workflow.v1",
            licoup_extension_contracts::deployment::PackageFacts::default()
        )
        .describe(),
        "not-installed",
        "an optional capability nobody installed is a catalogue fact, not an error"
    );

    cleanup(&root);
}

#[test]
fn a_network_source_still_needs_a_decision_bound_to_its_content() {
    let (root, store) = store("a37-source");
    let bytes = package_bytes("example.fixture.remote", "1.0.0", None);
    let tampered = package_bytes("example.fixture.remote", "1.0.1", None);

    // Bytes that are not the bytes the decision was made about are refused, no
    // matter how the decision was made.
    let request = InstallRequest::new(
        "example.fixture.remote",
        "1.0.0",
        PackageSource::OfficialDirectory,
        trust_for(&bytes),
    );
    assert_eq!(
        store
            .install(&request, &tampered)
            .expect_err("hash corruption")
            .code,
        "package_trust_not_bound_to_content"
    );
    assert!(store.installed().expect("installed").is_empty());

    // The same bytes with a publisher verification install, with no account and
    // no directory in this process.
    let verified = TrustRecord::publisher_verified(
        content_digest_of(&bytes),
        [PermissionRequest::new("example.fixture/net", "self")],
    )
    .expect("verified");
    let request = InstallRequest::new(
        "example.fixture.remote",
        "1.0.0",
        PackageSource::OfficialDirectory,
        verified,
    );
    let outcome = store.install(&request, &bytes).expect("installed");
    assert_eq!(outcome.installed.trust_channel, PackageLifecycle::Verified);
    assert_eq!(outcome.state, PackageLifecycle::Installed);

    cleanup(&root);
}

// ---------------------------------------------------------------------------
// A39 — permissions, sources and hostile packages
// ---------------------------------------------------------------------------

#[test]
fn a_hostile_package_is_refused_before_it_can_be_installed() {
    let (root, store) = store("a39-hostile");

    // A path that leaves the package.
    let escaping = archive(&[
        (
            "manifest.json",
            manifest_json(
                "example.fixture.escape",
                "1.0.0",
                "agent.py",
                &[("example.fixture/net", "self")],
                None,
                &[],
            )
            .into_bytes(),
        ),
        ("agent.py", b"print('fixture')\n".to_vec()),
        ("../escaped.txt", b"escaped".to_vec()),
    ]);
    let request = InstallRequest::new(
        "example.fixture.escape",
        "1.0.0",
        PackageSource::LocalImport,
        trust_for(&escaping),
    );
    let failure = store.install(&request, &escaping).expect_err("traversal");
    assert!(
        matches!(
            failure.code.as_str(),
            "package_artifact_path_unsafe" | "package_artifact_invalid"
        ),
        "unexpected refusal {}",
        failure.code
    );
    assert!(!root.join("escaped.txt").exists());
    assert!(store.installed().expect("installed").is_empty());

    // A manifest that declares a fact about its own bytes.
    let mut self_hashed: serde_json::Value = serde_json::from_str(&manifest_json(
        "example.fixture.selfhash",
        "1.0.0",
        "agent.py",
        &[("example.fixture/net", "self")],
        None,
        &[],
    ))
    .expect("json");
    self_hashed["verified"] = serde_json::Value::Bool(true);
    let bytes = archive(&[
        ("manifest.json", self_hashed.to_string().into_bytes()),
        ("agent.py", b"print('fixture')\n".to_vec()),
    ]);
    let request = InstallRequest::new(
        "example.fixture.selfhash",
        "1.0.0",
        PackageSource::LocalImport,
        trust_for(&bytes),
    );
    assert_eq!(
        store
            .install(&request, &bytes)
            .expect_err("self asserted trust")
            .code,
        "manifest_self_asserted_fact"
    );

    // The manifest asks for more than the user approved.
    let widening = archive(&[
        (
            "manifest.json",
            manifest_json(
                "example.fixture.widening",
                "1.0.0",
                "agent.py",
                &[
                    ("example.fixture/net", "self"),
                    ("example.fixture/fs", "home"),
                ],
                None,
                &[],
            )
            .into_bytes(),
        ),
        ("agent.py", b"print('fixture')\n".to_vec()),
    ]);
    let narrow = TrustRecord::local_approved(
        content_digest_of(&widening),
        [PermissionRequest::new("example.fixture/net", "self")],
    )
    .expect("narrow trust");
    let request = InstallRequest::new(
        "example.fixture.widening",
        "1.0.0",
        PackageSource::LocalImport,
        narrow,
    );
    assert_eq!(
        store
            .install(&request, &widening)
            .expect_err("permission expansion")
            .code,
        "package_permission_scope_expanded"
    );

    // A discovery rule that tries to read outside the location the user allowed.
    let probe_root = root.join("allowed");
    std::fs::create_dir_all(&probe_root).expect("probe root");
    std::fs::write(root.join("secret-marker"), b"not yours").expect("marker");
    let escaping_rule = CatalogIndex::from_entries([CatalogEntry::new(
        "example.fixture.probe",
        "1.0.0",
        "Fixture probe",
        PackageSource::LocalDirectory,
    )
    .with_rules([
        licoup_native::platform::extension_packages::DiscoveryRule::new(
            "example.fixture.probe",
            Detector::MarkerPath {
                relative_path: "../secret-marker".to_owned(),
            },
        ),
    ])]);
    let environment = DiscoveryEnvironment::new(Vec::<String>::new()).with_probe_root(probe_root);
    assert!(
        scan(&escaping_rule, &environment).is_empty(),
        "a probe rule may not leave the allowed location"
    );

    // A package that crashed after it was activated is visible as a failed
    // instance, and the package stays installed so the user can see what happened.
    install_local(&store, "example.fixture.echo", "1.0.0", None);
    let mut registry = InstanceRegistry::new();
    let mut machine = active_instance("example.fixture.echo", "1.0.0", 1);
    machine.begin_in_flight().expect("admitted work");
    machine.fail("the adapter process exited").expect("failed");
    assert_eq!(machine.state(), InstanceLifecycle::Failed);
    assert_eq!(
        machine.in_flight(),
        1,
        "unknown work is pinned, not re-dispatched"
    );
    registry.insert(machine);
    assert_eq!(store.installed().expect("installed").len(), 1);
    assert_eq!(
        registry
            .get("instance-example.fixture.echo-1")
            .expect("instance")
            .note(),
        Some("the adapter process exited")
    );

    cleanup(&root);
}

// ---------------------------------------------------------------------------
// A38 — crash injection, compatibility and recovery
// ---------------------------------------------------------------------------

#[test]
fn an_interrupted_install_keeps_the_old_version_and_recovery_finishes_the_journal() {
    let (root, store) = store("a38-crash");
    let first = install_local(&store, "example.fixture.echo", "1.0.0", None);
    assert!(!first.is_empty(), "a real archive was written to disk");

    let second = package_bytes("example.fixture.echo", "2.0.0", None);
    for phase in [
        InstallPhase::Download,
        InstallPhase::Verify,
        InstallPhase::Stage,
        InstallPhase::Activate,
    ] {
        let request = InstallRequest::new(
            "example.fixture.echo",
            "2.0.0",
            PackageSource::LocalImport,
            trust_for(&second),
        )
        .with_faults(FaultPlan::failing_at(phase));
        let failure = store.install(&request, &second).expect_err("injected");
        assert_eq!(failure.code, "package_install_interrupted");
        assert!(
            store
                .installed_path("example.fixture.echo", "1.0.0")
                .join("agent.py")
                .exists(),
            "the previously installed version keeps serving after a crash at {phase:?}"
        );

        let report = store.recover().expect("recover");
        if phase == InstallPhase::Activate {
            // Rename alone is not a published installation: the durable record
            // is still missing, so recovery reclaims this abandoned version.
            assert!(report.installed_untouched.is_empty());
            assert!(report.abandoned.iter().any(|entry| {
                entry.package_id == "example.fixture.echo" && entry.version == "2.0.0"
            }));
            assert!(report.reclaimed_bytes > 0);
            assert!(
                !store
                    .journal()
                    .committed("example.fixture.echo", "2.0.0")
                    .expect("journal")
            );
            assert!(
                !store
                    .installed_path("example.fixture.echo", "2.0.0")
                    .exists()
            );
        } else if phase == InstallPhase::Stage {
            assert!(
                report.reclaimed_bytes > 0,
                "the abandoned stage is reclaimed"
            );
            assert_eq!(report.abandoned.len(), 1);
        }
        assert!(store.staged_directories().expect("staged").is_empty());

        // The client is still usable: the core view of what is installed is a
        // local lookup, and the failure did not disturb it.
        assert_eq!(store.installed().expect("installed").len(), 1);
    }

    // A restart where the old instance is gone reports it rather than forgetting
    // it, and the pins it still owns stay accounted.
    let mut registry = InstanceRegistry::new();
    registry.insert(active_instance("example.fixture.echo", "1.0.0", 1));
    let missing = registry.reconcile_after_restart(&[]);
    assert_eq!(missing, vec!["instance-example.fixture.echo-1".to_owned()]);
    let mut pins = InFlightPins::new();
    pins.pin("example.fixture.echo@1.0.0#1", 2_048);
    let installed = store.installed().expect("installed");
    let report =
        account_store(&store, &installed, 8_000, 512, &BTreeMap::new(), &pins).expect("account");
    assert_eq!(report.category(StorageKind::InFlightPin), 2_048);

    cleanup(&root);
}

// ---------------------------------------------------------------------------
// A31 — uninstall: withdraw, drain, reclaim, preserve
// ---------------------------------------------------------------------------

#[test]
fn uninstall_withdraws_admission_first_and_then_reclaims_only_its_own_bytes() {
    let (root, store) = store("a31-uninstall");
    install_local(
        &store,
        "example.fixture.echo",
        "1.0.0",
        Some("user:python3"),
    );
    let user_data = root.join("user-data").join("example.fixture.echo");
    std::fs::create_dir_all(user_data.join("history")).expect("history dir");
    std::fs::write(
        user_data.join("history").join("turns.jsonl"),
        vec![5u8; 256],
    )
    .expect("write");

    let installed = store.installed().expect("installed").remove(0);
    let mut registry = InstanceRegistry::new();
    let instance_id = "instance-example.fixture.echo-1".to_owned();
    let mut machine = active_instance("example.fixture.echo", "1.0.0", 1);
    machine.begin_in_flight().expect("admitted work");
    registry.insert(machine);

    let catalogue = LocalCatalogue::new();
    let plan = preview(&store, &catalogue, &installed, &registry).expect("preview");
    assert!(
        plan.exclusive_bytes > 0,
        "the version occupies its own bytes"
    );
    assert_eq!(plan.in_flight, 1);
    assert_eq!(
        plan.shared_runtime_ref, None,
        "the user's own interpreter is not the host's to remove"
    );
    assert!(plan.preserved.history);

    // Closing a page is not uninstalling: nothing about the package changes.
    let closure = close_surface("example.fixture.echo");
    assert!(closure.package_still_installed);
    assert_eq!(closure.instances_changed, 0);
    assert!(
        store
            .installed_path("example.fixture.echo", "1.0.0")
            .exists()
    );

    // Waiting refuses while work is unsettled, and removes nothing.
    let transaction = UninstallTransaction::begin(
        &mut registry,
        plan.clone(),
        DependentsDecision::SelectedOnly,
    )
    .expect("begin");
    assert_eq!(
        transaction.withdrawn_instances(),
        std::slice::from_ref(&instance_id)
    );
    assert_eq!(
        registry.get(&instance_id).expect("instance").admission(),
        Admission::Withdrawn,
        "admission is withdrawn before anything drains"
    );
    assert_eq!(
        registry.get(&instance_id).expect("instance").state(),
        InstanceLifecycle::Active,
        "and the instance keeps running its admitted work"
    );
    assert_eq!(
        transaction
            .drain(&mut registry, RemainingWork::Wait)
            .expect_err("in-flight work")
            .code,
        "package_uninstall_in_flight"
    );
    assert!(
        store
            .installed_path("example.fixture.echo", "1.0.0")
            .exists()
    );

    // The user cancels the remaining work instead: the outcome is Unknown, and
    // then — and only then — the bytes are reclaimed.
    let transaction =
        UninstallTransaction::begin(&mut registry, plan, DependentsDecision::SelectedOnly)
            .expect("begin again");
    let drained: Drained = transaction
        .drain(&mut registry, RemainingWork::Cancel)
        .expect("cancel");
    assert_eq!(
        registry.get(&instance_id).expect("instance").state(),
        InstanceLifecycle::Stopped
    );
    let outcome = drained.collect(&store, &registry).expect("collect");

    assert_eq!(outcome.unknown_work, 1, "cancelled work is Unknown");
    assert!(outcome.reclaimed_bytes > 0);
    assert!(
        !store
            .installed_path("example.fixture.echo", "1.0.0")
            .exists(),
        "the code is actually gone, not hidden behind a menu"
    );
    assert!(outcome.user_runtime_kept, "the user's interpreter stays");
    assert!(outcome.preserved.history && outcome.preserved.credentials);
    assert!(
        user_data.join("history").join("turns.jsonl").exists(),
        "history is the user's, and uninstall keeps it"
    );

    // Reinstalling brings the package back with the history still there.
    install_local(&store, "example.fixture.echo", "1.0.0", None);
    assert_eq!(store.installed().expect("installed").len(), 1);

    cleanup(&root);
}

#[test]
fn a_shared_dependency_or_a_dependent_package_is_not_silently_removed() {
    let (root, store) = store("a31-dependents");
    install_local(
        &store,
        "example.fixture.shared",
        "1.0.0",
        Some("runtime.fixture-node"),
    );
    install_local(&store, "example.fixture.panel", "1.0.0", None);

    let mut catalogue = LocalCatalogue::new();
    catalogue.insert(PackageEntry::new(
        CORE_PACKAGE,
        "0.3.0",
        PackageSource::OfficialDirectory,
    ));
    catalogue.insert(
        PackageEntry::new(
            "example.fixture.shared",
            "1.0.0",
            PackageSource::LocalImport,
        )
        .requiring([Dependency::new(CORE_PACKAGE, "^0.3")]),
    );
    catalogue.insert(
        PackageEntry::new("example.fixture.panel", "1.0.0", PackageSource::LocalImport)
            .requiring([Dependency::new("example.fixture.shared", "^1")]),
    );
    let closure = install_closure(&catalogue, &["example.fixture.panel"]).expect("closure");
    assert!(
        closure.contains("example.fixture.shared"),
        "the dependency closure is what an install would bring"
    );

    let installed = store
        .installed()
        .expect("installed")
        .into_iter()
        .find(|installed| installed.package_id == "example.fixture.shared")
        .expect("shared package");
    let mut registry = InstanceRegistry::new();
    let plan = preview(&store, &catalogue, &installed, &registry).expect("preview");
    assert!(plan.needs_user_choice());
    assert_eq!(
        plan.reverse_dependencies,
        vec!["example.fixture.panel".to_owned()]
    );
    assert_eq!(
        UninstallTransaction::begin(
            &mut registry,
            plan.clone(),
            DependentsDecision::SelectedOnly
        )
        .expect_err("no cascade")
        .code,
        "package_uninstall_has_dependents"
    );
    assert!(
        store
            .installed_path("example.fixture.shared", "1.0.0")
            .exists()
    );

    // Storage accounting deducts the shared runtime while the other package uses
    // it, and GC keeps it.
    let installed_all = store.installed().expect("installed");
    let mut runtimes = BTreeMap::new();
    runtimes.insert("runtime.fixture-node".to_owned(), 64_000_000);
    let account = account_store(
        &store,
        &installed_all,
        16_000_000,
        0,
        &runtimes,
        &InFlightPins::new(),
    )
    .expect("account");
    assert_eq!(account.category(StorageKind::SharedRuntime), 64_000_000);
    assert!(account.unmeasured().is_empty());

    let entries = vec![
        licoup_native::platform::extension_packages::StorageEntry::new(
            "runtime:runtime.fixture-node",
            StorageKind::SharedRuntime,
            64_000_000,
        )
        .with_references(1),
        licoup_native::platform::extension_packages::StorageEntry::new(
            "cache",
            StorageKind::Cache,
            4_096,
        ),
    ];
    let gc = plan_gc(&entries);
    assert_eq!(gc.removed, vec!["cache".to_owned()]);
    assert_eq!(gc.retained.len(), 1, "a shared runtime in use is retained");

    cleanup(&root);
}

// ---------------------------------------------------------------------------
// A36 — one hundred available, three installed, one active
// ---------------------------------------------------------------------------

#[test]
fn one_hundred_available_three_installed_one_active_costs_metadata_only() {
    let (root, store) = store("a36-stress");

    // 100 available entries: metadata, one declarative rule each, no payload.
    let index = CatalogIndex::from_entries((0..100).map(|index| {
        let id = format!("example.fixture.adapter{index:03}");
        CatalogEntry::new(
            id.clone(),
            "1.0.0",
            format!("Fixture adapter {index}"),
            PackageSource::ThirdPartyDirectory,
        )
        .with_capabilities([format!("example.fixture/adapter{index:03}")])
        .with_rules([
            licoup_native::platform::extension_packages::DiscoveryRule::new(
                id,
                Detector::PathEntry {
                    name: format!("fixture-agent-{index:03}"),
                },
            ),
        ])
    }));
    let environment = DiscoveryEnvironment::new([
        "fixture-agent-003".to_owned(),
        "fixture-agent-017".to_owned(),
        "fixture-agent-042".to_owned(),
    ]);
    let lane = OffFrameLane::new_on_frame_thread();
    let scanned = lane
        .scan_off_frame(index, environment)
        .expect("off the frame thread");

    assert_eq!(
        scanned.recommendations.len(),
        3,
        "only what is present is recommended"
    );
    assert_eq!(scanned.rules_evaluated, 100);
    assert_eq!(scanned.processes_spawned, 0, "no candidate is executed");
    assert!(!scanned.code_loaded, "matching loads no code");

    // Three installed, from the recommended set.
    for index in [3usize, 17, 42] {
        let id = format!("example.fixture.adapter{index:03}");
        install_local(&store, &id, "1.0.0", None);
    }
    let installed = store.installed().expect("installed");
    assert_eq!(installed.len(), 3);
    assert!(
        installed
            .iter()
            .all(|installed| installed.source == PackageSource::LocalImport)
    );

    // One active. Installing three does not start three: activation is per
    // instance and on demand.
    let mut registry = InstanceRegistry::new();
    registry.insert(active_instance("example.fixture.adapter003", "1.0.0", 1));
    assert_eq!(registry.active().count(), 1);
    assert_eq!(registry.len(), 1);
    assert_eq!(registry.total_in_flight(), 0);

    // The account names six categories, and the 97 that were never installed
    // occupy nothing.
    let mut pins = InFlightPins::new();
    pins.pin("example.fixture.adapter003@1.0.0#1", 1_024);
    let report = account_store(
        &store,
        &installed,
        32_000_000,
        4_096,
        &BTreeMap::new(),
        &pins,
    )
    .expect("account");
    let lines = report.lines();
    assert_eq!(lines.len(), 6);
    assert_eq!(report.category(StorageKind::Core), 32_000_000);
    assert_eq!(report.category(StorageKind::UserData), 4_096);
    assert_eq!(report.category(StorageKind::InFlightPin), 1_024);
    assert!(
        report.category(StorageKind::OptionalCode) > 0,
        "the three installed packages are code that is really on disk"
    );
    assert!(
        report.total_bytes() > report.downloaded_bytes(),
        "the account is not a download size"
    );

    // And the state machines say the same thing about the three.
    let machine =
        PackageMachine::available("example.fixture.adapter003", "1.0.0").expect("machine");
    assert_eq!(machine.state(), PackageLifecycle::Available);
    let mut installed_machine = PackageMachine::local_import(
        "example.fixture.adapter003",
        "1.0.0",
        TrustRecord::local_approved("sha256:0123456789abcdef", []).expect("trust"),
    )
    .expect("import");
    installed_machine.mark_staged().expect("staged");
    installed_machine
        .commit(licoup_native::platform::extension_packages::InstallActivation::EnabledOnDemand)
        .expect("installed");
    let facts = installed_machine.facts();
    assert!(facts.installed && facts.enabled && !facts.active);
    assert!(!facts.available, "an import was never in a directory");

    cleanup(&root);
}

#[test]
fn every_installed_archive_is_bounded_before_it_is_written() {
    let (root, store) = store("limits");
    let bytes = package_bytes("example.fixture.large", "1.0.0", None);
    let request = InstallRequest::new(
        "example.fixture.large",
        "1.0.0",
        PackageSource::LocalImport,
        trust_for(&bytes),
    )
    .with_limits(ArtifactLimits {
        max_entries: 1,
        ..ArtifactLimits::default()
    });
    assert_eq!(
        store
            .install(&request, &bytes)
            .expect_err("over its entry bound")
            .code,
        "package_artifact_limit_exceeded"
    );
    assert!(store.installed().expect("installed").is_empty());
    assert!(store.staged_directories().expect("staged").is_empty());

    // Installing the same content twice over a live version is refused rather
    // than silently overwritten.
    install_local(&store, "example.fixture.large", "1.0.0", None);
    let duplicate = package_bytes("example.fixture.large", "1.0.0", None);
    assert_eq!(
        store
            .install_local_import(
                "example.fixture.large",
                "1.0.0",
                trust_for(&duplicate),
                &duplicate
            )
            .expect_err("already installed")
            .code,
        "package_version_already_installed"
    );

    // The core package is not the package manager's to depend on removable
    // things, and the ownership facts come from the contract rather than here.
    let mut catalogue = LocalCatalogue::new();
    catalogue.insert(PackageEntry::new(
        CORE_PACKAGE,
        "0.3.0",
        PackageSource::OfficialDirectory,
    ));
    assert!(
        licoup_extension_contracts::deployment::check_core_dependencies(&catalogue).is_ok(),
        "the core depends on nothing removable"
    );

    cleanup(&root);
}
