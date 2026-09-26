//! Path two of A33: a non-compatible API served by the provider's own stream
//! adapter, exercised against a real provider process.
//!
//! The synthetic provider declares `model-provider`, discovers its own catalog,
//! streams its own protocol and cancels like a real one would. Nothing here
//! pretends the custom dialect is a compatible API, and nothing invents usage
//! the provider did not report.

use crate::support;
use licoup_extension_contracts::profile::ExtensionProfile;
use licoup_extension_contracts::provider::ProviderConfig;
use licoup_model_provider::{
    CancelOutcome, CancelSupport, CatalogSource, ProviderRuntime, StreamEvent, TerminalState,
};
use serde_json::{Value, json};

const CUSTOM_CONFIG: &str = "extensions/providers/synthetic-custom/provider.config.json";
const CUSTOM_MANIFEST: &str = "extensions/providers/synthetic-custom/manifest.json";

fn custom_runtime(extra_flags: &[&str]) -> ProviderRuntime {
    let mut runtime = ProviderRuntime::new();
    let config = support::fixture_config(CUSTOM_CONFIG);
    runtime.install_user(config).expect("custom configuration");
    runtime
        .adopt_discovered_models("synthetic.example", support::plugin_models(extra_flags))
        .expect("discovered models");
    runtime.register_custom_adapter(
        "synthetic.example/stream",
        support::plugin_factory(extra_flags),
    );
    runtime
}

#[test]
fn the_package_manifest_declares_a_model_provider() {
    let manifest = support::fixture_manifest(CUSTOM_MANIFEST);
    assert!(manifest.validate().is_ok());
    assert!(
        manifest
            .published_profiles()
            .any(|profile| profile == ExtensionProfile::ModelProvider)
    );
}

#[test]
fn a_custom_profile_serves_discovered_models_through_its_own_adapter() {
    let mut runtime = ProviderRuntime::new();
    let config = support::fixture_config(CUSTOM_CONFIG);
    assert_eq!(config.api_dialect, "synthetic.example/native");
    assert_eq!(
        config.dialect(),
        licoup_extension_contracts::provider::Dialect::Custom,
        "a non-published dialect is custom, whatever it calls itself"
    );

    // Discovery is a real call to the provider process.
    let mut adapter = support::plugin_adapter(&[]);
    let description = adapter
        .plugin_description()
        .expect("handshake description")
        .clone();
    assert!(description.model_provider_available());
    assert!(description.implements("modelProvider.stream"));
    assert!(description.implements("modelProvider.models"));
    assert!(description.implements("modelProvider.cancel"));
    assert!(description.implements("auth.begin"));
    let models = adapter.models().expect("discovered models");
    assert_eq!(models.len(), 2);
    let unknown = models
        .iter()
        .find(|model| model.id == "synthetic-text")
        .expect("synthetic-text");
    assert_eq!(unknown.context_tokens, None);
    assert_eq!(unknown.tools, None);
    assert_eq!(unknown.pricing_source, None);

    let receipt = runtime.install_user(config).expect("custom configuration");
    let generation = runtime
        .adopt_discovered_models("synthetic.example", models)
        .expect("adopt");
    assert_eq!(generation, receipt.generation);
    let catalog = runtime.catalog();
    assert_eq!(catalog.entries().len(), 2);
    assert!(
        catalog
            .entries()
            .iter()
            .all(|entry| entry.source == CatalogSource::Discovered)
    );
    assert!(
        catalog
            .entries()
            .iter()
            .all(|entry| entry.key.provider_generation == receipt.generation)
    );

    runtime.register_custom_adapter("synthetic.example/stream", support::plugin_factory(&[]));
    let mut session = runtime
        .open_stream(
            "synthetic.example/synthetic-text",
            "user:synthetic",
            "effect:custom",
            json!({"scenario": "default"}),
        )
        .expect("custom admission");
    assert_eq!(session.cancel_support(), CancelSupport::Supported);
    let report = support::drain(&mut session);
    assert!(report.text.contains("chunk 1"), "text: {:?}", report.text);
    assert!(report.text.contains("chunk 8"));
    let notice = report.credential_notice().expect("credential notice");
    assert_eq!(
        notice,
        "credential=none;state=not-configured;principal=user:synthetic;effect=effect:custom",
        "no credential was configured, and none was invented"
    );
    let terminal = report.terminal.expect("terminal");
    assert_eq!(terminal.state, TerminalState::Completed);
    assert_eq!(terminal.usage.input_tokens, Some(12));
    assert_eq!(
        terminal.usage.output_tokens, None,
        "an unreported count stays unknown"
    );
    let cost = terminal.usage.cost.expect("cost observation");
    assert_eq!(cost.amount, None, "an unknown amount stays unknown");
}

#[test]
fn cancel_reaches_the_provider_and_the_stream_ends_cancelled_once() {
    let mut runtime = custom_runtime(&[]);
    let mut session = runtime
        .open_stream(
            "synthetic.example/synthetic-text",
            "user:synthetic",
            "effect:cancel",
            json!({"scenario": "long"}),
        )
        .expect("long admission");
    // The first frame is the credential notice, the second is text.
    assert!(matches!(
        session.next_event().expect("event"),
        Some(StreamEvent::Notice { .. })
    ));
    assert!(matches!(
        session.next_event().expect("event"),
        Some(StreamEvent::Text { .. })
    ));

    let report = session.cancel();
    assert_eq!(report.outcome, Some(CancelOutcome::Acknowledged));
    assert!(!report.after_terminal);

    let drained = support::drain(&mut session);
    assert_eq!(
        drained.terminal.expect("terminal").state,
        TerminalState::Cancelled,
        "the provider's terminal frame is the outcome"
    );

    // A late cancel neither rewrites the terminal state nor emits a second one.
    let late = session.cancel();
    assert!(late.after_terminal);
    assert_eq!(late.outcome, None);
    assert_eq!(
        session.terminal().expect("terminal").state,
        TerminalState::Cancelled
    );
    assert!(session.next_event().expect("closed").is_none());
}

#[test]
fn a_provider_without_cancel_reports_unsupported_instead_of_a_fake_cancel() {
    let mut runtime = custom_runtime(&["--no-cancel"]);
    let mut session = runtime
        .open_stream(
            "synthetic.example/synthetic-text",
            "user:synthetic",
            "effect:no-cancel",
            json!({"scenario": "default"}),
        )
        .expect("admission");
    assert_eq!(session.cancel_support(), CancelSupport::Unsupported);
    let report = session.cancel();
    assert_eq!(report.outcome, Some(CancelOutcome::Unsupported));
    assert!(!report.after_terminal);

    let drained = support::drain(&mut session);
    assert_eq!(
        drained.terminal.expect("terminal").state,
        TerminalState::Completed
    );
}

#[test]
fn text_bodies_are_carried_verbatim() {
    let mut runtime = custom_runtime(&[]);
    let mut session = runtime
        .open_stream(
            "synthetic.example/synthetic-text",
            "user:synthetic",
            "effect:verbatim",
            json!({"scenario": "verbatim"}),
        )
        .expect("admission");
    let report = support::drain(&mut session);
    assert_eq!(
        report.text,
        "line one\nline two with ünïcode ✓ and a tab\there\n末尾 done"
    );
    assert_eq!(
        report.terminal.expect("terminal").state,
        TerminalState::Completed
    );
}

#[test]
fn a_failed_stream_reports_its_own_terminal_failure_without_inventing_usage() {
    let mut runtime = custom_runtime(&[]);
    let mut session = runtime
        .open_stream(
            "synthetic.example/synthetic-text",
            "user:synthetic",
            "effect:fail",
            json!({"scenario": "fail"}),
        )
        .expect("admission");
    let report = support::drain(&mut session);
    let terminal = report.terminal.expect("terminal");
    let TerminalState::Failed { code, .. } = terminal.state else {
        panic!("expected a failed terminal, got {:?}", terminal.state);
    };
    assert_eq!(code, "synthetic.example/stream-failure");
    assert_eq!(terminal.usage.input_tokens, Some(5));
    assert_eq!(terminal.usage.output_tokens, None);
    assert_eq!(terminal.usage.cost, None, "no cost is implied by a failure");
}

#[test]
fn reconcile_reports_a_finished_invocation_and_preserves_unknown_for_others() {
    let mut plugin = support::plugin_handle(&[]);
    plugin.initialize().expect("handshake");
    assert!(plugin.implements("modelProvider.reconcile"));

    let invocation_ref = "stream-reconcile-1";
    let ack = plugin
        .request(
            "modelProvider.stream",
            json!({
                "invocationRef": invocation_ref,
                "effectRef": "effect:reconcile",
                "principal": "user:synthetic",
                "model": {
                    "providerId": "synthetic.example",
                    "providerGeneration": 1,
                    "vendorModelId": "synthetic-text",
                },
                "credentialRef": null,
                "credentialState": "not-configured",
                "input": {"scenario": "default"},
            }),
        )
        .expect("stream start");
    assert_eq!(ack.get("started").and_then(Value::as_bool), Some(true));

    let mut outcome = None;
    while outcome.is_none() {
        let params = plugin
            .next_notification("modelProvider.stream")
            .expect("stream notification");
        if params.get("kind").and_then(Value::as_str) == Some("terminal") {
            outcome = params
                .get("outcome")
                .and_then(Value::as_str)
                .map(str::to_owned);
        }
    }
    assert_eq!(outcome.as_deref(), Some("completed"));

    let reconciled = plugin.reconcile(invocation_ref).expect("reconcile");
    assert_eq!(
        reconciled.get("state").and_then(Value::as_str),
        Some("completed")
    );
    let usage = reconciled.get("usage").expect("usage");
    assert_eq!(usage.get("inputTokens").and_then(Value::as_u64), Some(12));
    assert!(
        usage
            .get("outputTokens")
            .map(Value::is_null)
            .unwrap_or(true),
        "an unreported count stays unknown through reconcile"
    );

    let unknown = plugin
        .reconcile("stream-never-ran")
        .expect("reconcile unknown invocation");
    assert_eq!(
        unknown.get("state").and_then(Value::as_str),
        Some("unknown"),
        "a provider that knows nothing says unknown, not success"
    );
}

#[test]
fn a_custom_configuration_without_its_adapter_is_refused_not_imitated() {
    // Removing the adapter from a custom dialect is a configuration error.
    let mut value = support::fixture_value(CUSTOM_CONFIG);
    value
        .as_object_mut()
        .expect("object")
        .remove("streamAdapter");
    let failure = ProviderConfig::from_value(value).expect_err("no adapter declared");
    assert_eq!(failure.code, "provider_custom_dialect_requires_adapter");

    // A configuration that names an adapter the host does not serve is refused
    // at admission; it is not routed to a compatible transport.
    let mut runtime = ProviderRuntime::new();
    let config = support::fixture_config(CUSTOM_CONFIG);
    runtime.install_user(config).expect("configuration");
    runtime
        .adopt_discovered_models("synthetic.example", support::plugin_models(&[]))
        .expect("discovered models");
    let failure = runtime
        .open_stream(
            "synthetic.example/synthetic-text",
            "user:synthetic",
            "effect:no-adapter",
            json!({}),
        )
        .expect_err("no custom adapter registered");
    assert_eq!(failure.code, "provider_stream_adapter_unavailable");
}
