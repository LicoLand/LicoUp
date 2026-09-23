//! A03 — the dependency direction, checked against the real Cargo graph and the
//! existing Dart architecture rule.
//!
//! The contract is `store → runtime::ports → core`. Two things could break it:
//! someone adds an edge that reverses it, or someone writes code that only
//! compiles because such an edge exists. The first is caught by reading Cargo's
//! own graph; the second by compiling the forbidden reference in a probe whose
//! dependency context is the referencing crate's real declared context, so a
//! reference resolves exactly when the referencing crate declares it. Each
//! forbidden probe is paired with a legal control through the same mechanism:
//! if a declared edge did not compile there, a failing probe would prove
//! nothing about the edge.
//!
//! The Dart-side view→RPC edge belongs to the client architecture verifier and
//! cannot be re-proved by a Rust probe; this file runs that verifier's real
//! check function over a synthetic counterexample instead.

use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};
use std::process::Command;

const STORE: &str = "licoup-workflow-store";
const RUNTIME: &str = "licoup-workflow-runtime";
const CORE: &str = "licoup-workflow";

fn workspace_root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .and_then(Path::parent)
        .expect("crate lives at <workspace>/crates/<name>")
        .to_path_buf()
}

/// Cargo's own view of the workspace, read once per call rather than from the
/// manifests by hand or from directory names.
fn workspace_metadata() -> serde_json::Value {
    let output = Command::new(env!("CARGO"))
        .args(["metadata", "--no-deps", "--format-version", "1"])
        .current_dir(workspace_root())
        .output()
        .expect("cargo metadata runs");
    assert!(
        output.status.success(),
        "cargo metadata failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    serde_json::from_slice(&output.stdout).expect("cargo metadata emits JSON")
}

fn declared_edges() -> BTreeMap<String, BTreeSet<String>> {
    let metadata = workspace_metadata();
    let mut edges = BTreeMap::new();
    for package in metadata["packages"].as_array().expect("packages array") {
        let name = package["name"].as_str().expect("package name").to_owned();
        let dependencies = package["dependencies"]
            .as_array()
            .expect("dependencies array")
            .iter()
            .filter_map(|dependency| dependency["name"].as_str())
            .map(str::to_owned)
            .collect();
        edges.insert(name, dependencies);
    }
    edges
}

fn closure(edges: &BTreeMap<String, BTreeSet<String>>, root: &str) -> BTreeSet<String> {
    let mut seen = BTreeSet::new();
    let mut stack = vec![root.to_owned()];
    while let Some(current) = stack.pop() {
        let Some(next) = edges.get(&current) else {
            continue;
        };
        for dependency in next {
            if seen.insert(dependency.clone()) {
                stack.push(dependency.clone());
            }
        }
    }
    seen
}

/// One declared dependency of a workspace package, as Cargo reports it.
struct DeclaredDependency {
    name: String,
    rename: Option<String>,
    req: String,
    path: Option<String>,
    source: Option<String>,
    features: Vec<String>,
    uses_default_features: bool,
}

impl DeclaredDependency {
    /// The manifest line a probe needs so its dependency context is the
    /// referencing crate's real declared context: a probe can then name a
    /// crate exactly when the referencing crate declares it. Sources the
    /// emulation cannot express fail loudly instead of silently weakening it.
    fn manifest_line(&self) -> String {
        let alias = self.rename.clone().unwrap_or_else(|| self.name.clone());
        let mut keys: Vec<String> = Vec::new();
        if self.rename.is_some() {
            keys.push(format!("package = \"{}\"", self.name));
        }
        match (&self.path, &self.source) {
            (Some(path), _) => keys.push(format!("path = \"{path}\"")),
            (None, Some(source)) if source.starts_with("registry+") => {
                keys.push(format!("version = \"{}\"", self.req));
            }
            (None, Some(source)) => {
                panic!("probe emulation does not support dependency source `{source}`")
            }
            (None, None) => keys.push(format!("version = \"{}\"", self.req)),
        }
        if !self.uses_default_features {
            keys.push("default-features = false".to_owned());
        }
        if !self.features.is_empty() {
            let features = self
                .features
                .iter()
                .map(|feature| format!("\"{feature}\""))
                .collect::<Vec<_>>()
                .join(", ");
            keys.push(format!("features = [{features}]"));
        }
        format!("{alias} = {{ {} }}", keys.join(", "))
    }
}

fn declared_dependencies(package_name: &str) -> Vec<DeclaredDependency> {
    let metadata = workspace_metadata();
    let package = metadata["packages"]
        .as_array()
        .expect("packages array")
        .iter()
        .find(|package| package["name"].as_str() == Some(package_name))
        .unwrap_or_else(|| panic!("{package_name} must be a workspace member"));
    package["dependencies"]
        .as_array()
        .expect("dependencies array")
        .iter()
        .map(|dependency| DeclaredDependency {
            name: dependency["name"]
                .as_str()
                .expect("dependency name")
                .to_owned(),
            rename: dependency["rename"].as_str().map(str::to_owned),
            req: dependency["req"]
                .as_str()
                .expect("dependency req")
                .to_owned(),
            path: dependency["path"].as_str().map(str::to_owned),
            source: dependency["source"].as_str().map(str::to_owned),
            features: dependency["features"]
                .as_array()
                .expect("dependency features")
                .iter()
                .map(|feature| feature.as_str().expect("feature name").to_owned())
                .collect(),
            uses_default_features: dependency["uses_default_features"]
                .as_bool()
                .expect("uses_default_features"),
        })
        .collect()
}

struct ProbeOutcome {
    compiled: bool,
    stderr: String,
}

/// Build one synthetic probe carrying the referencing crate's declared
/// dependency context. Nothing here inspects the forbidden edge directly: the
/// probe source either resolves or not because of what the real crate declares.
fn build_probe(root: &Path, label: &str, referencing_crate: &str, source: &str) -> ProbeOutcome {
    let probe = root.join("build/trybuild-local").join(label);
    let _ = std::fs::remove_dir_all(&probe);
    std::fs::create_dir_all(probe.join("src")).expect("probe source dir");

    let mut manifest = format!(
        "[package]\nname = \"{label}\"\nversion = \"0.0.0\"\nedition = \"2024\"\npublish = false\n\n\
         [dependencies]\n"
    );
    for dependency in declared_dependencies(referencing_crate) {
        manifest.push_str(&dependency.manifest_line());
        manifest.push('\n');
    }
    manifest.push_str("\n[workspace]\n");

    std::fs::write(probe.join("Cargo.toml"), manifest).expect("probe manifest");
    std::fs::write(probe.join("src/lib.rs"), source).expect("probe source");

    let mut command = Command::new(env!("CARGO"));
    command
        .args(["build", "--offline", "--quiet"])
        .current_dir(&probe);
    // Reuse the already-built artifacts so a probe costs a compile check
    // rather than a rebuild of the whole dependency graph.
    if let Ok(target) = std::env::var("CARGO_TARGET_DIR") {
        command.env("CARGO_TARGET_DIR", target);
    }
    let output = command.output().expect("probe compiles");
    let _ = std::fs::remove_dir_all(&probe);

    ProbeOutcome {
        compiled: output.status.success(),
        stderr: String::from_utf8_lossy(&output.stderr).into_owned(),
    }
}

fn first_error_line(stderr: &str) -> String {
    stderr
        .lines()
        .find(|line| line.contains("error"))
        .unwrap_or("no error line")
        .trim()
        .to_owned()
}

/// A forbidden probe must fail because the compiler cannot name the crate, not
/// because the probe, the toolchain, or the offline cache is broken.
fn unresolved_crate_error(stderr: &str, crate_name: &str) -> Result<(), String> {
    let unresolved = stderr.contains("error[E0432]") || stderr.contains("error[E0433]");
    let named = stderr.contains(crate_name) || stderr.contains(&crate_name.replace('-', "_"));
    if unresolved && named {
        Ok(())
    } else {
        Err(format!(
            "expected an E0432/E0433 diagnostic naming {crate_name}, got: {}",
            first_error_line(stderr)
        ))
    }
}

#[test]
fn the_three_crates_are_ordered_store_runtime_core() {
    let edges = declared_edges();
    for name in [STORE, RUNTIME, CORE] {
        assert!(
            edges.contains_key(name),
            "{name} must be a workspace member"
        );
    }
    assert!(
        edges[STORE].contains(RUNTIME),
        "{STORE} must depend on {RUNTIME}"
    );
    assert!(
        edges[RUNTIME].contains(CORE),
        "{RUNTIME} must depend on {CORE}"
    );
}

#[test]
fn a_consumer_owned_port_is_reachable_from_its_implementor() {
    // The legal direction has to actually work, or the ports are decoration.
    // This is a real use of the port trait through the store crate's own
    // dependency edge, so it fails to compile if the edge is removed.
    fn accepts_a_port<P: licoup_workflow_runtime::ports::StatePort>(_port: &P) {}
    let _ = accepts_a_port::<StubPort>;
    let _ = licoup_workflow_store::DEPENDENCY_DIRECTION;
}

struct StubPort;

impl licoup_workflow_runtime::ports::StatePort for StubPort {
    fn checkpoint(&self, _run_id: &str) -> anyhow::Result<licoup_workflow::RunSnapshot> {
        unimplemented!("fixture")
    }
    fn commit(
        &self,
        _run_id: &str,
        _expected_sequence: u64,
        _event: licoup_workflow::ReducerEvent,
    ) -> anyhow::Result<licoup_workflow::RunSnapshot> {
        unimplemented!("fixture")
    }
    fn claim_next(
        &self,
        _run_id: &str,
        _claimant: &str,
        _lease_until_unix_ms: i64,
    ) -> anyhow::Result<Option<licoup_workflow::RunCommand>> {
        unimplemented!("fixture")
    }
    fn renew_lease(
        &self,
        _command_id: &str,
        _claimant: &str,
        _lease_until_unix_ms: i64,
    ) -> anyhow::Result<()> {
        unimplemented!("fixture")
    }
    fn mark_started(
        &self,
        _run_id: &str,
        _command_id: &str,
        _attempt_token: &str,
    ) -> anyhow::Result<licoup_workflow::RunSnapshot> {
        unimplemented!("fixture")
    }
    fn result_ref(&self, _run_id: &str, _command_id: &str) -> anyhow::Result<Option<String>> {
        unimplemented!("fixture")
    }
}

#[test]
fn the_core_cannot_reach_the_runtime() {
    let edges = declared_edges();
    let core = closure(&edges, CORE);
    assert!(
        !core.contains(RUNTIME),
        "{CORE} must not reach {RUNTIME}; core is the pure machine and has no \
         business knowing how it is driven or stored"
    );
    assert!(
        !core.contains(STORE),
        "{CORE} must not reach {STORE} transitively either"
    );
}

#[test]
fn the_runtime_cannot_reach_the_store() {
    let edges = declared_edges();
    let runtime = closure(&edges, RUNTIME);
    assert!(
        !runtime.contains(STORE),
        "{RUNTIME} must not reach {STORE}; storage implements the ports, so the \
         ports cannot name it"
    );
}

/// The forbidden references, as real code compiled against the referencing
/// crate's own declared dependency context. Each names the crate, the
/// referencing crate, the crate that must not resolve, and the source.
const FORBIDDEN_REFERENCES: [(&str, &str, &str, &str); 2] = [
    (
        "core_cannot_use_the_runtime",
        CORE,
        RUNTIME,
        "use licoup_workflow_runtime::ports::StatePort;\n#[allow(dead_code)]\nfn probe<T: StatePort>() {}\n",
    ),
    (
        "runtime_cannot_use_the_store",
        RUNTIME,
        STORE,
        "use licoup_workflow_store::DEPENDENCY_DIRECTION;\n#[allow(dead_code)]\nfn probe() { let _ = DEPENDENCY_DIRECTION; }\n",
    ),
];

/// Legal controls through the same probe mechanism. Without these, a failed
/// forbidden probe would only show that the emulation cannot resolve anything.
const LEGAL_REFERENCES: [(&str, &str, &str, &str); 2] = [
    (
        "runtime_may_use_the_core",
        RUNTIME,
        CORE,
        "use licoup_workflow::RunSnapshot;\n#[allow(dead_code)]\nfn probe(_snapshot: RunSnapshot) {}\n",
    ),
    (
        "core_may_use_its_declared_dependency",
        CORE,
        "anyhow",
        "use anyhow::Result;\n#[allow(dead_code)]\nfn probe() -> Result<()> { Ok(()) }\n",
    ),
];

#[test]
fn each_forbidden_reference_fails_to_compile() {
    let root = workspace_root();
    let mut failures = Vec::new();

    // The controls run first: the same mechanism has to compile a declared
    // edge, or the failing probes below say nothing about the real graph.
    for (label, referencing_crate, referenced_crate, source) in LEGAL_REFERENCES {
        let outcome = build_probe(&root, label, referencing_crate, source);
        if !outcome.compiled {
            failures.push(format!(
                "{label}: a probe for {referencing_crate} could not compile its legal declared \
                 reference to {referenced_crate}, so the emulation is broken: {}",
                first_error_line(&outcome.stderr)
            ));
        }
    }

    for (label, referencing_crate, forbidden_crate, source) in FORBIDDEN_REFERENCES {
        let outcome = build_probe(&root, label, referencing_crate, source);
        if outcome.compiled {
            failures.push(format!(
                "{label}: {referencing_crate} compiled a reference to {forbidden_crate} it must \
                 not be able to make"
            ));
        } else if let Err(reason) = unresolved_crate_error(&outcome.stderr, forbidden_crate) {
            failures.push(format!(
                "{label}: probe failed for an unrelated reason: {reason}"
            ));
        }
    }

    assert!(failures.is_empty(), "{}", failures.join("\n"));
}

/// The view→RPC reverse edge is a Dart-side rule, so a Rust probe cannot test
/// it. This composes the existing verifier's real check function over a
/// synthetic counterexample: a view importing the application layer must be
/// reported, and a view that only imports Flutter must not be.
const ILLEGAL_VIEW: &str = "apps/desktop/lib/src/frontend/example/reverse_view.dart";
const LEGAL_VIEW: &str = "apps/desktop/lib/src/frontend/example/clean_view.dart";
const FORBIDDEN_IMPORT: &str = "apps/desktop/lib/src/application/state/client_state.dart";

#[test]
fn the_frontend_reverse_reference_is_rejected_by_the_existing_dart_rule() {
    let rule_module = workspace_root()
        .join("apps/desktop/scripts/client-architecture/checks/flutter/presentation-boundary.mjs");
    assert!(
        rule_module.is_file(),
        "the Dart boundary rule must exist where the client architecture verifier keeps it"
    );

    let script = format!(
        r#"
import {{ pathToFileURL }} from "node:url";
const {{ inspectPresentationBoundarySources }} = await import(pathToFileURL(process.argv[1]).href);
const illegal = new Map([[{illegal}, {illegal_source}]]);
const legal = new Map([[{legal}, {legal_source}]]);
const results = (sources) => inspectPresentationBoundarySources(sources).map((entry) => entry.slice(0, 3));
process.stdout.write(JSON.stringify({{
  illegal: results(illegal),
  legal: results(legal),
}}));
"#,
        illegal = serde_json::to_string(ILLEGAL_VIEW).expect("view path is JSON-safe"),
        illegal_source = serde_json::to_string(
            "import '../../application/state/client_state.dart';\nclass ReverseView {}\n"
        )
        .expect("fixture source is JSON-safe"),
        legal = serde_json::to_string(LEGAL_VIEW).expect("view path is JSON-safe"),
        legal_source =
            serde_json::to_string("import 'package:flutter/widgets.dart';\nclass CleanView {}\n")
                .expect("fixture source is JSON-safe"),
    );

    let output = Command::new("node")
        .args(["--input-type=module", "-e", &script])
        .arg(&rule_module)
        .output()
        .expect("node runs the existing Dart boundary rule");
    assert!(
        output.status.success(),
        "node could not run the Dart boundary rule: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    let result: serde_json::Value =
        serde_json::from_slice(&output.stdout).expect("the rule emits JSON");

    let illegal = result["illegal"].as_array().expect("illegal failure list");
    assert!(
        illegal.iter().any(
            |failure| failure[0] == "presentation_boundary_frontend_direction"
                && failure[1] == ILLEGAL_VIEW
                && failure[2] == FORBIDDEN_IMPORT
        ),
        "the real Dart rule did not reject a view importing the application layer: {result}"
    );
    let legal = result["legal"].as_array().expect("legal failure list");
    assert!(
        !legal
            .iter()
            .any(|failure| failure[0] == "presentation_boundary_frontend_direction"),
        "the real Dart rule rejected a view that only imports Flutter: {result}"
    );
}
