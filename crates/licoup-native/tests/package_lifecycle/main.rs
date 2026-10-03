//! V7-U1 acceptance at `component-integration` level: optional discovery, offline
//! local import, and the install/uninstall transaction, exercised against a real
//! managed root.
//!
//! What is real here: a real managed root on disk, real package archives built
//! from real manifests, the production `PackageStore` (staging directory, install
//! journal, atomic publication, recovery), the real bounded extractor
//! (`licoup_foundation::core::safe_archive`), the real state machines, and the real storage
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
//! harness would fail if anything on these paths needed to reach out. The
//! `commands` module drives the native routes over the same synthetic data home,
//! including the maintenance seam, which asks the real native idle guard and its
//! own canonical stores.

mod commands;

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
    UninstallTransaction, account_store, close_surface, plan_gc, preview, running_client_version,
    scan,
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
    manifest_json_declaring(
        id,
        version,
        entry,
        permissions,
        runtime_ref,
        requires,
        &covering_client_versions(),
    )
}

/// The client versions a fixture declares it supports: the client this test
/// binary runs as, up to but not including the next major line. The value comes
/// from the product version owner rather than a literal here, and the upper bound
/// is what lets a test exercise a client that has moved past a package's own
/// list.
fn covering_client_versions() -> Vec<String> {
    let client = running_client_version().expect("the binary declares a product version");
    let next_major = client
        .split('.')
        .next()
        .and_then(|major| major.parse::<u64>().ok())
        .map(|major| major + 1)
        .expect("a semantic major version");
    vec![format!(">={client}, <{next_major}")]
}

/// A compatibility list no 0.x client is inside, whatever the running version is.
fn excluding_client_versions() -> Vec<String> {
    vec![">=99.0.0".to_owned()]
}

fn manifest_json_declaring(
    id: &str,
    version: &str,
    entry: &str,
    permissions: &[(&str, &str)],
    runtime_ref: Option<&str>,
    requires: &[(&str, &str)],
    client_versions: &[String],
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
        "compatibility": { "clientVersions": client_versions },
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
    package_bytes_declaring(id, version, runtime_ref, &covering_client_versions())
}

/// One package archive whose manifest declares the given client versions.
fn package_bytes_declaring(
    id: &str,
    version: &str,
    runtime_ref: Option<&str>,
    client_versions: &[String],
) -> Vec<u8> {
    archive(&[
        (
            "manifest.json",
            manifest_json_declaring(
                id,
                version,
                "agent.py",
                &[("example.fixture/net", "self")],
                runtime_ref,
                &[],
                client_versions,
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

/// An installed package that is running, reached the way activation is reached:
/// the store admits the version, and only then may the instance prepare.
fn active_instance(
    store: &PackageStore,
    package_id: &str,
    version: &str,
    generation: u64,
) -> InstanceMachine {
    let identity = InstanceIdentity::new(
        format!("instance-{package_id}-{generation}"),
        package_id,
        version,
        generation,
        11,
        Vec::<String>::new(),
    )
    .expect("identity");
    let admission = store
        .admit_activation(package_id, version)
        .expect("the installed version covers this client");
    let mut machine = InstanceMachine::prepare(admission, identity).expect("preparing");
    machine.activate().expect("active");
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
            "endpoint-collaboration.v1",
            licoup_extension_contracts::deployment::PackageFacts::default()
        )
        .describe(),
        "not-installed",
        "an optional capability nobody installed is a catalogue fact, not an error"
    );

    // The Assistant and the workflow are the kernel's, so no profile choice and
    // no package absence can remove them.
    for capability in [
        licoup_extension_contracts::deployment::ASSISTANT_CAPABILITY,
        licoup_extension_contracts::deployment::WORKFLOW_CAPABILITY,
    ] {
        assert_eq!(
            licoup_extension_contracts::deployment::capability_owner(capability)
                .expect("the kernel owns it")
                .package(),
            CORE_PACKAGE
        );
        assert_eq!(
            licoup_extension_contracts::deployment::availability(capability, facts).describe(),
            "served",
            "{capability} is served by the installed kernel itself"
        );
        assert!(
            !licoup_extension_contracts::deployment::optional_capabilities()
                .any(|optional| optional == capability),
            "{capability} is not a capability a user may leave out"
        );
    }

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
    let mut machine = active_instance(&store, "example.fixture.echo", "1.0.0", 1);
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
// EX-07 — the compatibility list decides admission, not version equality
// ---------------------------------------------------------------------------

#[test]
fn a_package_released_independently_is_admitted_when_its_list_covers_the_client() {
    let (root, store) = store("compatibility-covers");
    let client = running_client_version().expect("the binary declares a product version");

    // The package's own version is deliberately unrelated to the client's: an
    // independently released package is not refused for being a different
    // version, and no exact-version-equality rule exists on this path.
    assert_ne!("7.4.1", client.as_str());
    let bytes = package_bytes_declaring(
        "example.fixture.independent",
        "7.4.1",
        None,
        &covering_client_versions(),
    );
    let outcome = store
        .install_local_import(
            "example.fixture.independent",
            "7.4.1",
            trust_for(&bytes),
            &bytes,
        )
        .expect("a covering list is admitted");
    assert_eq!(outcome.state, PackageLifecycle::Installed);

    let admission = store
        .admit_activation("example.fixture.independent", "7.4.1")
        .expect("activation is admitted against the same client");
    assert_eq!(admission.client_version(), client);
    assert_eq!(admission.package_id(), "example.fixture.independent");
    assert_eq!(admission.version(), "7.4.1");

    // The activation entry consumes that admission, and the instance really
    // reaches active.
    let identity = InstanceIdentity::new(
        "instance-independent-1",
        "example.fixture.independent",
        "7.4.1",
        1,
        3,
        Vec::<String>::new(),
    )
    .expect("identity");
    let mut machine = InstanceMachine::prepare(admission.clone(), identity).expect("prepared");
    machine.activate().expect("active");
    assert_eq!(machine.state(), InstanceLifecycle::Active);

    // An admission is for one package version. An instance that names another
    // version cannot borrow it.
    let other = InstanceIdentity::new(
        "instance-independent-2",
        "example.fixture.independent",
        "7.4.2",
        2,
        3,
        Vec::<String>::new(),
    )
    .expect("identity");
    assert_eq!(
        InstanceMachine::prepare(admission, other)
            .expect_err("an admission is not transferable")
            .code,
        "package_activation_admission_mismatch"
    );

    cleanup(&root);
}

#[test]
fn a_list_that_does_not_cover_the_client_is_refused_at_install_and_at_activation() {
    let (root, store) = store("compatibility-refused");
    let client = running_client_version().expect("the binary declares a product version");

    // Install refuses it before anything is published, with a stable reason that
    // names the client it was decided against.
    let excluded = package_bytes_declaring(
        "example.fixture.outgrown",
        "1.0.0",
        None,
        &excluding_client_versions(),
    );
    let failure = store
        .install_local_import(
            "example.fixture.outgrown",
            "1.0.0",
            trust_for(&excluded),
            &excluded,
        )
        .expect_err("the running client is outside the declared list");
    assert_eq!(failure.code, "package_client_incompatible");
    assert_eq!(failure.field.as_deref(), Some("compatibility"));
    assert_eq!(
        failure.presentation_args.get("clientVersion"),
        Some(client.as_str())
    );
    assert!(store.installed().expect("installed").is_empty());
    assert!(
        store.staged_directories().expect("staged").is_empty(),
        "a refused install leaves nothing staged"
    );

    // Activation checks again, because the client may have moved past a list that
    // covered it at install time.
    let covering = package_bytes_declaring(
        "example.fixture.outgrown",
        "1.0.0",
        None,
        &covering_client_versions(),
    );
    store
        .install_local_import(
            "example.fixture.outgrown",
            "1.0.0",
            trust_for(&covering),
            &covering,
        )
        .expect("installed while the list covered this client");

    let outgrowing = "99.0.0";
    let failure = store
        .admit_activation_for_client("example.fixture.outgrown", "1.0.0", outgrowing)
        .expect_err("the client has moved past the declared list");
    assert_eq!(failure.code, "package_client_incompatible");
    assert_eq!(
        failure.presentation_args.get("clientVersion"),
        Some(outgrowing)
    );
    assert!(
        store
            .installed_path("example.fixture.outgrown", "1.0.0")
            .exists(),
        "refusing activation is not uninstalling"
    );

    // The running client still admits it, and so does an instance prepared from
    // that admission.
    let admission = store
        .admit_activation("example.fixture.outgrown", "1.0.0")
        .expect("still covered by the running client");
    assert_eq!(admission.client_version(), client);

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
    registry.insert(active_instance(&store, "example.fixture.echo", "1.0.0", 1));
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
    let mut machine = active_instance(&store, "example.fixture.echo", "1.0.0", 1);
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
    // This package registered nothing outside its own bytes, so the real owners
    // are asked for nothing and the reclaim proceeds.
    let outcome = drained
        .collect(
            &store,
            &registry,
            &licoup_native::platform::package_registration_release::PackageRegistrationOwners::default(),
        )
        .expect("collect");

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
    registry.insert(active_instance(
        &store,
        "example.fixture.adapter003",
        "1.0.0",
        1,
    ));
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

// ---------------------------------------------------------------------------
// The committed release fixture imports offline
// ---------------------------------------------------------------------------

/// The committed release fixture is the same package the release pipeline
/// packages and signs in `tools/scripts/client-release-package-index.mjs`: a
/// host manifest plus the package's own release declaration (identity, version,
/// client compatibility and a native converter entry).
///
/// This test builds the archive from those declared sources exactly as the
/// packaging tool does and imports it with no directory, no account, no network
/// and no agent. What it proves about the binary-only requirement is structural:
/// the manifest references no interpreter, no archive entry is a script, and the
/// host record keeps no runtime reference to release, so the client starts the
/// entry the package ships.
#[test]
fn a_first_party_native_converter_package_imports_offline_from_its_release_fixture() {
    let fixture = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../tests/fixtures/client_package_release/fixture-native-converter");
    assert!(fixture.is_dir(), "the release package fixture is missing");

    let manifest_text = std::fs::read_to_string(fixture.join("manifest.json")).expect("manifest");
    let mut manifest: serde_json::Value =
        serde_json::from_str(&manifest_text).expect("manifest json");
    // The fixture carries the compatibility declaration a released package
    // ships. This synthetic host admits it for the client version it is
    // actually running, exactly as the neighbouring package fixtures do: a
    // development build's version is not the released product version, and the
    // list is what decides admission either way.
    manifest["compatibility"]["clientVersions"] =
        serde_json::json!(covering_client_versions());
    let manifest_text = serde_json::to_string_pretty(&manifest).expect("manifest text");
    let declaration_text =
        std::fs::read_to_string(fixture.join("package-release.json")).expect("declaration");
    let declaration: serde_json::Value =
        serde_json::from_str(&declaration_text).expect("declaration json");

    let package_id = manifest["id"].as_str().expect("package id").to_owned();
    let version = manifest["version"]
        .as_str()
        .expect("package version")
        .to_owned();
    let entry = manifest["runtime"]["entry"]
        .as_str()
        .expect("runtime entry")
        .to_owned();
    assert_eq!(manifest["runtime"]["mode"], "process");
    assert!(
        manifest["runtime"]["runtimeRef"].is_null(),
        "an official package declares no interpreter"
    );
    assert_eq!(declaration["converter"]["kind"], "native-executable");
    assert_eq!(
        declaration["converter"]["entry"].as_str(),
        Some(entry.as_str())
    );
    assert_eq!(declaration["packageId"].as_str(), Some(package_id.as_str()));
    assert_eq!(
        declaration["packageVersion"].as_str(),
        Some(version.as_str())
    );

    let converter = std::fs::read(fixture.join(&entry)).expect("converter entry");
    assert!(
        !converter.starts_with(b"#!"),
        "the converter entry is a program, not a script"
    );

    let bytes = archive(&[
        ("manifest.json", manifest_text.into_bytes()),
        ("package-release.json", declaration_text.into_bytes()),
        (entry.as_str(), converter),
    ]);

    // The trust record is bound to these bytes and covers exactly the
    // permissions the package asks for: the import decides nothing else.
    let permissions = manifest["permissions"]
        .as_array()
        .expect("permissions")
        .iter()
        .map(|permission| {
            PermissionRequest::new(
                permission["capability"].as_str().expect("capability"),
                permission["scope"].as_str().expect("scope"),
            )
        })
        .collect::<Vec<_>>();

    let (root, store) = store("release-package-fixture");
    let outcome = store
        .install_local_import(
            &package_id,
            &version,
            TrustRecord::local_approved(content_digest_of(&bytes), permissions).expect("trust"),
            &bytes,
        )
        .expect("offline import of the release fixture");

    assert_eq!(outcome.installed.source, PackageSource::LocalImport);
    assert_eq!(
        outcome.installed.trust_channel,
        PackageLifecycle::LocalApproved
    );
    assert_eq!(outcome.processes_spawned, 0);
    assert!(
        outcome.installed.install_scripts.is_empty(),
        "no install script runs for a native package"
    );
    assert_eq!(
        outcome.installed.runtime_ref, None,
        "the host starts the entry the package ships"
    );
    assert_eq!(outcome.installed.digest, content_digest_of(&bytes));
    assert_eq!(outcome.installed.package_id, package_id);
    assert_eq!(outcome.installed.version, version);
    assert_eq!(store.installed().expect("installed").len(), 1);

    cleanup(&root);
}
