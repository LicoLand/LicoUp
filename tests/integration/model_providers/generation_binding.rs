//! A30: in-flight binding, atomic catalogs, failed switches, removal and
//! revocation at the provider runtime's seams.
//!
//! The scenarios are injected rather than assumed: a refused update, a
//! concurrent installer, a provider removed while a stream runs, and a credential
//! revoked while a stream runs.

use crate::support;
use licoup_model_provider::{
    CredentialResolution, ModelCatalogKey, ProviderRuntime, TerminalState,
};
use serde_json::json;
use std::collections::BTreeMap;
use std::sync::{Arc, Mutex, RwLock};
use std::thread;

const COMPATIBLE_CONFIG: &str = "extensions/providers/compatible-local/provider.json";
const COMPATIBLE_STREAM: &str = "extensions/providers/compatible-local/stream-fixture.jsonl";

fn new_record() -> support::CredentialRecord {
    Arc::new(Mutex::new(None))
}

fn compatible_runtime(credential: &support::CredentialRecord) -> ProviderRuntime {
    let mut runtime = ProviderRuntime::new();
    runtime.register_compatible_adapter(
        "openai-chat-compatible",
        support::fixture_adapter_factory(COMPATIBLE_STREAM, Arc::clone(credential)),
    );
    runtime
}

#[test]
fn a_failed_switch_leaves_the_previous_generation_serving() {
    let credential = new_record();
    let mut runtime = compatible_runtime(&credential);
    let v1 = support::fixture_config(COMPATIBLE_CONFIG);
    support::authorize(&mut runtime, &v1);
    runtime.install_user(v1).expect("generation 1");
    let mut in_flight = runtime
        .open_stream(
            "synthetic.example.compat-local/local-small",
            "user:synthetic",
            "effect:switch",
            json!({}),
        )
        .expect("admission");

    // A refused update leaves the registry exactly as it was.
    let mut invalid = support::fixture_value(COMPATIBLE_CONFIG);
    invalid["configRevision"] = json!(2);
    invalid["apiDialect"] = json!("synthetic.example/native");
    let failure = runtime
        .install_from_value(invalid)
        .expect_err("custom dialect without an adapter");
    assert_eq!(failure.code, "provider_custom_dialect_requires_adapter");
    assert_eq!(
        runtime
            .snapshot()
            .generation_of("synthetic.example.compat-local"),
        Some(1)
    );
    let report = support::drain(&mut in_flight);
    assert_eq!(
        report.terminal.expect("terminal").state,
        TerminalState::Completed
    );

    // An accepted update whose adapter is not installed refuses new admission
    // locally; it does not fall back to generation 1.
    let mut switched = support::fixture_value(COMPATIBLE_CONFIG);
    switched["configRevision"] = json!(2);
    switched["apiDialect"] = json!("synthetic.example/native");
    switched["streamAdapter"] = json!("synthetic.example/stream");
    switched["catalogSource"] = json!("static");
    switched["models"] = json!([{"id": "custom-text", "displayName": "Custom Text"}]);
    let receipt = runtime.install_from_value(switched).expect("generation 2");
    assert_eq!(receipt.generation, 2);
    let failure = runtime
        .open_stream(
            "synthetic.example.compat-local/custom-text",
            "user:synthetic",
            "effect:switch-2",
            json!({}),
        )
        .expect_err("no registered adapter");
    assert_eq!(failure.code, "provider_stream_adapter_unavailable");
    let catalog = runtime.catalog();
    assert!(
        catalog
            .entries()
            .iter()
            .all(|entry| entry.key.provider_generation == 2),
        "no mixed-generation catalog after a switch"
    );
}

#[test]
fn concurrent_admission_never_sees_a_mixed_catalog() {
    let runtime = Arc::new(RwLock::new(ProviderRuntime::new()));
    {
        let mut guard = runtime.write().expect("write");
        guard
            .install_user(support::synthetic_compatible_config(
                "synthetic.example.a",
                1,
                "a-1",
            ))
            .expect("provider a");
        guard
            .install_user(support::synthetic_compatible_config(
                "synthetic.example.b",
                1,
                "b-1",
            ))
            .expect("provider b");
    }

    let writer = {
        let runtime = Arc::clone(&runtime);
        thread::spawn(move || {
            for revision in 2..=40u32 {
                let mut guard = runtime.write().expect("write");
                guard
                    .install_user(support::synthetic_compatible_config(
                        "synthetic.example.a",
                        revision,
                        &format!("a-{revision}"),
                    ))
                    .expect("install");
                if revision % 7 == 0 {
                    guard
                        .install_user(support::synthetic_compatible_config(
                            "synthetic.example.b",
                            revision,
                            &format!("b-{revision}"),
                        ))
                        .expect("install b");
                }
            }
        })
    };

    let mut readers = Vec::new();
    for _ in 0..4 {
        let runtime = Arc::clone(&runtime);
        readers.push(thread::spawn(move || {
            let mut snapshots = 0u64;
            for _ in 0..300 {
                let catalog = runtime.read().expect("read").catalog();
                assert!(!catalog.entries().is_empty());
                let mut generations: BTreeMap<String, u64> = BTreeMap::new();
                for entry in catalog.entries() {
                    let current = catalog
                        .generation_of(&entry.key.provider_id)
                        .expect("entry's provider is in the same snapshot");
                    assert_eq!(
                        current, entry.key.provider_generation,
                        "an entry comes from its snapshot's generation"
                    );
                    match generations.get(&entry.key.provider_id) {
                        Some(seen) => assert_eq!(
                            *seen, entry.key.provider_generation,
                            "one catalog names exactly one generation per provider"
                        ),
                        None => {
                            generations.insert(
                                entry.key.provider_id.clone(),
                                entry.key.provider_generation,
                            );
                        }
                    }
                }
                snapshots += 1;
            }
            snapshots
        }));
    }

    writer.join().expect("writer");
    let total: u64 = readers
        .into_iter()
        .map(|reader| reader.join().expect("reader"))
        .sum();
    assert_eq!(total, 4 * 300);
}

#[test]
fn a_removed_provider_settles_in_flight_work_and_leaves_others_alone() {
    let credential = new_record();
    let mut runtime = compatible_runtime(&credential);
    runtime
        .install_user(support::synthetic_compatible_config(
            "synthetic.example.a",
            1,
            "a-1",
        ))
        .expect("provider a");
    runtime
        .install_user(support::synthetic_compatible_config(
            "synthetic.example.b",
            1,
            "b-1",
        ))
        .expect("provider b");
    runtime
        .set_alias("a-fast", "synthetic.example.a/a-1")
        .expect("alias");

    let mut in_flight = runtime
        .open_stream(
            "synthetic.example.a/a-1",
            "user:synthetic",
            "effect:remove",
            json!({}),
        )
        .expect("admission");
    let key = in_flight.binding().request().key.clone();

    let removal = runtime.remove_provider("synthetic.example.a");
    assert_eq!(removal.removed_generation, Some(1));
    assert!(!removal.default_restored);

    let catalog = runtime.catalog();
    assert!(catalog.resolve("synthetic.example.a/a-1").is_err());
    assert!(
        catalog.resolve("a-fast").is_err(),
        "its aliases went with it"
    );
    assert!(catalog.resolve("synthetic.example.b/b-1").is_ok());

    // The in-flight stream is untouched and its generation still settles.
    let report = support::drain(&mut in_flight);
    assert_eq!(
        report.terminal.expect("terminal").state,
        TerminalState::Completed
    );
    let settled = runtime.instance_for_key(&key).expect("settlement binding");
    assert_eq!(settled.generation(), 1);

    // The other provider still admits.
    let mut other = runtime
        .open_stream(
            "synthetic.example.b/b-1",
            "user:synthetic",
            "effect:other",
            json!({}),
        )
        .expect("provider b admission");
    support::drain(&mut other);
}

#[test]
fn revocation_blocks_new_admission_without_stripping_an_admitted_stream() {
    let credential = new_record();
    let mut runtime = compatible_runtime(&credential);
    let config = support::fixture_config(COMPATIBLE_CONFIG);
    support::authorize(&mut runtime, &config);
    let reference = config.credential_ref.clone().expect("handle");
    let provider_id = config.id.clone();
    runtime.install_user(config).expect("provider");
    let mut in_flight = runtime
        .open_stream(
            "synthetic.example.compat-local/local-small",
            "user:synthetic",
            "effect:revoke",
            json!({}),
        )
        .expect("admission");
    assert_eq!(
        credential.lock().expect("record").as_deref(),
        Some("credential:compat-local")
    );

    let revoked = runtime.credentials_mut().revoke_reference(&reference);
    assert_eq!(revoked, 1);

    let mut after = runtime
        .open_stream(
            "synthetic.example.compat-local/local-small",
            "user:synthetic",
            "effect:after-revoke",
            json!({}),
        )
        .expect("a stream may still be attempted without a handle");
    support::drain(&mut after);
    assert_eq!(
        *credential.lock().expect("record"),
        None,
        "a revoked handle is not resolved for a new admission"
    );
    let key = ModelCatalogKey {
        provider_id,
        provider_generation: 1,
        vendor_model_id: "local-small".to_owned(),
    };
    assert!(matches!(
        runtime
            .instance_for_key(&key)
            .expect("binding")
            .credential(),
        CredentialResolution::NotConfigured
    ));

    // The admitted stream keeps the binding it was created with.
    assert!(in_flight.binding().instance().credential().is_resolved());
    let report = support::drain(&mut in_flight);
    assert_eq!(
        report.terminal.expect("terminal").state,
        TerminalState::Completed
    );
}
