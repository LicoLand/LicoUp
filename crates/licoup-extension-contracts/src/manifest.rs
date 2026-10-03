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
//!
//! `compatibility` is a third, separate claim: the client versions the package
//! itself says it supports ([`Compatibility`]). It is not `hostProtocol` — that
//! is the *wire* contract range, negotiated per connection — and it is not the
//! package's own version: a package version that differs from the client is not
//! itself a refusal. The kernel loads a package only when the list covers the
//! running client, and refuses it at install and at activation when it does not.

use crate::profile::ProfileDeclaration;
use crate::refusal;
use crate::ui::ContributionKind;
use licoup_application::{
    ActivationMode, ApplicationFailure, ContractRange, is_namespaced, is_semver,
};
use semver::{Version, VersionReq};
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

/// The client versions a package says it supports.
///
/// This is the package's own declaration, and it is what decides whether this
/// kernel loads it. Each entry is a bare major version (`"1"`) or a
/// semantic-version range, so a package released independently of the client can
/// support a line rather than one exact build. An empty list supports no client:
/// a package that declares none is admitted by nothing, which is why the list is
/// required rather than optional.
#[derive(Clone, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Compatibility {
    /// One entry per supported client line.
    #[serde(default)]
    pub client_versions: Vec<String>,
}

impl Compatibility {
    pub fn new(client_versions: impl IntoIterator<Item = impl Into<String>>) -> Self {
        Self {
            client_versions: client_versions.into_iter().map(Into::into).collect(),
        }
    }

    /// Structural validation: the list is present and every entry is a version
    /// requirement this contract can evaluate.
    ///
    /// It compares nothing here. Coverage is a decision about a running client
    /// ([`Compatibility::covers`]), and keeping the two apart is what stops a
    /// malformed list from reading as "no client is supported".
    pub fn validate(&self) -> Result<(), ApplicationFailure> {
        if self.client_versions.is_empty() {
            return Err(refusal::new("manifest_invalid", STAGE).with_field("compatibility"));
        }
        for declared in &self.client_versions {
            if declared.is_empty()
                || declared.len() > MAX_RANGE_BYTES
                || VersionReq::parse(declared).is_err()
            {
                return Err(refusal::new("manifest_invalid", STAGE).with_field("compatibility"));
            }
        }
        Ok(())
    }

    /// Whether one client version is inside the declared list.
    ///
    /// A client version this contract cannot parse is covered by nothing, so an
    /// unreadable identity fails closed rather than loading everything.
    pub fn covers(&self, client_version: &str) -> bool {
        let Ok(version) = Version::parse(client_version) else {
            return false;
        };
        self.client_versions.iter().any(|declared| {
            VersionReq::parse(declared).is_ok_and(|requirement| requirement.matches(&version))
        })
    }
}

/// Whether a package's self-described compatibility list covers one client.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ClientCompatibility {
    /// The running client is one of the versions this package declares.
    Covered,
    /// It is not, so this kernel must not load the package.
    NotCovered,
}

impl ClientCompatibility {
    pub const fn is_covered(self) -> bool {
        matches!(self, Self::Covered)
    }

    /// The refusal for a package this client must not load, or `None` when it
    /// may.
    ///
    /// It names the package and the client version it was decided against, and
    /// its recovery is the real next step: install a package whose list covers
    /// this client. The package's own version is not part of the refusal,
    /// because a different version is not itself the problem.
    pub fn refusal(self, package_id: &str, client_version: &str) -> Option<ApplicationFailure> {
        if self.is_covered() {
            return None;
        }
        Some(
            refusal::actionable("package_client_incompatible", STAGE, "compatibility")
                .with_presentation_arg("package", package_id)
                .with_presentation_arg("clientVersion", client_version),
        )
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
    /// The host protocol range this package needs. This is the wire contract,
    /// and it is not the compatibility rule: it is negotiated per connection and
    /// says nothing about which client builds may load the package.
    pub host_protocol: ContractRange,
    /// The client versions this package says it supports. Required: a package
    /// that declares none is admitted by nothing.
    #[serde(default)]
    pub compatibility: Compatibility,
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

    /// Whether this package's compatibility list covers one client version.
    ///
    /// The package's own `version` takes no part: two builds of a package that
    /// declare the same list are covered by the same clients.
    pub fn client_compatibility(&self, client_version: &str) -> ClientCompatibility {
        if self.compatibility.covers(client_version) {
            ClientCompatibility::Covered
        } else {
            ClientCompatibility::NotCovered
        }
    }

    /// Refuse a client this package's compatibility list does not cover.
    pub fn admit_client(&self, client_version: &str) -> Result<(), ApplicationFailure> {
        match self
            .client_compatibility(client_version)
            .refusal(&self.id, client_version)
        {
            Some(failure) => Err(failure),
            None => Ok(()),
        }
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
        self.compatibility.validate()?;
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
            compatibility: Compatibility::new(["0"]),
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
            "compatibility": { "clientVersions": ["0"] },
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
            "compatibility": { "clientVersions": ["0"] },
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

    #[test]
    fn a_package_declares_the_client_versions_it_supports() {
        let mut package = manifest();
        package.compatibility = Compatibility::new(["0"]);
        assert!(package.validate().is_ok());
        assert_eq!(
            package.client_compatibility("0.3.0"),
            ClientCompatibility::Covered
        );
        assert_eq!(
            package.client_compatibility("0.4.9"),
            ClientCompatibility::Covered,
            "a whole major line is covered, not one exact build"
        );
        assert_eq!(
            package.client_compatibility("1.0.0"),
            ClientCompatibility::NotCovered
        );

        package.compatibility = Compatibility::new([">=0.3.0, <0.5.0"]);
        assert!(package.client_compatibility("0.3.0").is_covered());
        assert!(package.client_compatibility("0.4.99").is_covered());
        assert!(!package.client_compatibility("0.5.0").is_covered());
        assert!(!package.client_compatibility("0.2.9").is_covered());

        // A client identity this contract cannot read is covered by nothing.
        package.compatibility = Compatibility::new(["0"]);
        assert!(!package.client_compatibility("nightly").is_covered());
    }

    #[test]
    fn a_different_package_version_is_not_itself_a_refusal() {
        let mut supported = manifest();
        supported.version = "1.0.0".to_owned();
        supported.compatibility = Compatibility::new(["0"]);

        let mut also_supported = manifest();
        also_supported.version = "9.9.9".to_owned();
        also_supported.compatibility = Compatibility::new(["0"]);

        assert_eq!(
            supported.client_compatibility("0.3.0"),
            also_supported.client_compatibility("0.3.0"),
            "the package's own version takes no part in the decision"
        );
        assert!(supported.admit_client("0.3.0").is_ok());

        let mut unsupported = manifest();
        unsupported.version = "0.3.0".to_owned();
        unsupported.compatibility = Compatibility::new([">=99.0.0"]);
        let failure = unsupported
            .admit_client("0.3.0")
            .expect_err("the running client is outside the declared list");
        assert_eq!(failure.code, "package_client_incompatible");
        assert_eq!(failure.field.as_deref(), Some("compatibility"));
        assert_eq!(
            failure.presentation_args.get("clientVersion"),
            Some("0.3.0")
        );
        assert_eq!(
            failure.recovery,
            licoup_application::RecoveryAction::InstallOrRetryRuntime
        );
    }

    #[test]
    fn a_package_that_declares_no_usable_client_versions_is_refused() {
        let mut absent = manifest();
        absent.compatibility = Compatibility::default();
        assert_eq!(
            absent
                .validate()
                .expect_err("a package with no list is admitted by nothing")
                .field
                .as_deref(),
            Some("compatibility")
        );

        let mut malformed = manifest();
        malformed.compatibility = Compatibility::new(["not a range"]);
        assert_eq!(
            malformed
                .validate()
                .expect_err("a range this contract cannot read is not a declaration")
                .field
                .as_deref(),
            Some("compatibility")
        );

        let mut oversized = manifest();
        oversized.compatibility = Compatibility::new(["0".repeat(MAX_RANGE_BYTES + 1)]);
        assert_eq!(
            oversized
                .validate()
                .expect_err("a bound the schema publishes is a bound here")
                .field
                .as_deref(),
            Some("compatibility")
        );
    }

    #[test]
    fn a_manifest_that_carries_no_compatibility_list_is_read_and_refused() {
        let wire = serde_json::json!({
            "schema": crate::wire::MANIFEST,
            "id": "example.specialist.echo",
            "version": "1.0.0",
            "displayName": "Echo specialist",
            "hostProtocol": { "major": 1, "minimumMinor": 0 },
            "profiles": [],
            "runtime": { "mode": "process", "entry": "agent.py" },
        });
        let failure = PackageManifest::from_value(wire).expect_err("no compatibility list");
        assert_eq!(failure.code, "manifest_invalid");
        assert_eq!(failure.field.as_deref(), Some("compatibility"));
    }
}
