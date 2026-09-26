//! Path one of A33: a compatible API configured entirely by configuration.
//!
//! No provider code is involved: the configuration names a published compatible
//! dialect and the host transport registered for that dialect serves the stream.
//! A hot update moves new admissions to a new generation, aliases stay a
//! separate mapping, and facts the vendor did not publish stay unknown.

use crate::support;
use licoup_model_provider::{CatalogSource, ProviderOrigin, ProviderRuntime, TerminalState};
use serde_json::json;
use std::sync::{Arc, Mutex};

const COMPATIBLE_CONFIG: &str = "extensions/providers/compatible-local/provider.json";
const COMPATIBLE_STREAM: &str = "extensions/providers/compatible-local/stream-fixture.jsonl";

#[test]
fn a_compatible_configuration_routes_without_provider_code_and_keeps_unknowns_unknown() {
    let mut runtime = ProviderRuntime::new();
    let credential: support::CredentialRecord = Arc::new(Mutex::new(None));
    runtime.register_compatible_adapter(
        "openai-chat-compatible",
        support::fixture_adapter_factory(COMPATIBLE_STREAM, Arc::clone(&credential)),
    );
    let config = support::fixture_config(COMPATIBLE_CONFIG);
    support::authorize(&mut runtime, &config);
    let receipt = runtime
        .install_user(config)
        .expect("compatible configuration is admitted");
    assert_eq!(receipt.generation, 1);

    let catalog = runtime.catalog();
    assert_eq!(catalog.entries().len(), 2);
    for entry in catalog.entries() {
        assert_eq!(entry.source, CatalogSource::Static);
        assert_eq!(
            entry.key.provider_generation, 1,
            "the snapshot's own generation"
        );
        assert_eq!(entry.origin, ProviderOrigin::UserConfigured);
    }
    let small = catalog
        .entries()
        .iter()
        .find(|entry| entry.key.vendor_model_id == "local-small")
        .expect("local-small");
    assert_eq!(
        small.model.context_tokens, None,
        "no default window is invented"
    );
    assert_eq!(small.model.tools, None, "no implied false");
    assert_eq!(small.model.pricing_source, None, "no price is invented");

    // An unset alias is an unknown name, not a silent default.
    assert_eq!(
        catalog.resolve("fast").expect_err("no such alias").code,
        "provider_alias_unknown"
    );

    let mut session = runtime
        .open_stream(
            "synthetic.example.compat-local/local-small",
            "user:synthetic",
            "effect:compatible",
            json!({"prompt": "hello"}),
        )
        .expect("compatible admission");
    let report = support::drain(&mut session);
    assert!(
        report.text.contains("local fixture stream"),
        "text arrived: {:?}",
        report.text
    );
    let terminal = report.terminal.expect("terminal frame");
    assert_eq!(terminal.state, TerminalState::Completed);
    assert_eq!(terminal.usage.input_tokens, Some(7));
    assert_eq!(
        terminal.usage.output_tokens, None,
        "an unreported count stays unknown"
    );
    let cost = terminal.usage.cost.expect("cost observation carried");
    assert_eq!(
        cost.amount, None,
        "an unknown amount is not turned into zero"
    );
    assert_eq!(
        credential.lock().expect("record").as_deref(),
        Some("credential:compat-local"),
        "the endpoint-scoped handle reached the transport"
    );
}

#[test]
fn a_hot_configuration_update_moves_new_admissions_and_leaves_in_flight_alone() {
    let mut runtime = ProviderRuntime::new();
    let credential: support::CredentialRecord = Arc::new(Mutex::new(None));
    runtime.register_compatible_adapter(
        "openai-chat-compatible",
        support::fixture_adapter_factory(COMPATIBLE_STREAM, Arc::clone(&credential)),
    );
    let config = support::fixture_config(COMPATIBLE_CONFIG);
    support::authorize(&mut runtime, &config);
    runtime.install_user(config).expect("generation 1");
    runtime
        .set_alias("fast", "synthetic.example.compat-local/local-small")
        .expect("alias points at generation 1");

    let mut in_flight = runtime
        .open_stream(
            "synthetic.example.compat-local/local-small",
            "user:synthetic",
            "effect:hot-update",
            json!({"prompt": "v1"}),
        )
        .expect("v1 admission");
    assert_eq!(in_flight.binding().instance().generation(), 1);
    assert_eq!(in_flight.binding().instance().config().config_revision, 1);

    // Hot update: same provider id, next revision, a different model list.
    let mut updated = support::fixture_value(COMPATIBLE_CONFIG);
    updated["configRevision"] = json!(2);
    updated["models"] = json!([{"id": "local-large", "displayName": "Local Large v2"}]);
    let receipt = runtime
        .install_from_value(updated)
        .expect("hot update is admitted");
    assert_eq!(receipt.generation, 2);

    let catalog = runtime.catalog();
    assert_eq!(catalog.epoch(), runtime.snapshot().epoch());
    assert!(
        catalog
            .entries()
            .iter()
            .all(|entry| entry.key.provider_generation == 2),
        "one catalog never mixes generations: {:?}",
        catalog.entries()
    );
    assert_eq!(catalog.entries().len(), 1);
    assert_eq!(catalog.entries()[0].key.vendor_model_id, "local-large");

    // The alias still names generation 1 and is refused for new admission
    // instead of being silently rebound.
    assert_eq!(
        catalog.resolve("fast").expect_err("stale alias").code,
        "provider_alias_stale"
    );
    // An explicit replacement moves it.
    let rebound = runtime
        .set_alias("fast", "synthetic.example.compat-local/local-large")
        .expect("explicit replacement");
    assert_eq!(rebound.provider_generation, 2);
    let mut via_alias = runtime
        .open_stream(
            "fast",
            "user:synthetic",
            "effect:rebound",
            json!({"prompt": "v2"}),
        )
        .expect("alias admission");
    assert_eq!(via_alias.binding().instance().generation(), 2);
    support::drain(&mut via_alias);

    // The in-flight request still finishes on its own generation.
    let report = support::drain(&mut in_flight);
    assert_eq!(
        in_flight.terminal().expect("terminal").state,
        TerminalState::Completed
    );
    assert_eq!(in_flight.binding().instance().generation(), 1);
    assert_eq!(in_flight.binding().instance().config().config_revision, 1);
    assert!(report.text.contains("local fixture stream"));
}

#[test]
fn a_user_configuration_replaces_the_seed_and_removal_restores_nothing() {
    let mut runtime = ProviderRuntime::new();
    let credential: support::CredentialRecord = Arc::new(Mutex::new(None));
    runtime.register_compatible_adapter(
        "openai-chat-compatible",
        support::fixture_adapter_factory(COMPATIBLE_STREAM, credential),
    );
    let seed = support::fixture_config(COMPATIBLE_CONFIG);
    runtime.install_default(seed).expect("seed");

    let mut user = support::fixture_value(COMPATIBLE_CONFIG);
    user["configRevision"] = json!(2);
    user["models"] = json!([{"id": "user-model", "displayName": "User Model"}]);
    let receipt = runtime
        .install_from_value(user)
        .expect("user configuration");
    assert_eq!(receipt.generation, 2, "the seed was generation 1");

    let catalog = runtime.catalog();
    assert_eq!(catalog.entries().len(), 1);
    assert_eq!(catalog.entries()[0].key.vendor_model_id, "user-model");
    assert_eq!(catalog.entries()[0].origin, ProviderOrigin::UserConfigured);

    // The seed list itself was never rewritten.
    let seeds: Vec<_> = runtime.registry().defaults().collect();
    assert_eq!(seeds.len(), 1);
    assert_eq!(seeds[0].config().models[0].id, "local-small");

    // Removal drops the provider for good; no earlier definition reappears.
    runtime.remove_provider("synthetic.example.compat-local");
    assert!(runtime.catalog().entries().is_empty());
    assert!(
        runtime
            .snapshot()
            .get("synthetic.example.compat-local")
            .is_none()
    );
    assert_eq!(
        runtime
            .open_stream(
                "synthetic.example.compat-local/local-small",
                "user:synthetic",
                "effect:removed",
                json!({}),
            )
            .expect_err("removed provider")
            .code,
        "provider_not_configured"
    );
}

#[test]
fn an_alias_is_a_mapping_separate_from_the_provider_namespace() {
    let mut runtime = ProviderRuntime::new();
    let credential: support::CredentialRecord = Arc::new(Mutex::new(None));
    runtime.register_compatible_adapter(
        "openai-chat-compatible",
        support::fixture_adapter_factory(COMPATIBLE_STREAM, credential),
    );
    runtime
        .install_user(support::synthetic_compatible_config(
            "synthetic.example.a",
            1,
            "mini",
        ))
        .expect("provider a");
    runtime
        .install_user(support::synthetic_compatible_config(
            "synthetic.example.b",
            1,
            "mini",
        ))
        .expect("provider b");

    // Two providers publish the same vendor model id without colliding.
    let catalog = runtime.catalog();
    assert_eq!(catalog.entries().len(), 2);
    let a = catalog
        .resolve("synthetic.example.a/mini")
        .expect("namespaced a");
    let b = catalog
        .resolve("synthetic.example.b/mini")
        .expect("namespaced b");
    assert_ne!(a.key(), b.key());

    // The alias is its own mapping onto one of them.
    runtime
        .set_alias("fast", "synthetic.example.b/mini")
        .expect("alias");
    let via_alias = runtime.catalog().resolve("fast").expect("alias");
    assert_eq!(via_alias.key(), b.key());
    assert_eq!(via_alias.alias(), Some("fast"));

    // Removing the provider removes its aliases and leaves the other's alone.
    runtime
        .set_alias("other", "synthetic.example.a/mini")
        .expect("alias");
    runtime.remove_provider("synthetic.example.b");
    let catalog = runtime.catalog();
    assert_eq!(
        catalog
            .resolve("fast")
            .expect_err("removed provider alias")
            .code,
        "provider_alias_unknown"
    );
    assert!(catalog.resolve("other").is_ok());
    assert!(catalog.resolve("synthetic.example.a/mini").is_ok());
}
