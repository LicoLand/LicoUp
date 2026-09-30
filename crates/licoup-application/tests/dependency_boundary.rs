//! Dependency-boundary proof for the shared composition crate.
//!
//! The direction of the promise is unchanged: a CLI and an MCP can both depend
//! on this crate, and it depends on neither of them nor on any endpoint host.
//! What the crate owns is composition and session policy, so it names the layer
//! crates it composes — foundation, client state, protocol bindings, endpoint
//! core, platform bridges and agent adapters — and those names are an explicit,
//! reviewed list rather than an accident of whoever compiled last.
//!
//! The check reads the crate's own manifest rather than the resolved dependency
//! graph, so it fails on the edit that adds the dependency — not later, in a
//! build that happens to notice.

use std::path::{Path, PathBuf};

/// Crates this one must never depend on: the endpoint hosts that run the
/// composition, and the domains that sit above it. Reaching one of these would
/// let the composition authority observe a caller, or invert a layer.
const FORBIDDEN: &[&str] = &[
    "licoup-native",
    "licoup-agent-runtime",
    "licoup-conversation",
    "licoup-extension-contracts",
    "licoup-mcp",
    "licoup-workflow",
    "licoup-workflow-runtime",
    "licoup-workflow-store",
];

/// The only dependencies allowed, by section: the layers this crate composes,
/// the primitives it genuinely needs, and the state-machine compiler that turns
/// the resources it owns into the tables its reducers read. A new name here
/// changes what both interfaces compile against, so it needs a deliberate edit.
const ALLOWED_DEPENDENCIES: &[&str] = &[
    "anyhow",
    "chacha20poly1305",
    "lico-catalog-convergence",
    "licoup-agent-adapters",
    "licoup-client-state",
    "licoup-endpoint-core",
    "licoup-foundation",
    "licoup-platform-bridges",
    "licoup-protocol-bindings",
    "licoup-state-machine-codegen",
    "rand_core",
    "serde",
    "serde_json",
    "uuid",
];

fn manifest_path() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("Cargo.toml")
}

/// Dependency names declared in one section of the manifest.
///
/// A hand-rolled reader keeps this test dependency-free: adding `toml` here to
/// parse the manifest would itself be a dependency change to police.
fn declared_dependencies(source: &str) -> Vec<(String, String)> {
    let mut section = String::new();
    let mut found = Vec::new();
    for line in source.lines() {
        let line = line.trim();
        if line.starts_with('[') && line.ends_with(']') {
            section = line.trim_matches(['[', ']']).to_owned();
            continue;
        }
        if section != "dependencies"
            && section != "dev-dependencies"
            && section != "build-dependencies"
        {
            continue;
        }
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let Some((name, _)) = line.split_once('=') else {
            continue;
        };
        // A workspace dependency is written `serde.workspace = true`, so the
        // crate name is the part before the first dot.
        let name = name.trim().split('.').next().unwrap_or_default().trim();
        if name.is_empty() {
            continue;
        }
        found.push((section.clone(), name.to_owned()));
    }
    found
}

#[test]
fn the_composition_crate_never_depends_on_an_endpoint_host_or_a_domain_above_it() {
    let source = std::fs::read_to_string(manifest_path()).expect("manifest is readable");
    let declared = declared_dependencies(&source);
    assert!(
        !declared.is_empty(),
        "the manifest reader found no dependencies at all, so it is not proving anything"
    );
    for (section, name) in &declared {
        assert!(
            !FORBIDDEN.contains(&name.as_str()),
            "{section} declares {name}, which the composition layer must not know about"
        );
    }
}

#[test]
fn the_composition_crate_depends_only_on_the_layers_it_composes() {
    let source = std::fs::read_to_string(manifest_path()).expect("manifest is readable");
    let declared = declared_dependencies(&source);
    for (section, name) in &declared {
        assert!(
            ALLOWED_DEPENDENCIES.contains(&name.as_str()),
            "{section} adds {name}; a new dependency here changes what both interfaces compile \
             against, so it needs a deliberate decision rather than an incidental edit"
        );
    }
}

#[test]
fn the_crate_is_registered_as_a_workspace_member() {
    let workspace = Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .and_then(Path::parent)
        .expect("workspace root")
        .join("Cargo.toml");
    let source = std::fs::read_to_string(workspace).expect("workspace manifest is readable");
    assert!(
        source.contains("\"crates/licoup-application\""),
        "the crate must stay a workspace member or its boundary is not enforced by the build"
    );
}
