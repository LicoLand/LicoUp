//! The sample under `samples/echo-agent/` is checked against the contract.
//!
//! The sample is the smallest complete extension: a program in a language that
//! is not Rust, implementing three Agent methods and the handshake, asking for no
//! permission, and installed from a directory the user already has. These tests
//! read authored synthetic wire vectors and assert their declared contract — that the
//! required set is satisfied exactly, that no optional method was needed, that
//! nothing was resolved over the network, and that the frames it emits are valid
//! envelopes.
//!
//! They do not run the program. A language-agnostic contract is checked against
//! frames, not against one interpreter being installed. The separate Python
//! subprocess suite verifies actual execution; these vectors are not runtime logs.

use licoup_application::ContractRange;
use licoup_extension_contracts::agent::AgentEvent;
use licoup_extension_contracts::deployment::{
    InstallClosure, LocalCatalogue, PackageEntry, PackageSource, install_closure,
};
use licoup_extension_contracts::manifest::PackageManifest;
use licoup_extension_contracts::profile::{
    DeclaredMethods, ExtensionProfile, PROFILE_MAJOR, ProfileStatus, all_contracts,
};
use licoup_extension_contracts::transport::{
    DEFAULT_MAX_FRAME_BYTES, Framing, JSONRPC_VERSION, MAX_MAX_FRAME_BYTES, MIN_MAX_FRAME_BYTES,
};
use licoup_extension_contracts::wire;
use serde_json::Value;
use std::collections::BTreeSet;

const MANIFEST: &str = include_str!("../samples/echo-agent/manifest.json");
const FIXTURE: &str = include_str!("../samples/echo-agent/wire_fixture.json");
const TRANSCRIPT: &str = "requestLines";
const EVENTS: &str = "eventLines";
const AGENT_SOURCE: &str = include_str!("../samples/echo-agent/agent.py");

fn frames(section: &str) -> Vec<Value> {
    let fixture: Value = serde_json::from_str(FIXTURE).expect("synthetic wire fixture");
    assert_eq!(fixture["schema"], "licoup.extension-sample-vector.v1");
    assert_eq!(fixture["synthetic"], true);
    fixture[section]
        .as_array()
        .expect("declared frame vector")
        .iter()
        .map(|line| {
            serde_json::from_str(line.as_str().expect("one frame string")).expect("frame JSON")
        })
        .collect()
}

fn published_methods() -> BTreeSet<&'static str> {
    all_contracts()
        .iter()
        .flat_map(|contract| contract.methods())
        .collect()
}

fn agent_optional_methods() -> BTreeSet<&'static str> {
    ExtensionProfile::AgentExecution
        .contract_profile()
        .optional
        .iter()
        .copied()
        .collect()
}

/// The required method set exercised by the synthetic request/event vectors.
fn declared_methods() -> DeclaredMethods {
    let mut names: BTreeSet<String> = BTreeSet::new();
    for frame in frames(TRANSCRIPT).into_iter().chain(frames(EVENTS)) {
        names.insert(
            frame["method"]
                .as_str()
                .expect("every frame names a method")
                .to_owned(),
        );
    }
    DeclaredMethods::new(names)
}

#[test]
fn the_sample_manifest_is_a_conformant_local_package() {
    let manifest =
        PackageManifest::from_value(serde_json::from_str(MANIFEST).expect("manifest JSON"))
            .expect("the sample manifest is accepted");

    assert_eq!(manifest.schema, wire::MANIFEST);
    assert!(
        manifest.permissions.is_empty(),
        "the smallest Agent asks for nothing"
    );
    assert!(
        matches!(
            manifest.activation,
            licoup_application::ActivationMode::OnDemand
        ),
        "an extension with no business call is never started"
    );

    // The interpreter is the user's. Uninstalling the package must not remove it.
    assert!(!manifest.runtime.owns_its_runtime());
    assert_eq!(manifest.runtime.mode(), "process");
}

#[test]
fn the_sample_manifest_carries_every_field_its_schema_requires() {
    let schema: Value = serde_json::from_str(include_str!(
        "../../../schemas/extensions/manifest.schema.json"
    ))
    .expect("manifest schema");
    let manifest: Value = serde_json::from_str(MANIFEST).expect("manifest JSON");
    let object = manifest.as_object().expect("object");
    for required in schema["required"].as_array().expect("required") {
        let key = required.as_str().expect("string");
        assert!(object.contains_key(key), "the sample omits {key}");
    }
    assert_eq!(manifest["schema"], wire::MANIFEST);
    let properties = schema["properties"]
        .as_object()
        .expect("properties")
        .keys()
        .cloned()
        .collect::<BTreeSet<_>>();
    for key in object.keys() {
        assert!(
            properties.contains(key),
            "the sample carries {key}, which the schema does not publish"
        );
    }
}

#[test]
fn the_sample_implements_the_required_set_exactly() {
    let declared = declared_methods();
    let methods: BTreeSet<&str> = declared.names().collect();
    let published = published_methods();

    for method in &methods {
        assert!(published.contains(method), "{method} is not published");
    }
    for method in &methods {
        assert!(
            !agent_optional_methods().contains(method),
            "the minimal sample must not need the optional {method}"
        );
    }

    let contract = ExtensionProfile::AgentExecution.contract_profile();
    let required: BTreeSet<&str> = contract.required.iter().copied().collect();
    assert_eq!(
        methods, required,
        "the sample implements exactly what agent-execution requires"
    );

    let status = declaration().status(host_range(), &declared);
    assert_eq!(status, ProfileStatus::Available);
    assert!(
        status
            .refusal(
                "org.licoland.example.echo",
                ExtensionProfile::AgentExecution
            )
            .is_none()
    );
}

/// The sample package's declared profile, as its manifest writes it.
fn declaration() -> licoup_extension_contracts::profile::ProfileDeclaration {
    let manifest: Value = serde_json::from_str(MANIFEST).expect("manifest JSON");
    serde_json::from_value(manifest["profiles"][0].clone()).expect("profile declaration")
}

fn host_range() -> ContractRange {
    ContractRange {
        major: 1,
        minimum_minor: 0,
    }
}

#[test]
fn the_sample_is_installed_from_a_local_directory_with_no_directory_service() {
    let manifest: Value = serde_json::from_str(MANIFEST).expect("manifest JSON");
    let requires = manifest["requires"].as_array().expect("requires");
    assert_eq!(requires.len(), 1);
    assert_eq!(requires[0]["packageId"], "org.licoland.core");
    assert!(
        manifest["optionalRequires"]
            .as_array()
            .expect("optional")
            .is_empty()
    );

    let mut catalogue = LocalCatalogue::new();
    catalogue.insert(PackageEntry::new(
        "org.licoland.core",
        "0.3.0",
        PackageSource::LocalImport,
    ));
    let mut sample = PackageEntry::new(
        manifest["id"].as_str().expect("id"),
        manifest["version"].as_str().expect("version"),
        PackageSource::LocalImport,
    );
    sample
        .requires
        .push(serde_json::from_value(requires[0].clone()).expect("dependency"));
    catalogue.insert(sample);

    let closure: InstallClosure = install_closure(&catalogue, &["org.licoland.example.echo"])
        .expect("a local import resolves offline");
    assert_eq!(closure.len(), 2);
    assert!(closure.contains("org.licoland.core"));
    assert!(closure.declined_optional().next().is_none());
}

#[test]
fn the_sample_emits_events_that_are_valid_envelopes() {
    let events = frames(EVENTS);
    assert_eq!(
        events[0]["method"], "extension.ready",
        "the handshake publishes readiness before any work"
    );
    assert!(
        events[0].get("id").is_none(),
        "readiness is a notification, not an answer to a request"
    );

    let mut sequences = Vec::new();
    let mut terminals = 0;
    for frame in &events[1..] {
        assert_eq!(frame["method"], "agent.event");
        let event: AgentEvent =
            serde_json::from_value(frame["params"].clone()).expect("a valid event envelope");
        assert_eq!(event.invocation_ref, "sample-invocation-1");
        if event.is_terminal() {
            terminals += 1;
        }
        sequences.push(event.sequence);
    }
    assert_eq!(sequences, vec![1, 2], "sequences are monotone from one");
    assert_eq!(terminals, 1);
    assert!(
        events.last().expect("last frame")["params"]["kind"] == "terminal",
        "the end of the work is reported last"
    );
    assert_eq!(
        events[1]["params"]["body"], "hello from the sample transcript",
        "the body is carried verbatim"
    );
}

#[test]
fn the_sample_session_stays_inside_the_published_carrier() {
    let transcript = frames(TRANSCRIPT);
    let initialize = &transcript[0];
    assert_eq!(initialize["jsonrpc"], JSONRPC_VERSION);
    assert_eq!(
        initialize["params"]["protocol"]["major"], PROFILE_MAJOR,
        "the sample negotiates the published profile major"
    );

    let max_frame_bytes = initialize["params"]["maxFrameBytes"]
        .as_u64()
        .expect("a negotiated bound");
    assert!(
        (MIN_MAX_FRAME_BYTES as u64..=MAX_MAX_FRAME_BYTES as u64).contains(&max_frame_bytes),
        "the sample negotiates outside the accepted range"
    );
    let negotiated = Framing::new(DEFAULT_MAX_FRAME_BYTES, max_frame_bytes as usize);
    assert_eq!(
        negotiated.negotiated_max_frame_bytes(),
        max_frame_bytes as usize
    );

    let published = published_methods();
    for frame in &transcript {
        assert_eq!(frame["jsonrpc"], JSONRPC_VERSION);
        let method = frame["method"].as_str().expect("method");
        assert!(published.contains(method), "{method} is not published");
        assert!(
            frame.get("id").is_some(),
            "{method} is a request, so it carries an id"
        );
    }

    // The program is a sample of the carrier, not of a language binding: it is
    // not Rust, and the contract does not care.
    assert!(AGENT_SOURCE.starts_with("#!/usr/bin/env python3"));
}
