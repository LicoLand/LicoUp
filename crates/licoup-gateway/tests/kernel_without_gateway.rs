//! Composition proof: the base client builds, starts and executes without the
//! Gateway Runtime.
//!
//! This is a source/composition assertion, not a run of the client gate. It
//! pins the invariants that keep the kernel free of a mandatory gateway
//! dependency: the kernel links the runtime only through an off-by-default
//! feature, the sidecar binaries are the only gateway entry points, and the
//! runtime reaches conversations, custody and readiness only through the ports.

use std::fs;
use std::path::{Path, PathBuf};

fn workspace_root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("..")
        .join("..")
        .canonicalize()
        .expect("workspace root resolves")
}

fn read(relative: &str) -> String {
    let path = workspace_root().join(relative);
    fs::read_to_string(&path).unwrap_or_else(|error| panic!("{relative} is readable: {error}"))
}

fn rust_sources(root: &str) -> Vec<(String, String)> {
    let base = workspace_root().join(root);
    let mut files = Vec::new();
    let mut pending = vec![base];
    while let Some(directory) = pending.pop() {
        let Ok(entries) = fs::read_dir(&directory) else {
            continue;
        };
        for entry in entries.flatten() {
            let path = entry.path();
            if path.is_dir() {
                pending.push(path);
            } else if path.extension().is_some_and(|extension| extension == "rs") {
                let relative = path
                    .strip_prefix(workspace_root())
                    .expect("source stays inside the workspace")
                    .to_string_lossy()
                    .replace('\\', "/");
                let source = fs::read_to_string(&path).unwrap_or_default();
                files.push((relative, source));
            }
        }
    }
    files.sort();
    files
}

#[test]
fn kernel_links_the_gateway_only_through_an_off_by_default_feature() {
    let manifest = read("crates/licoup-native/Cargo.toml");
    assert!(
        manifest.contains("licoup-gateway = { path = \"../licoup-gateway\", optional = true }"),
        "the kernel must declare the gateway runtime as an optional dependency"
    );
    assert!(
        manifest.contains("gateway = [\"dep:licoup-gateway\"]"),
        "one feature must own the optional gateway dependency"
    );
    assert!(
        manifest.contains("default = []"),
        "the default feature set must stay empty so the base client needs no gateway"
    );

    let gateway_bins = manifest
        .split("[[bin]]")
        .filter(|section| {
            section.contains("name = \"lico-gateway\"")
                || section.contains("name = \"lico-llm-gateway\"")
        })
        .collect::<Vec<_>>();
    assert_eq!(
        gateway_bins.len(),
        2,
        "both gateway sidecar binaries are declared in the kernel manifest"
    );
    for section in gateway_bins {
        assert!(
            section.contains("required-features = [\"gateway\"]"),
            "a gateway sidecar binary must not build without the gateway feature"
        );
    }
}

#[test]
fn only_the_gateway_sidecars_start_the_runtime_listeners() {
    let entry_points = [
        "crates/licoup-native/src/bin/lico-gateway.rs",
        "crates/licoup-native/src/bin/lico-llm-gateway.rs",
    ];
    let listener_symbols = [
        "serve_gateway_runtime",
        "serve_loopback",
        "serve_credentials_control",
        "serve_inventory_control",
    ];
    for (relative, source) in rust_sources("crates/licoup-native/src") {
        for symbol in listener_symbols {
            assert!(
                !source.contains(symbol) || entry_points.contains(&relative.as_str()),
                "{relative} must not start the gateway runtime listener {symbol}"
            );
        }
    }
}

#[test]
fn kernel_conversation_and_execution_owners_have_no_gateway_dependency() {
    // The dispatch owner moved to `licoup-agent-drivers` when the driver core
    // was extracted; it is still a conversation and execution owner this test
    // holds to the same rule, so it is named at the path that owns it now.
    let kernel_owners = [
        "crates/licoup-native/src/domain/conversations.rs",
        "crates/licoup-native/src/platform/conversation_lane.rs",
        "crates/licoup-agent-drivers/src/runtime_adapters/dispatch.rs",
        "crates/licoup-native/src/bin/licoup/stdio_rpc/server/conversation.rs",
        "crates/licoup-native/src/bin/licoup/conversation_host.rs",
    ];
    for relative in kernel_owners {
        let source = read(relative);
        assert!(
            !source.contains("licoup_gateway::") && !source.contains("licoup-gateway"),
            "{relative} must execute conversations without the gateway runtime"
        );
    }

    // The shared gateway contract (model, credential lease, control channels)
    // is kernel-linked; the runtime process crate is not.
    for (relative, source) in rust_sources("crates/licoup-native/src/domain") {
        assert!(
            !source.contains("licoup_gateway::") && !source.contains("licoup-gateway ="),
            "{relative} must not reach into the gateway runtime"
        );
    }
}

#[test]
fn the_runtime_reaches_host_capabilities_only_through_ports() {
    let gateway_manifest = read("crates/licoup-gateway/Cargo.toml");
    for forbidden in [
        "licoup-native",
        "licoup-conversation",
        "licoup-application",
        "licoup-workflow",
        "licoup-agent-adapters",
    ] {
        assert!(
            !gateway_manifest.contains(&format!("{forbidden} = {{")),
            "the gateway runtime must not depend on {forbidden}"
        );
    }

    let core_manifest = read("crates/licoup-gateway-core/Cargo.toml");
    assert!(
        core_manifest.contains("licoup-foundation = { path = \"../licoup-foundation\" }"),
        "the shared gateway surface depends on licoup-foundation"
    );
    assert!(
        !core_manifest.contains("licoup-native"),
        "the shared gateway surface must not depend on the kernel crate"
    );

    for (relative, source) in rust_sources("crates/licoup-gateway/src") {
        assert!(
            !source.contains("licoup_native"),
            "{relative} must reach the host through the gateway ports"
        );
    }

    let bridge = read("crates/licoup-gateway/src/channels/telegram/bridge.rs");
    assert!(
        bridge.contains("ports::lane") && !bridge.contains("dispatch_lane_operation("),
        "the Telegram bridge reaches conversations only through the lane port"
    );

    let inventory = read("crates/licoup-gateway-core/src/control/inventory.rs");
    assert!(
        inventory.contains("ports::readiness") && !inventory.contains("crate::platform"),
        "readiness stays a pushed document applied through the callback port"
    );
}

#[test]
fn the_login_item_is_registered_only_by_the_installed_gateway_package() {
    let autostart = read("crates/licoup-native/src/platform/llm_gateway_autostart.rs");
    // One owner writes the definition, and it reads the package identity and the
    // entry each generation declares rather than a path this file invents.
    assert!(
        autostart.contains("pub const GATEWAY_PACKAGE_ID: &str = \"org.licoland.feature.gateway\"")
            && autostart.contains("installed_manifest(GATEWAY_PACKAGE_ID"),
        "the login item names the optional package that owns it"
    );
    assert!(
        autostart.contains("pub fn activate"),
        "the package lifecycle reaches the one registration path through an explicit entry point"
    );

    // A base client build carries no gateway process to start, so the login item
    // cannot be registered by a bundled neighbour: the sidecar lookup resolves
    // from the packaged binary directory and never from the package store.
    let service = read("crates/licoup-native/src/platform/llm_gateway_service.rs");
    let lookup = service
        .split("fn sidecar_path()")
        .nth(1)
        .and_then(|rest| rest.split("\n}\n").next())
        .expect("the sidecar lookup is a bounded function");
    assert!(
        lookup.contains("packaged_binary_directory(&current)"),
        "the sidecar is the packaged neighbour, not a package-store lookup"
    );
    assert!(
        !lookup.contains("extension-packages"),
        "a base client must not reach into the package store to find a sidecar"
    );

    // The shipped package declares the entry, the capability owner and the
    // client line the host reads; the kernel names none of them.
    let manifest = read("crates/licoup-gateway/package/manifest.json");
    assert!(
        manifest.contains("\"id\": \"org.licoland.feature.gateway\"")
            && manifest.contains("\"entry\": \"bin/lico-gateway\""),
        "the package declares its own identity and runtime entry"
    );
    assert!(
        read("crates/licoup-gateway/package/package-release.json")
            .contains("\"entry\": \"bin/lico-gateway\""),
        "the release declaration names the same entry the manifest declares"
    );
    assert!(
        !read("crates/licoup-native/Cargo.toml").contains("org.licoland.feature.gateway"),
        "the kernel must not hard-depend on the optional gateway package"
    );
}
