//! Authentication interaction: the provider offers a challenge, the host shows
//! it with its own primitives, and the result is a scoped handle — never key
//! material, and never a handle for an origin the user did not authorize.

use crate::support;
use licoup_extension_contracts::provider::CredentialScope;
use licoup_model_provider::{
    AuthChallenge, AuthDriver, AuthInput, AuthStage, CredentialHandle, CredentialResolution,
    ModelCatalogKey, ProviderRuntime,
};
use serde_json::json;

const CUSTOM_CONFIG: &str = "extensions/providers/synthetic-custom/provider.config.json";
const ORIGIN: &str = "http://127.0.0.1:8099";

#[test]
fn a_device_code_flow_yields_a_scoped_handle_and_never_key_material() {
    let mut plugin = support::plugin_handle(&[]);
    plugin.initialize().expect("handshake");
    let mut driver = AuthDriver::new(&mut plugin, "synthetic.example", ORIGIN);
    let mut flow = driver.begin().expect("begin");

    let AuthStage::AwaitingUser { challenge } = &flow.stage else {
        panic!("expected a challenge, got {:?}", flow.stage);
    };
    let AuthChallenge::DeviceCode {
        verification_uri,
        user_code,
        expires_in_seconds,
    } = challenge
    else {
        panic!("expected a device code, got {challenge:?}");
    };
    assert_eq!(verification_uri, "https://auth.example.invalid/device");
    assert_eq!(user_code, "SYNTH-0001");
    assert_eq!(expires_in_seconds, &Some(600));

    driver
        .continue_with(&mut flow, AuthInput::PollDeviceCode)
        .expect("poll");
    assert_eq!(flow.stage, AuthStage::Pending);
    driver
        .continue_with(&mut flow, AuthInput::PollDeviceCode)
        .expect("poll again");
    let scope = flow.credential_scope().cloned().expect("authorized");
    assert_eq!(scope.reference, "credential:synthetic-device");
    assert_eq!(scope.provider_id, "synthetic.example");
    assert_eq!(scope.origin, ORIGIN);
    assert!(
        scope.reference.starts_with("credential:"),
        "the flow yields a handle, not key material"
    );

    // The handle the flow issued is what a stream carries, and only for the
    // origin it was authorized for.
    let mut runtime = ProviderRuntime::new();
    let config = support::fixture_config(CUSTOM_CONFIG);
    runtime.install_user(config).expect("configuration");
    runtime
        .adopt_discovered_models("synthetic.example", support::plugin_models(&[]))
        .expect("discovered models");
    runtime
        .credentials_mut()
        .insert(scope, CredentialHandle::new("credential:synthetic-device"));
    runtime.register_custom_adapter("synthetic.example/stream", support::plugin_factory(&[]));
    let mut session = runtime
        .open_stream(
            "synthetic.example/synthetic-text",
            "user:synthetic",
            "effect:auth",
            json!({"scenario": "default"}),
        )
        .expect("admission");
    let report = support::drain(&mut session);
    assert_eq!(
        report.credential_notice(),
        Some(
            "credential=credential:synthetic-device;state=resolved;principal=user:synthetic;effect=effect:auth"
        )
    );
}

#[test]
fn a_secret_input_continuation_yields_a_handle_without_moving_the_secret() {
    let mut plugin = support::plugin_handle(&[]);
    plugin.initialize().expect("handshake");
    let mut driver = AuthDriver::new(&mut plugin, "synthetic.example", ORIGIN);
    let mut flow = driver.begin().expect("begin");
    let handle = licoup_model_provider::SecretInputHandle::new("secret-input:host-1");
    assert!(
        !format!("{handle:?}").contains("host-1"),
        "the handle is opaque"
    );
    driver
        .continue_with(&mut flow, AuthInput::Secret { handle })
        .expect("continue with a host-collected secret");
    let scope = flow.credential_scope().cloned().expect("authorized");
    assert_eq!(scope.reference, "credential:synthetic-secret");
    assert_eq!(scope.origin, ORIGIN);
}

#[test]
fn refresh_and_revoke_change_the_flow_state() {
    let mut plugin = support::plugin_handle(&[]);
    plugin.initialize().expect("handshake");
    let mut driver = AuthDriver::new(&mut plugin, "synthetic.example", ORIGIN);
    let mut flow = driver.begin().expect("begin");
    driver
        .continue_with(&mut flow, AuthInput::PollDeviceCode)
        .expect("poll");
    driver
        .continue_with(&mut flow, AuthInput::PollDeviceCode)
        .expect("poll again");
    let original = flow.credential_scope().cloned().expect("authorized");

    driver.refresh(&mut flow).expect("refresh");
    let refreshed = flow.credential_scope().cloned().expect("still authorized");
    assert_eq!(refreshed.reference, original.reference);

    assert!(driver.revoke(&mut flow).expect("revoke"));
    assert_eq!(flow.stage, AuthStage::Revoked);
    assert!(flow.credential_scope().is_none());
}

#[test]
fn a_package_that_declares_no_auth_is_refused_actionably() {
    let mut plugin = support::plugin_handle(&["--no-auth"]);
    plugin.initialize().expect("handshake");
    let mut driver = AuthDriver::new(&mut plugin, "synthetic.example", ORIGIN);
    let failure = driver.begin().expect_err("auth is not declared");
    assert_eq!(failure.code, "provider_auth_unsupported");
}

#[test]
fn an_authorized_endpoint_does_not_cover_a_new_origin() {
    let mut runtime = ProviderRuntime::new();
    let config = support::fixture_config(CUSTOM_CONFIG);
    let origin = config.origin().expect("origin");
    runtime.credentials_mut().insert(
        CredentialScope {
            reference: config.credential_ref.clone().expect("handle"),
            provider_id: config.id.clone(),
            origin: origin.clone(),
        },
        CredentialHandle::new("credential:synthetic-device"),
    );
    let provider_id = config.id.clone();
    runtime.install_user(config).expect("generation 1");
    let generation_one = ModelCatalogKey {
        provider_id: provider_id.clone(),
        provider_generation: 1,
        vendor_model_id: "synthetic-text".to_owned(),
    };
    assert!(
        runtime
            .instance_for_key(&generation_one)
            .expect("binding")
            .credential()
            .is_resolved()
    );

    // The same handle reference, a different endpoint: nothing is inherited.
    let mut moved = support::fixture_value(CUSTOM_CONFIG);
    moved["configRevision"] = json!(2);
    moved["baseUrl"] = json!("http://127.0.0.1:8199/native/v1");
    runtime.install_from_value(moved).expect("generation 2");
    let generation_two = ModelCatalogKey {
        provider_id,
        provider_generation: 2,
        vendor_model_id: "synthetic-text".to_owned(),
    };
    match runtime
        .instance_for_key(&generation_two)
        .expect("binding")
        .credential()
    {
        CredentialResolution::ScopeMismatch { configured } => {
            assert_eq!(configured.origin, origin);
        }
        other => panic!("expected a scope mismatch, got {other:?}"),
    }
    // The old generation still resolves its own authorized handle.
    assert!(
        runtime
            .instance_for_key(&generation_one)
            .expect("binding")
            .credential()
            .is_resolved()
    );
}
