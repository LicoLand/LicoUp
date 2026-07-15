use anyhow::{Result, anyhow, ensure};
use serde::{Deserialize, Deserializer, Serialize, Serializer};
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, BTreeSet};
use std::sync::OnceLock;

const CAPABILITY_CATALOG_JSON: &str =
    include_str!("../../resources/secure-mesh-capability-catalog.json");
const CAPABILITY_CATALOG_SCHEMA_VERSION: u32 = 1;
pub const CAPABILITY_REPORT_SCHEMA_VERSION: u32 = 1;

#[derive(Clone, Copy, Debug, Eq, Hash, Ord, PartialEq, PartialOrd)]
pub enum SecurityCapability {
    AuthenticatedEncryption,
    CompleteAadBinding,
    EndpointIdentityAuthentication,
    VerifyBeforeSend,
    ReplayDuplicateRejection,
    ExpiryRollbackRejection,
    RatchetForwardSecrecy,
    EncryptedRelayHeaders,
    AuthenticatedPadding,
    PlaintextFallbackForbidden,
    SecureSessionFoundation,
    MemoryOnlyEphemeral,
    OsSecureStore,
    SoftwareBacked,
    NonExportable,
    DeviceBound,
    UnlockedDeviceRequired,
    OsUserPresence,
    DeviceCredential,
    StrongBiometric,
    AuthenticationValidityWindow,
    EnrollmentChangeInvalidation,
    HardwareBacked,
    HardwareEnforcedUserAuthentication,
    AndroidKeystore,
    AppleKeychain,
    LinuxSecretService,
    DataProtectionKeychain,
    Tee,
    Strongbox,
    SecureEnclave,
}

impl SecurityCapability {
    pub const COUNT: usize = 31;
    pub const ALL: [Self; Self::COUNT] = [
        Self::AuthenticatedEncryption,
        Self::CompleteAadBinding,
        Self::EndpointIdentityAuthentication,
        Self::VerifyBeforeSend,
        Self::ReplayDuplicateRejection,
        Self::ExpiryRollbackRejection,
        Self::RatchetForwardSecrecy,
        Self::EncryptedRelayHeaders,
        Self::AuthenticatedPadding,
        Self::PlaintextFallbackForbidden,
        Self::SecureSessionFoundation,
        Self::MemoryOnlyEphemeral,
        Self::OsSecureStore,
        Self::SoftwareBacked,
        Self::NonExportable,
        Self::DeviceBound,
        Self::UnlockedDeviceRequired,
        Self::OsUserPresence,
        Self::DeviceCredential,
        Self::StrongBiometric,
        Self::AuthenticationValidityWindow,
        Self::EnrollmentChangeInvalidation,
        Self::HardwareBacked,
        Self::HardwareEnforcedUserAuthentication,
        Self::AndroidKeystore,
        Self::AppleKeychain,
        Self::LinuxSecretService,
        Self::DataProtectionKeychain,
        Self::Tee,
        Self::Strongbox,
        Self::SecureEnclave,
    ];

    pub const fn id(self) -> &'static str {
        match self {
            Self::AuthenticatedEncryption => "protocol.authenticated_encryption",
            Self::CompleteAadBinding => "protocol.complete_aad_binding",
            Self::EndpointIdentityAuthentication => "protocol.endpoint_identity_authentication",
            Self::VerifyBeforeSend => "protocol.verify_before_send",
            Self::ReplayDuplicateRejection => "protocol.replay_duplicate_rejection",
            Self::ExpiryRollbackRejection => "protocol.expiry_rollback_rejection",
            Self::RatchetForwardSecrecy => "protocol.ratchet_forward_secrecy",
            Self::EncryptedRelayHeaders => "protocol.encrypted_relay_headers",
            Self::AuthenticatedPadding => "protocol.authenticated_padding",
            Self::PlaintextFallbackForbidden => "protocol.plaintext_fallback_forbidden",
            Self::SecureSessionFoundation => "protocol.secure_session_foundation",
            Self::MemoryOnlyEphemeral => "custody.memory_only_ephemeral",
            Self::OsSecureStore => "custody.os_secure_store",
            Self::SoftwareBacked => "custody.software_backed",
            Self::NonExportable => "custody.non_exportable",
            Self::DeviceBound => "custody.device_bound",
            Self::UnlockedDeviceRequired => "custody.unlocked_device_required",
            Self::OsUserPresence => "custody.os_user_presence",
            Self::DeviceCredential => "custody.device_credential",
            Self::StrongBiometric => "custody.strong_biometric",
            Self::AuthenticationValidityWindow => "custody.authentication_validity_window",
            Self::EnrollmentChangeInvalidation => "custody.enrollment_change_invalidation",
            Self::HardwareBacked => "custody.hardware_backed",
            Self::HardwareEnforcedUserAuthentication => {
                "custody.hardware_enforced_user_authentication"
            }
            Self::AndroidKeystore => "custody.android_keystore",
            Self::AppleKeychain => "custody.apple_keychain",
            Self::LinuxSecretService => "custody.linux_secret_service",
            Self::DataProtectionKeychain => "custody.data_protection_keychain",
            Self::Tee => "custody.tee",
            Self::Strongbox => "custody.strongbox",
            Self::SecureEnclave => "custody.secure_enclave",
        }
    }

    pub fn from_id(id: &str) -> Result<Self> {
        Self::ALL
            .into_iter()
            .find(|capability| capability.id() == id)
            .ok_or_else(|| anyhow!("unknown secure mesh capability identifier"))
    }

    const fn index(self) -> usize {
        self as usize
    }
}

impl Serialize for SecurityCapability {
    fn serialize<S>(&self, serializer: S) -> std::result::Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        serializer.serialize_str(self.id())
    }
}

impl<'de> Deserialize<'de> for SecurityCapability {
    fn deserialize<D>(deserializer: D) -> std::result::Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        let id = String::deserialize(deserializer)?;
        Self::from_id(&id).map_err(serde::de::Error::custom)
    }
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum CapabilityScope {
    ProtocolSession,
    LocalCustody,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CapabilityDefinition {
    pub capability: SecurityCapability,
    pub scope: CapabilityScope,
    pub mandatory: bool,
    pub derived: bool,
    pub prerequisites: Vec<SecurityCapability>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
struct RawCapabilityCatalog {
    schema_version: u32,
    capabilities: Vec<RawCapabilityDefinition>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct RawCapabilityDefinition {
    id: String,
    scope: CapabilityScope,
    mandatory: bool,
    derived: bool,
    prerequisites: Vec<String>,
}

#[derive(Clone, Debug)]
pub struct CapabilityCatalog {
    schema_version: u32,
    digest: String,
    definitions: Vec<Option<CapabilityDefinition>>,
    topological_order: Vec<SecurityCapability>,
    edge_count: usize,
}

impl CapabilityCatalog {
    pub fn from_json(source: &str) -> Result<Self> {
        let raw: RawCapabilityCatalog = serde_json::from_str(source)
            .map_err(|_| anyhow!("secure mesh capability catalog schema is invalid"))?;
        ensure!(
            raw.schema_version == CAPABILITY_CATALOG_SCHEMA_VERSION,
            "secure mesh capability catalog version is unsupported"
        );
        ensure!(
            !raw.capabilities.is_empty(),
            "secure mesh capability catalog is empty"
        );

        let mut definitions = vec![None; SecurityCapability::COUNT];
        for raw_definition in raw.capabilities {
            let capability = SecurityCapability::from_id(&raw_definition.id)?;
            ensure!(
                definitions[capability.index()].is_none(),
                "secure mesh capability catalog contains a duplicate identifier"
            );
            let prerequisites = raw_definition
                .prerequisites
                .iter()
                .map(|id| SecurityCapability::from_id(id))
                .collect::<Result<Vec<_>>>()?;
            ensure!(
                !prerequisites.contains(&capability),
                "secure mesh capability cannot depend on itself"
            );
            let unique_prerequisites = prerequisites.iter().copied().collect::<BTreeSet<_>>();
            ensure!(
                unique_prerequisites.len() == prerequisites.len(),
                "secure mesh capability contains a duplicate prerequisite"
            );
            definitions[capability.index()] = Some(CapabilityDefinition {
                capability,
                scope: raw_definition.scope,
                mandatory: raw_definition.mandatory,
                derived: raw_definition.derived,
                prerequisites,
            });
        }

        for definition in definitions.iter().flatten() {
            for prerequisite in &definition.prerequisites {
                ensure!(
                    definitions[prerequisite.index()].is_some(),
                    "secure mesh capability prerequisite is missing from the catalog"
                );
            }
            ensure!(
                !(definition.mandatory && definition.scope != CapabilityScope::ProtocolSession),
                "only protocol capabilities may be mandatory"
            );
        }

        let (topological_order, edge_count) = validated_topological_order(&definitions)?;
        let digest = sha256_hex(source.as_bytes());
        Ok(Self {
            schema_version: raw.schema_version,
            digest,
            definitions,
            topological_order,
            edge_count,
        })
    }

    fn require_complete(&self) -> Result<()> {
        ensure!(
            self.definitions.iter().all(Option::is_some),
            "canonical secure mesh capability catalog is incomplete"
        );
        Ok(())
    }

    pub fn schema_version(&self) -> u32 {
        self.schema_version
    }

    pub fn digest(&self) -> &str {
        &self.digest
    }

    pub fn definition(&self, capability: SecurityCapability) -> Option<&CapabilityDefinition> {
        self.definitions[capability.index()].as_ref()
    }

    pub fn definitions(&self) -> impl Iterator<Item = &CapabilityDefinition> {
        self.topological_order
            .iter()
            .filter_map(|capability| self.definition(*capability))
    }

    pub fn topological_order(&self) -> &[SecurityCapability] {
        &self.topological_order
    }

    pub fn edge_count(&self) -> usize {
        self.edge_count
    }

    pub fn evaluate(&self, facts: &[CapabilityFact]) -> Result<CapabilityEvaluation> {
        let mut facts_by_index = vec![None; SecurityCapability::COUNT];
        for fact in facts {
            let definition = self.definition(fact.capability).ok_or_else(|| {
                anyhow!("secure mesh capability fact is not present in the catalog")
            })?;
            ensure!(
                !definition.derived,
                "secure mesh derived capability cannot be supplied as a platform fact"
            );
            validate_reason_code(fact.reason_code.as_deref())?;
            ensure!(
                facts_by_index[fact.capability.index()].is_none(),
                "secure mesh capability facts contain a duplicate identifier"
            );
            facts_by_index[fact.capability.index()] = Some(fact);
        }

        let mut enabled_flags = [false; SecurityCapability::COUNT];
        let mut enabled = BTreeSet::new();
        let mut available = BTreeSet::new();
        let mut unavailable = BTreeSet::new();
        let mut unverified = BTreeSet::new();
        let mut reasons = BTreeMap::new();
        let mut visited_node_count = 0usize;
        let mut traversed_edge_count = 0usize;

        for capability in &self.topological_order {
            visited_node_count = visited_node_count.saturating_add(1);
            let definition = self
                .definition(*capability)
                .ok_or_else(|| anyhow!("secure mesh capability definition is unavailable"))?;
            let mut dependencies_enabled = true;
            for prerequisite in &definition.prerequisites {
                traversed_edge_count = traversed_edge_count.saturating_add(1);
                dependencies_enabled &= enabled_flags[prerequisite.index()];
            }

            let fact = facts_by_index[capability.index()];
            let supported = if definition.derived {
                dependencies_enabled
            } else {
                fact.map(|fact| fact.state == CapabilityFactState::Supported)
                    .unwrap_or(false)
            };
            if supported {
                available.insert(*capability);
            }
            if supported && dependencies_enabled {
                enabled_flags[capability.index()] = true;
                enabled.insert(*capability);
                continue;
            }

            match fact.map(|fact| fact.state) {
                Some(CapabilityFactState::Unsupported)
                | Some(CapabilityFactState::TemporarilyUnavailable) => {
                    unavailable.insert(*capability);
                }
                Some(CapabilityFactState::Supported) if !dependencies_enabled => {
                    reasons.insert(*capability, "capability_dependency_unmet".to_string());
                }
                Some(CapabilityFactState::Unverified) | None => {
                    unverified.insert(*capability);
                }
                Some(CapabilityFactState::Supported) => {}
            }
            reasons.entry(*capability).or_insert_with(|| {
                fact.and_then(|fact| fact.reason_code.clone())
                    .unwrap_or_else(|| match fact.map(|fact| fact.state) {
                        Some(CapabilityFactState::Unsupported) => {
                            "capability_not_supported".to_string()
                        }
                        Some(CapabilityFactState::TemporarilyUnavailable) => {
                            "capability_temporarily_unavailable".to_string()
                        }
                        _ if definition.derived && !dependencies_enabled => {
                            "capability_dependency_unmet".to_string()
                        }
                        _ => "capability_unverified".to_string(),
                    })
            });
        }

        let missing_mandatory = self
            .definitions()
            .filter(|definition| definition.mandatory)
            .map(|definition| definition.capability)
            .filter(|capability| !enabled.contains(capability))
            .collect::<BTreeSet<_>>();
        let mandatory_foundation_complete = missing_mandatory.is_empty();
        let custody = custody_selection_from_enabled(&enabled);

        Ok(CapabilityEvaluation {
            catalog_digest: self.digest.clone(),
            enabled,
            available,
            unavailable,
            unverified,
            reasons,
            missing_mandatory,
            mandatory_foundation_complete,
            custody,
            visited_node_count,
            traversed_edge_count,
        })
    }
}

fn sha256_hex(bytes: &[u8]) -> String {
    Sha256::digest(bytes)
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

fn validated_topological_order(
    definitions: &[Option<CapabilityDefinition>],
) -> Result<(Vec<SecurityCapability>, usize)> {
    let mut indegree = vec![0usize; SecurityCapability::COUNT];
    let mut dependents = vec![Vec::<SecurityCapability>::new(); SecurityCapability::COUNT];
    let mut defined_count = 0usize;
    let mut edge_count = 0usize;
    for definition in definitions.iter().flatten() {
        defined_count = defined_count.saturating_add(1);
        indegree[definition.capability.index()] = definition.prerequisites.len();
        edge_count = edge_count.saturating_add(definition.prerequisites.len());
        for prerequisite in &definition.prerequisites {
            dependents[prerequisite.index()].push(definition.capability);
        }
    }
    for entries in &mut dependents {
        entries.sort_unstable();
    }

    let mut roots = definitions
        .iter()
        .flatten()
        .filter(|definition| indegree[definition.capability.index()] == 0)
        .map(|definition| definition.capability)
        .collect::<BTreeSet<_>>();
    let mut order = Vec::with_capacity(defined_count);
    while let Some(capability) = roots.pop_first() {
        order.push(capability);
        for dependent in &dependents[capability.index()] {
            indegree[dependent.index()] = indegree[dependent.index()].saturating_sub(1);
            if indegree[dependent.index()] == 0 {
                roots.insert(*dependent);
            }
        }
    }
    ensure!(
        order.len() == defined_count,
        "secure mesh capability catalog contains a dependency cycle"
    );
    Ok((order, edge_count))
}

static EMBEDDED_CAPABILITY_CATALOG: OnceLock<std::result::Result<CapabilityCatalog, String>> =
    OnceLock::new();

pub fn capability_catalog() -> Result<&'static CapabilityCatalog> {
    let catalog = EMBEDDED_CAPABILITY_CATALOG.get_or_init(|| {
        CapabilityCatalog::from_json(CAPABILITY_CATALOG_JSON)
            .and_then(|catalog| {
                catalog.require_complete()?;
                Ok(catalog)
            })
            .map_err(|error| error.to_string())
    });
    catalog
        .as_ref()
        .map_err(|_| anyhow!("canonical secure mesh capability catalog is invalid"))
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum CapabilityFactState {
    Supported,
    Unsupported,
    TemporarilyUnavailable,
    Unverified,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum CapabilityEvidenceKind {
    SourceContract,
    RuntimeOperation,
    GeneratedKeyInspection,
    OsAuthorization,
    TestFixture,
    NotMeasured,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct CapabilityFact {
    pub capability: SecurityCapability,
    pub state: CapabilityFactState,
    pub evidence_kind: CapabilityEvidenceKind,
    pub measured_at_unix_seconds: Option<i64>,
    pub reason_code: Option<String>,
}

impl CapabilityFact {
    pub fn supported(
        capability: SecurityCapability,
        evidence_kind: CapabilityEvidenceKind,
    ) -> Self {
        Self {
            capability,
            state: CapabilityFactState::Supported,
            evidence_kind,
            measured_at_unix_seconds: None,
            reason_code: None,
        }
    }

    pub fn unavailable(
        capability: SecurityCapability,
        state: CapabilityFactState,
        evidence_kind: CapabilityEvidenceKind,
        reason_code: impl Into<String>,
    ) -> Result<Self> {
        ensure!(
            matches!(
                state,
                CapabilityFactState::Unsupported
                    | CapabilityFactState::TemporarilyUnavailable
                    | CapabilityFactState::Unverified
            ),
            "unavailable capability fact cannot use the supported state"
        );
        let reason_code = reason_code.into();
        validate_reason_code(Some(&reason_code))?;
        Ok(Self {
            capability,
            state,
            evidence_kind,
            measured_at_unix_seconds: None,
            reason_code: Some(reason_code),
        })
    }
}

fn validate_reason_code(reason_code: Option<&str>) -> Result<()> {
    let Some(reason_code) = reason_code else {
        return Ok(());
    };
    ensure!(
        !reason_code.is_empty()
            && reason_code.len() <= 96
            && reason_code.bytes().all(|byte| byte.is_ascii_lowercase()
                || byte.is_ascii_digit()
                || b"._-".contains(&byte)),
        "secure mesh capability reason code is invalid"
    );
    Ok(())
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum SecretCustodyStrategy {
    MemoryOnlyEphemeral,
    OsSecureStore,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum CustodyRestartSemantics {
    RePairRekeyAfterRestart,
    PersistentStateAvailable,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct CustodySelection {
    pub strategy: SecretCustodyStrategy,
    pub restart_semantics: CustodyRestartSemantics,
    pub enabled_hardening: BTreeSet<SecurityCapability>,
}

pub(crate) fn custody_selection_from_enabled(
    enabled: &BTreeSet<SecurityCapability>,
) -> Option<CustodySelection> {
    if enabled.contains(&SecurityCapability::OsSecureStore) {
        return Some(CustodySelection {
            strategy: SecretCustodyStrategy::OsSecureStore,
            restart_semantics: CustodyRestartSemantics::PersistentStateAvailable,
            enabled_hardening: enabled
                .iter()
                .copied()
                .filter(|capability| capability.id().starts_with("custody."))
                .collect(),
        });
    }
    enabled
        .contains(&SecurityCapability::MemoryOnlyEphemeral)
        .then(|| CustodySelection {
            strategy: SecretCustodyStrategy::MemoryOnlyEphemeral,
            restart_semantics: CustodyRestartSemantics::RePairRekeyAfterRestart,
            enabled_hardening: BTreeSet::from([SecurityCapability::MemoryOnlyEphemeral]),
        })
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CapabilityEvaluation {
    catalog_digest: String,
    enabled: BTreeSet<SecurityCapability>,
    available: BTreeSet<SecurityCapability>,
    unavailable: BTreeSet<SecurityCapability>,
    unverified: BTreeSet<SecurityCapability>,
    reasons: BTreeMap<SecurityCapability, String>,
    missing_mandatory: BTreeSet<SecurityCapability>,
    mandatory_foundation_complete: bool,
    custody: Option<CustodySelection>,
    visited_node_count: usize,
    traversed_edge_count: usize,
}

impl CapabilityEvaluation {
    pub fn catalog_digest(&self) -> &str {
        &self.catalog_digest
    }

    pub fn enabled(&self) -> &BTreeSet<SecurityCapability> {
        &self.enabled
    }

    pub fn available(&self) -> &BTreeSet<SecurityCapability> {
        &self.available
    }

    pub fn unavailable(&self) -> &BTreeSet<SecurityCapability> {
        &self.unavailable
    }

    pub fn unverified(&self) -> &BTreeSet<SecurityCapability> {
        &self.unverified
    }

    pub fn reasons(&self) -> &BTreeMap<SecurityCapability, String> {
        &self.reasons
    }

    pub fn missing_mandatory(&self) -> &BTreeSet<SecurityCapability> {
        &self.missing_mandatory
    }

    pub fn mandatory_foundation_complete(&self) -> bool {
        self.mandatory_foundation_complete
    }

    pub fn custody(&self) -> Option<&CustodySelection> {
        self.custody.as_ref()
    }

    pub fn require_mandatory_foundation(&self) -> Result<()> {
        ensure!(
            self.mandatory_foundation_complete,
            "secure mesh mandatory capability foundation is incomplete"
        );
        Ok(())
    }

    pub fn report(&self) -> CapabilityEvaluationReport {
        CapabilityEvaluationReport {
            schema_version: CAPABILITY_REPORT_SCHEMA_VERSION,
            catalog_digest: self.catalog_digest.clone(),
            mandatory_foundation_complete: self.mandatory_foundation_complete,
            enabled: self.enabled.clone(),
            available: self.available.clone(),
            unavailable: self.unavailable.clone(),
            unverified: self.unverified.clone(),
            missing_mandatory: self.missing_mandatory.clone(),
            reasons: self
                .reasons
                .iter()
                .map(|(capability, reason)| (capability.id().to_string(), reason.clone()))
                .collect(),
            custody: self.custody.clone(),
        }
    }

    #[cfg(test)]
    fn evaluation_work(&self) -> (usize, usize) {
        (self.visited_node_count, self.traversed_edge_count)
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct CapabilityEvaluationReport {
    pub schema_version: u32,
    pub catalog_digest: String,
    pub mandatory_foundation_complete: bool,
    pub enabled: BTreeSet<SecurityCapability>,
    pub available: BTreeSet<SecurityCapability>,
    pub unavailable: BTreeSet<SecurityCapability>,
    pub unverified: BTreeSet<SecurityCapability>,
    pub missing_mandatory: BTreeSet<SecurityCapability>,
    pub reasons: BTreeMap<String, String>,
    pub custody: Option<CustodySelection>,
}

pub fn mandatory_protocol_facts(
    evidence_kind: CapabilityEvidenceKind,
) -> Result<Vec<CapabilityFact>> {
    let catalog = capability_catalog()?;
    Ok(catalog
        .definitions()
        .filter(|definition| definition.mandatory && !definition.derived)
        .map(|definition| CapabilityFact::supported(definition.capability, evidence_kind))
        .collect())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn all_supported_facts(catalog: &CapabilityCatalog) -> Vec<CapabilityFact> {
        catalog
            .definitions()
            .filter(|definition| !definition.derived)
            .map(|definition| {
                CapabilityFact::supported(
                    definition.capability,
                    CapabilityEvidenceKind::TestFixture,
                )
            })
            .collect()
    }

    fn baseline_facts() -> Vec<CapabilityFact> {
        mandatory_protocol_facts(CapabilityEvidenceKind::TestFixture).unwrap()
    }

    #[test]
    fn canonical_catalog_is_complete_acyclic_and_evaluates_in_linear_work() {
        let catalog = capability_catalog().unwrap();
        assert_eq!(catalog.definitions().count(), SecurityCapability::COUNT);
        let evaluation = catalog.evaluate(&all_supported_facts(catalog)).unwrap();
        assert_eq!(evaluation.enabled().len(), SecurityCapability::COUNT);
        assert_eq!(
            evaluation.evaluation_work(),
            (SecurityCapability::COUNT, catalog.edge_count())
        );
        assert!(evaluation.mandatory_foundation_complete());
    }

    #[test]
    fn canonical_topological_order_and_report_are_deterministic() {
        let first = CapabilityCatalog::from_json(CAPABILITY_CATALOG_JSON).unwrap();
        let second = CapabilityCatalog::from_json(CAPABILITY_CATALOG_JSON).unwrap();
        assert_eq!(first.topological_order(), second.topological_order());
        assert_eq!(first.digest(), second.digest());
        let facts = all_supported_facts(&first);
        let first_report = serde_json::to_vec(&first.evaluate(&facts).unwrap().report()).unwrap();
        let second_report = serde_json::to_vec(&second.evaluate(&facts).unwrap().report()).unwrap();
        assert_eq!(first_report, second_report);
    }

    #[test]
    fn catalog_rejects_cycles_missing_dependencies_duplicates_and_unknown_fields() {
        let cycle = r#"{
          "schemaVersion": 1,
          "capabilities": [
            {"id":"protocol.authenticated_encryption","scope":"protocol_session","mandatory":true,"derived":false,"prerequisites":["protocol.complete_aad_binding"]},
            {"id":"protocol.complete_aad_binding","scope":"protocol_session","mandatory":true,"derived":false,"prerequisites":["protocol.authenticated_encryption"]}
          ]
        }"#;
        assert!(CapabilityCatalog::from_json(cycle).is_err());

        let missing = r#"{
          "schemaVersion": 1,
          "capabilities": [
            {"id":"protocol.complete_aad_binding","scope":"protocol_session","mandatory":true,"derived":false,"prerequisites":["protocol.authenticated_encryption"]}
          ]
        }"#;
        assert!(CapabilityCatalog::from_json(missing).is_err());

        let duplicate = r#"{
          "schemaVersion": 1,
          "capabilities": [
            {"id":"protocol.authenticated_encryption","scope":"protocol_session","mandatory":true,"derived":false,"prerequisites":[]},
            {"id":"protocol.authenticated_encryption","scope":"protocol_session","mandatory":true,"derived":false,"prerequisites":[]}
          ]
        }"#;
        assert!(CapabilityCatalog::from_json(duplicate).is_err());

        let unknown_field = r#"{
          "schemaVersion": 1,
          "unknown": true,
          "capabilities": []
        }"#;
        assert!(CapabilityCatalog::from_json(unknown_field).is_err());
    }

    #[test]
    fn supported_nodes_auto_enable_and_fact_additions_are_monotonic() {
        let catalog = capability_catalog().unwrap();
        let base = catalog.evaluate(&baseline_facts()).unwrap();
        let mut expanded_facts = baseline_facts();
        expanded_facts.extend([
            CapabilityFact::supported(
                SecurityCapability::OsSecureStore,
                CapabilityEvidenceKind::TestFixture,
            ),
            CapabilityFact::supported(
                SecurityCapability::SoftwareBacked,
                CapabilityEvidenceKind::TestFixture,
            ),
            CapabilityFact::supported(
                SecurityCapability::LinuxSecretService,
                CapabilityEvidenceKind::TestFixture,
            ),
        ]);
        let expanded = catalog.evaluate(&expanded_facts).unwrap();
        assert!(base.enabled().is_subset(expanded.enabled()));
        assert!(
            expanded
                .enabled()
                .contains(&SecurityCapability::OsSecureStore)
        );
        assert!(
            expanded
                .enabled()
                .contains(&SecurityCapability::SoftwareBacked)
        );
        assert!(
            expanded
                .enabled()
                .contains(&SecurityCapability::LinuxSecretService)
        );
    }

    #[test]
    fn strongbox_and_tee_are_independent_hardware_environment_facts() {
        let catalog = capability_catalog().unwrap();
        let mut facts = baseline_facts();
        for capability in [
            SecurityCapability::OsSecureStore,
            SecurityCapability::NonExportable,
            SecurityCapability::DeviceBound,
            SecurityCapability::HardwareBacked,
            SecurityCapability::AndroidKeystore,
            SecurityCapability::Strongbox,
        ] {
            facts.push(CapabilityFact::supported(
                capability,
                CapabilityEvidenceKind::TestFixture,
            ));
        }
        let evaluation = catalog.evaluate(&facts).unwrap();
        assert!(
            evaluation
                .enabled()
                .contains(&SecurityCapability::Strongbox)
        );
        assert!(!evaluation.enabled().contains(&SecurityCapability::Tee));
    }

    #[test]
    fn missing_dependency_disables_only_the_node_and_its_dependents() {
        let catalog = capability_catalog().unwrap();
        let mut facts = baseline_facts();
        facts.push(CapabilityFact::supported(
            SecurityCapability::HardwareBacked,
            CapabilityEvidenceKind::TestFixture,
        ));
        facts.push(CapabilityFact::supported(
            SecurityCapability::Tee,
            CapabilityEvidenceKind::TestFixture,
        ));
        let evaluation = catalog.evaluate(&facts).unwrap();
        assert!(evaluation.mandatory_foundation_complete());
        assert!(
            evaluation
                .available()
                .contains(&SecurityCapability::HardwareBacked)
        );
        assert!(
            !evaluation
                .enabled()
                .contains(&SecurityCapability::HardwareBacked)
        );
        assert!(!evaluation.enabled().contains(&SecurityCapability::Tee));
        assert_eq!(
            evaluation
                .reasons()
                .get(&SecurityCapability::HardwareBacked),
            Some(&"capability_dependency_unmet".to_string())
        );
    }

    #[test]
    fn every_missing_mandatory_node_is_rejected_without_protocol_downgrade() {
        let catalog = capability_catalog().unwrap();
        let baseline = baseline_facts();
        for omitted in baseline.iter().map(|fact| fact.capability) {
            let facts = baseline
                .iter()
                .filter(|fact| fact.capability != omitted)
                .cloned()
                .collect::<Vec<_>>();
            let evaluation = catalog.evaluate(&facts).unwrap();
            assert!(!evaluation.mandatory_foundation_complete());
            assert!(evaluation.require_mandatory_foundation().is_err());
            assert!(evaluation.missing_mandatory().contains(&omitted));
        }
    }

    #[test]
    fn memory_only_and_software_os_store_are_both_safe_custody_strategies() {
        let catalog = capability_catalog().unwrap();
        let memory = catalog.evaluate(&baseline_facts()).unwrap();
        assert_eq!(
            memory.custody().map(|selection| selection.strategy),
            Some(SecretCustodyStrategy::MemoryOnlyEphemeral)
        );
        assert_eq!(
            memory
                .custody()
                .map(|selection| selection.restart_semantics),
            Some(CustodyRestartSemantics::RePairRekeyAfterRestart)
        );

        let mut os_facts = baseline_facts();
        os_facts.extend([
            CapabilityFact::supported(
                SecurityCapability::OsSecureStore,
                CapabilityEvidenceKind::TestFixture,
            ),
            CapabilityFact::supported(
                SecurityCapability::SoftwareBacked,
                CapabilityEvidenceKind::TestFixture,
            ),
        ]);
        let os_store = catalog.evaluate(&os_facts).unwrap();
        assert_eq!(
            os_store.custody().map(|selection| selection.strategy),
            Some(SecretCustodyStrategy::OsSecureStore)
        );
        assert_eq!(
            os_store
                .custody()
                .map(|selection| selection.restart_semantics),
            Some(CustodyRestartSemantics::PersistentStateAvailable)
        );
        assert!(
            !os_store
                .enabled()
                .contains(&SecurityCapability::HardwareBacked)
        );
    }

    #[test]
    fn all_fact_states_are_independent_and_reason_codes_are_redacted() {
        let catalog = capability_catalog().unwrap();
        let mut facts = baseline_facts();
        facts.extend([
            CapabilityFact::unavailable(
                SecurityCapability::Strongbox,
                CapabilityFactState::Unsupported,
                CapabilityEvidenceKind::GeneratedKeyInspection,
                "strongbox_not_supported",
            )
            .unwrap(),
            CapabilityFact::unavailable(
                SecurityCapability::OsUserPresence,
                CapabilityFactState::TemporarilyUnavailable,
                CapabilityEvidenceKind::OsAuthorization,
                "system_credential_not_configured",
            )
            .unwrap(),
            CapabilityFact::unavailable(
                SecurityCapability::SecureEnclave,
                CapabilityFactState::Unverified,
                CapabilityEvidenceKind::NotMeasured,
                "host_measurement_pending",
            )
            .unwrap(),
        ]);
        let evaluation = catalog.evaluate(&facts).unwrap();
        assert!(
            evaluation
                .unavailable()
                .contains(&SecurityCapability::Strongbox)
        );
        assert!(
            evaluation
                .unavailable()
                .contains(&SecurityCapability::OsUserPresence)
        );
        assert!(
            evaluation
                .unverified()
                .contains(&SecurityCapability::SecureEnclave)
        );
        assert!(
            CapabilityFact::unavailable(
                SecurityCapability::Tee,
                CapabilityFactState::Unsupported,
                CapabilityEvidenceKind::TestFixture,
                "contains forbidden whitespace",
            )
            .is_err()
        );
    }

    #[test]
    fn report_schema_rejects_unknown_fields_and_has_no_scalar_posture_grade() {
        let catalog = capability_catalog().unwrap();
        let report = catalog.evaluate(&baseline_facts()).unwrap().report();
        let encoded = serde_json::to_string(&report).unwrap();
        assert!(!encoded.contains("\"tier\""));
        assert!(!encoded.contains("\"level\""));
        let mut value = serde_json::to_value(report).unwrap();
        value
            .as_object_mut()
            .unwrap()
            .insert("unknown".to_string(), serde_json::json!(true));
        assert!(serde_json::from_value::<CapabilityEvaluationReport>(value).is_err());
    }
}
