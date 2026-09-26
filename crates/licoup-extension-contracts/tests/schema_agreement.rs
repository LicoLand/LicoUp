//! The published schemas and this crate must say the same thing.
//!
//! A schema that drifts from the code is worse than no schema: a third party
//! validates against it, ships a package, and the host refuses it for a rule the
//! schema never published. These tests pin every value that appears in both
//! places — the wire identifiers, the namespaced-name pattern, the published
//! profile set and each closed enumeration — so an edit to one is an edit to the
//! other or a failing test.
//!
//! The schemas are read from the repository's public `schemas/extensions/`
//! directory, which is the copy a third party sees.

use licoup_application::is_namespaced;
use licoup_extension_contracts::agent::{AgentEventKind, CancelOutcome, UsageSupport};
use licoup_extension_contracts::deployment::{
    CapabilityAvailability, PackageLifecycle, PackageSource,
};
use licoup_extension_contracts::profile::ExtensionProfile;
use licoup_extension_contracts::provider::COMPATIBLE_DIALECTS;
use licoup_extension_contracts::ui::{
    ContributionKind, FieldType, GRAPH_RESOURCE_V1, MAX_CONTRIBUTION_ID_BYTES,
};
use licoup_extension_contracts::usage::{Quality, Temporality, UsageOperation};
use licoup_extension_contracts::wire;
use regex::Regex;
use serde_json::{Value, json};

const MANIFEST: &str = include_str!("../../../schemas/extensions/manifest.schema.json");
const PROVIDER: &str = include_str!("../../../schemas/extensions/provider.schema.json");
const USAGE: &str = include_str!("../../../schemas/extensions/usage.schema.json");
const UI: &str = include_str!("../../../schemas/extensions/ui.schema.json");
const GRAPH_RESOURCE: &str = include_str!("../../../schemas/extensions/graph-resource.schema.json");
const DEPLOYMENT: &str = include_str!("../../../schemas/extensions/deployment.schema.json");

fn schemas() -> Vec<(&'static str, Value)> {
    [
        ("manifest", MANIFEST),
        ("provider", PROVIDER),
        ("usage", USAGE),
        ("ui", UI),
        ("deployment", DEPLOYMENT),
    ]
    .into_iter()
    .map(|(name, text)| (name, serde_json::from_str(text).expect("valid JSON")))
    .collect()
}

/// The wire string one value serializes to, so an enumeration is compared in the
/// same vocabulary the schema publishes rather than in Rust's own naming.
fn wire_of<T: serde::Serialize>(value: &T) -> String {
    match serde_json::to_value(value).expect("serialize") {
        Value::String(text) => text,
        other => panic!("expected a string wire form, got {other}"),
    }
}

fn namespaced_pattern(schema: &Value) -> String {
    schema["$defs"]["namespacedName"]["pattern"]
        .as_str()
        .expect("namespaced pattern")
        .to_owned()
}

#[test]
fn every_schema_publishes_the_identifier_this_crate_uses() {
    let expected = [
        ("manifest", wire::MANIFEST),
        ("provider", wire::PROVIDER),
        ("usage", wire::USAGE),
        ("ui", wire::UI),
        ("deployment", wire::DEPLOYMENT),
    ];
    for (name, identifier) in expected {
        let (_, schema) = schemas()
            .into_iter()
            .find(|(candidate, _)| *candidate == name)
            .expect("schema");
        assert_eq!(
            schema["properties"]["schema"]["const"], identifier,
            "{name} schema publishes a different identifier"
        );
        assert!(
            schema["required"]
                .as_array()
                .expect("required list")
                .iter()
                .any(|key| key == "schema"),
            "{name} must require its identifier"
        );
    }
}

#[test]
fn one_namespaced_pattern_is_published_everywhere() {
    let all = schemas();
    let pattern = namespaced_pattern(&all[0].1);
    for (name, schema) in &all {
        assert_eq!(
            namespaced_pattern(schema),
            pattern,
            "{name} publishes a different namespaced-name pattern"
        );
    }

    let regex = Regex::new(&pattern).expect("compiles");
    let corpus = [
        "org.licoland.core",
        "org.licoland.adapter.generic",
        "org.licoland.example/stream",
        "licoup.quota.tokens",
        "licoup.tokens.input",
        "example.specialist/purpose",
        "a.b",
        "bareword",
        "org.licoland.core/",
        "org.licoland..core",
        "Org.Licoland.Core",
    ];
    for name in corpus {
        assert_eq!(
            regex.is_match(name),
            is_namespaced(name),
            "the published pattern and is_namespaced disagree on {name:?}"
        );
    }
}

#[test]
fn the_published_profile_set_is_exactly_the_contract_set() {
    let expected: Vec<String> = ExtensionProfile::ALL
        .iter()
        .map(|profile| profile.id().to_owned())
        .collect();
    for (name, schema) in schemas() {
        let Some(enumeration) = schema["$defs"]["publishedProfile"].get("enum") else {
            continue;
        };
        let published: Vec<String> = enumeration
            .as_array()
            .expect("enum")
            .iter()
            .map(|value| value.as_str().expect("string").to_owned())
            .collect();
        assert_eq!(published, expected, "{name} publishes another profile set");
    }
    // The two schemas that name profiles must not silently drop the catalog.
    assert!(MANIFEST.contains("publishedProfile"));
    assert!(UI.contains("publishedProfile"));
}

#[test]
fn manifest_declares_exactly_the_profiles_this_crate_publishes() {
    let manifest: Value = serde_json::from_str(MANIFEST).expect("manifest");
    let referenced =
        &manifest["properties"]["profiles"]["items"]["properties"]["id"]["anyOf"][0]["$ref"];
    assert_eq!(referenced, "#/$defs/publishedProfile");
    assert_eq!(
        manifest["properties"]["profiles"]["items"]["properties"]["id"]["anyOf"]
            .as_array()
            .expect("anyOf")
            .len(),
        2,
        "an unpublished profile id must stay expressible"
    );
}

#[test]
fn closed_enumerations_match_the_crate() {
    let manifest: Value = serde_json::from_str(MANIFEST).expect("manifest");
    let kinds: Vec<String> = ContributionKind::ALL.iter().map(wire_of).collect();
    assert_eq!(
        manifest["properties"]["contributions"]["items"]["properties"]["kind"]["enum"],
        json!(kinds)
    );
    assert_eq!(
        manifest["properties"]["activation"]["enum"],
        json!([
            wire_of(&licoup_application::ActivationMode::OnDemand),
            wire_of(&licoup_application::ActivationMode::Explicit)
        ]),
        "activation modes must match ActivationMode"
    );

    let ui: Value = serde_json::from_str(UI).expect("ui");
    let field_types: Vec<String> = [
        FieldType::Text,
        FieldType::Number,
        FieldType::Boolean,
        FieldType::Select,
        FieldType::SecretRef,
    ]
    .iter()
    .map(wire_of)
    .collect();
    assert_eq!(
        ui["properties"]["kind"]["enum"],
        json!(kinds),
        "the standalone contribution publishes the same kinds"
    );
    assert_eq!(
        ui["properties"]["fields"]["items"]["properties"]["type"]["enum"],
        json!(field_types)
    );
    assert_eq!(
        ui["$defs"]["namespacedName"]["maxLength"], MAX_CONTRIBUTION_ID_BYTES,
        "the published format bound is the native bound"
    );

    let graph: Value = serde_json::from_str(GRAPH_RESOURCE).expect("graph-resource");
    assert_eq!(
        graph["properties"]["schema"]["const"], GRAPH_RESOURCE_V1,
        "the graph document publishes the capability identifier this crate recognises"
    );
    assert_eq!(
        graph["properties"]["projects"]["maxItems"], 8,
        "the frozen multi-project bound"
    );
    assert_eq!(
        graph["$defs"]["project"]["properties"]["nodes"]["maxItems"], 1000,
        "the frozen node bound"
    );
    assert_eq!(
        graph["properties"]["edges"]["maxItems"], 2000,
        "the frozen edge bound"
    );
    assert_eq!(
        graph["$defs"]["node"]["properties"]["actions"]["items"]["$ref"], "#/$defs/opaqueRef",
        "actions stay opaque references, never executable payloads"
    );
    for forbidden in ["code", "script", "widget", "handler", "dart"] {
        assert!(
            graph["$defs"]["node"]["properties"]
                .get(forbidden)
                .is_none(),
            "a graph node has no place for {forbidden}"
        );
    }

    let usage: Value = serde_json::from_str(USAGE).expect("usage");
    assert_eq!(
        usage["properties"]["operation"]["enum"],
        json!([
            wire_of(&UsageOperation::Upsert),
            wire_of(&UsageOperation::Retract)
        ])
    );
    assert_eq!(
        usage["properties"]["metrics"]["additionalProperties"]["properties"]["quality"]["enum"],
        json!([
            wire_of(&Quality::Reported),
            wire_of(&Quality::Estimated),
            wire_of(&Quality::Unknown)
        ])
    );
    assert_eq!(
        usage["properties"]["metrics"]["additionalProperties"]["properties"]["temporality"]["enum"],
        json!([
            wire_of(&Temporality::Delta),
            wire_of(&Temporality::Cumulative),
            wire_of(&Temporality::Gauge),
            wire_of(&Temporality::Absolute)
        ])
    );

    let deployment: Value = serde_json::from_str(DEPLOYMENT).expect("deployment");
    assert_eq!(
        deployment["properties"]["packages"]["items"]["properties"]["source"]["enum"],
        json!([
            PackageSource::LocalImport.id(),
            PackageSource::LocalDirectory.id(),
            PackageSource::OfficialDirectory.id(),
            PackageSource::ThirdPartyDirectory.id()
        ])
    );
    assert_eq!(
        deployment["properties"]["packages"]["items"]["properties"]["lifecycle"]["enum"],
        json!([
            wire_of(&PackageLifecycle::Available),
            wire_of(&PackageLifecycle::Downloaded),
            wire_of(&PackageLifecycle::Verified),
            wire_of(&PackageLifecycle::LocalApproved),
            wire_of(&PackageLifecycle::Staged),
            wire_of(&PackageLifecycle::Installed)
        ])
    );
    assert_eq!(
        deployment["properties"]["capabilities"]["items"]["properties"]["availability"]["enum"],
        json!([
            CapabilityAvailability::Served.describe(),
            CapabilityAvailability::InstalledNotEnabled.describe(),
            CapabilityAvailability::NotInstalled.describe(),
            CapabilityAvailability::NotInDistribution.describe()
        ])
    );

    let provider: Value = serde_json::from_str(PROVIDER).expect("provider");
    assert_eq!(
        provider["allOf"][0]["if"]["properties"]["apiDialect"]["not"]["enum"],
        json!(COMPATIBLE_DIALECTS),
        "the dialects that need no stream adapter must be the published ones"
    );
}

#[test]
fn the_agent_event_vocabulary_is_published_with_its_optional_outcomes() {
    let kinds = [
        AgentEventKind::Text,
        AgentEventKind::Artifact,
        AgentEventKind::Progress,
        AgentEventKind::State,
        AgentEventKind::Terminal,
    ]
    .map(|kind| kind.as_str());
    assert_eq!(
        kinds,
        ["text", "artifact", "progress", "state", "terminal"],
        "the event kinds are the C09 vocabulary"
    );
    assert_eq!(
        [
            CancelOutcome::Requested,
            CancelOutcome::Acknowledged,
            CancelOutcome::Unsupported,
            CancelOutcome::Unknown,
        ]
        .iter()
        .map(wire_of)
        .collect::<Vec<_>>(),
        ["requested", "acknowledged", "unsupported", "unknown"]
    );
    // An Agent that reports no usage is a complete Agent, so "unavailable" is
    // part of the vocabulary rather than a missing value.
    assert_eq!(wire_of(&UsageSupport::Unavailable), "unavailable");
}

#[test]
fn no_schema_publishes_a_place_for_key_material_or_a_self_hash() {
    for (name, schema) in schemas() {
        let text = serde_json::to_string(&schema).expect("serialize");
        for forbidden in ["apiKey", "api_key", "password", "artifactDigest", "granted"] {
            assert!(!text.contains(forbidden), "{name} publishes {forbidden}");
        }
    }
}
