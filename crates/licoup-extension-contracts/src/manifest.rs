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
//!
//! `conversion` is a fourth claim, and the one that says which persisted formats
//! the package owns ([`ConversionDeclaration`]). A package that converts data
//! publishes the source formats it reads, the target format it produces and the
//! native entry inside its own payload that performs the move. It is absent from
//! a package that owns no format, so the field is optional; a *required*
//! conversion is refused when the package that was asked for it declares none
//! ([`PackageManifest::conversion_owner`]). The declaration names format
//! identities, never a client version: which client builds may load a package is
//! `compatibility`, and which formats it converts is this field.

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

/// The longest converter entry or format identity accepted, in bytes.
pub const MAX_CONVERTER_ENTRY_BYTES: usize = 160;

/// The longest published format identity accepted, in bytes.
pub const MAX_FORMAT_BYTES: usize = 160;

/// The most source formats one converter may declare.
///
/// A bound is published rather than implied: a converter that reads more than
/// this is a catalog, not one package's endpoint set.
pub const MAX_SOURCE_FORMATS: usize = 8;

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

/// The stable codes a conversion refusal is reported with.
///
/// They are published values rather than private strings: a caller that has to
/// report "this package does not own that conversion" maps them to its own
/// vocabulary without restating the rule, and each one names the field it read.
pub mod conversion_code {
    /// The package declares no conversion at all.
    pub const MISSING: &str = "manifest_conversion_missing";
    /// The declared converter kind is not a native executable.
    pub const NOT_NATIVE: &str = "manifest_converter_not_native";
    /// The declared entry is not an entry inside the package payload.
    pub const ENTRY_OUTSIDE_PACKAGE: &str = "manifest_converter_entry_outside_package";
    /// The declaration is present and incomplete.
    pub const INCOMPLETE: &str = "manifest_conversion_incomplete";
    /// The declaration is malformed, duplicated or over a published bound.
    pub const INVALID: &str = "manifest_conversion_invalid";
    /// The declared formats are not the pair the caller requires.
    pub const ENDPOINT_MISMATCH: &str = "manifest_conversion_endpoint_mismatch";
}

/// How a package performs one format conversion.
///
/// One kind is published, and the reason is the same one that makes the release
/// index refuse an interpreter for an official package: the package carries the
/// program. A converter that needs a runtime the package does not carry would
/// borrow the client's own runtime, and the migration would then depend on what
/// happens to be installed instead of on the package that declared the format.
#[derive(Clone, Copy, Debug, Default, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum ConverterKind {
    /// A program inside the package payload, run directly by its host.
    NativeExecutable,
    /// A kind this contract does not publish. It is read rather than rejected at
    /// parse time so the refusal names the rule — which converter kinds exist —
    /// instead of reporting an unreadable manifest. It is never a valid
    /// declaration.
    #[default]
    #[serde(other)]
    Unsupported,
}

impl ConverterKind {
    /// The wire string this kind is published as.
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::NativeExecutable => "native-executable",
            Self::Unsupported => "unsupported",
        }
    }
}

/// A published format identity: lowercase alphanumeric words joined by `.` or
/// `-`, such as `licoup.conversation.v1` or `licoup-state-0.1.1`.
///
/// It is an identity, not a version of the client: two format names are equal or
/// they are not, and nothing here orders them.
pub fn is_format_identity(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= MAX_FORMAT_BYTES
        && value.split(['.', '-']).all(|word| {
            !word.is_empty()
                && word
                    .bytes()
                    .all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit())
        })
}

/// Whether one value is an entry inside the package payload.
///
/// An entry is a relative path with at least one directory component. It never
/// starts at the root, never climbs out of the package and never carries a
/// backslash: an entry that leaves the payload is not this package's entry, and
/// the published release declaration refuses exactly the same shapes.
pub fn is_converter_entry(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= MAX_CONVERTER_ENTRY_BYTES
        && value.contains('/')
        && value.split('/').all(|segment| {
            segment.split('.').all(|word| {
                !word.is_empty()
                    && word
                        .bytes()
                        .all(|byte| byte.is_ascii_alphanumeric() || byte == b'_' || byte == b'-')
            })
        })
}

/// The native format conversion a package provides.
///
/// It answers one question: given a persisted format, which package owns moving
/// it to which produced format, and where is the program that does it. It is a
/// claim about the package's own payload, so it is read here and verified against
/// those bytes by packaging and by the host that installs them.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ConversionDeclaration {
    /// The converter kind. Only [`ConverterKind::NativeExecutable`] is valid.
    #[serde(default)]
    pub kind: ConverterKind,
    /// The converter entry, relative to the package root.
    #[serde(default)]
    pub entry: String,
    /// The published source formats this converter reads.
    #[serde(default)]
    pub source_formats: Vec<String>,
    /// The published target format it produces.
    #[serde(default)]
    pub target_format: String,
}

impl ConversionDeclaration {
    pub fn new(
        entry: impl Into<String>,
        source_formats: impl IntoIterator<Item = impl Into<String>>,
        target_format: impl Into<String>,
    ) -> Self {
        Self {
            kind: ConverterKind::NativeExecutable,
            entry: entry.into(),
            source_formats: source_formats.into_iter().map(Into::into).collect(),
            target_format: target_format.into(),
        }
    }

    /// Whether this converter reads one published source format.
    pub fn converts_from(&self, source_format: &str) -> bool {
        self.source_formats
            .iter()
            .any(|declared| declared == source_format)
    }

    /// Structural validation of one declaration.
    ///
    /// Every refusal names the rule it broke, so a package author learns which
    /// field to correct instead of that "the manifest is invalid".
    pub fn validate(&self) -> Result<(), ApplicationFailure> {
        if self.kind != ConverterKind::NativeExecutable {
            return Err(
                refusal::new(conversion_code::NOT_NATIVE, STAGE).with_field("conversion.kind")
            );
        }
        if !is_converter_entry(&self.entry) {
            return Err(refusal::new(conversion_code::ENTRY_OUTSIDE_PACKAGE, STAGE)
                .with_field("conversion.entry"));
        }
        if self.source_formats.is_empty() {
            return Err(refusal::new(conversion_code::INCOMPLETE, STAGE)
                .with_field("conversion.sourceFormats"));
        }
        if self.source_formats.len() > MAX_SOURCE_FORMATS
            || !self
                .source_formats
                .iter()
                .all(|format| is_format_identity(format))
        {
            return Err(refusal::new(conversion_code::INVALID, STAGE)
                .with_field("conversion.sourceFormats"));
        }
        let mut unique = self.source_formats.clone();
        unique.sort();
        unique.dedup();
        if unique.len() != self.source_formats.len() {
            return Err(refusal::new(conversion_code::INVALID, STAGE)
                .with_field("conversion.sourceFormats"));
        }
        if !is_format_identity(&self.target_format) {
            return Err(refusal::new(conversion_code::INCOMPLETE, STAGE)
                .with_field("conversion.targetFormat"));
        }
        // One format cannot be both endpoints of the same conversion: a converter
        // that produced the format it reads would have nothing to move.
        if self
            .source_formats
            .iter()
            .any(|format| format == &self.target_format)
        {
            return Err(
                refusal::new(conversion_code::INVALID, STAGE).with_field("conversion.targetFormat")
            );
        }
        Ok(())
    }
}

/// The source and target formats one required conversion spans.
///
/// A caller that needs a conversion names the pair it requires; the package then
/// answers whether it owns that pair. The pair is an identity pair, never a
/// client version, so a caller can require the same conversion of a package
/// released independently of the client it runs on.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct FrozenEndpoints {
    source_format: String,
    target_format: String,
}

impl FrozenEndpoints {
    pub fn new(source_format: impl Into<String>, target_format: impl Into<String>) -> Self {
        Self {
            source_format: source_format.into(),
            target_format: target_format.into(),
        }
    }

    /// The format a required conversion reads.
    pub fn source_format(&self) -> &str {
        &self.source_format
    }

    /// The format a required conversion produces.
    pub fn target_format(&self) -> &str {
        &self.target_format
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
    /// The native format conversion this package provides, when it provides one.
    /// A package that owns no persisted format carries nothing here, so an
    /// absent field is complete rather than an empty declaration.
    #[serde(default)]
    pub conversion: Option<ConversionDeclaration>,
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

    /// The declaration that owns one required conversion, or the refusal that
    /// says this package does not.
    ///
    /// This is the question a migration caller asks, and it is deliberately not
    /// the same question as [`PackageManifest::admit_client`]: which client builds
    /// may load a package and which formats it owns are separate claims, so a
    /// package whose compatibility list covers nothing is still the owner of the
    /// formats it declares. A package that declares no conversion at all is
    /// refused here — the conversion was required, and this package does not
    /// provide it — with the package and the source format named so the caller
    /// knows which package to obtain instead.
    pub fn conversion_owner(
        &self,
        endpoints: &FrozenEndpoints,
    ) -> Result<&ConversionDeclaration, ApplicationFailure> {
        let Some(declaration) = self.conversion.as_ref() else {
            return Err(
                refusal::actionable(conversion_code::MISSING, STAGE, "conversion")
                    .with_presentation_arg("package", &self.id)
                    .with_presentation_arg("sourceFormat", endpoints.source_format()),
            );
        };
        if !declaration.converts_from(endpoints.source_format()) {
            return Err(refusal::actionable(
                conversion_code::ENDPOINT_MISMATCH,
                STAGE,
                "conversion.sourceFormats",
            )
            .with_presentation_arg("package", &self.id)
            .with_presentation_arg("sourceFormat", endpoints.source_format()));
        }
        if declaration.target_format != endpoints.target_format() {
            return Err(refusal::actionable(
                conversion_code::ENDPOINT_MISMATCH,
                STAGE,
                "conversion.targetFormat",
            )
            .with_presentation_arg("package", &self.id)
            .with_presentation_arg("targetFormat", endpoints.target_format()));
        }
        Ok(declaration)
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
        if let Some(conversion) = self.conversion.as_ref() {
            conversion.validate()?;
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
            compatibility: Compatibility::new(["0"]),
            conversion: None,
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

    /// The frozen pair a migration caller requires of a converter.
    fn endpoints() -> FrozenEndpoints {
        FrozenEndpoints::new("agent-session.v2", "licoup.conversation.v1")
    }

    fn conversion() -> ConversionDeclaration {
        ConversionDeclaration::new(
            "bin/licoup-kilo-converter",
            ["agent-session.v2", "agent-session.v1"],
            "licoup.conversation.v1",
        )
    }

    #[test]
    fn a_package_declares_the_conversion_it_owns_and_round_trips_it() {
        let mut package = manifest();
        package.conversion = Some(conversion());
        assert!(package.validate().is_ok());

        let wire = serde_json::to_value(&package).expect("serialize");
        assert_eq!(
            wire["conversion"],
            serde_json::json!({
                "kind": "native-executable",
                "entry": "bin/licoup-kilo-converter",
                "sourceFormats": ["agent-session.v2", "agent-session.v1"],
                "targetFormat": "licoup.conversation.v1",
            }),
            "the declaration publishes the release index's converter vocabulary"
        );
        let read = PackageManifest::from_value(wire).expect("the manifest reads back");
        assert_eq!(read, package, "a declared conversion round-trips");

        let declaration = package
            .conversion_owner(&endpoints())
            .expect("the package owns the required conversion");
        assert!(declaration.converts_from("agent-session.v1"));
        assert!(!declaration.converts_from("agent-session.v3"));
        assert_eq!(declaration.entry, "bin/licoup-kilo-converter");
        assert_eq!(declaration.kind, ConverterKind::NativeExecutable);
    }

    #[test]
    fn a_manifest_that_owns_no_format_carries_no_declaration_and_is_admitted() {
        // The field is optional: most packages convert nothing, and refusing them
        // for not publishing a conversion would refuse the ordinary package. Only
        // a package that was *asked* for a conversion and declares none is refused.
        let package = manifest();
        assert!(package.conversion.is_none());
        assert!(package.validate().is_ok());

        let failure = package
            .conversion_owner(&endpoints())
            .expect_err("the required conversion has no owner here");
        assert_eq!(failure.code, "manifest_conversion_missing");
        assert_eq!(failure.field.as_deref(), Some("conversion"));
        assert_eq!(
            failure.presentation_args.get("package"),
            Some("example.specialist.echo")
        );
        assert_eq!(
            failure.presentation_args.get("sourceFormat"),
            Some("agent-session.v2")
        );
        assert_eq!(
            failure.recovery,
            licoup_application::RecoveryAction::InstallOrRetryRuntime
        );
    }

    #[test]
    fn a_conversion_declaration_refuses_each_invalid_shape() {
        // An interpreter is not a converter: the package would borrow a runtime
        // it does not carry.
        let mut interpreter = conversion();
        interpreter.kind = ConverterKind::Unsupported;
        let failure = interpreter.validate().expect_err("not native");
        assert_eq!(failure.code, "manifest_converter_not_native");
        assert_eq!(failure.field.as_deref(), Some("conversion.kind"));

        // The same refusal answers a wire declaration that names an interpreter,
        // rather than reporting the manifest as unreadable.
        let mut wire = serde_json::to_value(manifest()).expect("serialize");
        wire["conversion"] = serde_json::json!({
            "kind": "node-module",
            "entry": "bin/convert.js",
            "sourceFormats": ["agent-session.v2"],
            "targetFormat": "licoup.conversation.v1",
        });
        let failure =
            PackageManifest::from_value(wire).expect_err("an interpreter is not a converter");
        assert_eq!(failure.code, "manifest_converter_not_native");
        assert_eq!(failure.field.as_deref(), Some("conversion.kind"));

        // An entry outside the package payload is not this package's entry.
        for escaping in [
            "/usr/local/bin/convert",
            "../outside/convert",
            "bin/../../convert",
            "bin\\convert.exe",
            "convert",
        ] {
            let mut entry = conversion();
            entry.entry = escaping.to_owned();
            let failure = entry.validate().expect_err(escaping);
            assert_eq!(
                failure.code, "manifest_converter_entry_outside_package",
                "{escaping} must not be accepted as a package entry"
            );
        }

        // A converter that reads nothing converts nothing.
        let mut no_sources = conversion();
        no_sources.source_formats = Vec::new();
        let failure = no_sources.validate().expect_err("no source formats");
        assert_eq!(failure.code, "manifest_conversion_incomplete");
        assert_eq!(failure.field.as_deref(), Some("conversion.sourceFormats"));

        // A missing target format is an incomplete declaration, named as such.
        let mut no_target = conversion();
        no_target.target_format = String::new();
        let failure = no_target.validate().expect_err("no target format");
        assert_eq!(failure.code, "manifest_conversion_incomplete");
        assert_eq!(failure.field.as_deref(), Some("conversion.targetFormat"));

        // A format that is not an identity is not a published format.
        let mut malformed = conversion();
        malformed.source_formats = vec!["Agent Session v2".to_owned()];
        assert_eq!(
            malformed.validate().expect_err("not an identity").code,
            "manifest_conversion_invalid"
        );

        // A converter cannot produce the format it reads.
        let mut circular = conversion();
        circular.target_format = "agent-session.v1".to_owned();
        let failure = circular.validate().expect_err("circular conversion");
        assert_eq!(failure.code, "manifest_conversion_invalid");
        assert_eq!(failure.field.as_deref(), Some("conversion.targetFormat"));

        // The published bound is a bound here too.
        let mut oversized = conversion();
        oversized.source_formats = (0..=MAX_SOURCE_FORMATS)
            .map(|index| format!("agent-session.v{index}"))
            .collect();
        assert_eq!(
            oversized.validate().expect_err("over the bound").code,
            "manifest_conversion_invalid"
        );

        let mut duplicated = conversion();
        duplicated.source_formats =
            vec!["agent-session.v1".to_owned(), "agent-session.v1".to_owned()];
        assert_eq!(
            duplicated.validate().expect_err("duplicate").code,
            "manifest_conversion_invalid"
        );
    }

    #[test]
    fn a_declared_conversion_the_caller_did_not_require_is_refused_by_endpoint() {
        let mut package = manifest();
        package.conversion = Some(conversion());

        let wrong_source = FrozenEndpoints::new("agent-session.v3", "licoup.conversation.v1");
        let failure = package
            .conversion_owner(&wrong_source)
            .expect_err("this converter does not read that format");
        assert_eq!(failure.code, "manifest_conversion_endpoint_mismatch");
        assert_eq!(failure.field.as_deref(), Some("conversion.sourceFormats"));

        let wrong_target = FrozenEndpoints::new("agent-session.v2", "licoup.conversation.v2");
        let failure = package
            .conversion_owner(&wrong_target)
            .expect_err("this converter does not produce that format");
        assert_eq!(failure.code, "manifest_conversion_endpoint_mismatch");
        assert_eq!(failure.field.as_deref(), Some("conversion.targetFormat"));
    }

    #[test]
    fn which_client_may_load_a_package_takes_no_part_in_which_formats_it_owns() {
        // The two claims are independent: a package released for another client
        // line still owns its formats, and owning no format is not a client
        // compatibility question either.
        let mut future = manifest();
        future.conversion = Some(conversion());
        future.compatibility = Compatibility::new([">=99.0.0"]);
        assert!(!future.client_compatibility("0.3.0").is_covered());
        assert!(future.conversion_owner(&endpoints()).is_ok());
        assert_eq!(
            future.conversion_owner(&endpoints()).expect("owner").entry,
            "bin/licoup-kilo-converter"
        );
    }

    #[test]
    fn an_absent_conversion_in_a_wire_manifest_is_read_rather_than_refused_at_parse_time() {
        let wire = serde_json::json!({
            "schema": crate::wire::MANIFEST,
            "id": "example.specialist.echo",
            "version": "1.0.0",
            "displayName": "Echo specialist",
            "hostProtocol": { "major": 1, "minimumMinor": 0 },
            "compatibility": { "clientVersions": ["0"] },
            "profiles": [],
            "runtime": { "mode": "process", "entry": "agent.py" },
        });
        let package = PackageManifest::from_value(wire).expect("an optional field may be absent");
        assert!(package.conversion.is_none());
    }
}
