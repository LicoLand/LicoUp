//! Local LLM-provider credential contracts.
//!
//! API-key bytes never appear in an inventory, configuration document, debug
//! projection, or command result. Platform custody owns persistence; the
//! gateway receives only a process-bound, revocable in-memory lease.

use anyhow::{Result, anyhow, ensure};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet};
use std::fmt;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use crate::core::secure_mesh_secret_store::SecretBytes;

pub const LLM_API_KEY_INVENTORY_SCHEMA: &str = "licoup.llm-api-key-inventory.v1";
pub const GATEWAY_CREDENTIAL_HANDOFF_SCHEMA: &str = "licoup.llm-gateway-credential-handoff.v1";
pub const MAX_LLM_API_KEYS: usize = 64;
pub const MAX_LLM_API_KEY_BYTES: usize = 8 * 1024;
pub const MAX_LLM_API_KEY_LABEL_BYTES: usize = 96;

const LEASE_VALIDATION_INTERVAL: Duration = Duration::from_secs(1);

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(crate) enum GatewayCredentialChange {
    CredentialCreated,
    CredentialDeleted,
    LeaseDaysChanged,
}

impl GatewayCredentialChange {
    pub(crate) fn revokes_active_leases(self) -> bool {
        matches!(self, Self::CredentialCreated | Self::CredentialDeleted)
    }
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, Hash, Ord, PartialEq, PartialOrd, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum LlmApiKeyProvider {
    Kimi,
    DeepSeek,
    Kilo,
}

impl LlmApiKeyProvider {
    pub const ALL: [Self; 3] = [Self::Kimi, Self::DeepSeek, Self::Kilo];

    pub fn as_str(self) -> &'static str {
        match self {
            Self::Kimi => "kimi",
            Self::DeepSeek => "deepseek",
            Self::Kilo => "kilo",
        }
    }

    pub fn display_name(self) -> &'static str {
        match self {
            Self::Kimi => "Kimi",
            Self::DeepSeek => "DeepSeek",
            Self::Kilo => "Kilo",
        }
    }
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(try_from = "u16", into = "u16")]
pub enum GatewayCredentialLeaseDays {
    Seven,
    Thirty,
    Sixty,
    Ninety,
    OneEighty,
    ThreeSixtyFive,
}

impl GatewayCredentialLeaseDays {
    pub fn days(self) -> u16 {
        match self {
            Self::Seven => 7,
            Self::Thirty => 30,
            Self::Sixty => 60,
            Self::Ninety => 90,
            Self::OneEighty => 180,
            Self::ThreeSixtyFive => 365,
        }
    }

    pub fn duration(self) -> Duration {
        Duration::from_secs(u64::from(self.days()) * 24 * 60 * 60)
    }
}

impl Default for GatewayCredentialLeaseDays {
    fn default() -> Self {
        Self::Seven
    }
}

impl TryFrom<u16> for GatewayCredentialLeaseDays {
    type Error = &'static str;

    fn try_from(value: u16) -> std::result::Result<Self, Self::Error> {
        match value {
            7 => Ok(Self::Seven),
            30 => Ok(Self::Thirty),
            60 => Ok(Self::Sixty),
            90 => Ok(Self::Ninety),
            180 => Ok(Self::OneEighty),
            365 => Ok(Self::ThreeSixtyFive),
            _ => Err("llm_api_key_lease_days_invalid"),
        }
    }
}

impl From<GatewayCredentialLeaseDays> for u16 {
    fn from(value: GatewayCredentialLeaseDays) -> Self {
        value.days()
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct LlmApiKeyMetadata {
    pub credential_id: String,
    pub provider: LlmApiKeyProvider,
    pub label: String,
    pub created_at_epoch_seconds: u64,
    /// Per-key storage validity chosen at creation time. Legacy entries
    /// written before validity existed deserialize as `None` and are treated
    /// as non-expiring until the owner sets a period through an update.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub expires_at_epoch_seconds: Option<u64>,
}

impl LlmApiKeyMetadata {
    pub fn validate(&self) -> Result<()> {
        ensure!(
            uuid::Uuid::parse_str(&self.credential_id)
                .is_ok_and(|value| value.to_string() == self.credential_id),
            "llm_api_key_credential_id_invalid"
        );
        validate_label(&self.label)?;
        ensure!(
            self.created_at_epoch_seconds > 0,
            "llm_api_key_created_at_invalid"
        );
        if let Some(expires_at) = self.expires_at_epoch_seconds {
            ensure!(expires_at > 0, "llm_api_key_expires_at_invalid");
        }
        Ok(())
    }

    pub fn is_expired(&self, now_epoch_seconds: u64) -> bool {
        self.expires_at_epoch_seconds
            .is_some_and(|expires_at| now_epoch_seconds >= expires_at)
    }

    /// Applies a rename and/or a validity extension. The new expiry counts
    /// from the later of "now" and the current expiry so extending an
    /// already-expired key reactivates it for the chosen full period.
    pub fn apply_update(
        &mut self,
        update: &LlmApiKeyCredentialUpdate,
        now_epoch_seconds: u64,
    ) -> Result<()> {
        if let Some(label) = &update.label {
            validate_label(label)?;
            self.label = label.clone();
        }
        if let Some(extension) = update.extension {
            let base = self
                .expires_at_epoch_seconds
                .map_or(now_epoch_seconds, |expires_at| {
                    expires_at.max(now_epoch_seconds)
                });
            self.expires_at_epoch_seconds = Some(
                base.checked_add(extension.duration().as_secs())
                    .ok_or_else(|| anyhow!("llm_api_key_expires_at_invalid"))?,
            );
        }
        self.validate()
    }
}

/// Owner-initiated metadata change: a new label and/or a validity extension.
/// At least one field must be present.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct LlmApiKeyCredentialUpdate {
    pub label: Option<String>,
    pub extension: Option<GatewayCredentialLeaseDays>,
}

impl LlmApiKeyCredentialUpdate {
    pub fn new(
        label: Option<String>,
        extension: Option<GatewayCredentialLeaseDays>,
    ) -> Result<Self> {
        ensure!(
            label.is_some() || extension.is_some(),
            "llm_api_key_update_empty"
        );
        if let Some(label) = &label {
            validate_label(label)?;
        }
        Ok(Self { label, extension })
    }
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LlmApiKeyInventory {
    pub schema_version: &'static str,
    pub lease_days: u16,
    pub entries: Vec<LlmApiKeyMetadata>,
}

impl LlmApiKeyInventory {
    pub fn new(
        lease_days: GatewayCredentialLeaseDays,
        mut entries: Vec<LlmApiKeyMetadata>,
    ) -> Result<Self> {
        ensure!(
            entries.len() <= MAX_LLM_API_KEYS,
            "llm_api_key_inventory_capacity_exceeded"
        );
        entries.sort_by(|left, right| {
            left.provider
                .cmp(&right.provider)
                .then_with(|| {
                    left.created_at_epoch_seconds
                        .cmp(&right.created_at_epoch_seconds)
                })
                .then_with(|| left.credential_id.cmp(&right.credential_id))
        });
        for entry in &entries {
            entry.validate()?;
        }
        Ok(Self {
            schema_version: LLM_API_KEY_INVENTORY_SCHEMA,
            lease_days: lease_days.days(),
            entries,
        })
    }

    /// Providers that still have at least one non-expired saved key.
    ///
    /// Gateway model projections use this set so a provider with no usable key
    /// never appears in agent-visible model lists or default routes.
    pub fn providers_with_usable_keys(&self, now_epoch_seconds: u64) -> BTreeSet<LlmApiKeyProvider> {
        self.entries
            .iter()
            .filter(|entry| !entry.is_expired(now_epoch_seconds))
            .map(|entry| entry.provider)
            .collect()
    }
}

pub struct NewLlmApiKey {
    provider: LlmApiKeyProvider,
    label: String,
    validity: GatewayCredentialLeaseDays,
    secret: SecretBytes,
}

impl NewLlmApiKey {
    pub fn new(
        provider: LlmApiKeyProvider,
        label: String,
        api_key: String,
        validity: GatewayCredentialLeaseDays,
    ) -> Result<Self> {
        validate_label(&label)?;
        validate_api_key(&api_key)?;
        let secret = SecretBytes::try_from_string(api_key)
            .map_err(|_| anyhow!("llm_api_key_secret_invalid"))?;
        Ok(Self {
            provider,
            label,
            validity,
            secret,
        })
    }

    pub fn provider(&self) -> LlmApiKeyProvider {
        self.provider
    }

    pub fn label(&self) -> &str {
        &self.label
    }

    pub fn validity(&self) -> GatewayCredentialLeaseDays {
        self.validity
    }

    pub(crate) fn into_secret(self) -> SecretBytes {
        self.secret
    }
}

impl fmt::Debug for NewLlmApiKey {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("NewLlmApiKey")
            .field("provider", &self.provider)
            .field("label", &self.label)
            .field("secret", &"[redacted]")
            .finish()
    }
}

pub trait GatewayCredentialEpochSource: Send + Sync {
    fn active_epoch(&self) -> Result<Option<String>>;
}

/// A portable, JSON-encodable projection of unlocked gateway credentials.
///
/// The handoff carries secret material between the unlocking process and one
/// gateway sidecar over an inherited file descriptor; it is never written to
/// disk. Parsing fails closed so a truncated or tampered document can never
/// become a partial credential set.
pub struct GatewayCredentialHandoff {
    credentials: BTreeMap<LlmApiKeyProvider, Vec<SecretBytes>>,
    lease_days: GatewayCredentialLeaseDays,
    epoch: String,
}

impl GatewayCredentialHandoff {
    pub(crate) fn providers(&self) -> impl Iterator<Item = LlmApiKeyProvider> + '_ {
        self.credentials.keys().copied()
    }

    pub(crate) fn new(
        credentials: BTreeMap<LlmApiKeyProvider, Vec<SecretBytes>>,
        lease_days: GatewayCredentialLeaseDays,
        epoch: String,
    ) -> Result<Self> {
        ensure!(
            uuid::Uuid::parse_str(&epoch).is_ok_and(|value| value.to_string() == epoch),
            "llm_api_key_lease_epoch_invalid"
        );
        ensure!(
            credentials.values().map(Vec::len).sum::<usize>() <= MAX_LLM_API_KEYS
                && credentials.values().all(|values| !values.is_empty()),
            "llm_api_key_lease_inventory_invalid"
        );
        Ok(Self {
            credentials,
            lease_days,
            epoch,
        })
    }

    /// Serialize the handoff as a closed JSON document. Secret bytes appear
    /// only as arrays of byte numbers; no serde derive touches secret-bearing
    /// types.
    pub fn to_json(&self) -> Result<Vec<u8>> {
        let credentials: Vec<serde_json::Value> = self
            .credentials
            .iter()
            .map(|(provider, keys)| {
                serde_json::json!({
                    "provider": provider.as_str(),
                    "keys": keys
                        .iter()
                        .map(|key| key.expose_bytes().to_vec())
                        .collect::<Vec<Vec<u8>>>(),
                })
            })
            .collect();
        let document = serde_json::json!({
            "schemaVersion": GATEWAY_CREDENTIAL_HANDOFF_SCHEMA,
            "leaseDays": self.lease_days.days(),
            "epoch": self.epoch,
            "credentials": credentials,
        });
        Ok(serde_json::to_vec(&document)?)
    }

    /// Parse and fully validate a handoff document. Every malformed shape
    /// fails closed with the same `llm_api_key_handoff_invalid` code.
    pub fn from_json(bytes: &[u8]) -> Result<Self> {
        let invalid = || anyhow!("llm_api_key_handoff_invalid");
        let value: serde_json::Value = serde_json::from_slice(bytes).map_err(|_| invalid())?;
        let object = value.as_object().ok_or_else(invalid)?;
        for key in object.keys() {
            ensure!(
                matches!(
                    key.as_str(),
                    "schemaVersion" | "leaseDays" | "epoch" | "credentials"
                ),
                "llm_api_key_handoff_invalid"
            );
        }
        ensure!(
            object
                .get("schemaVersion")
                .and_then(serde_json::Value::as_str)
                == Some(GATEWAY_CREDENTIAL_HANDOFF_SCHEMA),
            "llm_api_key_handoff_invalid"
        );
        let lease_days_value = object
            .get("leaseDays")
            .and_then(serde_json::Value::as_u64)
            .and_then(|value| u16::try_from(value).ok())
            .ok_or_else(invalid)?;
        let lease_days =
            GatewayCredentialLeaseDays::try_from(lease_days_value).map_err(|_| invalid())?;
        let epoch = object
            .get("epoch")
            .and_then(serde_json::Value::as_str)
            .ok_or_else(invalid)?
            .to_owned();
        ensure!(
            uuid::Uuid::parse_str(&epoch).is_ok_and(|value| value.to_string() == epoch),
            "llm_api_key_handoff_invalid"
        );
        let entries = object
            .get("credentials")
            .and_then(serde_json::Value::as_array)
            .ok_or_else(invalid)?;
        let mut credentials = BTreeMap::<LlmApiKeyProvider, Vec<SecretBytes>>::new();
        let mut total_keys = 0usize;
        for entry in entries {
            let provider_value = entry
                .get("provider")
                .and_then(serde_json::Value::as_str)
                .ok_or_else(invalid)?;
            let provider = LlmApiKeyProvider::ALL
                .into_iter()
                .find(|candidate| candidate.as_str() == provider_value)
                .ok_or_else(invalid)?;
            ensure!(
                !credentials.contains_key(&provider),
                "llm_api_key_handoff_invalid"
            );
            let keys = entry
                .get("keys")
                .and_then(serde_json::Value::as_array)
                .ok_or_else(invalid)?;
            ensure!(!keys.is_empty(), "llm_api_key_handoff_invalid");
            let mut secrets = Vec::with_capacity(keys.len());
            for key in keys {
                let key_bytes = key
                    .as_array()
                    .ok_or_else(invalid)?
                    .iter()
                    .map(|byte| {
                        byte.as_u64()
                            .and_then(|value| u8::try_from(value).ok())
                            .ok_or_else(invalid)
                    })
                    .collect::<Result<Vec<u8>>>()?;
                secrets.push(SecretBytes::try_from_bytes(key_bytes).map_err(|_| invalid())?);
            }
            total_keys += secrets.len();
            ensure!(
                total_keys <= MAX_LLM_API_KEYS,
                "llm_api_key_handoff_invalid"
            );
            credentials.insert(provider, secrets);
        }
        Self::new(credentials, lease_days, epoch)
    }
}

impl fmt::Debug for GatewayCredentialHandoff {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("GatewayCredentialHandoff")
            .field("provider_count", &self.credentials.len())
            .field("lease_days", &self.lease_days.days())
            .field("credentials", &"[redacted]")
            .finish()
    }
}

struct LeaseValidationState {
    checked_at: Option<Instant>,
    valid: bool,
}

/// A process-local snapshot of system-keyring credentials.
///
/// The lease never survives process exit. Its duration is an upper bound for
/// one running gateway process, not a persisted bypass of platform user
/// authentication.
pub struct GatewayCredentialLease {
    credentials: BTreeMap<LlmApiKeyProvider, Vec<SecretBytes>>,
    lease_days: GatewayCredentialLeaseDays,
    expires_at: Instant,
    epoch: String,
    epoch_source: Arc<dyn GatewayCredentialEpochSource>,
    validation: Mutex<LeaseValidationState>,
}

impl GatewayCredentialLease {
    /// A healthy local Gateway is allowed to run before any provider is
    /// connected. Model requests fail closed with CredentialUnavailable until
    /// an authorized handoff is installed by restarting the sidecar.
    pub fn disconnected() -> Self {
        Self {
            credentials: BTreeMap::new(),
            lease_days: GatewayCredentialLeaseDays::Seven,
            expires_at: Instant::now(),
            epoch: String::new(),
            epoch_source: Arc::new(DisconnectedEpochSource),
            validation: Mutex::new(LeaseValidationState {
                checked_at: None,
                valid: false,
            }),
        }
    }

    pub(crate) fn new(
        credentials: BTreeMap<LlmApiKeyProvider, Vec<SecretBytes>>,
        lease_days: GatewayCredentialLeaseDays,
        epoch: String,
        epoch_source: Arc<dyn GatewayCredentialEpochSource>,
    ) -> Result<Self> {
        ensure!(
            uuid::Uuid::parse_str(&epoch).is_ok_and(|value| value.to_string() == epoch),
            "llm_api_key_lease_epoch_invalid"
        );
        ensure!(
            credentials.values().map(Vec::len).sum::<usize>() <= MAX_LLM_API_KEYS
                && credentials.values().all(|values| !values.is_empty()),
            "llm_api_key_lease_inventory_invalid"
        );
        let expires_at = Instant::now()
            .checked_add(lease_days.duration())
            .ok_or_else(|| anyhow!("llm_api_key_lease_expiry_invalid"))?;
        Ok(Self {
            credentials,
            lease_days,
            expires_at,
            epoch,
            epoch_source,
            validation: Mutex::new(LeaseValidationState {
                checked_at: None,
                valid: false,
            }),
        })
    }

    pub fn lease_days(&self) -> GatewayCredentialLeaseDays {
        self.lease_days
    }

    /// Project the lease into a portable handoff, copying every secret so the
    /// lease itself keeps its own zeroizing bytes.
    pub fn handoff_projection(&self) -> Result<GatewayCredentialHandoff> {
        let credentials = self
            .credentials
            .iter()
            .map(|(provider, keys)| {
                (
                    *provider,
                    keys.iter()
                        .map(SecretBytes::copy_for_persistent_read)
                        .collect(),
                )
            })
            .collect();
        GatewayCredentialHandoff::new(credentials, self.lease_days, self.epoch.clone())
    }

    /// Rebuild a lease from a received handoff under the local epoch source.
    /// Construction reuses the same closed validations as a vault unlock.
    pub fn from_handoff(
        handoff: GatewayCredentialHandoff,
        epoch_source: Arc<dyn GatewayCredentialEpochSource>,
    ) -> Result<Self> {
        Self::new(
            handoff.credentials,
            handoff.lease_days,
            handoff.epoch,
            epoch_source,
        )
    }

    pub fn contains_provider(&self, provider: LlmApiKeyProvider) -> bool {
        self.credentials
            .get(&provider)
            .is_some_and(|values| !values.is_empty())
    }

    pub fn resolve(&self, provider: LlmApiKeyProvider) -> Result<SecretBytes> {
        let credential = self
            .credentials
            .get(&provider)
            .and_then(|values| values.first())
            .map(SecretBytes::copy_for_persistent_read)
            .ok_or_else(|| anyhow!("llm_api_key_credential_unavailable"))?;
        self.ensure_active()?;
        Ok(credential)
    }

    fn ensure_active(&self) -> Result<()> {
        ensure!(
            Instant::now() < self.expires_at,
            "llm_api_key_lease_expired"
        );
        let mut state = self
            .validation
            .lock()
            .map_err(|_| anyhow!("llm_api_key_lease_validation_unavailable"))?;
        if state
            .checked_at
            .is_some_and(|checked| checked.elapsed() < LEASE_VALIDATION_INTERVAL)
        {
            ensure!(state.valid, "llm_api_key_lease_revoked");
            return Ok(());
        }
        state.valid = self.epoch_source.active_epoch()?.as_deref() == Some(self.epoch.as_str());
        state.checked_at = Some(Instant::now());
        ensure!(state.valid, "llm_api_key_lease_revoked");
        Ok(())
    }
}

struct DisconnectedEpochSource;

impl GatewayCredentialEpochSource for DisconnectedEpochSource {
    fn active_epoch(&self) -> Result<Option<String>> {
        Ok(None)
    }
}

impl fmt::Debug for GatewayCredentialLease {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("GatewayCredentialLease")
            .field("provider_count", &self.credentials.len())
            .field("lease_days", &self.lease_days.days())
            .field("credentials", &"[redacted]")
            .finish()
    }
}

fn validate_label(label: &str) -> Result<()> {
    ensure!(
        label == label.trim()
            && !label.is_empty()
            && label.len() <= MAX_LLM_API_KEY_LABEL_BYTES
            && !label.chars().any(char::is_control),
        "llm_api_key_label_invalid"
    );
    Ok(())
}

fn validate_api_key(api_key: &str) -> Result<()> {
    ensure!(
        api_key == api_key.trim()
            && (12..=MAX_LLM_API_KEY_BYTES).contains(&api_key.len())
            && api_key.bytes().all(|byte| (0x21..=0x7e).contains(&byte)),
        "llm_api_key_secret_invalid"
    );
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex as StdMutex;

    #[derive(Default)]
    struct TestEpochSource(StdMutex<Option<String>>);

    impl GatewayCredentialEpochSource for TestEpochSource {
        fn active_epoch(&self) -> Result<Option<String>> {
            Ok(self.0.lock().unwrap().clone())
        }
    }

    #[test]
    fn providers_and_lease_days_are_closed() {
        assert_eq!(LlmApiKeyProvider::ALL.len(), 3);
        assert_eq!(LlmApiKeyProvider::Kilo.as_str(), "kilo");
        assert_eq!(LlmApiKeyProvider::Kilo.display_name(), "Kilo");
        assert_eq!(GatewayCredentialLeaseDays::try_from(7).unwrap().days(), 7);
        assert_eq!(GatewayCredentialLeaseDays::try_from(30).unwrap().days(), 30);
        assert_eq!(GatewayCredentialLeaseDays::try_from(60).unwrap().days(), 60);
        assert_eq!(GatewayCredentialLeaseDays::try_from(90).unwrap().days(), 90);
        assert_eq!(
            GatewayCredentialLeaseDays::try_from(180).unwrap().days(),
            180
        );
        assert_eq!(
            GatewayCredentialLeaseDays::try_from(365).unwrap().days(),
            365
        );
        assert!(GatewayCredentialLeaseDays::try_from(14).is_err());
    }

    #[test]
    fn lease_policy_changes_do_not_revoke_the_running_gateway() {
        assert!(!GatewayCredentialChange::LeaseDaysChanged.revokes_active_leases());
        assert!(GatewayCredentialChange::CredentialCreated.revokes_active_leases());
        assert!(GatewayCredentialChange::CredentialDeleted.revokes_active_leases());
    }

    #[test]
    fn disconnected_gateway_lease_fails_closed_without_authorization() {
        let lease = GatewayCredentialLease::disconnected();

        assert!(!lease.contains_provider(LlmApiKeyProvider::Kimi));
        assert_eq!(
            lease
                .resolve(LlmApiKeyProvider::Kimi)
                .unwrap_err()
                .to_string(),
            "llm_api_key_credential_unavailable"
        );
    }

    #[test]
    fn new_key_debug_and_inventory_never_include_secret_material() {
        let secret = ["fixture", "value", "12345"].join("-");
        let key = NewLlmApiKey::new(
            LlmApiKeyProvider::Kimi,
            "Primary".to_owned(),
            secret.clone(),
            GatewayCredentialLeaseDays::Thirty,
        )
        .unwrap();
        assert!(!format!("{key:?}").contains(secret.as_str()));
        let inventory = LlmApiKeyInventory::new(
            GatewayCredentialLeaseDays::Seven,
            vec![LlmApiKeyMetadata {
                credential_id: uuid::Uuid::new_v4().to_string(),
                provider: LlmApiKeyProvider::Kimi,
                label: "Primary".to_owned(),
                created_at_epoch_seconds: 1,
                expires_at_epoch_seconds: Some(1 + 30 * 24 * 60 * 60),
            }],
        )
        .unwrap();
        assert!(
            !serde_json::to_string(&inventory)
                .unwrap()
                .contains(secret.as_str())
        );
    }

    #[test]
    fn providers_with_usable_keys_skips_expired_entries() {
        let inventory = LlmApiKeyInventory::new(
            GatewayCredentialLeaseDays::Thirty,
            vec![
                LlmApiKeyMetadata {
                    credential_id: uuid::Uuid::new_v4().to_string(),
                    provider: LlmApiKeyProvider::Kimi,
                    label: "Active".to_owned(),
                    created_at_epoch_seconds: 100,
                    expires_at_epoch_seconds: Some(300),
                },
                LlmApiKeyMetadata {
                    credential_id: uuid::Uuid::new_v4().to_string(),
                    provider: LlmApiKeyProvider::Kilo,
                    label: "Expired".to_owned(),
                    created_at_epoch_seconds: 100,
                    expires_at_epoch_seconds: Some(200),
                },
            ],
        )
        .unwrap();
        let usable = inventory.providers_with_usable_keys(250);
        assert_eq!(usable, BTreeSet::from([LlmApiKeyProvider::Kimi]));
    }

    #[test]
    fn legacy_metadata_without_expiry_deserializes_as_non_expiring() {
        let id = uuid::Uuid::new_v4().to_string();
        let legacy = serde_json::json!({
            "credentialId": id,
            "provider": "kimi",
            "label": "Legacy",
            "createdAtEpochSeconds": 100
        });
        let metadata: LlmApiKeyMetadata = serde_json::from_value(legacy).unwrap();
        assert_eq!(metadata.expires_at_epoch_seconds, None);
        assert!(!metadata.is_expired(u64::MAX));
    }

    #[test]
    fn expiry_and_extension_semantics_are_deterministic() {
        let mut metadata = LlmApiKeyMetadata {
            credential_id: uuid::Uuid::new_v4().to_string(),
            provider: LlmApiKeyProvider::DeepSeek,
            label: "Share".to_owned(),
            created_at_epoch_seconds: 100,
            expires_at_epoch_seconds: Some(200),
        };
        assert!(!metadata.is_expired(199));
        assert!(metadata.is_expired(200));

        // Extension counts from the current expiry while it is still valid.
        let update =
            LlmApiKeyCredentialUpdate::new(None, Some(GatewayCredentialLeaseDays::Thirty)).unwrap();
        metadata.apply_update(&update, 150).unwrap();
        assert_eq!(
            metadata.expires_at_epoch_seconds,
            Some(200 + 30 * 24 * 60 * 60)
        );

        // Extension reactivates an expired key with a full period from now.
        let now = 1_000_000;
        metadata.expires_at_epoch_seconds = Some(200);
        metadata.apply_update(&update, now).unwrap();
        assert_eq!(
            metadata.expires_at_epoch_seconds,
            Some(now + 30 * 24 * 60 * 60)
        );
        assert!(!metadata.is_expired(now + 30 * 24 * 60 * 60 - 1));

        // Rename-only updates validate the label.
        let rename = LlmApiKeyCredentialUpdate::new(Some("Renamed".to_owned()), None).unwrap();
        metadata.apply_update(&rename, now).unwrap();
        assert_eq!(metadata.label, "Renamed");
        assert!(LlmApiKeyCredentialUpdate::new(None, None).is_err());
        assert!(LlmApiKeyCredentialUpdate::new(Some("  ".to_owned()), None).is_err());
    }

    #[test]
    fn lease_fails_closed_after_epoch_revocation() {
        let epoch = uuid::Uuid::new_v4().to_string();
        let source = Arc::new(TestEpochSource(StdMutex::new(Some(epoch.clone()))));
        let mut credentials = BTreeMap::new();
        credentials.insert(
            LlmApiKeyProvider::DeepSeek,
            vec![SecretBytes::try_from_string("synthetic-key-12345".to_owned()).unwrap()],
        );
        let lease = GatewayCredentialLease::new(
            credentials,
            GatewayCredentialLeaseDays::Seven,
            epoch,
            source.clone(),
        )
        .unwrap();
        assert_eq!(
            lease
                .resolve(LlmApiKeyProvider::DeepSeek)
                .unwrap()
                .expose_utf8()
                .unwrap(),
            "synthetic-key-12345"
        );
        *source.0.lock().unwrap() = None;
        lease.validation.lock().unwrap().checked_at = None;
        assert!(lease.resolve(LlmApiKeyProvider::DeepSeek).is_err());
    }

    fn handoff_test_credentials() -> BTreeMap<LlmApiKeyProvider, Vec<SecretBytes>> {
        let mut credentials = BTreeMap::new();
        credentials.insert(
            LlmApiKeyProvider::Kimi,
            vec![
                SecretBytes::try_from_string("synthetic-kimi-key-1".to_owned()).unwrap(),
                SecretBytes::try_from_string("synthetic-kimi-key-2".to_owned()).unwrap(),
            ],
        );
        credentials.insert(
            LlmApiKeyProvider::DeepSeek,
            vec![SecretBytes::try_from_string("synthetic-deepseek-key-1".to_owned()).unwrap()],
        );
        credentials.insert(
            LlmApiKeyProvider::Kilo,
            vec![SecretBytes::try_from_string("synthetic-kilo-key-1".to_owned()).unwrap()],
        );
        credentials
    }

    fn handoff_document(credentials: serde_json::Value) -> Vec<u8> {
        serde_json::to_vec(&serde_json::json!({
            "schemaVersion": GATEWAY_CREDENTIAL_HANDOFF_SCHEMA,
            "leaseDays": 30,
            "epoch": "11111111-1111-4111-8111-111111111111",
            "credentials": credentials,
        }))
        .unwrap()
    }

    fn assert_handoff_invalid(payload: &[u8]) {
        let error = GatewayCredentialHandoff::from_json(payload).unwrap_err();
        assert_eq!(error.to_string(), "llm_api_key_handoff_invalid");
    }

    #[test]
    fn handoff_round_trip_preserves_credentials_lease_days_and_epoch() {
        let epoch = uuid::Uuid::new_v4().to_string();
        let source = Arc::new(TestEpochSource(StdMutex::new(Some(epoch.clone()))));
        let lease = GatewayCredentialLease::new(
            handoff_test_credentials(),
            GatewayCredentialLeaseDays::Thirty,
            epoch.clone(),
            source.clone(),
        )
        .unwrap();
        let payload = lease.handoff_projection().unwrap().to_json().unwrap();
        assert!(String::from_utf8_lossy(&payload).contains(GATEWAY_CREDENTIAL_HANDOFF_SCHEMA));

        let parsed = GatewayCredentialHandoff::from_json(&payload).unwrap();
        assert_eq!(parsed.lease_days, GatewayCredentialLeaseDays::Thirty);
        assert_eq!(parsed.epoch, epoch);
        let kimi = &parsed.credentials[&LlmApiKeyProvider::Kimi];
        assert_eq!(kimi.len(), 2);
        assert_eq!(kimi[0].expose_bytes(), b"synthetic-kimi-key-1");
        assert_eq!(kimi[1].expose_bytes(), b"synthetic-kimi-key-2");
        let deepseek = &parsed.credentials[&LlmApiKeyProvider::DeepSeek];
        assert_eq!(deepseek.len(), 1);
        assert_eq!(deepseek[0].expose_bytes(), b"synthetic-deepseek-key-1");
        let kilo = &parsed.credentials[&LlmApiKeyProvider::Kilo];
        assert_eq!(kilo.len(), 1);
        assert_eq!(kilo[0].expose_bytes(), b"synthetic-kilo-key-1");

        let restored = GatewayCredentialLease::from_handoff(parsed, source).unwrap();
        assert_eq!(restored.lease_days(), GatewayCredentialLeaseDays::Thirty);
        assert_eq!(
            restored
                .resolve(LlmApiKeyProvider::Kimi)
                .unwrap()
                .expose_bytes(),
            b"synthetic-kimi-key-1"
        );
        assert_eq!(
            restored
                .resolve(LlmApiKeyProvider::DeepSeek)
                .unwrap()
                .expose_bytes(),
            b"synthetic-deepseek-key-1"
        );
        assert_eq!(
            restored
                .resolve(LlmApiKeyProvider::Kilo)
                .unwrap()
                .expose_bytes(),
            b"synthetic-kilo-key-1"
        );
    }

    #[test]
    fn handoff_rejects_malformed_documents() {
        let kimi_entry = serde_json::json!({"provider": "kimi", "keys": [[1, 2, 3]]});
        // Unparseable payload.
        assert_handoff_invalid(b"not-json");
        // Wrong schema version.
        let mut wrong_schema: serde_json::Value =
            serde_json::from_slice(&handoff_document(serde_json::json!([kimi_entry]))).unwrap();
        wrong_schema["schemaVersion"] = serde_json::json!("licoup.other.v1");
        assert_handoff_invalid(&serde_json::to_vec(&wrong_schema).unwrap());
        // Unknown top-level field.
        let mut extra_field: serde_json::Value =
            serde_json::from_slice(&handoff_document(serde_json::json!([kimi_entry]))).unwrap();
        extra_field["extra"] = serde_json::json!(true);
        assert_handoff_invalid(&serde_json::to_vec(&extra_field).unwrap());
        // Lease days outside the closed enum.
        let mut bad_lease_days: serde_json::Value =
            serde_json::from_slice(&handoff_document(serde_json::json!([kimi_entry]))).unwrap();
        bad_lease_days["leaseDays"] = serde_json::json!(14);
        assert_handoff_invalid(&serde_json::to_vec(&bad_lease_days).unwrap());
        // Non-canonical epoch.
        let mut bad_epoch: serde_json::Value =
            serde_json::from_slice(&handoff_document(serde_json::json!([kimi_entry]))).unwrap();
        bad_epoch["epoch"] = serde_json::json!("AAAAAAAA-1111-4111-8111-111111111111");
        assert_handoff_invalid(&serde_json::to_vec(&bad_epoch).unwrap());
        // Unknown provider.
        assert_handoff_invalid(&handoff_document(
            serde_json::json!([{"provider": "openai", "keys": [[1, 2, 3]]}]),
        ));
        // Duplicate provider.
        assert_handoff_invalid(&handoff_document(serde_json::json!([
            kimi_entry, kimi_entry
        ])));
        // Empty keys array for a provider.
        assert_handoff_invalid(&handoff_document(
            serde_json::json!([{"provider": "kimi", "keys": []}]),
        ));
        // Empty key byte array.
        assert_handoff_invalid(&handoff_document(
            serde_json::json!([{"provider": "kimi", "keys": [[]]}]),
        ));
        // Byte value outside 0-255.
        assert_handoff_invalid(&handoff_document(
            serde_json::json!([{"provider": "kimi", "keys": [[256]]}]),
        ));
        // One key exceeding MAX_SECRET_BYTES.
        let oversize_key = vec![0u8; crate::core::secure_mesh_secret_store::MAX_SECRET_BYTES + 1];
        assert_handoff_invalid(&handoff_document(
            serde_json::json!([{"provider": "kimi", "keys": [oversize_key]}]),
        ));
        // Total key count above MAX_LLM_API_KEYS.
        let too_many_keys = vec![serde_json::json!([1, 2, 3]); MAX_LLM_API_KEYS + 1];
        assert_handoff_invalid(&handoff_document(
            serde_json::json!([{"provider": "kimi", "keys": too_many_keys}]),
        ));
    }

    #[test]
    fn handoff_debug_never_includes_secret_material() {
        let epoch = uuid::Uuid::new_v4().to_string();
        let source = Arc::new(TestEpochSource(StdMutex::new(Some(epoch.clone()))));
        let lease = GatewayCredentialLease::new(
            handoff_test_credentials(),
            GatewayCredentialLeaseDays::Seven,
            epoch,
            source,
        )
        .unwrap();
        let handoff = lease.handoff_projection().unwrap();
        let debug = format!("{handoff:?}");
        assert!(!debug.contains("synthetic-kimi-key-1"));
        assert!(!debug.contains("synthetic-kimi-key-2"));
        assert!(!debug.contains("synthetic-deepseek-key-1"));
    }
}
