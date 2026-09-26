//! C09 and C12: the package manifest — what a package says about itself.
//!
//! A manifest is a claim. It describes an identity, the profiles it serves, how
//! it is carried, what it asks the host for, and what it contributes. Two things
//! it can never do are declare itself trustworthy and declare itself authorized:
//!
//! - **It carries no digest and no signature.** The content hash and publisher
//!   verification are produced by packaging and by the update mechanism, from the
//!   bytes. A manifest that writes its own hash is describing itself with a value
//!   that could not have been computed yet, and one that claims it "has been
//!   verified" is asking the reader to skip the check
//!   ([`PackageManifest::from_value`] refuses both).
//! - **A permission request is a request.** There is no `granted` field, and the
//!   host's decision is made elsewhere and is not data in here — the same split
//!   [`CapabilityDescriptor`](licoup_application::CapabilityDescriptor) uses.
//!
//! `requires` and `optionalRequires` are *deployment* relations. They decide
//! which packages are installed together, and nothing about the development task
//! that produced them: a task that changes a package makes the evidence of the
//! tasks that touch its closure stale, and that closure is computed from these
//! two lists rather than from a task graph.

use crate::profile::ProfileDeclaration;
use crate::refusal;
use crate::ui::ContributionKind;
use licoup_application::{
    ActivationMode, ApplicationFailure, ContractRange, is_namespaced, is_semver,
};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::BTreeMap;

const STAGE: &str = "extension/manifest";

/// The longest range expression accepted.
pub const MAX_RANGE_BYTES: usize = 64;

/// Fields a manifest may not carry, because they are facts about the *bytes* or
/// about the host's decision rather than about the package's own plan.
pub const SELF_ASSERTED_FIELDS: &[&str] = &[
    "artifactdigest",
    "contenthash",
    "granted",
    "installed",
    "integrity",
    "sha256",
    "signedby",
    "signature",
    "trusted",
    "verified",
];

/// A prefix marking a runtime the user provides.
pub const USER_RUNTIME_PREFIX: &str = "user:";

/// One deployment dependency.
///
/// The range is recorded, not solved: constraint resolution belongs to the host's
/// package manager, which applies it together with platform artefacts and the
/// install journal.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Dependency {
    /// The namespaced package id.
    pub package_id: String,
    /// The accepted version range, verbatim.
    pub range: String,
}

impl Dependency {
    pub fn new(package_id: impl Into<String>, range: impl Into<String>) -> Self {
        Self {
            package_id: package_id.into(),
            range: range.into(),
        }
    }

    pub fn validate(&self) -> Result<(), ApplicationFailure> {
        if !is_namespaced(&self.package_id) {
            return Err(refusal::new("manifest_dependency_invalid", STAGE).with_field("packageId"));
        }
        if self.range.is_empty() || self.range.len() > MAX_RANGE_BYTES {
            return Err(refusal::new("manifest_dependency_invalid", STAGE).with_field("range"));
        }
        Ok(())
    }
}

/// One permission the package asks for.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PermissionRequest {
    /// The namespaced capability being asked for.
    pub capability: String,
    /// The scope the request is bounded to, such as a directory or an endpoint.
    pub scope: String,
}

impl PermissionRequest {
    pub fn new(capability: impl Into<String>, scope: impl Into<String>) -> Self {
        Self {
            capability: capability.into(),
            scope: scope.into(),
        }
    }

    pub fn validate(&self) -> Result<(), ApplicationFailure> {
        if !is_namespaced(&self.capability) || self.scope.is_empty() {
            return Err(
                refusal::new("manifest_permission_invalid", STAGE).with_field("permissions")
            );
        }
        Ok(())
    }
}

/// One interface contribution, in the manifest's own vocabulary.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ContributionDeclaration {
    pub kind: ContributionKind,
    /// The namespaced contribution identity.
    pub id: String,
    /// The resource that carries the declaration.
    pub definition: String,
}

impl ContributionDeclaration {
    pub fn validate(&self) -> Result<(), ApplicationFailure> {
        if !is_namespaced(&self.id) || self.definition.is_empty() {
            return Err(
                refusal::new("manifest_contribution_invalid", STAGE).with_field("contributions")
            );
        }
        Ok(())
    }
}

/// How a package is carried.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(tag = "mode", rename_all = "kebab-case")]
pub enum Runtime {
    /// A program the host starts, framed over a pipe.
    Process {
        entry: String,
        /// A reference to the interpreter or virtual machine this program needs.
        /// A `user:` reference names something the user installed: the host
        /// reuses it and never removes it.
        #[serde(default, rename = "runtimeRef")]
        runtime_ref: Option<String>,
    },
    /// A descriptor the host maps onto an existing protocol or an ordinary CLI.
    /// The mapping executes nothing: it names fields.
    Declarative { descriptor: String },
    /// An endpoint the user configured. It is bridged, not started.
    Service {
        #[serde(rename = "endpointRef")]
        endpoint_ref: String,
    },
}

impl Runtime {
    pub fn mode(&self) -> &'static str {
        match self {
            Self::Process { .. } => "process",
            Self::Declarative { .. } => "declarative",
            Self::Service { .. } => "service",
        }
    }

    /// Whether the host may remove the runtime this package needs when nothing
    /// references it any more.
    ///
    /// A `user:` reference is the user's own interpreter or tool: it stays. A
    /// shared runtime the host installed is reference-counted and released only
    /// when no package needs it.
    pub fn owns_its_runtime(&self) -> bool {
        match self {
            Self::Process { runtime_ref, .. } => runtime_ref
                .as_deref()
                .is_none_or(|reference| !reference.starts_with(USER_RUNTIME_PREFIX)),
            Self::Declarative { .. } | Self::Service { .. } => false,
        }
    }

    pub fn validate(&self) -> Result<(), ApplicationFailure> {
        match self {
            Self::Process { entry, .. } if entry.is_empty() => {
                Err(refusal::new("manifest_runtime_invalid", STAGE).with_field("runtime.entry"))
            }
            Self::Declarative { descriptor } if descriptor.is_empty() => {
                Err(refusal::new("manifest_runtime_invalid", STAGE)
                    .with_field("runtime.descriptor"))
            }
            Self::Service { endpoint_ref } if endpoint_ref.is_empty() => {
                Err(refusal::new("manifest_runtime_invalid", STAGE)
                    .with_field("runtime.endpointRef"))
            }
            _ => Ok(()),
        }
    }
}

/// The package manifest.
#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PackageManifest {
    pub schema: String,
    /// The namespaced package identity.
    pub id: String,
    pub version: String,
    pub display_name: String,
    /// The host protocol range this package needs.
    pub host_protocol: ContractRange,
    #[serde(default)]
    pub profiles: Vec<ProfileDeclaration>,
    pub runtime: Runtime,
    #[serde(default)]
    pub activation: ActivationMode,
    /// Deployment dependencies that are installed with this package.
    #[serde(default)]
    pub requires: Vec<Dependency>,
    /// Deployment dependencies that are *not* installed with this package. They
    /// enable extra capability when the user already has them.
    #[serde(default)]
    pub optional_requires: Vec<Dependency>,
    #[serde(default)]
    pub permissions: Vec<PermissionRequest>,
    #[serde(default)]
    pub contributions: Vec<ContributionDeclaration>,
    /// The package's own namespaced attributes, preserved for newer hosts.
    #[serde(default)]
    pub extensions: BTreeMap<String, Value>,
}

impl PackageManifest {
    /// The profiles this package declares, resolved against the published set.
    ///
    /// An unpublished id is kept in the manifest and reported as unknown; it
    /// refuses nothing and grants nothing.
    pub fn published_profiles(
        &self,
    ) -> impl Iterator<Item = crate::profile::ExtensionProfile> + '_ {
        self.profiles
            .iter()
            .filter_map(|declaration| declaration.profile())
    }

    /// Structural validation of every field the host reads before it runs
    /// anything.
    pub fn validate(&self) -> Result<(), ApplicationFailure> {
        if self.schema != crate::wire::MANIFEST {
            return Err(refusal::new("manifest_invalid", STAGE).with_field("schema"));
        }
        if !is_namespaced(&self.id) {
            return Err(refusal::new("manifest_invalid", STAGE).with_field("id"));
        }
        if !is_semver(&self.version) {
            return Err(refusal::new("manifest_invalid", STAGE).with_field("version"));
        }
        if self.display_name.is_empty() || self.host_protocol.major < 1 {
            return Err(refusal::new("manifest_invalid", STAGE).with_field("hostProtocol"));
        }
        self.runtime.validate()?;
        for declaration in &self.profiles {
            declaration.validate()?;
        }
        for dependency in self.requires.iter().chain(self.optional_requires.iter()) {
            dependency.validate()?;
        }
        for permission in &self.permissions {
            permission.validate()?;
        }
        for contribution in &self.contributions {
            contribution.validate()?;
        }
        for attribute in self.extensions.keys() {
            if !is_namespaced(attribute) {
                return Err(refusal::new("manifest_invalid", STAGE).with_field("extensions"));
            }
        }
        Ok(())
    }

    /// Read a manifest, refusing one that declares a fact about its own bytes or
    /// about a permission the host has not granted.
    pub fn from_value(value: Value) -> Result<Self, ApplicationFailure> {
        if let Some(field) = self_asserted_field(&value) {
            return Err(refusal::new("manifest_self_asserted_fact", STAGE).with_field(&field));
        }
        let manifest: Self = serde_json::from_value(value)
            .map_err(|_| refusal::new("manifest_invalid", STAGE).with_field("manifest"))?;
        manifest.validate()?;
        Ok(manifest)
    }
}

/// The dotted path of the first field in `value` that a manifest may not assert,
/// if any.
pub fn self_asserted_field(value: &Value) -> Option<String> {
    fn walk(value: &Value, path: &str, found: &mut Option<String>) {
        if found.is_some() {
            return;
        }
        match value {
            Value::Object(map) => {
                for (key, nested) in map {
                    let normalized: String = key
                        .chars()
                        .filter(|character| *character != '_' && *character != '-')
                        .flat_map(char::to_lowercase)
                        .collect();
                    if SELF_ASSERTED_FIELDS.contains(&normalized.as_str()) {
                        *found = Some(format!("{path}{key}"));
                        return;
                    }
                    walk(nested, &format!("{path}{key}."), found);
                }
            }
            Value::Array(items) => {
                for (index, nested) in items.iter().enumerate() {
                    walk(nested, &format!("{path}{index}."), found);
                }
            }
            _ => {}
        }
    }

    let mut found = None;
    walk(value, "", &mut found);
    found
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::profile::ExtensionProfile;

    fn manifest() -> PackageManifest {
        PackageManifest {
            schema: crate::wire::MANIFEST.to_owned(),
            id: "example.specialist.echo".to_owned(),
            version: "1.0.0".to_owned(),
            display_name: "Echo specialist".to_owned(),
            host_protocol: ContractRange {
                major: 1,
                minimum_minor: 0,
            },
            profiles: vec![
                ProfileDeclaration::new(ExtensionProfile::AgentExecution.id(), 1)
                    .with_capabilities(["example.specialist/stream"]),
            ],
            runtime: Runtime::Process {
                entry: "agent.py".to_owned(),
                runtime_ref: Some("user:python3".to_owned()),
            },
            activation: ActivationMode::OnDemand,
            requires: Vec::new(),
            optional_requires: vec![Dependency::new("org.licoland.feature.analytics", "^1.0")],
            permissions: Vec::new(),
            contributions: Vec::new(),
            extensions: BTreeMap::new(),
        }
    }

    #[test]
    fn a_manifest_carries_no_self_asserted_trust_or_grant() {
        assert!(manifest().validate().is_ok());

        let wire = serde_json::json!({
            "schema": crate::wire::MANIFEST,
            "id": "example.specialist.echo",
            "version": "1.0.0",
            "displayName": "Echo specialist",
            "hostProtocol": { "major": 1, "minimumMinor": 0 },
            "profiles": [],
            "runtime": { "mode": "process", "entry": "agent.py" },
            "requires": [],
            "optionalRequires": [],
            "permissions": [],
            "artifactDigest": "sha256:0",
        });
        assert_eq!(
            PackageManifest::from_value(wire)
                .expect_err("a package cannot hash itself")
                .code,
            "manifest_self_asserted_fact"
        );

        let wire = serde_json::json!({
            "schema": crate::wire::MANIFEST,
            "id": "example.specialist.echo",
            "version": "1.0.0",
            "displayName": "Echo specialist",
            "hostProtocol": { "major": 1, "minimumMinor": 0 },
            "profiles": [],
            "runtime": { "mode": "process", "entry": "agent.py" },
            "permissions": [{ "capability": "example.specialist/net", "scope": "self", "granted": true }]
        });
        assert_eq!(
            PackageManifest::from_value(wire)
                .expect_err("no self-grant")
                .code,
            "manifest_self_asserted_fact"
        );
    }

    #[test]
    fn uninstall_never_owns_the_users_runtime() {
        let user = manifest();
        assert!(!user.runtime.owns_its_runtime());

        let mut shared = manifest();
        shared.runtime = Runtime::Process {
            entry: "agent.js".to_owned(),
            runtime_ref: Some("runtime.node-22".to_owned()),
        };
        assert!(shared.runtime.owns_its_runtime());

        shared.runtime = Runtime::Service {
            endpoint_ref: "endpoint.example.agent".to_owned(),
        };
        assert!(!shared.runtime.owns_its_runtime());
        assert_eq!(shared.runtime.mode(), "service");
        let wire = serde_json::json!({"mode": "service", "endpointRef": "endpoint.example.agent"});
        assert_eq!(serde_json::to_value(&shared.runtime).unwrap(), wire);
        assert_eq!(
            serde_json::from_value::<Runtime>(wire).unwrap(),
            shared.runtime
        );
    }

    #[test]
    fn structural_validation_names_the_offending_field() {
        let mut bad = manifest();
        bad.id = "echo".to_owned();
        assert_eq!(
            bad.validate().expect_err("bare id").field.as_deref(),
            Some("id")
        );

        let mut bad = manifest();
        bad.version = "1.0".to_owned();
        assert_eq!(
            bad.validate().expect_err("not a version").field.as_deref(),
            Some("version")
        );

        let mut bad = manifest();
        bad.extensions.insert("bareword".to_owned(), Value::Null);
        assert_eq!(
            bad.validate().expect_err("bare attribute").field.as_deref(),
            Some("extensions")
        );
    }

    #[test]
    fn an_unpublished_profile_is_kept_and_refuses_nothing() {
        let mut ahead = manifest();
        ahead
            .profiles
            .push(ProfileDeclaration::new("future-profile", 1));
        assert!(ahead.validate().is_ok());
        let published: Vec<_> = ahead.published_profiles().collect();
        assert_eq!(published, vec![ExtensionProfile::AgentExecution]);
        assert_eq!(ahead.profiles.len(), 2);
    }
}
