use crate::domain::targets;
use crate::platform::client_state::ClientStateStore;
use crate::platform::url_security::{
    canonical_https_or_loopback_http_origin, https_or_loopback_http_host,
};
use anyhow::{Context, Result, anyhow, ensure};
use base64::{Engine as _, engine::general_purpose};
use ed25519_dalek::{Signer, SigningKey};
use hmac::{Hmac, Mac};
use rand::{RngCore, rngs::OsRng};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::cell::RefCell;
use std::collections::BTreeSet;
use std::env;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, OnceLock};
use time::{Duration, OffsetDateTime, format_description::well_known::Rfc3339};
use uuid::Uuid;
use x25519_dalek::{PublicKey, StaticSecret};

type MobileRelayClaimMac = Hmac<Sha256>;

use crate::core::secure_mesh_capability::{
    CapabilityEvaluation, CapabilityEvaluationReport, CustodyRestartSemantics,
    SecretCustodyStrategy, SecurityCapability,
};
use crate::core::secure_mesh_directory::{
    AuthorizedDirectoryLeaf, DirectoryAuthorizationPurpose, DirectoryAuthorizationRequest,
    PinnedKtLogConfiguration, SecureMeshDirectoryAuthority,
    SecureMeshDirectoryKeyMaterialCommitment, SecureMeshDirectoryLeafClaim,
    SecureMeshKtVerifierConfiguration, UntrustedDirectoryResponse,
};
use crate::core::secure_mesh_pairwise::{
    SECURE_MESH_PAIRWISE_CIPHER_SUITE, SecureMeshLocalPreKeyUse, SecureMeshPairwiseDurableRecord,
    SecureMeshPairwiseDurableStore, SecureMeshPairwisePrivateKey, SecureMeshPairwiseSession,
    SecureMeshPairwiseSessionAccepted, SecureMeshPairwiseSessionFinished,
    SecureMeshPairwiseSessionIntro, SecureMeshRemotePreKeyUse,
};
use crate::core::secure_mesh_pqxdh::{
    ML_KEM_1024_CIPHERTEXT_BYTES, ML_KEM_1024_KEY_GENERATION_SEED_BYTES,
    ML_KEM_1024_PUBLIC_KEY_BYTES, SecureMeshMlKem1024PreKeySeed,
};
use crate::core::secure_mesh_prekey::{
    SecureMeshPairwisePreKeyBundle, SecureMeshPreKeyKind, SecureMeshPreKeyRecord,
    SecureMeshPreKeyValidationPolicy, one_time_prekey_batch_digest, sign_prekey_record,
    signed_prekey_bundle_digest,
};
use crate::core::secure_mesh_relay_envelope::{
    SECURE_MESH_MAILBOX_ROTATION_WINDOW_SECONDS, SecureMeshDeliverySecret,
    SecureMeshMailboxDirection, SecureMeshMailboxSchedule, SecureMeshRelayChannelBinding,
    SecureMeshRelayEnvelope,
};
use crate::core::secure_mesh_transparency::SecureMeshTransparencyLeafBody;
use crate::core::secure_mesh_transparency::{
    KT_JSON_SAFE_INTEGER_MAX, KtFreshnessPolicy, PinnedKtLogKey, SecureMeshKtAuthorizationReceipt,
    SecureMeshKtGossipPayload, stable_directory_label,
};
#[cfg(test)]
use crate::core::secure_mesh_transparency::{SecureMeshKtLog, directory_scope_commitment};
use crate::core::secure_mesh_trust::{
    DeviceTrustPublicIdentity, DeviceTrustState, ProtectedSendAuthorization,
    ProtectedSendPayloadKind, authorize_protected_send_from_trust_record,
    device_trust_record_to_json, qr_verification_payload, sas_decimal_chunks,
    sign_device_trust_record, verify_device_trust_record_json,
};
use crate::platform::file_security::{
    create_private_state_marker, private_state_marker_exists, read_private_state_marker,
    remove_private_state_marker,
};
use crate::platform::secure_client_relay_transport::{
    SecureClientRelayAuth, SecureClientRelayEndpointRegistration, SecureClientRelayPublicJwk,
    SecureClientRelayScope, SecureClientRelayTransport,
};
use crate::platform::secure_mesh_secret_store::{
    EphemeralSecretStore, PlatformSecretStore, SecretClassPersistenceProof,
    SecretStoreAuthorizationRequest, SecretStoreAuthorizationSession, SecretStoreHandle,
    SecureMeshSecretStore, platform_linux_secret_service_probe_snapshot,
    platform_native_secret_store_supported,
};

const CONFIG_SCHEMA_VERSION: u32 = 1;
const CONFIG_MAX_BYTES: usize = 512 * 1024;
const CONFIG_GENERATION_FIELD: &str = "configGeneration";
const AUTHORITY_GENERATION_FIELD: &str = "securityAuthorityGeneration";
const KT_AUTHORITY_CHALLENGE_SCHEMA_VERSION: u64 = 1;
const KT_AUTHORITY_CHALLENGE_TTL_SECONDS: u64 = 5 * 60;
const DEFAULT_GATEWAY_URL: &str = "https://api.licolite.app";
const EPHEMERAL_CUSTOM_GATEWAY_HOST_SUFFIXES: &[&str] = &[".trycloudflare.com"];
const SECURE_MESH_PROTOCOL_VERSION: &str = "licolite.secure-mesh.v1";
const MOBILE_RELAY_E2EE_PROTOCOL_VERSION: &str = "licolite.mobile-relay.e2ee.pqxdh-mlkem1024.v1";
const SECURE_MESH_ENVELOPE_COMMAND: &str = "secure_mesh.envelope";
const MOBILE_RELAY_COMMAND_TTL_SECONDS: i64 = 10 * 60;
const MOBILE_RELAY_RESULT_TTL_SECONDS: i64 = 10 * 60;
const MOBILE_RELAY_KEY_BYTES: usize = 32;
const MOBILE_RELAY_PREKEY_VALIDITY_DAYS: i64 = 30;
const MOBILE_RELAY_TRUST_RECORD_VALIDITY_DAYS: i64 = 90;
// Kept for REQ-004 envelope migration and future trust authority wiring.
#[allow(dead_code)]
const MOBILE_RELAY_ENVELOPE_CLOCK_SKEW_SECONDS: i64 = 5 * 60;
#[allow(dead_code)]
const MOBILE_RELAY_MAX_ENVELOPE_TEXT_BYTES: usize = 4096;
#[allow(dead_code)]
const MOBILE_RELAY_MAX_ENCRYPTED_HEADER_BYTES: usize = 512;
const RUNTIME_SECRET_OVERRIDE_TRANSPORT: &str = "platform_keyring_to_rust_ffi_memory_override";
const NATIVE_SECRET_STORE_MODE_ENV: &str = "LICO_MOBILE_RELAY_NATIVE_SECRET_STORE";
const NATIVE_SECRET_STORE_SERVICE: &str = "app.licolite.licoarc.mobile-relay.pqxdh-mlkem1024.v1";
const NATIVE_SECRET_STORE_ACCOUNT_PREFIX: &str = "mobileRelayE2ee";
const MOBILE_RELAY_PLATFORM_SECRET_STORE_NAMESPACE: &str = "mobileRelayPqxdhMlKem1024Runtime";
const NATIVE_SECRET_STORE_SUPPORTED_BACKENDS: &[&str] = &[
    "macos-keychain",
    "linux-secret-service-keyring",
    "windows-credential-manager",
    "android-keystore",
];
const NATIVE_SECRET_STORE_SHARED_SECRET_CLASSES: &[&str] = &[
    "pairwiseSessionSnapshot",
    "mlsEpochSecret",
    "recoverySecret",
];
const SECURE_MESH_ENDPOINT_CRYPTO_RUNTIME_FAILED_CODE: &str =
    "secure_mesh_endpoint_crypto_runtime_failed";
const SECURE_MESH_ENDPOINT_CRYPTO_RUNTIME_FAILED_DETAIL: &str =
    "secure mesh endpoint could not open or execute command; details are local-only";
const KT_AUTHORITY_RESET_GUARD_SCHEMA_VERSION: u64 = 1;
const KT_AUTHORITY_RESET_GUARD_STATE: &str = "security-blocked-reset-in-progress";
const SECURE_MESH_KT_GOSSIP_CONTROL_TYPE: &str = "secure_mesh.kt.gossip";
const SECURE_MESH_PEER_TRUST_AUTHORITY_SCHEMA: &str =
    "licolite.secure-mesh.peer-trust-authority.v1";
const MAX_SECURE_MESH_PEER_TRUST_ENTRIES: usize = 256;

pub const SECURE_MESH_KT_NATIVE_ACTIONS: &[&str] = &[
    "secure_mesh.kt.configureAuthority",
    "secure_mesh.kt.publicationRequest",
    "secure_mesh.kt.revocationRequest",
    "secure_mesh.kt.provision",
    "secure_mesh.kt.gossip",
    "secure_mesh.kt.selfMonitor",
    "secure_mesh.kt.status",
];

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
struct SecureMeshKtGossipControlMessage {
    message_type: String,
    gossip: SecureMeshKtGossipPayload,
}

thread_local! {
    static PAIRWISE_SECRET_STORE_OVERRIDE: RefCell<Option<Arc<dyn SecureMeshSecretStore>>> =
        RefCell::new(None);
    static MOBILE_RELAY_SECRET_STORE_OVERRIDE: RefCell<Option<Arc<dyn SecureMeshSecretStore>>> =
        RefCell::new(None);
    #[cfg(test)]
    static KT_AUTHORITY_RESET_FAILPOINT: RefCell<Option<&'static str>> = const { RefCell::new(None) };
    #[cfg(test)]
    static KT_FRESHNESS_NOW_OVERRIDE: RefCell<Option<u64>> = const { RefCell::new(None) };
}

static MOBILE_RELAY_EPHEMERAL_SECRET_STORE: OnceLock<Arc<EphemeralSecretStore>> = OnceLock::new();

#[derive(Default)]
struct RuntimeSecretOverrides {
    pc_token: bool,
    mobile_token: bool,
    e2ee_private_key: bool,
    e2ee_pairing_secret: bool,
    e2ee_signing_key: bool,
    e2ee_signed_prekey_private_key: bool,
    e2ee_one_time_prekey_private_key: bool,
    e2ee_one_time_mlkem1024_prekey_seed: bool,
    secret_storage_backend: Option<&'static str>,
    secret_store_authorization: Option<RuntimeSecretStoreAuthorizationProof>,
    paired_device_tokens: Vec<PairedDeviceSecretOverride>,
}

#[derive(Clone, Debug)]
struct RuntimeSecretStoreAuthorizationProof {
    backend: &'static str,
    operation_count: usize,
    consumed_operation_count: usize,
    remaining_operation_count: usize,
    authorization_batch_within_budget: bool,
    allow_interaction: bool,
    shared_system_context_required: bool,
    shared_system_context_available: bool,
    system_authorization_attempt_count: usize,
    system_authorization_completed: bool,
    single_system_authorization_context_verified: bool,
    app_password_prompt_used: bool,
    app_credential_prompt_used: bool,
    capability_report: Option<CapabilityEvaluationReport>,
}

struct PairedDeviceSecretOverride {
    id: String,
    pairing_id: String,
}

impl RuntimeSecretOverrides {
    fn merge(&mut self, other: RuntimeSecretOverrides) {
        self.pc_token |= other.pc_token;
        self.mobile_token |= other.mobile_token;
        self.e2ee_private_key |= other.e2ee_private_key;
        self.e2ee_pairing_secret |= other.e2ee_pairing_secret;
        self.e2ee_signing_key |= other.e2ee_signing_key;
        self.e2ee_signed_prekey_private_key |= other.e2ee_signed_prekey_private_key;
        self.e2ee_one_time_prekey_private_key |= other.e2ee_one_time_prekey_private_key;
        self.e2ee_one_time_mlkem1024_prekey_seed |= other.e2ee_one_time_mlkem1024_prekey_seed;
        if other.secret_storage_backend.is_some() {
            self.secret_storage_backend = other.secret_storage_backend;
        }
        if other.secret_store_authorization.is_some() {
            self.secret_store_authorization = other.secret_store_authorization;
        }
        self.paired_device_tokens.extend(other.paired_device_tokens);
    }

    fn mark_e2ee_secret_store(&mut self, backend: &'static str) {
        self.secret_storage_backend = Some(backend);
    }

    fn mark_secret_store_authorization(&mut self, session: &SecretStoreAuthorizationSession) {
        self.secret_store_authorization = Some(RuntimeSecretStoreAuthorizationProof {
            backend: session.backend(),
            operation_count: session.operation_count(),
            consumed_operation_count: session.consumed_operation_count(),
            remaining_operation_count: session.remaining_operation_count(),
            authorization_batch_within_budget: session.authorization_batch_within_budget(),
            allow_interaction: session.allow_interaction(),
            shared_system_context_required: session.shared_system_context_required(),
            shared_system_context_available: session.shared_system_context_available(),
            system_authorization_attempt_count: session.system_authorization_attempt_count(),
            system_authorization_completed: session.system_authorization_completed(),
            single_system_authorization_context_verified: session
                .single_system_authorization_context_verified(),
            app_password_prompt_used: session.app_password_prompt_used(),
            app_credential_prompt_used: false,
            capability_report: session.capability_report().cloned(),
        });
    }
}

struct RuntimeSecretContext {
    overrides: RuntimeSecretOverrides,
    secret_store_batch: MobileRelaySecretStoreAuthBatch,
}

impl Default for RuntimeSecretContext {
    fn default() -> Self {
        Self {
            overrides: RuntimeSecretOverrides::default(),
            secret_store_batch: MobileRelaySecretStoreAuthBatch::default(),
        }
    }
}

impl RuntimeSecretContext {
    fn shared_authorization_session(&mut self) -> Result<Option<SecretStoreAuthorizationSession>> {
        Ok(self
            .secret_store_batch
            .authorization()?
            .map(|(_, session, _)| session))
    }
}

struct MobileRelaySecretStoreAuthBatch {
    reason: String,
    operation_count: usize,
    allow_interaction: bool,
    initialized: bool,
    store: Option<Arc<dyn SecureMeshSecretStore>>,
    namespace: Option<String>,
    session: Option<SecretStoreAuthorizationSession>,
}

impl Default for MobileRelaySecretStoreAuthBatch {
    fn default() -> Self {
        Self::new(
            "Mobile Relay E2EE secret store authorization batch",
            mobile_relay_e2ee_secret_store_authorization_batch_operation_count(),
        )
    }
}

impl MobileRelaySecretStoreAuthBatch {
    fn new(reason: impl Into<String>, operation_count: usize) -> Self {
        Self::with_interaction(reason, operation_count, true)
    }

    fn with_interaction(
        reason: impl Into<String>,
        operation_count: usize,
        allow_interaction: bool,
    ) -> Self {
        Self {
            reason: reason.into(),
            operation_count,
            allow_interaction,
            initialized: false,
            store: None,
            namespace: None,
            session: None,
        }
    }

    fn init(&mut self) -> Result<()> {
        if self.initialized {
            return Ok(());
        }
        self.initialized = true;
        if let Some(store) = mobile_relay_secret_store_override() {
            self.store = Some(store);
            self.namespace = Some(MOBILE_RELAY_PLATFORM_SECRET_STORE_NAMESPACE.to_string());
            return Ok(());
        }
        self.store = Some(selected_mobile_relay_secret_store());
        self.namespace = Some(native_secret_store_namespace()?);
        Ok(())
    }

    fn authorization(
        &mut self,
    ) -> Result<
        Option<(
            Arc<dyn SecureMeshSecretStore>,
            SecretStoreAuthorizationSession,
            String,
        )>,
    > {
        self.init()?;
        let Some(store) = self.store.as_ref().map(Arc::clone) else {
            return Ok(None);
        };
        ensure!(
            store.supported(),
            "mobile relay native secret store backend is unsupported"
        );
        if self.session.is_none() {
            let request = if self.allow_interaction {
                SecretStoreAuthorizationRequest::new(&self.reason, self.operation_count)
            } else {
                SecretStoreAuthorizationRequest::noninteractive(&self.reason, self.operation_count)
            };
            self.session = Some(store.begin_authorized_session(&request)?);
        }
        let session = self
            .session
            .as_ref()
            .ok_or_else(|| anyhow!("mobile relay secret store authorization batch is missing"))?
            .clone();
        let namespace = self
            .namespace
            .as_ref()
            .ok_or_else(|| anyhow!("mobile relay native secret store namespace is missing"))?
            .clone();
        Ok(Some((store, session, namespace)))
    }
}

pub fn with_pairwise_secret_store_override<T>(
    store: Arc<dyn SecureMeshSecretStore>,
    f: impl FnOnce() -> Result<T>,
) -> Result<T> {
    let previous = PAIRWISE_SECRET_STORE_OVERRIDE.with(|slot| slot.replace(Some(store)));
    let result = f();
    PAIRWISE_SECRET_STORE_OVERRIDE.with(|slot| {
        slot.replace(previous);
    });
    result
}

pub fn with_mobile_relay_secret_store_override<T>(
    store: Arc<dyn SecureMeshSecretStore>,
    f: impl FnOnce() -> Result<T>,
) -> Result<T> {
    let previous = MOBILE_RELAY_SECRET_STORE_OVERRIDE.with(|slot| slot.replace(Some(store)));
    let result = f();
    MOBILE_RELAY_SECRET_STORE_OVERRIDE.with(|slot| {
        slot.replace(previous);
    });
    result
}

fn pairwise_secret_store_override() -> Option<Arc<dyn SecureMeshSecretStore>> {
    PAIRWISE_SECRET_STORE_OVERRIDE.with(|slot| slot.borrow().as_ref().map(Arc::clone))
}

fn mobile_relay_secret_store_override() -> Option<Arc<dyn SecureMeshSecretStore>> {
    MOBILE_RELAY_SECRET_STORE_OVERRIDE.with(|slot| slot.borrow().as_ref().map(Arc::clone))
}

fn selected_mobile_relay_secret_store() -> Arc<dyn SecureMeshSecretStore> {
    let store =
        MOBILE_RELAY_EPHEMERAL_SECRET_STORE.get_or_init(|| Arc::new(EphemeralSecretStore::new()));
    if native_secret_store_permitted() {
        let platform_store = native_secret_store();
        if platform_store.supported() {
            return Arc::new(platform_store);
        }
        if let Ok(facts) = platform_store.capability_facts() {
            let _ = store.set_unavailable_platform_facts(facts);
        }
    } else {
        let _ = store.set_unavailable_platform_facts(Vec::new());
    }
    Arc::clone(store) as Arc<dyn SecureMeshSecretStore>
}

/// Returns the capability evaluation for the secret store selected by the current client.
///
/// Capability evaluation is intentionally non-interactive: it does not begin an
/// authorization session and never reads key material. Platform probe failures are
/// represented by the selected store's conservative capability facts.
pub fn selected_mobile_relay_capability_evaluation() -> Result<CapabilityEvaluation> {
    mobile_relay_secret_store_override()
        .unwrap_or_else(selected_mobile_relay_secret_store)
        .capability_evaluation()
}

/// Execute an MLS operation with the established local device identity and the selected custody
/// backend under one authorization batch. Key material and the authorization session never leave
/// this Rust-only closure.
pub(crate) fn with_secure_mesh_mls_local_runtime<T>(
    params: &Value,
    additional_secret_store_operations: usize,
    operation: impl FnOnce(
        &mut Value,
        &DeviceTrustPublicIdentity,
        &SigningKey,
        &Arc<dyn SecureMeshSecretStore>,
        &SecretStoreAuthorizationSession,
        &str,
    ) -> Result<T>,
) -> Result<T> {
    ensure_secure_mesh_protected_operation_allowed()?;
    static MLS_RUNTIME_OPERATION_MUTEX: OnceLock<Mutex<()>> = OnceLock::new();
    let _process_guard = MLS_RUNTIME_OPERATION_MUTEX
        .get_or_init(|| Mutex::new(()))
        .lock()
        .map_err(|_| anyhow!("secure mesh MLS participant operation lock is unavailable"))?;
    let operation_lock_path = secure_mesh_mls_state_dir()?.join("participant-operation.lock");
    let operation_lock =
        crate::platform::file_security::open_private_lock_file(&operation_lock_path)?;
    fs2::FileExt::lock_exclusive(&operation_lock)
        .map_err(|_| anyhow!("secure mesh MLS participant operation lock could not be acquired"))?;
    ensure!(
        additional_secret_store_operations <= 8,
        "secure mesh MLS secret-store operation budget is invalid"
    );
    let operation_count = mobile_relay_e2ee_secret_store_authorization_batch_operation_count()
        .saturating_add(additional_secret_store_operations);
    let (mut config, mut secret_context) = load_config_with_runtime_secret_context_for_operation(
        params,
        "Secure Mesh MLS selected-custody authorization batch",
        operation_count,
    )?;
    if local_endpoint_state(&config).is_err() {
        let endpoint_kind =
            text_param(params, &["endpointKind"]).unwrap_or_else(|| "desktop_sidecar".to_string());
        ensure_mobile_relay_endpoint_material(&mut config, &endpoint_kind)?;
    }
    let endpoint = local_endpoint_state(&config)?;
    let identity = endpoint.device_identity()?;
    let signing_key = endpoint.signing_key()?;
    let (secret_store, authorization, namespace) = secret_context
        .secret_store_batch
        .authorization()?
        .ok_or_else(|| anyhow!("secure mesh MLS selected custody is unavailable"))?;
    ensure!(
        secret_store.supported(),
        "secure mesh MLS selected custody is unsupported"
    );
    let output = operation(
        &mut config,
        &identity,
        &signing_key,
        &secret_store,
        &authorization,
        &namespace,
    )?;
    save_config_with_runtime_secret_context(&mut config, &mut secret_context)?;
    Ok(output)
}

/// Resolve MLS peer trust from the locally persisted Mobile Relay authority.
///
/// The caller supplies an identity to bind the protocol message, but cannot supply or promote
/// its trust state. Until the directory/KT authority is wired, only the single peer represented by
/// the current locally signed and persisted pairing trust record is eligible for MLS operations.
pub(crate) fn persisted_mobile_relay_peer_trust_state(
    config: &Value,
    local_identity: &DeviceTrustPublicIdentity,
    peer_identity: &DeviceTrustPublicIdentity,
) -> Result<DeviceTrustState> {
    ensure_secure_mesh_protected_operation_allowed()?;
    ensure!(
        local_endpoint_state(config)?.device_identity()? == *local_identity,
        "secure mesh MLS persisted local trust identity differs"
    );
    let scope = configured_directory_scope_commitment(config)?;
    let stable_label = stable_directory_label(scope, &peer_identity.endpoint_id);
    let authority = config
        .get("mobileRelayE2ee")
        .and_then(|state| state.get("peerTrustAuthority"))
        .filter(|value| value.is_object())
        .ok_or_else(|| anyhow!("secure mesh MLS persisted trust authority is unavailable"))?;
    ensure!(
        authority.get("schemaVersion").and_then(Value::as_str)
            == Some(SECURE_MESH_PEER_TRUST_AUTHORITY_SCHEMA),
        "secure mesh MLS persisted trust authority schema is invalid"
    );
    let entries = authority
        .get("entries")
        .and_then(Value::as_object)
        .ok_or_else(|| anyhow!("secure mesh MLS persisted trust authority entries are missing"))?;
    ensure!(
        entries.len() <= MAX_SECURE_MESH_PEER_TRUST_ENTRIES,
        "secure mesh MLS persisted trust authority exceeds its bound"
    );
    let entry = entries
        .get(&stable_label)
        .filter(|value| value.is_object())
        .ok_or_else(|| {
            anyhow!("secure mesh MLS peer is absent from the persisted trust authority")
        })?;
    ensure!(
        entry.get("stableLabel").and_then(Value::as_str) == Some(stable_label.as_str()),
        "secure mesh MLS persisted peer trust label binding is invalid"
    );
    let identity_value = entry
        .get("identity")
        .filter(|value| value.is_object())
        .ok_or_else(|| anyhow!("secure mesh MLS persisted peer identity is missing"))?;
    let persisted_identity = DeviceTrustPublicIdentity::new(
        descriptor_text(identity_value, "endpointId")?,
        decode_key_32(
            &descriptor_text(identity_value, "identityPublicKeyBase64url")?,
            "secure mesh persisted peer identity public key",
        )?,
        decode_key_32(
            &descriptor_text(identity_value, "signingPublicKeyBase64url")?,
            "secure mesh persisted peer signing public key",
        )?,
        identity_value
            .get("rotationEpoch")
            .and_then(Value::as_u64)
            .ok_or_else(|| anyhow!("secure mesh persisted peer rotation epoch is missing"))?,
    )?;
    ensure!(
        persisted_identity == *peer_identity,
        "secure mesh MLS persisted peer identity binding differs"
    );
    let record = entry
        .get("trustRecord")
        .ok_or_else(|| anyhow!("secure mesh MLS persisted peer trust record is missing"))?;
    let trust_state = verify_device_trust_record_json(
        local_identity,
        peer_identity,
        record,
        mobile_relay_trust_record_now_epoch()?,
    )?;
    ensure!(
        trust_state == DeviceTrustState::Verified,
        "secure mesh MLS persisted peer trust is not verified"
    );
    Ok(trust_state)
}

#[allow(dead_code)]
fn persist_peer_trust_authority_entry(
    config: &mut Value,
    local_identity: &DeviceTrustPublicIdentity,
    peer_identity: &DeviceTrustPublicIdentity,
    trust_record: &Value,
) -> Result<()> {
    ensure!(
        verify_device_trust_record_json(
            local_identity,
            peer_identity,
            trust_record,
            mobile_relay_trust_record_now_epoch()?,
        )? == DeviceTrustState::Verified,
        "secure mesh peer trust authority only accepts verified records"
    );
    let stable_label = stable_directory_label(
        configured_directory_scope_commitment(config)?,
        &peer_identity.endpoint_id,
    );
    if config["mobileRelayE2ee"]
        .get("peerTrustAuthority")
        .is_none()
    {
        config["mobileRelayE2ee"]["peerTrustAuthority"] = json!({
            "schemaVersion": SECURE_MESH_PEER_TRUST_AUTHORITY_SCHEMA,
            "entries": {}
        });
    }
    let authority = config["mobileRelayE2ee"]
        .get_mut("peerTrustAuthority")
        .and_then(Value::as_object_mut)
        .ok_or_else(|| anyhow!("secure mesh peer trust authority is invalid"))?;
    ensure!(
        authority.get("schemaVersion").and_then(Value::as_str)
            == Some(SECURE_MESH_PEER_TRUST_AUTHORITY_SCHEMA),
        "secure mesh peer trust authority schema is invalid"
    );
    let entries = authority
        .get_mut("entries")
        .and_then(Value::as_object_mut)
        .ok_or_else(|| anyhow!("secure mesh peer trust authority entries are invalid"))?;
    ensure!(
        entries.contains_key(&stable_label) || entries.len() < MAX_SECURE_MESH_PEER_TRUST_ENTRIES,
        "secure mesh peer trust authority is at capacity"
    );
    entries.insert(
        stable_label.clone(),
        json!({
            "stableLabel": stable_label,
            "identity": {
                "endpointId": peer_identity.endpoint_id,
                "identityPublicKeyBase64url": general_purpose::URL_SAFE_NO_PAD.encode(peer_identity.identity_public_key),
                "signingPublicKeyBase64url": general_purpose::URL_SAFE_NO_PAD.encode(peer_identity.signing_public_key),
                "rotationEpoch": peer_identity.rotation_epoch,
            },
            "trustRecord": trust_record,
        }),
    );
    Ok(())
}

#[allow(dead_code)]
fn remove_peer_trust_authority_entry(config: &mut Value, peer_endpoint_id: &str) -> Result<()> {
    let scope = configured_directory_scope_commitment(config)?.to_string();
    let stable_label = stable_directory_label(&scope, peer_endpoint_id);
    if let Some(entries) = config
        .get_mut("mobileRelayE2ee")
        .and_then(|state| state.get_mut("peerTrustAuthority"))
        .and_then(|authority| authority.get_mut("entries"))
        .and_then(Value::as_object_mut)
    {
        entries.remove(&stable_label);
    }
    Ok(())
}

pub(crate) fn secure_mesh_mls_state_dir() -> Result<PathBuf> {
    let directory = ClientStateStore::portable()?
        .root()
        .join("mobile-relay")
        .join("secure-mesh-mls");
    fs::create_dir_all(&directory)?;
    Ok(directory)
}

pub(crate) fn secure_mesh_mls_public_directory_context()
-> Result<(Value, DeviceTrustPublicIdentity)> {
    ensure_secure_mesh_protected_operation_allowed()?;
    let config = load_config_without_persistence()?;
    let state = config
        .get("mobileRelayE2ee")
        .ok_or_else(|| anyhow!("secure mesh MLS local endpoint state is unavailable"))?;
    let identity = DeviceTrustPublicIdentity::new(
        descriptor_text(state, "endpointId")?,
        decode_key_32(
            &descriptor_text(state, "publicKeyBase64url")?,
            "secure mesh MLS local identity public key",
        )?,
        decode_key_32(
            &descriptor_text(state, "signingPublicKeyBase64url")?,
            "secure mesh MLS local signing public key",
        )?,
        state
            .get("rotationEpoch")
            .and_then(Value::as_u64)
            .ok_or_else(|| anyhow!("secure mesh MLS local rotation epoch is unavailable"))?,
    )?;
    Ok((config, identity))
}

pub(crate) fn secure_mesh_kt_authority_path(local_endpoint_id: &str) -> Result<PathBuf> {
    ensure!(
        !local_endpoint_id.trim().is_empty(),
        "secure mesh KT local endpoint id is required"
    );
    let directory = ClientStateStore::portable()?
        .root()
        .join("mobile-relay")
        .join("secure-mesh-kt");
    fs::create_dir_all(&directory)?;
    Ok(directory.join(format!(
        "{}.sqlite3",
        sha256_hex(local_endpoint_id.as_bytes())
    )))
}

#[cfg(test)]
pub(crate) fn initialize_secure_mesh_mls_test_endpoint(endpoint_kind: &str) -> Result<()> {
    let mut config = default_config();
    ensure_mobile_relay_endpoint_descriptor(&mut config, endpoint_kind)?;
    save_config(&mut config)
}

#[cfg(test)]
pub(crate) fn initialize_secure_mesh_mls_test_peer(
    peer_identity: &DeviceTrustPublicIdentity,
) -> Result<()> {
    let (mut config, _context) = load_config_with_runtime_secret_context_for_operation(
        &json!({"allowInteraction": true}),
        "Secure Mesh MLS test peer authority",
        mobile_relay_e2ee_secret_store_authorization_batch_operation_count(),
    )?;
    let local_endpoint = local_endpoint_state(&config)?;
    let local_identity = local_endpoint.device_identity()?;
    let issued_at = mobile_relay_trust_record_now_epoch()?;
    let trust_record = sign_device_trust_record(
        &local_endpoint.signing_key()?,
        &local_identity,
        peer_identity,
        DeviceTrustState::Verified,
        peer_identity.rotation_epoch,
        "test_persisted_pairing_authority",
        issued_at,
        mobile_relay_trust_record_expiry_epoch(issued_at)?,
    )?;
    let trust_record_json = device_trust_record_to_json(&trust_record);
    persist_peer_trust_authority_entry(
        &mut config,
        &local_identity,
        peer_identity,
        &trust_record_json,
    )?;
    config["mobileRelayE2ee"]["peerEndpointId"] = json!(peer_identity.endpoint_id);
    config["mobileRelayE2ee"]["peerEndpointKind"] = json!("secure_mesh_mls_test_peer");
    config["mobileRelayE2ee"]["peerPublicKeyBase64url"] =
        json!(general_purpose::URL_SAFE_NO_PAD.encode(peer_identity.identity_public_key));
    config["mobileRelayE2ee"]["peerSigningPublicKeyBase64url"] =
        json!(general_purpose::URL_SAFE_NO_PAD.encode(peer_identity.signing_public_key));
    config["mobileRelayE2ee"]["peerRotationEpoch"] = json!(peer_identity.rotation_epoch);
    config["mobileRelayE2ee"]["peerVerified"] = json!(true);
    config["mobileRelayE2ee"]["peerTrustRecord"] = trust_record_json;
    refresh_secure_mesh_mls_test_directory_authority(&mut config)?;
    save_config(&mut config)
}

#[cfg(test)]
pub(crate) fn secure_mesh_mls_test_directory_response(
    member_identity: &DeviceTrustPublicIdentity,
    member_key_package: &[u8],
    directory_version: u64,
    key_package_version: u64,
) -> Result<Value> {
    let config = load_config()?;
    let local_endpoint_id = descriptor_text(
        config
            .get("mobileRelayE2ee")
            .ok_or_else(|| anyhow!("secure mesh MLS test local endpoint is missing"))?,
        "endpointId",
    )?;
    let authority = open_mobile_relay_directory_authority(&config, &local_endpoint_id)?;
    let previous_tree_size = authority
        .latest_checkpoint()?
        .map(|checkpoint| checkpoint.tree_size);
    let claim = SecureMeshDirectoryLeafClaim {
        endpoint: SecureMeshTransparencyLeafBody {
            directory_scope_commitment: directory_scope_commitment(
                "local-test-tenant",
                "local-test-account",
                "local-test-workspace",
            ),
            endpoint_id: member_identity.endpoint_id.clone(),
            endpoint_kind: "mls-test-member".to_string(),
            identity_public_key: hex_encode_bytes(&member_identity.identity_public_key),
            signing_public_key: hex_encode_bytes(&member_identity.signing_public_key),
            fingerprint: member_identity.fingerprint()?,
            rotation_epoch: member_identity.rotation_epoch,
            directory_state: "active".to_string(),
            updated_at: now_iso(),
        },
        key_material: SecureMeshDirectoryKeyMaterialCommitment {
            signed_prekey_bundle_digest: sha256_hex(b"mls-test-signed-prekey"),
            one_time_prekey_batch_digest: sha256_hex(b"mls-test-one-time-prekeys"),
            pairwise_prekey_version: 1,
            mls_key_package_digest: sha256_hex(member_key_package),
            mls_key_package_version: key_package_version,
        },
        directory_version,
    };
    let now_epoch_seconds = mobile_relay_trust_record_now_epoch()?;
    let response = with_mobile_relay_test_kt_log(|log| {
        let index = log.append_hashed_directory_leaf(
            &claim.stable_label(),
            claim.version(),
            claim.revoked(),
            claim.leaf_hash()?,
        )?;
        Ok(UntrustedDirectoryResponse {
            claim: claim.clone(),
            inclusion: log.inclusion_proof_at(index, now_epoch_seconds)?,
            latest_map: log.map_proof_at(&claim.stable_label(), now_epoch_seconds)?,
            consistency: previous_tree_size
                .filter(|size| *size < log.tree_size())
                .map(|size| log.consistency_proof_at(size, now_epoch_seconds))
                .transpose()?,
        })
    })?;
    serde_json::to_value(response).map_err(Into::into)
}

pub fn config_get(params: &Value) -> Result<Value> {
    let (mut config, _) = load_config_for_read(params)?;
    if let Some(providers) = relay_authorized_providers_param(params) {
        config["authorizedProviders"] = providers;
    }
    Ok(json!({
        "ok": true,
        "schemaVersion": CONFIG_SCHEMA_VERSION,
        "config": public_config(&config)
    }))
}

pub fn config_set(params: &Value) -> Result<Value> {
    // Validate external gateway input before opening secret custody, resetting
    // pairing state, or performing any durable write.
    let requested_default_gateway = text_param(params, &["defaultGatewayUrl"])
        .map(|value| validated_default_gateway(&value))
        .transpose()?;
    let requested_custom_gateway = text_param(params, &["customGatewayUrl", "gatewayUrl"])
        .map(|value| validated_optional_custom_gateway(&value))
        .transpose()?;
    let (mut config, mut secret_context) = load_config_with_runtime_secret_context(params)?;
    let reset_pairing = bool_param(params, &["resetPairing"]).unwrap_or(false);
    if reset_pairing {
        delete_mobile_relay_pairing_token_secrets(&config, &mut secret_context.secret_store_batch)?;
        clear_mobile_relay_pairing_state(&mut config)?;
    }
    if let Some(value) = requested_default_gateway {
        config["defaultGatewayUrl"] = json!(value);
    }
    if let Some(value) = requested_custom_gateway {
        config["customGatewayUrl"] = json!(value);
    }
    if let Some(value) = bool_param(params, &["useCustomGateway"]) {
        config["useCustomGateway"] = json!(value);
    }
    if let Some(value) = bool_param(params, &["relayEnabled"]) {
        config["relayEnabled"] = json!(value);
    }
    if let Some(value) = relay_authorized_providers_param(params) {
        config["authorizedProviders"] = value;
    }
    if let Some(value) = text_param(params, &["pcClientId"]) {
        config["pcClientId"] = json!(value);
    }
    if let Some(value) = text_param(params, &["pcClientName"]) {
        config["pcClientName"] = json!(value);
    }
    if let Some(value) = text_param(params, &["pairingId"]) {
        config["pairingId"] = json!(value);
    }
    if let Some(value) = text_param(params, &["relayTenantId"]) {
        config["relayTenantId"] = json!(value);
    }
    if let Some(value) = text_param(params, &["relayAccountId"]) {
        config["relayAccountId"] = json!(value);
    }
    if let Some(value) = text_param(params, &["relayWorkspaceId"]) {
        config["relayWorkspaceId"] = json!(value);
    }
    if let Some(value) =
        text_param(params, &["mobileToken"]).filter(|value| is_unredacted_secret(value))
    {
        config["mobileToken"] = json!(value);
    }
    apply_selected_paired_device_credentials(&mut config);
    if let Some(value) = bool_param(params, &["paired"]) {
        config["paired"] = json!(value);
    }
    normalize_gateway_fields(&mut config);
    save_config_with_runtime_secret_context(&mut config, &mut secret_context)?;
    Ok(json!({
        "ok": true,
        "status": "saved",
        "schemaVersion": CONFIG_SCHEMA_VERSION,
        "config": public_config(&config)
    }))
}

pub fn dispatch_key_transparency_action(action: &str, params: &Value) -> Result<Value> {
    match action {
        "secure_mesh.kt.configureAuthority" => key_transparency_configure_authority(params),
        "secure_mesh.kt.publicationRequest" => key_transparency_publication_request(params),
        "secure_mesh.kt.revocationRequest" => key_transparency_revocation_request(params),
        "secure_mesh.kt.provision" => key_transparency_provision(params),
        "secure_mesh.kt.gossip" => key_transparency_gossip(params),
        "secure_mesh.kt.selfMonitor" => key_transparency_self_monitor(params),
        "secure_mesh.kt.status" => key_transparency_status(params),
        _ => Err(anyhow!("secure mesh KT native action is unsupported")),
    }
}

struct KtAuthorityProposal {
    pin_value: Value,
    pin: PinnedKtLogKey,
    scope: String,
    max_sth_age_seconds: u64,
    max_future_skew_seconds: u64,
    digest: String,
}

enum KtAuthorityChallengeState {
    Pending { requires_security_reset: bool },
    AlreadyCommitted { required_security_reset: bool },
}

fn parse_kt_authority_proposal(params: &Value) -> Result<KtAuthorityProposal> {
    let pin_value = params
        .get("pin")
        .filter(|value| value.is_object())
        .cloned()
        .ok_or_else(|| anyhow!("secure mesh KT explicit pinned log is required"))?;
    let pin_configuration: PinnedKtLogConfiguration = serde_json::from_value(pin_value.clone())
        .map_err(|_| anyhow!("secure mesh KT explicit pinned log is invalid"))?;
    let pin = pin_configuration.into_pin()?;
    let scope = descriptor_sha256_hex(params, "directoryScopeCommitment")?;
    let max_sth_age_seconds = params
        .get("maxSthAgeSeconds")
        .and_then(Value::as_u64)
        .unwrap_or(3600);
    let max_future_skew_seconds = params
        .get("maxFutureSkewSeconds")
        .and_then(Value::as_u64)
        .unwrap_or(300);
    KtFreshnessPolicy::strict(max_sth_age_seconds, max_future_skew_seconds)?;
    let digest = stable_json_sha256(&json!({
        "pin": pin_value,
        "directoryScopeCommitment": scope,
        "maxSthAgeSeconds": max_sth_age_seconds,
        "maxFutureSkewSeconds": max_future_skew_seconds,
    }));
    Ok(KtAuthorityProposal {
        pin_value,
        pin,
        scope,
        max_sth_age_seconds,
        max_future_skew_seconds,
        digest,
    })
}

fn kt_authority_challenge_path() -> Result<PathBuf> {
    Ok(ClientStateStore::portable()?
        .root()
        .join("mobile-relay")
        .join("secure-mesh-kt-authority-config.pending"))
}

fn authority_configuration_matches(config: &Value, proposal: &KtAuthorityProposal) -> bool {
    config
        .get("secureMeshKeyTransparency")
        .and_then(|settings| settings.get("pin"))
        == Some(&proposal.pin_value)
        && config
            .get("secureMeshDirectoryScopeCommitment")
            .and_then(Value::as_str)
            == Some(proposal.scope.as_str())
        && config
            .get("secureMeshKeyTransparency")
            .and_then(|settings| settings.get("maxSthAgeSeconds"))
            .and_then(Value::as_u64)
            == Some(proposal.max_sth_age_seconds)
        && config
            .get("secureMeshKeyTransparency")
            .and_then(|settings| settings.get("maxFutureSkewSeconds"))
            .and_then(Value::as_u64)
            == Some(proposal.max_future_skew_seconds)
}

fn authority_change_requires_reset(config: &Value, proposal: &KtAuthorityProposal) -> bool {
    let existing = config
        .get("secureMeshKeyTransparency")
        .filter(|value| value.is_object());
    let existing_scope = config
        .get("secureMeshDirectoryScopeCommitment")
        .and_then(Value::as_str);
    (existing.is_some() || existing_scope.is_some())
        && !authority_configuration_matches(config, proposal)
}

fn read_kt_authority_challenge() -> Result<Option<Value>> {
    let Some(raw) = read_private_state_marker(&kt_authority_challenge_path()?)? else {
        return Ok(None);
    };
    let challenge: Value = serde_json::from_slice(&raw)
        .map_err(|_| anyhow!("secure mesh KT authority challenge is invalid"))?;
    ensure!(
        challenge.get("schemaVersion").and_then(Value::as_u64)
            == Some(KT_AUTHORITY_CHALLENGE_SCHEMA_VERSION)
            && challenge
                .get("challengeId")
                .and_then(Value::as_str)
                .is_some_and(|value| !value.trim().is_empty())
            && challenge
                .get("proposalDigest")
                .and_then(Value::as_str)
                .is_some_and(|value| value.len() == 64)
            && challenge
                .get("configGeneration")
                .and_then(Value::as_u64)
                .is_some()
            && challenge
                .get("authorityGeneration")
                .and_then(Value::as_u64)
                .is_some()
            && challenge
                .get("expiresAtEpochSeconds")
                .and_then(Value::as_u64)
                .is_some()
            && challenge
                .get("requiresSecurityReset")
                .and_then(Value::as_bool)
                .is_some(),
        "secure mesh KT authority challenge is invalid"
    );
    Ok(Some(challenge))
}

fn kt_authority_challenge_response(challenge: &Value) -> Value {
    json!({
        "ok": true,
        "schemaVersion": CONFIG_SCHEMA_VERSION,
        "status": "confirmation_required",
        "authorityChallengeId": challenge["challengeId"],
        "proposalDigest": challenge["proposalDigest"],
        "expiresAtEpochSeconds": challenge["expiresAtEpochSeconds"],
        "requiresSecurityReset": challenge["requiresSecurityReset"],
        "requiresUserPresence": true,
        "directoryResponseAccepted": false,
        "privateKeyMaterial": "redacted",
    })
}

fn stage_kt_authority_challenge(config: &Value, proposal: &KtAuthorityProposal) -> Result<Value> {
    let now = current_secure_mesh_kt_gate_epoch_seconds()?;
    let mesh_config_generation = config_generation(config, CONFIG_GENERATION_FIELD)?;
    let authority_generation = config_generation(config, AUTHORITY_GENERATION_FIELD)?;
    if let Some(existing) = read_kt_authority_challenge()? {
        let unexpired = existing["expiresAtEpochSeconds"]
            .as_u64()
            .is_some_and(|expires_at| now <= expires_at);
        let same_proposal = existing["proposalDigest"].as_str() == Some(proposal.digest.as_str())
            && existing["configGeneration"].as_u64() == Some(mesh_config_generation)
            && existing["authorityGeneration"].as_u64() == Some(authority_generation);
        if unexpired && same_proposal {
            return Ok(kt_authority_challenge_response(&existing));
        }
        if unexpired {
            return Err(anyhow!(
                "a different secure mesh KT authority challenge is already pending"
            ));
        }
        ensure!(
            remove_private_state_marker(&kt_authority_challenge_path()?)?,
            "expired secure mesh KT authority challenge could not be removed"
        );
    }
    let challenge = json!({
        "schemaVersion": KT_AUTHORITY_CHALLENGE_SCHEMA_VERSION,
        "challengeId": random_base64url(24),
        "proposalDigest": proposal.digest,
        "configGeneration": mesh_config_generation,
        "authorityGeneration": authority_generation,
        "expiresAtEpochSeconds": now.saturating_add(KT_AUTHORITY_CHALLENGE_TTL_SECONDS),
        "requiresSecurityReset": authority_change_requires_reset(config, proposal)
            || kt_authority_reset_in_progress()?,
    });
    create_private_state_marker(
        &kt_authority_challenge_path()?,
        &serde_json::to_vec(&challenge)?,
    )?;
    Ok(kt_authority_challenge_response(&challenge))
}

fn verify_kt_authority_challenge(
    config: &Value,
    proposal: &KtAuthorityProposal,
    challenge_id: &str,
) -> Result<KtAuthorityChallengeState> {
    let challenge = read_kt_authority_challenge()?
        .ok_or_else(|| anyhow!("secure mesh KT authority challenge is missing"))?;
    ensure!(
        challenge["challengeId"].as_str() == Some(challenge_id),
        "secure mesh KT authority challenge id mismatch"
    );
    ensure!(
        challenge["proposalDigest"].as_str() == Some(proposal.digest.as_str()),
        "secure mesh KT authority challenge proposal mismatch"
    );
    let prepared_config_generation = challenge["configGeneration"]
        .as_u64()
        .ok_or_else(|| anyhow!("secure mesh KT authority challenge is invalid"))?;
    let prepared_authority_generation = challenge["authorityGeneration"]
        .as_u64()
        .ok_or_else(|| anyhow!("secure mesh KT authority challenge is invalid"))?;
    let requires_security_reset = challenge["requiresSecurityReset"]
        .as_bool()
        .ok_or_else(|| anyhow!("secure mesh KT authority challenge is invalid"))?;
    let current_config_generation = config_generation(config, CONFIG_GENERATION_FIELD)?;
    let current_authority_generation = config_generation(config, AUTHORITY_GENERATION_FIELD)?;
    let committed_authority_generation =
        prepared_authority_generation.saturating_add(u64::from(requires_security_reset));
    if current_config_generation > prepared_config_generation
        && current_authority_generation == committed_authority_generation
        && authority_configuration_matches(config, proposal)
    {
        return Ok(KtAuthorityChallengeState::AlreadyCommitted {
            required_security_reset: requires_security_reset,
        });
    }
    ensure!(
        current_config_generation == prepared_config_generation
            && current_authority_generation == prepared_authority_generation,
        "secure mesh KT authority challenge generation is stale"
    );
    ensure!(
        current_secure_mesh_kt_gate_epoch_seconds()?
            <= challenge["expiresAtEpochSeconds"].as_u64().unwrap_or(0),
        "secure mesh KT authority challenge has expired"
    );
    Ok(KtAuthorityChallengeState::Pending {
        requires_security_reset,
    })
}

fn complete_kt_authority_challenge() -> Result<()> {
    ensure!(
        remove_private_state_marker(&kt_authority_challenge_path()?)?,
        "secure mesh KT authority challenge is missing"
    );
    Ok(())
}

/// Store a user-authorized KT pin and opaque directory scope independently from all directory
/// responses. Replacing either authority root requires an explicit destructive security reset.
pub fn key_transparency_configure_authority(params: &Value) -> Result<Value> {
    ensure_only_known_params(
        params,
        &[
            "operation",
            "authorityChallengeId",
            "confirmAuthorityConfiguration",
            "confirmSecurityReset",
            "directoryScopeCommitment",
            "pin",
            "maxSthAgeSeconds",
            "maxFutureSkewSeconds",
            "allowInteraction",
            "secretOverrideTransport",
            "secretOverrides",
        ],
        "secure mesh KT authority configuration",
    )?;
    let proposal = parse_kt_authority_proposal(params)?;
    let operation = text_param(params, &["operation"]).unwrap_or_else(|| "prepare".to_string());
    if operation == "prepare" {
        ensure!(
            bool_param(params, &["confirmAuthorityConfiguration"]) != Some(true)
                && params.get("authorityChallengeId").is_none(),
            "secure mesh KT authority preparation cannot confirm its own challenge"
        );
        let mut config = load_config_without_persistence()?;
        let persisted = read_persisted_config()?;
        if persisted.as_ref() != Some(&config) {
            ensure!(
                !config_contains_native_store_secret_material(&config),
                "secure mesh KT authority preparation requires prior authorized secret migration"
            );
            save_config_raw(&mut config)?;
        }
        return stage_kt_authority_challenge(&config, &proposal);
    }
    ensure!(
        operation == "confirm",
        "secure mesh KT authority configuration operation must be prepare or confirm"
    );
    ensure!(
        bool_param(params, &["confirmAuthorityConfiguration"]) == Some(true),
        "secure mesh KT authority configuration requires explicit user confirmation"
    );
    ensure!(
        bool_param(params, &["allowInteraction"]) == Some(true),
        "secure mesh KT authority confirmation requires foreground user interaction"
    );
    let challenge_id = text_param(params, &["authorityChallengeId"])
        .ok_or_else(|| anyhow!("secure mesh KT authority confirmation challenge id is required"))?;
    let (mut config, mut secret_context) =
        load_config_with_runtime_secret_context_for_authority_reset(params)?;
    let challenge_state = verify_kt_authority_challenge(&config, &proposal, &challenge_id)?;
    if let KtAuthorityChallengeState::AlreadyCommitted {
        required_security_reset,
    } = challenge_state
    {
        if kt_authority_reset_in_progress()? {
            complete_kt_authority_reset()?;
        }
        complete_kt_authority_challenge()?;
        return Ok(json!({
            "ok": true,
            "schemaVersion": CONFIG_SCHEMA_VERSION,
            "authorityProvenance": proposal.pin.provenance().stable_code(),
            "mock": proposal.pin.provenance().is_mock(),
            "productionAuthority": proposal.pin.provenance().production_service_claim_allowed(),
            "scopeCommitted": true,
            "authorityChanged": required_security_reset,
            "alreadyCommitted": true,
            "directoryResponseAccepted": false,
            "privateKeyMaterial": "redacted"
        }));
    }
    let KtAuthorityChallengeState::Pending {
        requires_security_reset,
    } = challenge_state
    else {
        unreachable!("committed challenge returned above")
    };
    let pin_value = proposal.pin_value.clone();
    let pin = &proposal.pin;
    let scope = proposal.scope.clone();
    let max_sth_age_seconds = proposal.max_sth_age_seconds;
    let max_future_skew_seconds = proposal.max_future_skew_seconds;

    let existing = config
        .get("secureMeshKeyTransparency")
        .filter(|value| value.is_object())
        .cloned();
    let existing_scope = config
        .get("secureMeshDirectoryScopeCommitment")
        .and_then(Value::as_str);
    let has_existing_authority_root = existing.is_some() || existing_scope.is_some();
    let authority_changed = has_existing_authority_root
        && (existing.as_ref().and_then(|settings| settings.get("pin")) != Some(&pin_value)
            || existing_scope != Some(scope.as_str()));
    let reset_in_progress = kt_authority_reset_in_progress()?;
    ensure!(
        requires_security_reset == (authority_changed || reset_in_progress),
        "secure mesh KT authority challenge reset binding mismatch"
    );
    if authority_changed || reset_in_progress {
        ensure!(
            text_param(params, &["confirmSecurityReset"]).as_deref()
                == Some("RESET_KEY_TRANSPARENCY_AUTHORITY"),
            "secure mesh KT authority replacement requires explicit security reset"
        );
        if !reset_in_progress {
            begin_kt_authority_reset()?;
        }
        kt_authority_reset_failpoint("after_guard_persisted")?;
        if let Ok(endpoint) = local_endpoint_state(&config) {
            let identity = endpoint.device_identity()?;
            let (secret_store, authorization, namespace) = secret_context
                .secret_store_batch
                .authorization()?
                .ok_or_else(|| {
                    anyhow!("secure mesh MLS selected custody is unavailable for authority reset")
                })?;
            crate::domain::secure_mesh_mls::reset_selected_custody_for_kt_authority_change(
                &identity,
                secret_store.as_ref(),
                &authorization,
                &namespace,
            )?;
        }
        kt_authority_reset_failpoint("after_mls_selected_custody_reset")?;
        crate::domain::secure_mesh_mls::reset_durable_state_for_kt_authority_change()?;
        kt_authority_reset_failpoint("after_mls_durable_state_reset")?;
        if let Some(endpoint_id) = config
            .get("mobileRelayE2ee")
            .and_then(|state| state.get("endpointId"))
            .and_then(Value::as_str)
        {
            let path = secure_mesh_kt_authority_path(endpoint_id)?;
            crate::core::secure_mesh_transparency::reset_kt_persistent_authority_state(path)?;
        }
        kt_authority_reset_failpoint("after_kt_authority_state_reset")?;
        clear_mobile_relay_pairing_state(&mut config)?;
        kt_authority_reset_failpoint("after_pairwise_and_trust_reset")?;
        if let Some(e2ee) = config
            .get_mut("mobileRelayE2ee")
            .and_then(Value::as_object_mut)
        {
            for key in [
                "keyTransparencyResponse",
                "keyTransparencyAuthorization",
                "pendingKeyTransparencyClaim",
                "pendingKeyTransparencyPurpose",
                "directoryVersion",
                "mlsKeyPackageVersion",
                "mlsKeyPackageDigest",
            ] {
                e2ee.remove(key);
            }
        }
    }
    config["secureMeshDirectoryScopeCommitment"] = json!(scope);
    config["secureMeshKeyTransparency"] = json!({
        "pin": pin_value,
        "maxSthAgeSeconds": max_sth_age_seconds,
        "maxFutureSkewSeconds": max_future_skew_seconds
    });
    if authority_changed {
        let next_authority_generation = config_generation(&config, AUTHORITY_GENERATION_FIELD)?
            .checked_add(1)
            .filter(|generation| *generation <= KT_JSON_SAFE_INTEGER_MAX)
            .ok_or_else(|| anyhow!("mobile relay authority generation overflow"))?;
        config[AUTHORITY_GENERATION_FIELD] = json!(next_authority_generation);
    }
    if authority_changed || reset_in_progress {
        save_config_with_runtime_secret_context_for_authority_reset(
            &mut config,
            &mut secret_context,
        )?;
    } else {
        save_config_with_runtime_secret_context(&mut config, &mut secret_context)?;
    }
    if authority_changed || reset_in_progress {
        kt_authority_reset_failpoint("after_replacement_config_persisted")?;
        complete_kt_authority_reset()?;
    }
    complete_kt_authority_challenge()?;
    Ok(json!({
        "ok": true,
        "schemaVersion": CONFIG_SCHEMA_VERSION,
        "authorityProvenance": pin.provenance().stable_code(),
        "mock": pin.provenance().is_mock(),
        "productionAuthority": pin.provenance().production_service_claim_allowed(),
        "scopeCommitted": true,
        "authorityChanged": authority_changed || reset_in_progress,
        "directoryResponseAccepted": false,
        "privateKeyMaterial": "redacted"
    }))
}

/// Prepare the exact public directory claim for the preconfigured authority. A real MLS
/// KeyPackage publication must already exist; zero/sentinel commitments are rejected.
pub fn key_transparency_publication_request(params: &Value) -> Result<Value> {
    ensure_only_known_params(
        params,
        &[
            "endpointKind",
            "allowInteraction",
            "secretOverrideTransport",
            "secretOverrides",
        ],
        "secure mesh KT publication request",
    )?;
    let (mut config, mut secret_context) = load_config_with_runtime_secret_context(params)?;
    let endpoint_kind = text_param(params, &["endpointKind"])
        .or_else(|| {
            config
                .get("mobileRelayE2ee")
                .and_then(|state| state.get("endpointKind"))
                .and_then(Value::as_str)
                .map(str::to_string)
        })
        .unwrap_or_else(|| "desktop_sidecar".to_string());
    let scope = configured_directory_scope_commitment(&config)?.to_string();
    let _ = configured_kt_pin(&config)?;
    ensure_mobile_relay_endpoint_material(&mut config, &endpoint_kind)?;
    let state = config
        .get("mobileRelayE2ee")
        .ok_or_else(|| anyhow!("mobile relay E2EE endpoint state is missing"))?;
    let current_directory_version = state
        .get("directoryVersion")
        .and_then(Value::as_u64)
        .unwrap_or(0);
    let directory_version = current_directory_version
        .checked_add(1)
        .ok_or_else(|| anyhow!("secure mesh directory publication version overflow"))?;
    ensure!(
        directory_version <= KT_JSON_SAFE_INTEGER_MAX,
        "secure mesh directory publication version exceeds the cross-language safe range"
    );
    let mls_key_package_version = state
        .get("mlsKeyPackageVersion")
        .and_then(Value::as_u64)
        .filter(|version| *version > 0)
        .ok_or_else(|| anyhow!("secure mesh real MLS KeyPackage publication is required"))?;
    let mls_key_package_digest = state
        .get("mlsKeyPackageDigest")
        .and_then(Value::as_str)
        .ok_or_else(|| anyhow!("secure mesh real MLS KeyPackage digest is required"))?;
    validate_canonical_sha256_hex(mls_key_package_digest, "MLS KeyPackage digest")?;
    ensure!(
        mls_key_package_digest
            != "0000000000000000000000000000000000000000000000000000000000000000",
        "secure mesh MLS KeyPackage digest cannot be a sentinel"
    );
    let claim = build_local_directory_claim(
        &config,
        &scope,
        directory_version,
        "active",
        mls_key_package_digest,
        mls_key_package_version,
    )?;
    let purpose = derive_local_publication_purpose(&config, &claim)?;
    config["mobileRelayE2ee"]["pendingKeyTransparencyClaim"] = serde_json::to_value(&claim)?;
    config["mobileRelayE2ee"]["pendingKeyTransparencyPurpose"] = json!(purpose.stable_code());
    save_config_with_runtime_secret_context(&mut config, &mut secret_context)?;
    Ok(json!({
        "ok": true,
        "schemaVersion": CONFIG_SCHEMA_VERSION,
        "authorityOperation": "publish-directory-claim",
        "claim": claim,
        "derivedPurpose": purpose.stable_code(),
        "privateKeyMaterial": "redacted",
        "authorityRequired": true
    }))
}

pub fn key_transparency_revocation_request(params: &Value) -> Result<Value> {
    ensure_only_known_params(
        params,
        &[
            "confirmRevocation",
            "allowInteraction",
            "secretOverrideTransport",
            "secretOverrides",
        ],
        "secure mesh KT revocation request",
    )?;
    ensure!(
        bool_param(params, &["confirmRevocation"]) == Some(true),
        "secure mesh directory revocation requires explicit user confirmation"
    );
    let (mut config, mut secret_context) = load_config_with_runtime_secret_context(params)?;
    let scope = configured_directory_scope_commitment(&config)?.to_string();
    let _ = configured_kt_pin(&config)?;
    let state = config
        .get("mobileRelayE2ee")
        .ok_or_else(|| anyhow!("mobile relay E2EE endpoint state is missing"))?;
    let current: UntrustedDirectoryResponse = serde_json::from_value(
        state
            .get("keyTransparencyResponse")
            .cloned()
            .ok_or_else(|| anyhow!("secure mesh current KT directory response is required"))?,
    )
    .map_err(|_| anyhow!("secure mesh current KT directory response is invalid"))?;
    let directory_version = current
        .claim
        .directory_version
        .checked_add(1)
        .ok_or_else(|| anyhow!("secure mesh directory revocation version overflow"))?;
    let claim = build_local_directory_claim(
        &config,
        &scope,
        directory_version,
        "revoked",
        &current.claim.key_material.mls_key_package_digest,
        current.claim.key_material.mls_key_package_version,
    )?;
    config["mobileRelayE2ee"]["pendingKeyTransparencyClaim"] = serde_json::to_value(&claim)?;
    config["mobileRelayE2ee"]["pendingKeyTransparencyPurpose"] =
        json!(DirectoryAuthorizationPurpose::Revocation.stable_code());
    save_config_with_runtime_secret_context(&mut config, &mut secret_context)?;
    Ok(json!({
        "ok": true,
        "schemaVersion": CONFIG_SCHEMA_VERSION,
        "authorityOperation": "publish-directory-revocation",
        "claim": claim,
        "derivedPurpose": DirectoryAuthorizationPurpose::Revocation.stable_code(),
        "privateKeyMaterial": "redacted"
    }))
}

/// Verify a service response only against the previously configured pin/scope and the exact
/// locally persisted pending claim. The transport caller cannot select purpose or replace roots.
pub fn key_transparency_provision(params: &Value) -> Result<Value> {
    ensure_only_known_params(
        params,
        &[
            "response",
            "allowInteraction",
            "secretOverrideTransport",
            "secretOverrides",
        ],
        "secure mesh KT provision",
    )?;
    for forbidden in ["pin", "directoryScopeCommitment", "authorizationPurpose"] {
        ensure!(
            params.get(forbidden).is_none(),
            "secure mesh KT provision cannot replace local authority configuration or purpose"
        );
    }
    let (mut config, mut secret_context) = load_config_with_runtime_secret_context(params)?;
    let scope = configured_directory_scope_commitment(&config)?.to_string();
    let pin = configured_kt_pin(&config)?;
    let response_value = params
        .get("response")
        .filter(|value| value.is_object())
        .cloned()
        .ok_or_else(|| anyhow!("secure mesh KT directory response is required"))?;
    let response: UntrustedDirectoryResponse = serde_json::from_value(response_value.clone())
        .map_err(|_| anyhow!("secure mesh KT directory response is invalid"))?;
    let state = config
        .get("mobileRelayE2ee")
        .ok_or_else(|| anyhow!("mobile relay E2EE endpoint state is missing"))?;
    let pending: SecureMeshDirectoryLeafClaim = serde_json::from_value(
        state
            .get("pendingKeyTransparencyClaim")
            .cloned()
            .ok_or_else(|| anyhow!("secure mesh pending KT publication claim is required"))?,
    )
    .map_err(|_| anyhow!("secure mesh pending KT publication claim is invalid"))?;
    let purpose = state
        .get("pendingKeyTransparencyPurpose")
        .and_then(Value::as_str)
        .map(parse_local_directory_authorization_purpose)
        .transpose()?
        .ok_or_else(|| anyhow!("secure mesh pending KT publication purpose is missing"))?;
    ensure!(
        pending.endpoint.directory_scope_commitment == scope
            && response.claim == pending
            && response.claim.leaf_hash()? == pending.leaf_hash()?,
        "secure mesh KT service response does not match the exact pending local claim"
    );
    config["mobileRelayE2ee"]["keyTransparencyResponse"] = response_value.clone();
    let authorized = authorize_exact_local_directory_response(
        &config,
        response_value.clone(),
        &pending,
        OffsetDateTime::now_utc(),
        purpose,
    )?;
    let mls_key_package_authorized = if pending.revoked() {
        ensure!(
            purpose == DirectoryAuthorizationPurpose::Revocation,
            "secure mesh revoked local claim requires revocation authorization"
        );
        None
    } else {
        let mls_authorized = authorize_exact_local_directory_response(
            &config,
            response_value,
            &pending,
            OffsetDateTime::now_utc(),
            DirectoryAuthorizationPurpose::MlsKeyPackage,
        )?;
        ensure_mobile_relay_key_transparency(&mut config)?;
        Some(mls_authorized.authorization_digest().to_string())
    };
    config["mobileRelayE2ee"]["directoryVersion"] = json!(pending.directory_version);
    config["mobileRelayE2ee"]["mlsKeyPackageVersion"] =
        json!(pending.key_material.mls_key_package_version);
    config["mobileRelayE2ee"]["mlsKeyPackageDigest"] =
        json!(pending.key_material.mls_key_package_digest);
    if let Some(e2ee) = config
        .get_mut("mobileRelayE2ee")
        .and_then(Value::as_object_mut)
    {
        e2ee.remove("pendingKeyTransparencyClaim");
        e2ee.remove("pendingKeyTransparencyPurpose");
    }
    save_config_with_runtime_secret_context(&mut config, &mut secret_context)?;
    Ok(json!({
        "ok": true,
        "schemaVersion": CONFIG_SCHEMA_VERSION,
        "authorityProvenance": pin.provenance().stable_code(),
        "mock": pin.provenance().is_mock(),
        "productionAuthority": pin.provenance().production_service_claim_allowed(),
        "purpose": purpose.stable_code(),
        "treeSize": authorized.signed_tree_head().tree_size,
        "authorizationDigest": authorized.authorization_digest(),
        "mlsKeyPackageAuthorizationDigest": mls_key_package_authorized,
        "privateKeyMaterial": "redacted"
    }))
}

pub fn key_transparency_self_monitor(params: &Value) -> Result<Value> {
    ensure_only_known_params(
        params,
        &[
            "response",
            "allowInteraction",
            "secretOverrideTransport",
            "secretOverrides",
        ],
        "secure mesh KT self monitor",
    )?;
    let (mut config, mut secret_context) = load_config_with_runtime_secret_context(params)?;
    let response_value = params
        .get("response")
        .filter(|value| value.is_object())
        .cloned()
        .ok_or_else(|| anyhow!("secure mesh KT self-monitor response is required"))?;
    let response: UntrustedDirectoryResponse = serde_json::from_value(response_value.clone())
        .map_err(|_| anyhow!("secure mesh KT self-monitor response is invalid"))?;
    let local = local_endpoint_state(&config)?;
    let identity = local.device_identity()?;
    let bundle = local.pairwise_prekey_bundle()?;
    let scope = configured_directory_scope_commitment(&config)?;
    ensure!(
        response.claim.endpoint.directory_scope_commitment == scope,
        "secure mesh KT self-monitor response scope differs from local authority"
    );
    let purpose = if response.claim.revoked() {
        DirectoryAuthorizationPurpose::Revocation
    } else {
        DirectoryAuthorizationPurpose::SelfMonitor
    };
    let signed_prekey_digest = signed_prekey_bundle_digest(&bundle)?;
    let one_time_prekey_digest = one_time_prekey_batch_digest(&bundle)?;
    let local_mls_key_package_digest = config
        .get("mobileRelayE2ee")
        .and_then(|state| state.get("mlsKeyPackageDigest"))
        .and_then(Value::as_str)
        .map(str::to_string)
        .ok_or_else(|| anyhow!("secure mesh local MLS KeyPackage digest is required"))?;
    validate_canonical_sha256_hex(&local_mls_key_package_digest, "local MLS KeyPackage digest")?;
    let local_mls_key_package_version = config
        .get("mobileRelayE2ee")
        .and_then(|state| state.get("mlsKeyPackageVersion"))
        .and_then(Value::as_u64)
        .filter(|version| *version > 0)
        .ok_or_else(|| anyhow!("secure mesh local MLS KeyPackage version is required"))?;
    let mut authority = open_mobile_relay_directory_authority(&config, &local.endpoint_id)?;
    let now_epoch_seconds = current_secure_mesh_kt_gate_epoch_seconds()?;
    #[cfg(test)]
    if config
        .get("secureMeshKeyTransparency")
        .and_then(|settings| settings.get("pin"))
        .and_then(|pin| pin.get("provenance"))
        .and_then(Value::as_str)
        == Some("local-acceptance-mock")
    {
        authority.observe_response_gossip_for_test(&response, now_epoch_seconds)?;
    }
    let authorized = authority.authorize_request(
        response.clone(),
        DirectoryAuthorizationRequest::for_full_subject(
            purpose,
            scope,
            &identity,
            response.claim.directory_version,
            &signed_prekey_digest,
            &one_time_prekey_digest,
            bundle.prekey_publication_version,
            &local_mls_key_package_digest,
            local_mls_key_package_version,
        ),
        now_epoch_seconds,
    )?;
    let mls_key_package_authorized = if authorized.claim().revoked() {
        None
    } else {
        Some(authority.authorize_request(
            response.clone(),
            DirectoryAuthorizationRequest::for_mls(
                DirectoryAuthorizationPurpose::MlsKeyPackage,
                scope,
                &identity,
                response.claim.directory_version,
                &local_mls_key_package_digest,
                local_mls_key_package_version,
            ),
            now_epoch_seconds,
        )?)
    };
    config["mobileRelayE2ee"]["keyTransparencyResponse"] = response_value;
    config["mobileRelayE2ee"]["keyTransparencyAuthorization"] = json!({
        "provenance": authorized.provenance().stable_code(),
        "productionAuthority": authorized.provenance().production_service_claim_allowed(),
        "selfMonitorDigest": authorized.authorization_digest(),
        "mlsKeyPackageDigest": mls_key_package_authorized
            .as_ref()
            .map(AuthorizedDirectoryLeaf::authorization_digest),
        "purpose": purpose.stable_code(),
        "treeSize": authorized.signed_tree_head().tree_size,
        "issuedAtEpochSeconds": authorized.signed_tree_head().issued_at_epoch_seconds,
        "observedAtEpochSeconds": authorized.freshness().observed_at_epoch_seconds
    });
    if authorized.claim().revoked() {
        config["mobileRelayE2ee"]["localDirectoryState"] = json!("revoked");
        clear_mobile_relay_pairing_state(&mut config)?;
    } else {
        config["mobileRelayE2ee"]["localDirectoryState"] = json!("active");
    }
    save_config_with_runtime_secret_context(&mut config, &mut secret_context)?;
    Ok(json!({
        "ok": true,
        "schemaVersion": CONFIG_SCHEMA_VERSION,
        "purpose": purpose.stable_code(),
        "directoryState": if authorized.claim().revoked() { "revoked" } else { "active" },
        "treeSize": authorized.signed_tree_head().tree_size,
        "issuedAtEpochSeconds": authorized.signed_tree_head().issued_at_epoch_seconds,
        "observedAtEpochSeconds": authorized.freshness().observed_at_epoch_seconds,
        "authorizationDigest": authorized.authorization_digest(),
        "mlsKeyPackageAuthorizationDigest": mls_key_package_authorized
            .as_ref()
            .map(AuthorizedDirectoryLeaf::authorization_digest),
        "privateKeyMaterial": "redacted"
    }))
}

pub fn key_transparency_gossip(params: &Value) -> Result<Value> {
    ensure_only_known_params(
        params,
        &[
            "operation",
            "gossip",
            "envelope",
            "allowInteraction",
            "secretOverrideTransport",
            "secretOverrides",
        ],
        "secure mesh KT gossip",
    )?;
    let operation = params
        .get("operation")
        .and_then(Value::as_str)
        .ok_or_else(|| anyhow!("secure mesh KT gossip operation is required"))?;
    let (config, mut secret_context) = load_config_with_runtime_secret_context_for_operation(
        params,
        "Secure Mesh KT gossip authorization batch",
        mobile_relay_e2ee_secret_store_authorization_batch_operation_count().saturating_add(4),
    )?;
    let local_endpoint_id = descriptor_text(
        config
            .get("mobileRelayE2ee")
            .ok_or_else(|| anyhow!("secure mesh KT gossip local endpoint is missing"))?,
        "endpointId",
    )?;
    let now_epoch_seconds = current_secure_mesh_kt_gate_epoch_seconds()?;
    let mut pairwise_operation = mobile_relay_pairwise_operation_with_runtime_secret_context(
        &config,
        "Secure Mesh KT gossip authorization batch",
        4,
        &mut secret_context,
    )?;
    match operation {
        "seal" => {
            let gossip: SecureMeshKtGossipPayload = serde_json::from_value(
                params
                    .get("gossip")
                    .filter(|value| value.is_object())
                    .cloned()
                    .ok_or_else(|| anyhow!("secure mesh KT gossip payload is required"))?,
            )
            .map_err(|_| anyhow!("secure mesh KT gossip payload is invalid"))?;
            let mut authority = open_mobile_relay_directory_authority(&config, &local_endpoint_id)?;
            let checkpoint = authority.validate_outgoing_gossip(&gossip, now_epoch_seconds)?;
            let control = SecureMeshKtGossipControlMessage {
                message_type: SECURE_MESH_KT_GOSSIP_CONTROL_TYPE.to_string(),
                gossip,
            };
            let envelope = seal_mobile_relay_payload_with_pairwise_operation_and_gate(
                &config,
                crate::core::secure_mesh_crypto::SecureMeshPayloadKind::ServiceAction,
                &serde_json::to_value(control)?,
                &mut pairwise_operation,
                PairwiseDirectoryGate::KtGossipControl,
            )?;
            Ok(json!({
                "ok": true,
                "operation": "seal",
                "envelope": envelope,
                "treeSize": checkpoint.tree_size,
                "bodyRedacted": true,
                "privateKeyMaterial": "redacted"
            }))
        }
        "open" => {
            let envelope = secure_envelope_param(params)
                .ok_or_else(|| anyhow!("secure mesh KT gossip encrypted envelope is required"))?;
            let opened = open_mobile_relay_payload_with_pairwise_operation_and_gate(
                &config,
                &envelope,
                crate::core::secure_mesh_crypto::SecureMeshPayloadKind::ServiceAction,
                &mut pairwise_operation,
                PairwiseDirectoryGate::KtGossipControl,
            )?;
            let control: SecureMeshKtGossipControlMessage = serde_json::from_slice(&opened)
                .map_err(|_| anyhow!("secure mesh KT gossip control payload is invalid"))?;
            ensure!(
                control.message_type == SECURE_MESH_KT_GOSSIP_CONTROL_TYPE,
                "secure mesh KT gossip control type is invalid"
            );
            let mut authority = open_mobile_relay_directory_authority(&config, &local_endpoint_id)?;
            let checkpoint = authority.observe_gossip(&control.gossip, now_epoch_seconds)?;
            Ok(json!({
                "ok": true,
                "operation": "open",
                "treeSize": checkpoint.tree_size,
                "bodyRedacted": true,
                "privateKeyMaterial": "redacted"
            }))
        }
        _ => Err(anyhow!("secure mesh KT gossip operation is unsupported")),
    }
}

pub fn key_transparency_status(params: &Value) -> Result<Value> {
    ensure_only_known_params(params, &[], "secure mesh KT status")?;
    let config = load_config_without_persistence()?;
    let reset_guard = kt_authority_reset_in_progress();
    let reset_in_progress = reset_guard.as_ref().copied().unwrap_or(true);
    let guard_valid = reset_guard.is_ok();
    let settings = config
        .get("secureMeshKeyTransparency")
        .filter(|value| value.is_object())
        .cloned()
        .map(serde_json::from_value::<SecureMeshKtVerifierConfiguration>)
        .transpose()
        .map_err(|_| anyhow!("secure mesh KT local verifier configuration is invalid"))?;
    let pin = settings
        .as_ref()
        .map(|settings| settings.pin.clone().into_pin())
        .transpose()?;
    let endpoint_id = config
        .get("mobileRelayE2ee")
        .and_then(|state| state.get("endpointId"))
        .and_then(Value::as_str)
        .filter(|value| !value.trim().is_empty());
    let (checkpoint, security_blocked) = if !reset_in_progress {
        if let (Some(endpoint_id), Some(settings)) = (endpoint_id, settings.as_ref()) {
            let authority = SecureMeshDirectoryAuthority::open(
                secure_mesh_kt_authority_path(endpoint_id)?,
                settings.pin.clone().into_pin()?,
                KtFreshnessPolicy::strict(
                    settings.max_sth_age_seconds,
                    settings.max_future_skew_seconds,
                )?,
            )?;
            (
                authority.latest_checkpoint()?,
                authority.security_blocked()?,
            )
        } else {
            (None, false)
        }
    } else {
        (None, true)
    };
    Ok(json!({
        "ok": guard_valid,
        "schemaVersion": CONFIG_SCHEMA_VERSION,
        "configured": settings.is_some(),
        "authorityProvenance": pin.as_ref().map(|pin| pin.provenance().stable_code()),
        "mock": pin.as_ref().is_some_and(|pin| pin.provenance().is_mock()),
        "productionAuthority": pin.as_ref().is_some_and(|pin| pin.provenance().production_service_claim_allowed()),
        "directoryScopeCommitted": config
            .get("secureMeshDirectoryScopeCommitment")
            .and_then(Value::as_str)
            .is_some_and(|value| !value.trim().is_empty()),
        "resetInProgress": reset_in_progress,
        "guardValid": guard_valid,
        "securityBlocked": security_blocked,
        "latestCheckpoint": checkpoint.map(|checkpoint| json!({
            "treeSize": checkpoint.tree_size,
            "issuedAtEpochSeconds": checkpoint.issued_at_epoch_seconds,
            "rootCommitted": true,
            "mapRootCommitted": true
        })),
        "privateKeyMaterial": "redacted"
    }))
}

pub fn pairing_create(params: &Value) -> Result<Value> {
    let (mut config, mut secret_context) = load_config_with_runtime_secret_context(params)?;
    let (registration, _secure_mesh) =
        register_local_relay_endpoint(params, &mut config, "desktop_sidecar")?;
    if let Some(providers) = relay_authorized_providers_param(params) {
        config["authorizedProviders"] = providers;
    }
    let pairing_id = format!("pair_{}", Uuid::new_v4());
    let pairing_code = random_base64url(12);
    config["pairingId"] = json!(pairing_id);
    config["lastPairingCode"] = json!(pairing_code);
    let response = json!({
        "ok": true,
        "schemaVersion": CONFIG_SCHEMA_VERSION,
        "transportProtocol": SECURE_MESH_PROTOCOL_VERSION,
        "pairingId": pairing_id,
        "pairingCode": pairing_code,
        "endpointRegistration": registration,
        "serverVisiblePairingState": false
    });
    let invite = one_time_pairing_invite(&config, &response);
    config["relayEnabled"] = json!(true);
    clear_pairing_presentation(&mut config);
    save_config_with_runtime_secret_context(&mut config, &mut secret_context)?;
    let mut output = with_config(response, &config);
    if let (Some(object), Some(invite)) = (output.as_object_mut(), invite) {
        object.insert("mobileRelayPairingInvite".to_string(), invite);
    }
    Ok(output)
}

pub fn pairing_claim(params: &Value) -> Result<Value> {
    let (mut config, mut secret_context) = load_config_with_runtime_secret_context(params)?;
    apply_pairing_invite_params_with_context(&mut config, params, Some(&mut secret_context))?;
    let pairing_id = text_param(params, &["pairingId", "pairing_id"])
        .filter(|value| !value.trim().is_empty())
        .or_else(|| {
            config
                .get("pairingId")
                .and_then(Value::as_str)
                .map(str::to_string)
        })
        .ok_or_else(|| anyhow!("mobile relay pairing claim requires --pairing-id"))?;
    let code = text_param(params, &["pairingCode", "code"])
        .filter(|value| !value.trim().is_empty())
        .or_else(|| {
            config
                .get("lastPairingCode")
                .and_then(Value::as_str)
                .map(str::to_string)
        })
        .filter(|value| !value.trim().is_empty())
        .ok_or_else(|| anyhow!("mobile relay pairing claim requires --pairing-code"))?;
    let pc_secure_mesh = pairing_claim_secure_mesh_descriptor_from_params(params)?
        .or_else(|| peer_secure_mesh_descriptor(&config))
        .ok_or_else(|| anyhow!("mobile relay pairing claim requires PC secure mesh invite"))?;
    apply_peer_secure_mesh_descriptor_with_context(
        &mut config,
        &pc_secure_mesh,
        true,
        Some(&mut secret_context),
    )?;
    let expected_code = config
        .get("lastPairingCode")
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty());
    if let Some(expected_code) = expected_code {
        ensure!(
            expected_code == code,
            "mobile relay pairing code does not match the local one-time invite"
        );
    }
    let (registration, mobile_secure_mesh) =
        register_local_relay_endpoint(params, &mut config, "mobile")?;
    let claim_proof = mobile_relay_claim_proof(&config, &pairing_id, &mobile_secure_mesh)?;
    config["paired"] = json!(true);
    config["relayEnabled"] = json!(true);
    let response = json!({
        "ok": true,
        "schemaVersion": CONFIG_SCHEMA_VERSION,
        "transportProtocol": SECURE_MESH_PROTOCOL_VERSION,
        "pairingId": pairing_id,
        "endpointRegistration": registration,
        "outOfBandPairingResponse": {
            "mobileSecureMesh": mobile_secure_mesh,
            "secureMeshClaimProof": claim_proof
        },
        "serverVisiblePairingState": false
    });
    clear_pairing_presentation(&mut config);
    save_config_with_runtime_secret_context(&mut config, &mut secret_context)?;
    Ok(with_config(response, &config))
}

pub fn pairing_status(params: &Value) -> Result<Value> {
    if let Some(response) = params
        .get("outOfBandPairingResponse")
        .filter(|value| value.is_object())
    {
        let (mut config, mut secret_context) = load_config_with_runtime_secret_context(params)?;
        apply_out_of_band_pairing_response_with_context(
            &mut config,
            response,
            Some(&mut secret_context),
        )?;
        save_config_with_runtime_secret_context(&mut config, &mut secret_context)?;
        return Ok(pairing_status_response(&config));
    }
    let (config, _) = load_config_with_runtime_secret_overrides(params)?;
    Ok(pairing_status_response(&config))
}

fn pairing_status_response(config: &Value) -> Value {
    with_config(
        json!({
            "ok": true,
            "schemaVersion": CONFIG_SCHEMA_VERSION,
            "transportProtocol": SECURE_MESH_PROTOCOL_VERSION,
            "registered": config
                .get("relayRegisteredEndpointId")
                .and_then(Value::as_str)
                .is_some_and(|value| !value.is_empty()),
            "paired": config.get("paired").and_then(Value::as_bool).unwrap_or(false),
            "serverVisiblePairingState": false
        }),
        config,
    )
}

fn refresh_pairing_status_with_context(
    params: &Value,
    config: &mut Value,
    secret_context: &mut RuntimeSecretContext,
) -> Result<Value> {
    let _ = secret_context;
    let response = json!({
        "ok": true,
        "schemaVersion": CONFIG_SCHEMA_VERSION,
        "registered": config
            .get("relayRegisteredEndpointId")
            .and_then(Value::as_str)
            .is_some_and(|value| !value.is_empty()),
        "paired": config.get("paired").and_then(Value::as_bool).unwrap_or(false),
        "serverVisiblePairingState": false
    });
    let _ = params;
    Ok(response)
}

fn refresh_pairwise_acceptance_if_pending(
    params: &Value,
    config: &mut Value,
    secret_context: &mut RuntimeSecretContext,
) -> Result<()> {
    let Some(state) = config.get("mobileRelayE2ee") else {
        return Ok(());
    };
    let endpoint_kind = state
        .get("endpointKind")
        .and_then(Value::as_str)
        .unwrap_or_default();
    let paired = config
        .get("paired")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    let pending_intro = state.get("pendingPairwiseIntro").is_some();
    if endpoint_kind != "mobile" || !paired || !pending_intro {
        return Ok(());
    }
    let _ = refresh_pairing_status_with_context(params, config, secret_context)?;
    Ok(())
}

pub fn pairing_revoke(params: &Value) -> Result<Value> {
    let (mut config, mut secret_context) = load_config_with_runtime_secret_context(params)?;
    ensure_mobile_relay_endpoint_descriptor(&mut config, "desktop_sidecar")?;
    let current_epoch = config
        .get("mobileRelayE2ee")
        .and_then(|state| state.get("mailboxRotationEpoch"))
        .and_then(Value::as_u64)
        .unwrap_or(current_mailbox_rotation_epoch()?);
    let next_epoch = current_epoch
        .checked_add(1)
        .ok_or_else(|| anyhow!("secure client relay mailbox rotation epoch overflow"))?;
    config["mobileRelayE2ee"]["mailboxRotationEpoch"] = json!(next_epoch);
    let (registration, _) = register_local_relay_endpoint(params, &mut config, "desktop_sidecar")?;
    clear_mobile_relay_pairing_state(&mut config)?;
    save_config_with_runtime_secret_context(&mut config, &mut secret_context)?;
    Ok(with_config(
        json!({
            "ok": true,
            "schemaVersion": CONFIG_SCHEMA_VERSION,
            "mailboxRotated": true,
            "endpointRegistration": registration,
            "serverVisiblePairingState": false
        }),
        &config,
    ))
}

pub fn pc_check_in(params: &Value) -> Result<Value> {
    let (mut config, mut secret_context) = load_config_with_runtime_secret_context(params)?;
    pc_check_in_with_context(params, &mut config, &mut secret_context)
}

fn pc_check_in_with_context(
    params: &Value,
    config: &mut Value,
    secret_context: &mut RuntimeSecretContext,
) -> Result<Value> {
    let (response, _) = register_local_relay_endpoint(params, config, "desktop_sidecar")?;
    if let Some(providers) = relay_authorized_providers_param(params) {
        config["authorizedProviders"] = providers;
    }
    save_config_with_runtime_secret_context(config, secret_context)?;
    let mut output = response;
    if let Some(object) = output.as_object_mut() {
        if let Some(providers) = public_authorized_providers(config) {
            object
                .entry("authorizedProviders".to_string())
                .or_insert(providers);
        }
    }
    Ok(output)
}

pub fn commands_poll(params: &Value) -> Result<Value> {
    let (config, _) = load_config_with_runtime_secret_overrides(params)?;
    commands_poll_with_config(params, &config)
}

fn commands_poll_with_config(params: &Value, config: &Value) -> Result<Value> {
    let relay = canonical_relay_context(params, config)?;
    relay.transport.envelope_sync(
        &relay.scope,
        &local_canonical_mailbox_token(config)?,
        params.get("afterDeliverySequence").and_then(Value::as_u64),
        Some(params.get("limit").and_then(Value::as_u64).unwrap_or(10)),
        Some(
            params
                .get("leaseMs")
                .and_then(Value::as_u64)
                .unwrap_or(30_000),
        ),
    )
}

pub fn command_complete(params: &Value) -> Result<Value> {
    let (config, _) = load_config_with_runtime_secret_overrides(params)?;
    command_complete_with_config(params, &config)
}

fn command_complete_with_config(params: &Value, config: &Value) -> Result<Value> {
    let command_id = text_param(params, &["commandId"])
        .filter(|value| !value.trim().is_empty())
        .ok_or_else(|| anyhow!("mobile relay command complete requires --command-id"))?;
    let result_envelope = params
        .get("resultEnvelope")
        .filter(|value| validate_secure_envelope(value).is_ok())
        .cloned()
        .ok_or_else(|| anyhow!("mobile relay command complete requires --result-envelope"))?;
    let lease_id = text_param(params, &["leaseId"])
        .filter(|value| !value.trim().is_empty())
        .ok_or_else(|| anyhow!("mobile relay command complete requires --lease-id"))?;
    let lease_generation = params
        .get("leaseGeneration")
        .and_then(Value::as_u64)
        .filter(|value| *value > 0)
        .ok_or_else(|| anyhow!("mobile relay command complete requires --lease-generation"))?;
    let relay = canonical_relay_context(params, config)?;
    let result_envelope = relay_envelope_from_value(&result_envelope)?;
    let send = relay.transport.envelope_send(
        &relay.scope,
        &result_envelope,
        Some("mobile_relay"),
        None,
    )?;
    let ack = relay.transport.envelope_ack(
        &relay.scope,
        &local_canonical_mailbox_token(config)?,
        &command_id,
        &lease_id,
        lease_generation,
    )?;
    Ok(json!({
        "ok": true,
        "schemaVersion": CONFIG_SCHEMA_VERSION,
        "resultSend": send,
        "ack": ack
    }))
}

pub fn command_create(params: &Value) -> Result<Value> {
    ensure_secure_mesh_protected_operation_allowed()?;
    let config = load_config()?;
    let secure_envelope = secure_envelope_param(params)
        .ok_or_else(|| anyhow!("mobile relay command create requires --secure-envelope"))?;
    let envelope = relay_envelope_from_value(&secure_envelope)?;
    let relay = canonical_relay_context(params, &config)?;
    relay
        .transport
        .envelope_send(&relay.scope, &envelope, Some("mobile_relay"), None)
}

pub fn command_create_secure(params: &Value) -> Result<Value> {
    let (config, mut secret_context) = load_config_with_runtime_secret_context_for_operation(
        params,
        "Mobile Relay secure command create authorization batch",
        mobile_relay_e2ee_secret_store_authorization_batch_operation_count().saturating_add(3),
    )?;
    ensure_peer_verified(&config)?;
    let body = json_param(params, "body")
        .or_else(|| json_param(params, "payload"))
        .unwrap_or_else(|| json!({}));
    let command_kind = text_param(params, &["commandKind", "type", "command"])
        .filter(|value| !value.trim().is_empty())
        .unwrap_or_else(|| "agent.message.send".to_string());
    let target_agent_id = text_param(params, &["targetAgentId", "agentId", "agent", "target"]);
    let workspace_id = text_param(params, &["workspaceId", "workspace"])
        .filter(|value| !value.trim().is_empty())
        .unwrap_or_else(|| "default".to_string());
    let payload = secure_command_payload(
        &config,
        &command_kind,
        target_agent_id.as_deref(),
        &workspace_id,
        body,
    )?;
    let payload_command_id = payload
        .get("commandId")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_string();
    let payload_idempotency_key = payload
        .get("idempotencyKey")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_string();
    let mut pairwise_operation = mobile_relay_pairwise_operation_with_runtime_secret_context(
        &config,
        "Mobile Relay secure command create authorization batch",
        3,
        &mut secret_context,
    )?;
    let envelope = seal_mobile_relay_payload_with_pairwise_operation(
        &config,
        crate::core::secure_mesh_crypto::SecureMeshPayloadKind::Command,
        &payload,
        &mut pairwise_operation,
    )?;
    let relay = canonical_relay_context(params, &config)?;
    let relay_envelope = relay_envelope_from_value(&envelope)?;
    let mut response =
        relay
            .transport
            .envelope_send(&relay.scope, &relay_envelope, Some("mobile_relay"), None)?;
    response
        .as_object_mut()
        .ok_or_else(|| anyhow!("mobile relay secure command response is invalid"))?
        .insert(
            "secureCommandBinding".to_string(),
            json!({
                "payloadCommandId": payload_command_id,
                "idempotencyKey": payload_idempotency_key,
                "commandKind": command_kind,
            }),
        );
    Ok(response)
}

pub fn command_result(params: &Value) -> Result<Value> {
    let (config, _) = load_config_with_runtime_secret_overrides(params)?;
    command_result_with_config(params, &config)
}

fn command_result_with_config(params: &Value, config: &Value) -> Result<Value> {
    let synced = commands_poll_with_config(params, config)?;
    let deliveries = synced
        .get("envelopes")
        .and_then(Value::as_array)
        .ok_or_else(|| anyhow!("secure client relay sync response is missing envelopes"))?;
    let requested_delivery_id = text_param(params, &["deliveryId"]);
    let delivery = deliveries
        .iter()
        .find(|delivery| {
            requested_delivery_id.as_deref().is_none_or(|expected| {
                delivery.get("deliveryId").and_then(Value::as_str) == Some(expected)
            })
        })
        .ok_or_else(|| anyhow!("secure client relay result envelope is not available"))?;
    let envelope = relay_envelope_from_delivery(delivery)?;
    Ok(json!({
        "ok": true,
        "schemaVersion": CONFIG_SCHEMA_VERSION,
        "command": {
            "resultEnvelope": serde_json::from_str::<Value>(&envelope.to_json()?)?,
            "deliveryId": envelope.delivery_id(),
            "leaseId": delivery.get("leaseId").cloned().unwrap_or(Value::Null),
            "leaseGeneration": delivery.get("leaseGeneration").cloned().unwrap_or(Value::Null)
        },
        "cursor": synced.get("cursor").cloned().unwrap_or(Value::Null)
    }))
}

pub fn command_result_secure(params: &Value) -> Result<Value> {
    let (mut config, mut secret_context) = load_config_with_runtime_secret_context_for_operation(
        params,
        "Mobile Relay secure result operation authorization batch",
        mobile_relay_e2ee_secret_store_authorization_batch_operation_count().saturating_add(3),
    )?;
    refresh_pairwise_acceptance_if_pending(params, &mut config, &mut secret_context)?;
    let response = command_result_with_config(params, &config)?;
    let Some(envelope) = response
        .get("command")
        .and_then(|command| command.get("resultEnvelope"))
        .filter(|value| value.is_object())
    else {
        return Err(anyhow!(
            "mobile relay secure result missing encrypted result envelope"
        ));
    };
    ensure_peer_verified(&config)?;
    let mut pairwise_operation = mobile_relay_pairwise_operation_with_runtime_secret_context(
        &config,
        "Mobile Relay secure result operation authorization batch",
        3,
        &mut secret_context,
    )?;
    let opened = open_mobile_relay_payload_with_pairwise_operation(
        &config,
        envelope,
        crate::core::secure_mesh_crypto::SecureMeshPayloadKind::ResultPayload,
        &mut pairwise_operation,
    )?;
    let result_payload = serde_json::from_slice::<Value>(&opened)
        .map_err(|error| anyhow!("mobile relay secure result payload is not JSON: {}", error))?;
    let command = response
        .get("command")
        .ok_or_else(|| anyhow!("secure client relay result delivery metadata is missing"))?;
    let delivery_id = command
        .get("deliveryId")
        .and_then(Value::as_str)
        .ok_or_else(|| anyhow!("secure client relay result delivery id is missing"))?;
    let lease_id = command
        .get("leaseId")
        .and_then(Value::as_str)
        .ok_or_else(|| anyhow!("secure client relay result lease id is missing"))?;
    let lease_generation = command
        .get("leaseGeneration")
        .and_then(Value::as_u64)
        .ok_or_else(|| anyhow!("secure client relay result lease generation is missing"))?;
    let relay = canonical_relay_context(params, &config)?;
    let ack = relay.transport.envelope_ack(
        &relay.scope,
        &local_canonical_mailbox_token(&config)?,
        delivery_id,
        lease_id,
        lease_generation,
    )?;
    let response_summary = secure_result_response_summary(&response);
    Ok(json!({
        "ok": true,
        "schemaVersion": CONFIG_SCHEMA_VERSION,
        "response": response_summary,
        "ack": ack,
        "openedResult": result_payload,
        "bodyRedacted": true
    }))
}

pub fn command_result_replay_proof(params: &Value) -> Result<Value> {
    let (mut config, mut secret_context) = load_config_with_runtime_secret_context_for_operation(
        params,
        "Mobile Relay secure result replay proof authorization batch",
        mobile_relay_e2ee_secret_store_authorization_batch_operation_count().saturating_add(5),
    )?;
    refresh_pairwise_acceptance_if_pending(params, &mut config, &mut secret_context)?;
    let response = command_result_with_config(params, &config)?;
    let Some(envelope) = response
        .get("command")
        .and_then(|command| command.get("resultEnvelope"))
        .filter(|value| value.is_object())
    else {
        return Err(anyhow!(
            "mobile relay secure result replay proof missing encrypted result envelope"
        ));
    };
    let mut pairwise_operation = mobile_relay_pairwise_operation_with_runtime_secret_context(
        &config,
        "Mobile Relay secure result replay proof authorization batch",
        5,
        &mut secret_context,
    )?;
    result_envelope_replay_proof_with_pairwise_operation(
        &config,
        envelope,
        secure_result_response_summary(&response),
        &mut pairwise_operation,
    )
}

pub fn e2ee_status(params: &Value) -> Result<Value> {
    let secret_read_authorized = should_authorize_secret_read(params);
    let mut authorized_context = None;
    let mut unauthorized_overrides = RuntimeSecretOverrides::default();
    let config = if secret_read_authorized {
        let (config, context) = load_config_with_runtime_secret_context_for_operation(
            params,
            "Mobile Relay E2EE status authorization batch",
            mobile_relay_e2ee_secret_store_authorization_batch_operation_count().saturating_add(2),
        )?;
        authorized_context = Some(context);
        config
    } else {
        let (config, overrides) = load_config_for_read(params)?;
        unauthorized_overrides = overrides;
        config
    };
    let local = if secret_read_authorized {
        local_endpoint_state(&config)
            .ok()
            .map(|endpoint| endpoint.public_descriptor())
            .transpose()?
    } else {
        local_endpoint_public_descriptor(&config).ok()
    };
    let peer = peer_endpoint_state(&config).ok();
    let peer_verified_flag = config
        .get("mobileRelayE2ee")
        .and_then(|state| state.get("peerVerified"))
        .and_then(Value::as_bool)
        .unwrap_or(false);
    let peer_trust_record_verified = peer_verified_flag && is_peer_trust_record_verified(&config);
    let authority_reset_in_progress = kt_authority_reset_in_progress().unwrap_or(true);
    let pairwise_directory_freshness = current_secure_mesh_kt_gate_epoch_seconds()
        .and_then(|now| require_current_pairwise_directory_authority(&config, now));
    let pairwise_directory_fresh = pairwise_directory_freshness.is_ok();
    let pairwise_status = if let Some(context) = authorized_context.as_mut() {
        authorized_pairwise_session_status(&config, context)
    } else {
        AuthorizedPairwiseSessionStatus::blocked(
            "pairwise_session_verification_requires_authorization",
        )
    };
    let secret_overrides = authorized_context
        .as_ref()
        .map(|context| &context.overrides)
        .unwrap_or(&unauthorized_overrides);
    let mut secret_store = mobile_relay_e2ee_secret_store_status(&config, secret_overrides);
    if let Some(object) = secret_store.as_object_mut() {
        object.insert(
            "fullStatusAuthorized".to_string(),
            json!(secret_read_authorized),
        );
        object.insert(
            "authorizationRequiredForFullStatus".to_string(),
            json!(!secret_read_authorized),
        );
    }
    let mandatory_foundation_complete = secret_store
        .get("capabilityReport")
        .and_then(|report| report.get("mandatoryFoundationComplete"))
        .and_then(Value::as_bool)
        .unwrap_or(false);
    let custody_operational = secret_store
        .get("custodyOperational")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    let secure_session_established = local.is_some()
        && peer.is_some()
        && peer_trust_record_verified
        && mandatory_foundation_complete
        && custody_operational
        && pairwise_directory_fresh
        && !authority_reset_in_progress
        && pairwise_status.established;
    let mut blockers = Vec::new();
    if local.is_none() {
        blockers.push("local_endpoint_unavailable");
    }
    if peer.is_none() {
        blockers.push("peer_endpoint_unavailable");
    }
    if !peer_trust_record_verified {
        blockers.push("peer_trust_not_verified");
    }
    if !mandatory_foundation_complete {
        blockers.push("mandatory_capability_foundation_incomplete");
    }
    if !custody_operational {
        blockers.push("safe_secret_custody_not_operational");
    }
    if !pairwise_directory_fresh {
        blockers.push("key_transparency_label_refresh_required");
    }
    if authority_reset_in_progress {
        blockers.push("key_transparency_authority_reset_incomplete");
    }
    if let Some(blocker) = pairwise_status.blocker {
        blockers.push(blocker);
    }
    Ok(json!({
        "ok": true,
        "schemaVersion": CONFIG_SCHEMA_VERSION,
        "protocolVersion": MOBILE_RELAY_E2EE_PROTOCOL_VERSION,
        "local": local,
        "peer": peer.map(|endpoint| json!({
            "protocolVersion": MOBILE_RELAY_E2EE_PROTOCOL_VERSION,
            "endpointId": endpoint.endpoint_id,
            "endpointKind": endpoint.endpoint_kind,
                "fingerprint": endpoint.fingerprint
            })),
        "peerVerified": peer_trust_record_verified,
        "peerVerifiedFlag": peer_verified_flag,
        "peerTrustRecordVerified": peer_trust_record_verified,
        "secretStore": secret_store,
        "fullStatusAuthorized": secret_read_authorized,
        "authorizationRequiredForFullStatus": !secret_read_authorized,
        "mandatoryFoundationComplete": mandatory_foundation_complete,
        "secureSessionEstablished": secure_session_established,
        "keyTransparencyFresh": pairwise_directory_fresh,
        "keyTransparencyFreshness": pairwise_directory_freshness.ok().map(|freshness| json!({
            "treeSize": freshness.tree_size,
            "expiresAtEpochSeconds": freshness.expires_at_epoch_seconds,
            "labelBound": true,
            "purposeBound": true,
            "proofReverifiedFromAuthorityState": true
        })),
        "keyTransparencyAuthorityResetInProgress": authority_reset_in_progress,
        "capabilityProjection": pairwise_status.capability_projection,
        "blockers": blockers,
        "pairingInvite": redacted_pairing_invite(config.get("mobileRelayPairingInvite"))
    }))
}

struct AuthorizedPairwiseSessionStatus {
    established: bool,
    blocker: Option<&'static str>,
    capability_projection: Option<Value>,
}

impl AuthorizedPairwiseSessionStatus {
    fn blocked(blocker: &'static str) -> Self {
        Self {
            established: false,
            blocker: Some(blocker),
            capability_projection: None,
        }
    }
}

fn authorized_pairwise_session_status(
    config: &Value,
    secret_context: &mut RuntimeSecretContext,
) -> AuthorizedPairwiseSessionStatus {
    let Ok(endpoint) = local_endpoint_state(config) else {
        return AuthorizedPairwiseSessionStatus::blocked("pairwise_session_missing");
    };
    let Ok(session_id) = session_id(config) else {
        return AuthorizedPairwiseSessionStatus::blocked("pairwise_session_missing");
    };
    let Ok(store) = mobile_relay_pairwise_store() else {
        return AuthorizedPairwiseSessionStatus::blocked("pairwise_session_unavailable");
    };
    let Ok(Some(_record)) = store.read_record(&session_id, &endpoint.endpoint_id) else {
        return AuthorizedPairwiseSessionStatus::blocked("pairwise_session_missing");
    };
    let Ok(Some(authorization_session)) = secret_context.shared_authorization_session() else {
        return AuthorizedPairwiseSessionStatus::blocked("pairwise_session_custody_mismatch");
    };
    if authorization_session.backend() != store.secret_store_backend() {
        return AuthorizedPairwiseSessionStatus::blocked("pairwise_session_custody_mismatch");
    }
    let Ok(Some(session)) = store.load_session_with_authorized_session(
        &session_id,
        &endpoint.endpoint_id,
        &authorization_session,
    ) else {
        return AuthorizedPairwiseSessionStatus::blocked("pairwise_session_unavailable");
    };
    secret_context
        .overrides
        .mark_secret_store_authorization(&authorization_session);
    if !session.handshake_confirmed() {
        return AuthorizedPairwiseSessionStatus::blocked("pairwise_handshake_incomplete");
    }
    let Some(projection) = session.capability_projection() else {
        return AuthorizedPairwiseSessionStatus::blocked("pairwise_capability_negotiation_missing");
    };
    let Ok(capability_projection) = serde_json::to_value(projection) else {
        return AuthorizedPairwiseSessionStatus::blocked("pairwise_session_unavailable");
    };
    AuthorizedPairwiseSessionStatus {
        established: true,
        blocker: None,
        capability_projection: Some(capability_projection),
    }
}

pub fn e2ee_secret_store_self_test(_params: &Value) -> Result<Value> {
    let temp_dir = env::temp_dir().join(format!(
        "lico-mobile-relay-secret-store-self-test-{}",
        Uuid::new_v4()
    ));
    let previous_portable =
        crate::platform::paths::set_portable_data_dir_override(Some(temp_dir.clone()));
    let result = e2ee_secret_store_self_test_in_current_portable_dir();
    crate::platform::paths::set_portable_data_dir_override(previous_portable);
    let _ = fs::remove_dir_all(&temp_dir);
    match result {
        Ok(value) => Ok(value),
        Err(error) => {
            // Classify locally for a stable redacted receipt; never return the
            // formatted error or any platform/runtime detail to the caller.
            let message = format!("{error:#}");
            let failure_category = if message.contains("secure_mesh_authorization_required") {
                "system_authorization_required"
            } else if message.contains("security status -34018") {
                "keychain_entitlement_missing"
            } else if message.contains("security status -25293") {
                "keychain_authentication_failed"
            } else if message.contains("security status -25308") {
                "keychain_interaction_not_allowed"
            } else if message.contains("access control unavailable") {
                "platform_access_control_unavailable"
            } else if message.contains("authorization callback") {
                "system_authorization_callback_unavailable"
            } else if message.contains("system authentication") {
                "system_authentication_unavailable"
            } else if message.contains("operation budget") {
                "authorization_operation_budget_exceeded"
            } else if message.contains("secret-store self-test cleanup") {
                "secret_store_cleanup_failed"
            } else {
                "platform_secret_store_unavailable"
            };
            let failure_operation = if message.contains(" secret store write failed ") {
                "write"
            } else if message.contains(" secret store read failed ") {
                "read"
            } else if message.contains(" secret store delete failed ") {
                "delete"
            } else if message.contains("self-test cleanup") {
                "cleanup"
            } else {
                "authorization-or-access-control"
            };
            let selected_store = selected_mobile_relay_secret_store();
            let capability_report = selected_store
                .capability_evaluation()
                .ok()
                .and_then(|evaluation| serde_json::to_value(evaluation.report()).ok())
                .unwrap_or(Value::Null);
            Ok(json!({
            "ok": false,
            "backend": selected_store.backend(),
            "supportedBackends": NATIVE_SECRET_STORE_SUPPORTED_BACKENDS,
            "selfTestPassed": false,
            "redacted": true,
            "rawPrivateMaterialIncluded": false,
            "rawPlaintextIncluded": false,
            "rawPublicWireBytesIncluded": false,
            "reportLeakScan": true,
            "capabilityReport": capability_report,
            "operationFailed": true,
            "failureCategory": failure_category,
            "failureOperation": failure_operation,
            "failureSummary": "selected secret custody operation failed; local details redacted"
            }))
        }
    }
}

fn e2ee_secret_store_self_test_in_current_portable_dir() -> Result<Value> {
    let mut config = default_config();
    let mut secret_store_batch = MobileRelaySecretStoreAuthBatch::new(
        "Mobile Relay E2EE secret store self-test authorization batch",
        mobile_relay_secret_store_self_test_authorization_batch_operation_count(),
    );
    ensure_mobile_relay_endpoint_descriptor(&mut config, "desktop_sidecar")?;
    persist_config_secret_material_to_native_store_with_batch(
        &mut config,
        &mut secret_store_batch,
    )?;
    save_config_raw(&mut config)?;

    let persisted = fs::read_to_string(config_path()?).unwrap_or_default();
    let persisted_private_fields: Vec<&str> = MOBILE_RELAY_E2EE_NATIVE_SECRET_FIELDS
        .iter()
        .filter_map(|(field, _)| {
            if persisted.contains(&format!("\"{}\"", field)) {
                Some(*field)
            } else {
                None
            }
        })
        .collect();
    let mut loaded = normalize_config(config.clone());
    let mut overrides = RuntimeSecretOverrides::default();
    hydrate_config_secret_material_from_native_store_with_batch(
        &mut loaded,
        &mut overrides,
        &mut secret_store_batch,
    )?;
    let local_rehydrated = local_endpoint_state(&loaded).is_ok();
    let secret_store = mobile_relay_e2ee_secret_store_status(&loaded, &overrides);
    let (store, authorization_session, namespace) =
        secret_store_batch.authorization()?.ok_or_else(|| {
            anyhow!("mobile relay native secret-store self-test authorization batch is unavailable")
        })?;
    let shared_secret_class_round_trip = verify_secret_class_round_trip_with_session(
        store.as_ref(),
        &authorization_session,
        native_secret_store_shared_secret_classes_namespace()?,
        NATIVE_SECRET_STORE_SHARED_SECRET_CLASSES,
    )?;
    let shared_secret_class_round_trip_passed = shared_secret_class_round_trip
        .all_classes_persisted
        && shared_secret_class_round_trip.all_classes_deleted
        && !shared_secret_class_round_trip.raw_secret_material_included;
    let all_private_keys_in_selected_custody = secret_store
        .get("allPrivateKeysInSelectedCustody")
        .and_then(Value::as_bool)
        == Some(true);
    let authorization_claim_consistent = secret_store
        .get("authorization")
        .and_then(|authorization| authorization.get("claimConsistent"))
        .and_then(Value::as_bool)
        == Some(true);
    let pairing_secret_in_selected_custody = secret_store
        .get("pairingSecretInSelectedCustody")
        .and_then(Value::as_bool)
        == Some(true);
    let capability_report = authorization_session
        .capability_report()
        .cloned()
        .or_else(|| {
            store
                .capability_evaluation()
                .ok()
                .map(|evaluation| evaluation.report())
        })
        .ok_or_else(|| anyhow!("mobile relay capability report is unavailable"))?;
    let custody_strategy = capability_report
        .custody
        .as_ref()
        .map(|selection| selection.strategy)
        .ok_or_else(|| anyhow!("mobile relay safe custody strategy is unavailable"))?;
    let restart_semantics = capability_report
        .custody
        .as_ref()
        .map(|selection| selection.restart_semantics)
        .ok_or_else(|| anyhow!("mobile relay custody restart semantics are unavailable"))?;
    let persistent_custody = custody_strategy == SecretCustodyStrategy::OsSecureStore;
    let shared_secret_class_persistence_ready =
        persistent_custody && shared_secret_class_round_trip_passed;
    let restart_requires_re_pair_rekey =
        restart_semantics == CustodyRestartSemantics::RePairRekeyAfterRestart;
    let stale_session_restoration_rejected = if restart_requires_re_pair_rekey {
        let fresh_store = EphemeralSecretStore::new();
        let bundle_handle = native_e2ee_secret_bundle_handle_for_namespace(&namespace)?;
        fresh_store.get_secret(&bundle_handle)?.is_none()
    } else {
        true
    };
    let self_test_passed = local_rehydrated
        && all_private_keys_in_selected_custody
        && pairing_secret_in_selected_custody
        && authorization_claim_consistent
        && shared_secret_class_round_trip_passed
        && stale_session_restoration_rejected
        && persisted_private_fields.is_empty();
    cleanup_native_secret_store_fields_for_store_with_session(
        &config,
        store.as_ref(),
        &authorization_session,
        &namespace,
    )
    .context("mobile relay secret-store self-test cleanup failed")?;
    let capability_report_value = serde_json::to_value(&capability_report)?;
    let secret_service_probe = platform_linux_secret_service_probe_snapshot(
        persistent_custody && shared_secret_class_round_trip_passed,
        persisted_private_fields.is_empty(),
    );
    Ok(json!({
        "ok": self_test_passed,
        "backend": store.backend(),
        "selectedBackend": store.backend(),
        "supportedBackends": NATIVE_SECRET_STORE_SUPPORTED_BACKENDS,
        "selfTestPassed": self_test_passed,
        "redacted": true,
        "rawPrivateMaterialIncluded": false,
        "rawPlaintextIncluded": false,
        "rawPublicWireBytesIncluded": false,
        "reportLeakScan": true,
        "localEndpointRehydrated": local_rehydrated,
        "capabilityReport": capability_report_value,
        "secretServiceProbe": secret_service_probe,
        "secretStore": secret_store,
        "sharedSecretClassRoundTrip": {
            "backend": shared_secret_class_round_trip.backend,
            "secretClasses": shared_secret_class_round_trip.secret_classes,
            "requestedClassCount": shared_secret_class_round_trip.requested_class_count,
            "storedClassCount": shared_secret_class_round_trip.persisted_class_count,
            "deletedClassCount": shared_secret_class_round_trip.deleted_class_count,
            "allClassesStored": shared_secret_class_round_trip.all_classes_persisted,
            "allClassesDeleted": shared_secret_class_round_trip.all_classes_deleted,
            "rawSecretMaterialIncluded": shared_secret_class_round_trip.raw_secret_material_included
        },
        "secretStoreAuthorization": secret_store_authorization_report(&authorization_session),
        "sharedSecretClassRoundTripPassed": shared_secret_class_round_trip_passed,
        "sharedSecretClassPersistenceReady": shared_secret_class_persistence_ready,
        "ordinaryFileSecretArtifactCount": persisted_private_fields.len(),
        "restartProof": {
            "staleSessionRestorationRejected": stale_session_restoration_rejected,
            "rePairRekeyRequired": restart_requires_re_pair_rekey
        },
        "portableConfigPrivateFieldsPresent": persisted_private_fields,
        "portableConfigPrivateMaterialRedacted": persisted_private_fields.is_empty()
    }))
}

pub fn commands_sync(params: &Value) -> Result<Value> {
    let command_limit = params.get("limit").and_then(Value::as_u64).unwrap_or(10) as usize;
    let (mut config, mut secret_context) = load_config_with_runtime_secret_context_for_operation(
        params,
        "Mobile Relay commands sync operation authorization batch",
        mobile_relay_e2ee_secret_store_authorization_batch_operation_count()
            .saturating_add(command_limit.saturating_mul(4))
            .saturating_add(4),
    )?;
    let check_in = pc_check_in_with_context(params, &mut config, &mut secret_context)?;
    let polled = commands_poll_with_config(params, &config)?;
    let deliveries = polled
        .get("envelopes")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    let commands = deliveries
        .iter()
        .map(local_command_from_relay_delivery)
        .collect::<Result<Vec<_>>>()?;
    let secure_command_count = commands
        .iter()
        .filter(|command| {
            let command_type = command
                .get("type")
                .and_then(Value::as_str)
                .unwrap_or_default();
            command_type == "secure_mesh.envelope" || command_type == "secure-mesh.envelope"
        })
        .count();
    let pairwise_operation_count = secure_command_count.saturating_mul(4).saturating_add(2);
    let mut pairwise_operation = None;
    let mut completed = Vec::<Value>::new();
    let mut visible_commands = Vec::<Value>::new();
    for command in &commands {
        let command_id = command
            .get("commandId")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_string();
        let command_type = command
            .get("type")
            .and_then(Value::as_str)
            .unwrap_or_default();
        let redacted_command = redacted_relay_command(command);
        visible_commands.push(redacted_command.clone());
        if command_type == "secure_mesh.envelope" || command_type == "secure-mesh.envelope" {
            if pairwise_operation.is_none() {
                match mobile_relay_pairwise_operation_with_runtime_secret_context(
                    &config,
                    "Mobile Relay commands sync operation authorization batch",
                    pairwise_operation_count,
                    &mut secret_context,
                ) {
                    Ok(operation) => {
                        pairwise_operation = Some(operation);
                    }
                    Err(_error) => {
                        completed.push(json!({
                            "command": redacted_command,
                            "ok": false,
                            "bodyRedacted": true,
                            "error": SECURE_MESH_ENDPOINT_CRYPTO_RUNTIME_FAILED_DETAIL,
                            "completion": {
                                "ok": false,
                                "code": SECURE_MESH_ENDPOINT_CRYPTO_RUNTIME_FAILED_CODE
                            }
                        }));
                        continue;
                    }
                }
            }
            let operation = pairwise_operation
                .as_mut()
                .ok_or_else(|| anyhow!("mobile relay commands sync authorization batch missing"))?;
            match execute_secure_envelope_command_with_pairwise_operation(
                command, params, &config, operation,
            ) {
                Ok(result_envelope) => {
                    let mut completion_params = json!({
                        "commandId": command_id,
                        "ok": true,
                        "resultEnvelope": result_envelope,
                        "leaseId": command.get("leaseId").cloned().unwrap_or(Value::Null),
                        "leaseGeneration": command.get("leaseGeneration").cloned().unwrap_or(Value::Null)
                    });
                    attach_runtime_secret_overrides_param(&mut completion_params, params);
                    attach_canonical_relay_params(&mut completion_params, params);
                    let completion = command_complete_with_config(&completion_params, &config)?;
                    completed.push(json!({
                        "command": redacted_command,
                        "ok": true,
                        "bodyRedacted": true,
                        "resultEnvelope": result_envelope,
                        "completion": completion
                    }));
                }
                Err(_error) => {
                    completed.push(json!({
                        "command": redacted_command,
                        "ok": false,
                        "bodyRedacted": true,
                        "error": SECURE_MESH_ENDPOINT_CRYPTO_RUNTIME_FAILED_DETAIL,
                        "completion": {
                            "ok": false,
                            "code": SECURE_MESH_ENDPOINT_CRYPTO_RUNTIME_FAILED_CODE
                        }
                    }));
                }
            }
            continue;
        };
        let mut rejection = reject_plaintext_relay_command(command);
        if let Some(object) = rejection.as_object_mut() {
            object.insert("command".to_string(), redacted_command);
        }
        completed.push(rejection);
    }
    Ok(json!({
        "ok": true,
        "schemaVersion": CONFIG_SCHEMA_VERSION,
        "checkIn": check_in,
        "commands": visible_commands,
        "completed": completed
    }))
}

fn reject_plaintext_relay_command(command: &Value) -> Value {
    let command_type = command
        .get("type")
        .and_then(Value::as_str)
        .unwrap_or_default();
    let command_label = if command_type.is_empty() {
        "<missing>"
    } else {
        command_type
    };
    json!({
        "ok": false,
        "bodyRedacted": true,
        "error": format!(
            "mobile relay plaintext command {} requires SecureEnvelope transport",
            command_label
        ),
        "completion": {
            "ok": false,
            "code": "mobile_relay_plaintext_command_rejected"
        }
    })
}

fn redacted_relay_command(command: &Value) -> Value {
    json!({
        "commandId": command.get("commandId").and_then(Value::as_str).unwrap_or_default(),
        "type": command.get("type").and_then(Value::as_str).unwrap_or_default(),
        "bodyRedacted": true,
        "secureEnvelopePresent": command_has_secure_envelope(command)
    })
}

fn command_has_secure_envelope(command: &Value) -> bool {
    command.get("envelope").is_some_and(Value::is_object)
        || command
            .get("payload")
            .and_then(|payload| payload.get("envelope"))
            .is_some_and(Value::is_object)
}

fn secure_result_response_summary(response: &Value) -> Value {
    let command = response.get("command").unwrap_or(&Value::Null);
    json!({
        "ok": response.get("ok").and_then(Value::as_bool).unwrap_or(false),
        "command": {
            "commandId": command.get("commandId").and_then(Value::as_str).unwrap_or_default(),
            "status": command.get("status").and_then(Value::as_str).unwrap_or_default(),
            "resultEnvelopePresent": command
                .get("resultEnvelope")
                .map(Value::is_object)
                .unwrap_or(false)
        },
        "ackPurge": {
            "purged": response
                .get("ackPurge")
                .and_then(|ack| ack.get("purged"))
                .and_then(Value::as_bool)
                .unwrap_or(false)
        },
        "bodyRedacted": true
    })
}

#[cfg(test)]
fn result_envelope_replay_proof(
    config: &Value,
    envelope: &Value,
    response_summary: Value,
) -> Result<Value> {
    ensure_peer_verified(config)?;
    let mut pairwise_operation = mobile_relay_pairwise_operation(
        config,
        "Mobile Relay secure result replay proof authorization batch",
        5,
    )?;
    result_envelope_replay_proof_with_pairwise_operation(
        config,
        envelope,
        response_summary,
        &mut pairwise_operation,
    )
}

fn result_envelope_replay_proof_with_pairwise_operation(
    config: &Value,
    envelope: &Value,
    response_summary: Value,
    pairwise_operation: &mut MobileRelayPairwiseOperation,
) -> Result<Value> {
    ensure_peer_verified(config)?;
    validate_secure_envelope(envelope)?;
    let opened = open_mobile_relay_payload_with_pairwise_operation(
        config,
        envelope,
        crate::core::secure_mesh_crypto::SecureMeshPayloadKind::ResultPayload,
        pairwise_operation,
    )?;
    let first_payload = serde_json::from_slice::<Value>(&opened).map_err(|error| {
        anyhow!(
            "mobile relay secure replay proof payload is not JSON: {}",
            error
        )
    })?;
    let first_open_ok = first_payload.get("ok").and_then(Value::as_bool) == Some(true);
    let first_body_redacted =
        first_payload.get("bodyRedacted").and_then(Value::as_bool) == Some(true);
    let first_evaluation_code = first_payload
        .get("evaluation")
        .and_then(|evaluation| evaluation.get("code"))
        .and_then(Value::as_str)
        .unwrap_or_default();
    let first_execution_outcome = first_payload
        .get("execution")
        .and_then(|execution| execution.get("outcome"))
        .and_then(Value::as_str)
        .unwrap_or_default();
    let replay_rejected = match open_mobile_relay_payload_with_pairwise_operation(
        config,
        envelope,
        crate::core::secure_mesh_crypto::SecureMeshPayloadKind::ResultPayload,
        pairwise_operation,
    ) {
        Ok(_) => false,
        Err(error) => is_pairwise_replay_rejection_error(&error),
    };
    let ack_purge_ready = response_summary
        .get("ackPurge")
        .and_then(|ack| ack.get("purged"))
        .and_then(Value::as_bool)
        == Some(true);
    let result_envelope_present = response_summary
        .get("command")
        .and_then(|command| command.get("resultEnvelopePresent"))
        .and_then(Value::as_bool)
        == Some(true);
    let proof_ready =
        first_open_ok && first_body_redacted && replay_rejected && result_envelope_present;
    Ok(json!({
        "ok": proof_ready,
        "schemaVersion": CONFIG_SCHEMA_VERSION,
        "resultEnvelopePresent": result_envelope_present,
        "ackPurgeReady": ack_purge_ready,
        "firstOpenOk": first_open_ok,
        "firstOpenBodyRedacted": first_body_redacted,
        "firstOpenEvaluationCode": first_evaluation_code,
        "firstOpenExecutionOutcome": first_execution_outcome,
        "replayRejected": replay_rejected,
        "replayErrorRedacted": true,
        "bodyRedacted": true
    }))
}

fn is_pairwise_replay_rejection(error: &str) -> bool {
    let normalized = error.to_ascii_lowercase();
    normalized.contains("replay detected")
        || normalized.contains("stale ratchet epoch")
        || normalized.contains("stale chain index")
}

fn is_pairwise_replay_rejection_error(error: &anyhow::Error) -> bool {
    is_pairwise_replay_rejection(&format!("{error:#}"))
}

fn attach_runtime_secret_overrides_param(target: &mut Value, source: &Value) {
    if source
        .get("secretOverrideTransport")
        .and_then(Value::as_str)
        .map(str::trim)
        != Some(RUNTIME_SECRET_OVERRIDE_TRANSPORT)
    {
        return;
    }
    if let Some(overrides) = source
        .get("secretOverrides")
        .filter(|value| value.is_object())
    {
        target["secretOverrideTransport"] = json!(RUNTIME_SECRET_OVERRIDE_TRANSPORT);
        target["secretOverrides"] = overrides.clone();
    }
}

fn attach_canonical_relay_params(target: &mut Value, source: &Value) {
    for key in [
        "relaySessionToken",
        "relayCsrfToken",
        "relayTenantId",
        "relayAccountId",
        "relayWorkspaceId",
    ] {
        if let Some(value) = source.get(key).and_then(Value::as_str) {
            target[key] = json!(value);
        }
    }
}

#[cfg(test)]
fn execute_secure_envelope_command(command: &Value, params: &Value) -> Result<Value> {
    let (config, _) = load_config_with_runtime_secret_overrides(params)?;
    ensure_peer_verified(&config)?;
    let mut pairwise_operation = mobile_relay_pairwise_operation(
        &config,
        "Mobile Relay secure command operation authorization batch",
        5,
    )?;
    execute_secure_envelope_command_with_pairwise_operation(
        command,
        params,
        &config,
        &mut pairwise_operation,
    )
}

fn execute_secure_envelope_command_with_pairwise_operation(
    command: &Value,
    params: &Value,
    config: &Value,
    pairwise_operation: &mut MobileRelayPairwiseOperation,
) -> Result<Value> {
    ensure_peer_verified(config)?;
    let envelope = command
        .get("envelope")
        .cloned()
        .ok_or_else(|| anyhow!("secure mesh relay command is missing envelope"))?;
    validate_secure_envelope(&envelope)?;
    let opened = open_mobile_relay_payload_with_pairwise_operation(
        config,
        &envelope,
        crate::core::secure_mesh_crypto::SecureMeshPayloadKind::Command,
        pairwise_operation,
    )?;
    let payload: Value = serde_json::from_slice(&opened)
        .map_err(|error| anyhow!("secure mesh command payload is not JSON: {}", error))?;
    let context = secure_command_context(config, params, &payload)?;
    let ledger_path = crate::core::secure_mesh_command::default_secure_command_ledger_path()?;
    let mut ledger =
        crate::core::secure_mesh_command::SecureCommandSqliteReplayLedger::open(ledger_path)?;
    let mut executor = crate::core::secure_mesh_command::SecureCommandRuntimeExecutor;
    let completed_at = now_iso();
    let execution = crate::core::secure_mesh_command::execute_secure_command_json(
        &payload,
        &context,
        &mut ledger,
        &mut executor,
        completed_at,
    )
    .unwrap_or_else(|_error| {
        json!({
            "ok": false,
            "protocolVersion": crate::core::secure_mesh::SECURE_MESH_COMMAND_PROTOCOL_VERSION,
            "code": SECURE_MESH_ENDPOINT_CRYPTO_RUNTIME_FAILED_CODE,
            "error": SECURE_MESH_ENDPOINT_CRYPTO_RUNTIME_FAILED_DETAIL,
            "bodyRedacted": true
        })
    });
    seal_mobile_relay_payload_with_pairwise_operation(
        config,
        crate::core::secure_mesh_crypto::SecureMeshPayloadKind::ResultPayload,
        &execution,
        pairwise_operation,
    )
}

fn secure_command_payload(
    config: &Value,
    command_kind: &str,
    target_agent_id: Option<&str>,
    workspace_id: &str,
    body: Value,
) -> Result<Value> {
    let endpoint = local_endpoint_state(config)?;
    let peer = peer_endpoint_state(config)?;
    let created_at = now_iso();
    let expires_at = timestamp_after_seconds(MOBILE_RELAY_COMMAND_TTL_SECONDS)?;
    Ok(json!({
        "schema": crate::core::secure_mesh::SECURE_MESH_COMMAND_PROTOCOL_VERSION,
        "commandId": format!("cmd_{}", Uuid::new_v4()),
        "commandKind": command_kind,
        "senderIdentity": {
            "endpointId": endpoint.endpoint_id,
            "identityFingerprint": endpoint.fingerprint,
            "trustState": "verified",
            "endpointKind": endpoint.endpoint_kind
        },
        "targetBinding": {
            "targetEndpointId": peer.endpoint_id,
            "targetAgentId": target_agent_id.map(Value::from).unwrap_or(Value::Null),
            "workspaceId": workspace_id
        },
        "riskClass": if matches!(
            command_kind,
            "agent.sessions.list" | "agent.sessions.describe"
        ) {
            "read_only"
        } else {
            "safe_write"
        },
        "requiresUserConfirmation": false,
        "idempotencyKey": format!("idem_{}", Uuid::new_v4()),
        "createdAt": created_at,
        "expiresAt": expires_at,
        "body": body
    }))
}

fn secure_command_context(config: &Value, params: &Value, payload: &Value) -> Result<Value> {
    let endpoint = local_endpoint_state(config)?;
    let peer = peer_endpoint_state(config)?;
    let has_agent_binding = payload
        .get("targetBinding")
        .and_then(|binding| binding.get("targetAgentId"))
        .and_then(Value::as_str)
        .map(|value| !value.trim().is_empty())
        .unwrap_or(false);
    let command_kind = payload
        .get("commandKind")
        .and_then(Value::as_str)
        .unwrap_or_default();
    let allowed_agents = if has_agent_binding {
        allowed_agent_ids(params, command_kind)?
    } else {
        json!([])
    };
    let allowed_workspaces = json_param(params, "allowedWorkspaceIds")
        .filter(Value::is_array)
        .unwrap_or_else(|| json!(["default"]));
    Ok(json!({
        "localEndpointId": endpoint.endpoint_id,
        "senderEndpointId": peer.endpoint_id,
        "senderIdentityFingerprint": peer.fingerprint,
        "senderTrustState": "verified",
        "senderEndpointKind": peer.endpoint_kind,
        "senderRosterActive": true,
        "targetRosterActive": true,
        "sessionOrEpochValid": true,
        "userConfirmed": false,
        "allowedWorkspaceIds": allowed_workspaces,
        "allowedAgentIds": allowed_agents,
        "now": now_iso()
    }))
}

#[cfg(test)]
fn seal_mobile_relay_payload(
    config: &Value,
    kind: crate::core::secure_mesh_crypto::SecureMeshPayloadKind,
    payload: &Value,
) -> Result<Value> {
    let mut pairwise_operation = mobile_relay_pairwise_operation(
        config,
        "Mobile Relay pairwise payload authorization batch",
        3,
    )?;
    seal_mobile_relay_payload_with_pairwise_operation(
        config,
        kind,
        payload,
        &mut pairwise_operation,
    )
}

fn seal_mobile_relay_payload_with_pairwise_operation(
    config: &Value,
    kind: crate::core::secure_mesh_crypto::SecureMeshPayloadKind,
    payload: &Value,
    pairwise_operation: &mut MobileRelayPairwiseOperation,
) -> Result<Value> {
    seal_mobile_relay_payload_with_pairwise_operation_and_gate(
        config,
        kind,
        payload,
        pairwise_operation,
        PairwiseDirectoryGate::Required,
    )
}

fn seal_mobile_relay_payload_with_pairwise_operation_and_gate(
    config: &Value,
    kind: crate::core::secure_mesh_crypto::SecureMeshPayloadKind,
    payload: &Value,
    pairwise_operation: &mut MobileRelayPairwiseOperation,
    directory_gate: PairwiseDirectoryGate,
) -> Result<Value> {
    ensure_secure_mesh_protected_operation_allowed()?;
    let payload_kind = protected_send_kind_from_payload(kind);
    let _authorization = match directory_gate {
        PairwiseDirectoryGate::Required => {
            ensure_peer_authorized_for_protected_send(config, payload_kind)?
        }
        PairwiseDirectoryGate::KtGossipControl => {
            ensure_peer_trust_authorized_for_protected_send(config, payload_kind)?
        }
    };
    let endpoint = local_endpoint_state(config)?;
    let peer = peer_endpoint_state(config)?;
    let created_at = now_iso();
    let expires_at = timestamp_after_seconds(match kind {
        crate::core::secure_mesh_crypto::SecureMeshPayloadKind::ResultPayload
        | crate::core::secure_mesh_crypto::SecureMeshPayloadKind::Error => {
            MOBILE_RELAY_RESULT_TTL_SECONDS
        }
        _ => MOBILE_RELAY_COMMAND_TTL_SECONDS,
    })?;
    let mut delivery_id_bytes = [0u8; 24];
    OsRng.fill_bytes(&mut delivery_id_bytes);
    let envelope_id = general_purpose::URL_SAFE_NO_PAD.encode(delivery_id_bytes);
    let message_id = format!("msg_{}", Uuid::new_v4());
    let opaque_mailbox_id = canonical_mailbox_token(
        config,
        &peer.endpoint_id,
        &peer.endpoint_kind,
        peer.mailbox_rotation_epoch,
    )?;
    let context = crate::core::secure_mesh_crypto::SecureMeshContentContext::new(
        &envelope_id,
        &message_id,
        &opaque_mailbox_id,
        &endpoint.endpoint_id,
        &peer.endpoint_id,
        session_id(config)?,
        &created_at,
        &expires_at,
    );
    let body = serde_json::to_vec(payload)?;
    let envelope = pairwise_operation.session.seal_payload_envelope(
        &context,
        &crate::core::secure_mesh_crypto::SecureMeshPlaintext::new(kind, body)
            .with_content_type("application/json"),
    )?;
    pairwise_operation.commit()?;
    serde_json::from_str(&envelope.to_json()?)
        .context("mobile relay secure envelope serialization failed")
}

#[cfg(test)]
fn open_mobile_relay_payload(
    config: &Value,
    envelope: &Value,
    kind: crate::core::secure_mesh_crypto::SecureMeshPayloadKind,
) -> Result<Vec<u8>> {
    let mut pairwise_operation = mobile_relay_pairwise_operation(
        config,
        "Mobile Relay pairwise payload authorization batch",
        3,
    )?;
    open_mobile_relay_payload_with_pairwise_operation(
        config,
        envelope,
        kind,
        &mut pairwise_operation,
    )
}

fn open_mobile_relay_payload_with_pairwise_operation(
    config: &Value,
    envelope: &Value,
    kind: crate::core::secure_mesh_crypto::SecureMeshPayloadKind,
    pairwise_operation: &mut MobileRelayPairwiseOperation,
) -> Result<Vec<u8>> {
    open_mobile_relay_payload_with_pairwise_operation_and_gate(
        config,
        envelope,
        kind,
        pairwise_operation,
        PairwiseDirectoryGate::Required,
    )
}

fn open_mobile_relay_payload_with_pairwise_operation_and_gate(
    config: &Value,
    envelope: &Value,
    kind: crate::core::secure_mesh_crypto::SecureMeshPayloadKind,
    pairwise_operation: &mut MobileRelayPairwiseOperation,
    directory_gate: PairwiseDirectoryGate,
) -> Result<Vec<u8>> {
    ensure_secure_mesh_protected_operation_allowed()?;
    let payload_kind = protected_send_kind_from_payload(kind);
    let _authorization = match directory_gate {
        PairwiseDirectoryGate::Required => {
            ensure_peer_authorized_for_protected_send(config, payload_kind)?
        }
        PairwiseDirectoryGate::KtGossipControl => {
            ensure_peer_trust_authorized_for_protected_send(config, payload_kind)?
        }
    };
    validate_secure_envelope(envelope)?;
    let wire = serde_json::to_string(envelope)
        .context("mobile relay secure envelope serialization failed")?;
    let pairwise_envelope = SecureMeshRelayEnvelope::from_json(&wire)?;
    let opened = pairwise_operation
        .session
        .open_payload_envelope(&pairwise_envelope, kind)?;
    pairwise_operation.commit()?;
    Ok(opened.body)
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum PairwiseDirectoryGate {
    Required,
    KtGossipControl,
}

struct MobileRelayPairwiseOperation {
    store: SecureMeshPairwiseDurableStore,
    record: SecureMeshPairwiseDurableRecord,
    session: SecureMeshPairwiseSession,
    secret_store_session: SecretStoreAuthorizationSession,
}

impl MobileRelayPairwiseOperation {
    fn commit(&mut self) -> Result<()> {
        self.record = self.store.commit_session_with_authorized_session(
            &self.record,
            &self.session,
            now_iso(),
            &self.secret_store_session,
        )?;
        Ok(())
    }
}

#[cfg(test)]
fn mobile_relay_pairwise_operation(
    config: &Value,
    reason: &'static str,
    operation_count: usize,
) -> Result<MobileRelayPairwiseOperation> {
    mobile_relay_pairwise_operation_with_authorized_session(config, reason, operation_count, None)
}

fn mobile_relay_pairwise_operation_with_runtime_secret_context(
    config: &Value,
    reason: &'static str,
    operation_count: usize,
    secret_context: &mut RuntimeSecretContext,
) -> Result<MobileRelayPairwiseOperation> {
    let shared_session = secret_context.shared_authorization_session()?;
    mobile_relay_pairwise_operation_with_authorized_session(
        config,
        reason,
        operation_count,
        shared_session.as_ref(),
    )
}

fn mobile_relay_pairwise_operation_with_authorized_session(
    config: &Value,
    reason: &'static str,
    operation_count: usize,
    authorized_session: Option<&SecretStoreAuthorizationSession>,
) -> Result<MobileRelayPairwiseOperation> {
    ensure_secure_mesh_protected_operation_allowed()?;
    let store = mobile_relay_pairwise_store()?;
    let endpoint = local_endpoint_state(config)?;
    let session_id = session_id(config)?;
    if let Some(record) = store.read_record(&session_id, &endpoint.endpoint_id)? {
        let secret_store_session = authorized_session
            .filter(|session| session.backend() == store.secret_store_backend())
            .cloned()
            .map(Ok)
            .unwrap_or_else(|| {
                store.begin_authorized_session(&SecretStoreAuthorizationRequest::new(
                    reason,
                    operation_count,
                ))
            })?;
        let session = store
            .load_session_with_authorized_session(
                &session_id,
                &endpoint.endpoint_id,
                &secret_store_session,
            )?
            .ok_or_else(|| anyhow!("mobile relay pairwise session record is missing"))?;
        return Ok(MobileRelayPairwiseOperation {
            store,
            record,
            session,
            secret_store_session,
        });
    }
    Err(anyhow!(
        "mobile relay pairwise session is not initialized; re-pairing is required"
    ))
}

fn initialize_mobile_relay_pairwise_session(
    config: &mut Value,
    peer_descriptor: &Value,
    peer_identity: &DeviceTrustPublicIdentity,
) -> Result<()> {
    ensure_secure_mesh_protected_operation_allowed()?;
    let mut store = mobile_relay_pairwise_store()?;
    let endpoint = local_endpoint_state(config)?;
    let peer = peer_endpoint_state(config)?;
    let session_id = session_id(config)?;
    let capability_evaluation = selected_mobile_relay_capability_evaluation()?;
    if let Some(record) = store.read_record(&session_id, &endpoint.endpoint_id)? {
        if let Some(finished) = pairwise_finished_from_descriptor(peer_descriptor)? {
            if finished.responder_endpoint_id == endpoint.endpoint_id
                && finished.initiator_endpoint_id == peer.endpoint_id
            {
                let secret_store_session =
                    store.begin_authorized_session(&SecretStoreAuthorizationRequest::new(
                        "Mobile Relay pairwise finished authorization batch",
                        3,
                    ))?;
                let mut session = store
                    .load_session_with_authorized_session(
                        &session_id,
                        &endpoint.endpoint_id,
                        &secret_store_session,
                    )?
                    .ok_or_else(|| anyhow!("mobile relay pairwise session record is missing"))?;
                session.complete_responder_handshake(&finished)?;
                store.commit_session_with_authorized_session(
                    &record,
                    &session,
                    now_iso(),
                    &secret_store_session,
                )?;
                if let Some(e2ee) = config
                    .get_mut("mobileRelayE2ee")
                    .and_then(Value::as_object_mut)
                {
                    e2ee.remove("pairwiseAccepted");
                }
                return Ok(());
            }
        }
        if let Some(accepted) = pairwise_accepted_from_descriptor(peer_descriptor)? {
            let secret_store_session =
                store.begin_authorized_session(&SecretStoreAuthorizationRequest::new(
                    "Mobile Relay pairwise handshake authorization batch",
                    3,
                ))?;
            let mut session = store
                .load_session_with_authorized_session(
                    &session_id,
                    &endpoint.endpoint_id,
                    &secret_store_session,
                )?
                .ok_or_else(|| anyhow!("mobile relay pairwise session record is missing"))?;
            if session.remote_endpoint_id == accepted.responder_endpoint_id {
                let local_identity = endpoint.device_identity()?;
                let now = OffsetDateTime::now_utc();
                let finished = session.complete_initiator_handshake(
                    &local_identity,
                    peer_identity,
                    &accepted,
                    now,
                    &mut crate::core::secure_mesh_session_negotiation::CapabilityProofReplayGuard::default(),
                )?;
                store.commit_session_with_authorized_session_and_capability_proofs(
                    &record,
                    &session,
                    session.local_capability_proof(),
                    &accepted.responder_capability_proof,
                    now.unix_timestamp(),
                    now_iso(),
                    &secret_store_session,
                )?;
                config["mobileRelayE2ee"]["pairwiseFinished"] =
                    pairwise_finished_to_json(&finished);
                if let Some(e2ee) = config
                    .get_mut("mobileRelayE2ee")
                    .and_then(Value::as_object_mut)
                {
                    e2ee.remove("pendingPairwiseIntro");
                }
            }
        }
        return Ok(());
    }

    if let Some(intro) = pairwise_intro_from_descriptor(peer_descriptor)? {
        if intro.responder_endpoint_id == endpoint.endpoint_id
            && intro.initiator_endpoint_id == peer.endpoint_id
        {
            let local_identity = endpoint.device_identity()?;
            validate_pairwise_intro_targets_local_prekeys(
                config,
                &endpoint,
                &local_identity,
                peer_identity,
                &intro,
            )?;
            let local_identity_secret = endpoint.identity_secret()?;
            let local_signing_key = endpoint.signing_key()?;
            let signed_prekey_secret = endpoint.signed_prekey_secret()?;
            let one_time_prekey_secret = endpoint
                .one_time_prekey_secret_for(intro.responder_one_time_prekey_id.as_deref())?;
            let one_time_mlkem1024_prekey_seed = endpoint.one_time_mlkem1024_prekey_seed_for(
                &intro.responder_one_time_mlkem1024_prekey_id,
            )?;
            let now = OffsetDateTime::now_utc();
            let (session, accepted) = SecureMeshPairwiseSession::accept(
                &local_identity,
                &local_identity_secret,
                &local_signing_key,
                peer_identity,
                &signed_prekey_secret,
                one_time_prekey_secret.as_ref(),
                &one_time_mlkem1024_prekey_seed,
                &intro,
                &capability_evaluation,
                now,
                &mut crate::core::secure_mesh_session_negotiation::CapabilityProofReplayGuard::default(),
            )?;
            config["mobileRelayE2ee"]["sessionId"] = json!(session.session_id.clone());
            config["mobileRelayE2ee"]["pairwiseAccepted"] = pairwise_accepted_to_json(&accepted);
            if let Some(e2ee) = config
                .get_mut("mobileRelayE2ee")
                .and_then(Value::as_object_mut)
            {
                e2ee.remove("pendingPairwiseIntro");
                e2ee.remove("pairwiseFinished");
            }
            let local_prekey_use = SecureMeshLocalPreKeyUse {
                local_endpoint_id: endpoint.endpoint_id.clone(),
                local_identity_fingerprint: local_identity.fingerprint()?,
                one_time_prekey_id: endpoint.one_time_prekey_id.clone(),
                one_time_prekey_public_key_hash: prekey_public_key_hash(&decode_key_32(
                    &endpoint.one_time_prekey_public_key,
                    "mobile relay local one-time prekey public key",
                )?),
                one_time_mlkem1024_prekey_id: endpoint.one_time_mlkem1024_prekey_id.clone(),
                one_time_mlkem1024_prekey_public_key_hash: prekey_public_key_hash(
                    &decode_fixed_base64url::<ML_KEM_1024_PUBLIC_KEY_BYTES>(
                        &endpoint.one_time_mlkem1024_prekey_public_key,
                        "mobile relay local ML-KEM-1024 one-time prekey public key",
                    )?,
                ),
            };
            store.upsert_initial_with_local_prekey_claim_and_capability_proofs(
                &session,
                &local_prekey_use,
                &accepted.responder_capability_proof,
                &intro.initiator_capability_proof,
                now.unix_timestamp(),
                now_iso(),
            )?;
            rotate_mobile_relay_one_time_prekeys(config)?;
            return Ok(());
        }
    }

    if endpoint.endpoint_kind == "mobile" {
        let local_identity = endpoint.device_identity()?;
        let local_identity_secret = endpoint.identity_secret()?;
        let local_signing_key = endpoint.signing_key()?;
        ensure_peer_verified(config)?;
        let mut remote_bundle = pairwise_prekey_bundle_from_descriptor(peer_descriptor)?;
        ensure!(
            remote_bundle.endpoint_identity == *peer_identity,
            "mobile relay pairwise prekey identity does not match pinned peer"
        );
        remote_bundle.trust_state = DeviceTrustState::Verified;
        let remote_directory_authorization = authorize_peer_pairwise_directory(
            config,
            peer_descriptor,
            &remote_bundle,
            OffsetDateTime::now_utc(),
        )?;
        let (session, intro) = SecureMeshPairwiseSession::initiate(
            &local_identity,
            &local_identity_secret,
            &local_signing_key,
            &remote_bundle,
            &remote_directory_authorization,
            &SecureMeshPreKeyValidationPolicy::default(),
            &capability_evaluation,
            OffsetDateTime::now_utc(),
        )?;
        let one_time_prekey_public_key = remote_bundle
            .one_time_prekey
            .as_ref()
            .ok_or_else(|| anyhow!("mobile relay pairwise one-time prekey is missing"))?
            .public_key
            .as_slice();
        let one_time_mlkem1024_prekey_public_key = remote_bundle
            .one_time_mlkem1024_prekey
            .public_key
            .as_slice();
        let remote_prekey_use = SecureMeshRemotePreKeyUse {
            session_id: session.session_id.clone(),
            local_endpoint_id: session.local_endpoint_id.clone(),
            remote_endpoint_id: remote_bundle.endpoint_identity.endpoint_id.clone(),
            remote_identity_fingerprint: remote_bundle.endpoint_identity.fingerprint()?,
            signed_prekey_id: intro.responder_signed_prekey_id.clone(),
            one_time_prekey_id: intro
                .responder_one_time_prekey_id
                .clone()
                .ok_or_else(|| anyhow!("mobile relay pairwise intro missing one-time prekey id"))?,
            one_time_prekey_public_key_hash: prekey_public_key_hash(one_time_prekey_public_key),
            one_time_mlkem1024_prekey_id: intro.responder_one_time_mlkem1024_prekey_id.clone(),
            one_time_mlkem1024_prekey_public_key_hash: prekey_public_key_hash(
                one_time_mlkem1024_prekey_public_key,
            ),
            directory_authorization_digest: intro.directory_authorization_digest.clone(),
        };
        config["mobileRelayE2ee"]["sessionId"] = json!(session.session_id.clone());
        config["mobileRelayE2ee"]["pendingPairwiseIntro"] = pairwise_intro_to_json(&intro);
        if let Some(e2ee) = config
            .get_mut("mobileRelayE2ee")
            .and_then(Value::as_object_mut)
        {
            e2ee.remove("pairwiseAccepted");
            e2ee.remove("pairwiseFinished");
        }
        store.upsert_initial_with_remote_prekey_claim(&session, &remote_prekey_use, now_iso())?;
        return Ok(());
    }

    Err(anyhow!(
        "mobile relay peer secure mesh descriptor does not contain a PQXDH pairwise intro"
    ))
}

fn mobile_relay_pairwise_store() -> Result<SecureMeshPairwiseDurableStore> {
    ensure_secure_mesh_protected_operation_allowed()?;
    mobile_relay_pairwise_store_for_authority_reset()
}

fn mobile_relay_pairwise_store_for_authority_reset() -> Result<SecureMeshPairwiseDurableStore> {
    let path = mobile_relay_pairwise_store_path()?;
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    let secret_store = pairwise_secret_store_override()
        .or_else(mobile_relay_secret_store_override)
        .unwrap_or_else(selected_mobile_relay_secret_store);
    let mut store = SecureMeshPairwiseDurableStore::open_with_secret_store(
        &path,
        secret_store,
        crate::core::secure_mesh_pairwise::pairwise_secret_store_namespace(&path),
    )?;
    // Public SQLite snapshots cannot recover a memory-only session after process restart.
    // Purge the whole session set before any lookup so callers fail closed into re-pairing.
    store.purge_unrecoverable_memory_only_sessions()?;
    Ok(store)
}

fn mobile_relay_pairwise_store_path() -> Result<PathBuf> {
    Ok(ClientStateStore::portable()?
        .root()
        .join("mobile-relay")
        .join("pairwise-pqxdh.sqlite3"))
}

fn purge_mobile_relay_pairwise_sessions() -> Result<()> {
    let mut store = mobile_relay_pairwise_store_for_authority_reset()?;
    store.purge_sessions_preserving_prekey_history()?;
    Ok(())
}

fn allowed_agent_ids(params: &Value, command_kind: &str) -> Result<Value> {
    let mut agent_ids = if matches!(
        command_kind,
        "agent.sessions.list" | "agent.sessions.describe"
    ) {
        // Read-only native-history discovery is independent from send
        // readiness, but it is still constrained to the canonical packaged
        // adapter registry.
        crate::platform::runtime_adapters::PACKAGED_RUNTIME_ADAPTER_IDS
            .iter()
            .map(|agent| (*agent).to_string())
            .collect::<BTreeSet<_>>()
    } else {
        let scan = targets::scan_targets_with_params(&json!({}))?;
        let candidates = scan.get("candidates").cloned().unwrap_or_else(|| json!([]));
        connectable_relay_targets(&candidates)
            .as_array()
            .map(|items| {
                items
                    .iter()
                    .filter_map(|target| target.get("target").and_then(Value::as_str))
                    .map(str::to_string)
                    .collect::<BTreeSet<_>>()
            })
            .unwrap_or_default()
    };
    if let Some(explicit) =
        json_param(params, "allowedAgentIds").and_then(|value| value.as_array().cloned())
    {
        let explicit = explicit
            .iter()
            .filter_map(Value::as_str)
            .map(str::to_string)
            .collect::<BTreeSet<_>>();
        agent_ids.retain(|agent| explicit.contains(agent));
    }
    Ok(json!(agent_ids.into_iter().collect::<Vec<_>>()))
}

fn connectable_relay_targets(value: &Value) -> Value {
    let items = value.as_array().cloned().unwrap_or_default();
    Value::Array(
        items
            .into_iter()
            .filter_map(|item| {
                let status = item
                    .get("status")
                    .and_then(Value::as_str)
                    .unwrap_or_default();
                let supports_runtime = item
                    .get("supportedActions")
                    .and_then(Value::as_array)
                    .map(|actions| {
                        actions.iter().any(|action| {
                            action.as_str().unwrap_or_default() == "runtime.message.send"
                        })
                    })
                    .unwrap_or(false);
                if status == "not-detected" || !supports_runtime {
                    return None;
                }
                let target = item
                    .get("target")
                    .or_else(|| item.get("id"))
                    .and_then(Value::as_str)
                    .map(str::trim)
                    .filter(|value| !value.is_empty())?;
                let label = item
                    .get("label")
                    .or_else(|| item.get("name"))
                    .and_then(Value::as_str)
                    .map(str::trim)
                    .filter(|value| !value.is_empty())
                    .unwrap_or(target);
                let kind = item
                    .get("kind")
                    .or_else(|| item.get("type"))
                    .and_then(Value::as_str)
                    .map(str::trim)
                    .filter(|value| !value.is_empty())
                    .unwrap_or("cli");
                Some(json!({
                    "target": target,
                    "label": label,
                    "kind": kind,
                    "status": status
                }))
            })
            .collect(),
    )
}

fn secure_envelope_param(params: &Value) -> Option<Value> {
    let envelope = json_param(params, "envelope")?;
    if validate_secure_envelope(&envelope).is_ok() {
        Some(envelope)
    } else {
        None
    }
}

fn validate_secure_envelope(envelope: &Value) -> Result<()> {
    // Validate through the canonical v2 SecureMeshRelayEnvelope which rejects
    // unknown fields, validates base64url encoding, and enforces bucket sizing.
    let wire = serde_json::to_string(envelope)
        .context("secure mesh relay envelope serialization failed")?;
    crate::core::secure_mesh_relay_envelope::SecureMeshRelayEnvelope::from_json(&wire)?;
    Ok(())
}

#[allow(dead_code)]
fn validate_envelope_text_field(label: &str, value: &str, max_bytes: usize) -> Result<()> {
    if value.trim().is_empty() {
        return Err(anyhow!("secure envelope missing {}", label));
    }
    if value.len() > max_bytes {
        return Err(anyhow!("secure envelope {} is too large", label));
    }
    Ok(())
}

#[allow(dead_code)]
fn validate_envelope_time_window(created_at: &str, expires_at: &str) -> Result<()> {
    let created = OffsetDateTime::parse(created_at, &Rfc3339)
        .map_err(|error| anyhow!("secure envelope createdAt is not RFC3339: {}", error))?;
    let expires = OffsetDateTime::parse(expires_at, &Rfc3339)
        .map_err(|error| anyhow!("secure envelope expiresAt is not RFC3339: {}", error))?;
    if expires <= created {
        return Err(anyhow!("secure envelope expiresAt must be after createdAt"));
    }
    let now = OffsetDateTime::now_utc();
    if created > now + Duration::seconds(MOBILE_RELAY_ENVELOPE_CLOCK_SKEW_SECONDS) {
        return Err(anyhow!("secure envelope createdAt is in the future"));
    }
    if expires <= now - Duration::seconds(MOBILE_RELAY_ENVELOPE_CLOCK_SKEW_SECONDS) {
        return Err(anyhow!("secure envelope has expired"));
    }
    if expires
        > now
            + Duration::seconds(
                MOBILE_RELAY_COMMAND_TTL_SECONDS + MOBILE_RELAY_ENVELOPE_CLOCK_SKEW_SECONDS,
            )
    {
        return Err(anyhow!(
            "secure envelope expiresAt exceeds mobile relay TTL"
        ));
    }
    Ok(())
}

#[allow(dead_code)]
fn encoded_len_limit(decoded_bytes: usize) -> usize {
    decoded_bytes.div_ceil(3) * 4
}

fn load_config() -> Result<Value> {
    let parsed = read_persisted_config()?;
    let mut config = normalize_config(parsed.clone().unwrap_or_else(|| json!({})));
    validate_config_generations(&config)?;
    if parsed.as_ref() != Some(&config) || config_contains_native_store_secret_material(&config) {
        save_config(&mut config)?;
        config = normalize_config(read_persisted_config()?.ok_or_else(|| {
            anyhow!("mobile relay config disappeared after durable initialization")
        })?);
        validate_config_generations(&config)?;
    }
    Ok(config)
}

fn load_config_without_persistence() -> Result<Value> {
    let config = normalize_config(read_persisted_config()?.unwrap_or_else(|| json!({})));
    validate_config_generations(&config)?;
    Ok(config)
}

fn read_persisted_config() -> Result<Option<Value>> {
    let Some(raw) = crate::platform::file_security::read_private_text_bounded(
        &config_path()?,
        CONFIG_MAX_BYTES,
    )?
    else {
        return Ok(None);
    };
    ensure!(
        !raw.trim().is_empty(),
        "mobile relay config exists but is empty"
    );
    let parsed: Value = serde_json::from_str(&raw)
        .map_err(|_| anyhow!("mobile relay config exists but is invalid"))?;
    ensure!(
        parsed.is_object(),
        "mobile relay config exists but is not an object"
    );
    validate_config_generations(&parsed)?;
    Ok(Some(parsed))
}

fn validate_config_generations(config: &Value) -> Result<()> {
    for field in [CONFIG_GENERATION_FIELD, AUTHORITY_GENERATION_FIELD] {
        let value = config.get(field).and_then(Value::as_u64).unwrap_or(0);
        ensure!(
            value <= KT_JSON_SAFE_INTEGER_MAX,
            "mobile relay config security generation is invalid"
        );
        if config.get(field).is_some() {
            ensure!(
                config.get(field).and_then(Value::as_u64).is_some(),
                "mobile relay config security generation is invalid"
            );
        }
    }
    Ok(())
}

fn config_generation(config: &Value, field: &str) -> Result<u64> {
    validate_config_generations(config)?;
    Ok(config.get(field).and_then(Value::as_u64).unwrap_or(0))
}

fn load_config_with_runtime_secret_overrides(
    params: &Value,
) -> Result<(Value, RuntimeSecretOverrides)> {
    ensure_secure_mesh_protected_operation_allowed()?;
    let mut config = load_config()?;
    let mut overrides = RuntimeSecretOverrides::default();
    hydrate_config_secret_material_from_native_store(&mut config, &mut overrides)?;
    overrides.merge(apply_runtime_secret_overrides(&mut config, params)?);
    apply_selected_paired_device_credentials(&mut config);
    Ok((config, overrides))
}

fn load_config_for_read(params: &Value) -> Result<(Value, RuntimeSecretOverrides)> {
    let authorize_secret_read = should_authorize_secret_read(params);
    let mut config = if authorize_secret_read {
        load_config()?
    } else {
        load_config_without_persistence()?
    };
    let mut overrides = RuntimeSecretOverrides::default();
    if authorize_secret_read {
        hydrate_config_secret_material_from_native_store(&mut config, &mut overrides)?;
    }
    overrides.merge(apply_runtime_secret_overrides(&mut config, params)?);
    if authorize_secret_read {
        apply_selected_paired_device_credentials(&mut config);
    }
    Ok((config, overrides))
}

fn should_authorize_secret_read(params: &Value) -> bool {
    bool_param(params, &["authorize"]).unwrap_or(false)
        && bool_param(params, &["hydrateSecrets"]).unwrap_or(true)
}

fn load_config_with_runtime_secret_context(
    params: &Value,
) -> Result<(Value, RuntimeSecretContext)> {
    load_config_with_runtime_secret_context_for_operation(
        params,
        "Mobile Relay E2EE secret store authorization batch",
        mobile_relay_e2ee_secret_store_authorization_batch_operation_count(),
    )
}

fn load_config_with_runtime_secret_context_for_operation(
    params: &Value,
    reason: impl Into<String>,
    operation_count: usize,
) -> Result<(Value, RuntimeSecretContext)> {
    ensure_secure_mesh_protected_operation_allowed()?;
    load_config_with_runtime_secret_context_unchecked(params, reason, operation_count)
}

fn load_config_with_runtime_secret_context_for_authority_reset(
    params: &Value,
) -> Result<(Value, RuntimeSecretContext)> {
    load_config_with_runtime_secret_context_unchecked(
        params,
        "Mobile Relay KT authority reset authorization batch",
        mobile_relay_e2ee_secret_store_authorization_batch_operation_count(),
    )
}

fn load_config_with_runtime_secret_context_unchecked(
    params: &Value,
    reason: impl Into<String>,
    operation_count: usize,
) -> Result<(Value, RuntimeSecretContext)> {
    let mut config = load_config()?;
    let allow_interaction =
        bool_param(params, &["allowInteraction", "allow-interaction"]).unwrap_or(true);
    let mut context = RuntimeSecretContext {
        overrides: RuntimeSecretOverrides::default(),
        secret_store_batch: MobileRelaySecretStoreAuthBatch::with_interaction(
            reason,
            operation_count,
            allow_interaction,
        ),
    };
    hydrate_config_secret_material_from_native_store_with_batch(
        &mut config,
        &mut context.overrides,
        &mut context.secret_store_batch,
    )?;
    context
        .overrides
        .merge(apply_runtime_secret_overrides(&mut config, params)?);
    apply_selected_paired_device_credentials(&mut config);
    Ok((config, context))
}

fn apply_runtime_secret_overrides(
    _config: &mut Value,
    params: &Value,
) -> Result<RuntimeSecretOverrides> {
    let applied = RuntimeSecretOverrides::default();
    if params
        .get("secretOverrideTransport")
        .and_then(Value::as_str)
        .map(str::trim)
        != Some(RUNTIME_SECRET_OVERRIDE_TRANSPORT)
    {
        return Ok(applied);
    }
    let Some(overrides) = params
        .get("secretOverrides")
        .filter(|value| value.is_object())
    else {
        return Ok(applied);
    };
    ensure!(
        !contains_unredacted_token_secret_override(overrides),
        "mobile relay raw token secretOverrides are disabled; use the platform secret-store callback"
    );
    if let Some(e2ee_overrides) = overrides
        .get("mobileRelayE2ee")
        .filter(|value| value.is_object())
    {
        ensure!(
            !contains_unredacted_e2ee_secret_override(e2ee_overrides),
            "mobile relay raw E2EE secretOverrides are disabled; use the platform secret-store callback"
        );
    }
    Ok(applied)
}

fn contains_unredacted_token_secret_override(value: &Value) -> bool {
    MOBILE_RELAY_NATIVE_TOKEN_SECRET_FIELDS.iter().any(|field| {
        value
            .get(*field)
            .and_then(Value::as_str)
            .is_some_and(is_unredacted_secret)
    }) || value
        .get("pairedDevices")
        .and_then(Value::as_array)
        .is_some_and(|devices| {
            devices.iter().any(|device| {
                device
                    .get("mobileToken")
                    .and_then(Value::as_str)
                    .is_some_and(is_unredacted_secret)
            })
        })
}

fn contains_unredacted_e2ee_secret_override(value: &Value) -> bool {
    MOBILE_RELAY_E2EE_NATIVE_SECRET_FIELDS
        .iter()
        .any(|(field, _)| {
            value
                .get(*field)
                .and_then(Value::as_str)
                .is_some_and(is_unredacted_secret)
        })
}

fn save_config(config: &mut Value) -> Result<()> {
    let overrides = RuntimeSecretOverrides::default();
    save_config_with_runtime_secret_overrides(config, &overrides)
}

fn save_config_raw(config: &mut Value) -> Result<()> {
    save_config_raw_with_reset_policy(config, false)
}

static CONFIG_WRITE_MUTEX: OnceLock<Mutex<()>> = OnceLock::new();

fn save_config_raw_with_reset_policy(config: &mut Value, allow_reset_write: bool) -> Result<()> {
    prepare_gateway_fields_for_persistence(config)?;
    validate_config_generations(config)?;
    let expected_generation = config_generation(config, CONFIG_GENERATION_FIELD)?;
    let candidate_authority_generation = config_generation(config, AUTHORITY_GENERATION_FIELD)?;
    let _process_guard = CONFIG_WRITE_MUTEX
        .get_or_init(|| Mutex::new(()))
        .lock()
        .map_err(|_| anyhow!("mobile relay config writer lock is unavailable"))?;
    let lock_path = config_lock_path()?;
    let lock_file = crate::platform::file_security::open_private_lock_file(&lock_path)?;
    fs2::FileExt::lock_exclusive(&lock_file)
        .map_err(|_| anyhow!("mobile relay config writer lock could not be acquired"))?;
    let durable = read_persisted_config()?;
    let durable_generation = durable
        .as_ref()
        .map(|value| config_generation(value, CONFIG_GENERATION_FIELD))
        .transpose()?
        .unwrap_or(0);
    let durable_authority_generation = durable
        .as_ref()
        .map(|value| config_generation(value, AUTHORITY_GENERATION_FIELD))
        .transpose()?
        .unwrap_or(0);
    ensure!(
        expected_generation == durable_generation,
        "mobile relay config snapshot is stale"
    );
    if allow_reset_write {
        ensure!(
            candidate_authority_generation == durable_authority_generation
                || candidate_authority_generation == durable_authority_generation.saturating_add(1),
            "mobile relay authority generation transition is invalid"
        );
    } else {
        ensure!(
            candidate_authority_generation == durable_authority_generation,
            "mobile relay config authority generation is stale"
        );
        ensure!(
            !kt_authority_reset_in_progress()?,
            "mobile relay config write is blocked during KT authority reset"
        );
    }
    let committed_generation = expected_generation
        .checked_add(1)
        .filter(|generation| *generation <= KT_JSON_SAFE_INTEGER_MAX)
        .ok_or_else(|| anyhow!("mobile relay config generation overflow"))?;
    config[CONFIG_GENERATION_FIELD] = json!(committed_generation);
    config[AUTHORITY_GENERATION_FIELD] = json!(candidate_authority_generation);
    let encoded = format!("{}\n", serde_json::to_string_pretty(config)?);
    crate::platform::file_security::atomic_write_private_text_bounded(
        &config_path()?,
        &encoded,
        CONFIG_MAX_BYTES,
    )?;
    let committed = read_persisted_config()?
        .ok_or_else(|| anyhow!("mobile relay config disappeared after commit"))?;
    ensure!(
        config_generation(&committed, CONFIG_GENERATION_FIELD)? == committed_generation
            && config_generation(&committed, AUTHORITY_GENERATION_FIELD)?
                == candidate_authority_generation,
        "mobile relay config durable generation verification failed"
    );
    Ok(())
}

const MOBILE_RELAY_E2EE_NATIVE_SECRET_FIELDS: [(&str, &str); 6] = [
    ("privateKeyBase64url", "privateKeyMaterial"),
    ("signingKeyBase64url", "signingKeyMaterial"),
    (
        "signedPrekeyPrivateKeyBase64url",
        "signedPrekeyPrivateKeyMaterial",
    ),
    (
        "oneTimePrekeyPrivateKeyBase64url",
        "oneTimePrekeyPrivateKeyMaterial",
    ),
    (
        "oneTimeMlKem1024PrekeySeedBase64url",
        "oneTimeMlKem1024PrekeySeedMaterial",
    ),
    ("pairingSecretBase64url", "pairingSecretMaterial"),
];
const MOBILE_RELAY_NATIVE_TOKEN_SECRET_FIELDS: [&str; 2] = ["pcToken", "mobileToken"];
const MOBILE_RELAY_E2EE_NATIVE_SECRET_BUNDLE_KEY: &str =
    "mobileRelayE2eeSecretBundle.pqxdhMlKem1024";
const MOBILE_RELAY_E2EE_NATIVE_SECRET_BUNDLE_SCHEMA_VERSION: &str =
    "licolite.mobile-relay.e2ee-secret-bundle.pqxdh-mlkem1024.v1";

fn mobile_relay_e2ee_secret_store_authorization_batch_operation_count() -> usize {
    MOBILE_RELAY_E2EE_NATIVE_SECRET_FIELDS
        .len()
        .saturating_mul(2)
        .saturating_add(
            MOBILE_RELAY_NATIVE_TOKEN_SECRET_FIELDS
                .len()
                .saturating_mul(2),
        )
        .saturating_add(5)
}

fn mobile_relay_secret_store_self_test_authorization_batch_operation_count() -> usize {
    mobile_relay_e2ee_secret_store_authorization_batch_operation_count()
        .saturating_add(
            NATIVE_SECRET_STORE_SHARED_SECRET_CLASSES
                .len()
                .saturating_mul(4),
        )
        .saturating_add(4)
}

fn config_contains_native_store_secret_material(config: &Value) -> bool {
    config
        .get("mobileRelayE2ee")
        .and_then(Value::as_object)
        .map(|e2ee| {
            MOBILE_RELAY_E2EE_NATIVE_SECRET_FIELDS
                .iter()
                .any(|(field, _)| {
                    e2ee.get(*field)
                        .and_then(Value::as_str)
                        .is_some_and(is_unredacted_secret)
                })
        })
        .unwrap_or(false)
}

fn hydrate_config_secret_material_from_native_store(
    config: &mut Value,
    overrides: &mut RuntimeSecretOverrides,
) -> Result<()> {
    if let Some(store) = mobile_relay_secret_store_override() {
        return hydrate_config_secret_material_from_secret_store(
            config,
            overrides,
            store.as_ref(),
            MOBILE_RELAY_PLATFORM_SECRET_STORE_NAMESPACE,
        );
    }
    let store = selected_mobile_relay_secret_store();
    let namespace = native_secret_store_namespace()?;
    hydrate_config_secret_material_from_secret_store(config, overrides, store.as_ref(), &namespace)
}

fn hydrate_config_secret_material_from_native_store_with_batch(
    config: &mut Value,
    overrides: &mut RuntimeSecretOverrides,
    batch: &mut MobileRelaySecretStoreAuthBatch,
) -> Result<()> {
    let Some((store, session, namespace)) = batch.authorization()? else {
        return Ok(());
    };
    hydrate_config_secret_material_from_secret_store_with_session(
        config,
        overrides,
        store.as_ref(),
        &session,
        &namespace,
    )
}

fn hydrate_config_secret_material_from_secret_store(
    config: &mut Value,
    overrides: &mut RuntimeSecretOverrides,
    store: &dyn SecureMeshSecretStore,
    namespace: &str,
) -> Result<()> {
    ensure!(
        store.supported(),
        "mobile relay native secret store backend is unsupported"
    );
    let session = store.begin_authorized_session(&SecretStoreAuthorizationRequest::new(
        "Mobile Relay E2EE secret bundle hydration",
        mobile_relay_e2ee_secret_store_authorization_batch_operation_count(),
    ))?;
    hydrate_config_secret_material_from_secret_store_with_session(
        config, overrides, store, &session, namespace,
    )
}

fn hydrate_config_secret_material_from_secret_store_with_session(
    config: &mut Value,
    overrides: &mut RuntimeSecretOverrides,
    store: &dyn SecureMeshSecretStore,
    session: &SecretStoreAuthorizationSession,
    namespace: &str,
) -> Result<()> {
    overrides.mark_secret_store_authorization(session);
    hydrate_config_token_secret_material_from_secret_store_with_session(
        config, overrides, store, session, namespace,
    )?;
    let Some(e2ee) = config
        .get_mut("mobileRelayE2ee")
        .and_then(Value::as_object_mut)
    else {
        overrides.mark_secret_store_authorization(session);
        return Ok(());
    };
    let mut hydrated_fields = Vec::new();
    for (field, _) in MOBILE_RELAY_E2EE_NATIVE_SECRET_FIELDS {
        if e2ee
            .get(field)
            .and_then(Value::as_str)
            .is_some_and(is_unredacted_secret)
        {
            hydrated_fields.push(field);
        }
    }
    if hydrated_fields.len() < MOBILE_RELAY_E2EE_NATIVE_SECRET_FIELDS.len() {
        let bundle = read_native_e2ee_secret_bundle(store, &session, namespace)?;
        if let Some(bundle) = bundle {
            for (field, secret) in bundle {
                if e2ee
                    .get(field)
                    .and_then(Value::as_str)
                    .is_some_and(is_unredacted_secret)
                {
                    continue;
                }
                e2ee.insert(field.to_string(), json!(secret));
                hydrated_fields.push(field);
            }
        }
    }
    if !hydrated_fields.is_empty() {
        for field in hydrated_fields {
            mark_native_secret_override(overrides, field);
        }
        e2ee.insert("secretStorageStatus".to_string(), json!(store.backend()));
        overrides.mark_e2ee_secret_store(store.backend());
    }
    overrides.mark_secret_store_authorization(session);
    Ok(())
}

fn hydrate_config_token_secret_material_from_secret_store_with_session(
    config: &mut Value,
    overrides: &mut RuntimeSecretOverrides,
    store: &dyn SecureMeshSecretStore,
    session: &SecretStoreAuthorizationSession,
    namespace: &str,
) -> Result<()> {
    let mut hydrated_any = false;
    for field in MOBILE_RELAY_NATIVE_TOKEN_SECRET_FIELDS {
        if config
            .get(field)
            .and_then(Value::as_str)
            .is_some_and(is_unredacted_secret)
        {
            continue;
        }
        let handle = native_secret_store_handle_for_namespace(namespace, field)?;
        if let Some(secret) = store.get_secret_with_session(session, &handle)? {
            let secret = secret.trim();
            if is_unredacted_secret(secret) {
                config[field] = json!(secret);
                mark_native_secret_override(overrides, field);
                hydrated_any = true;
            }
        }
    }

    if let Some(devices) = config
        .get_mut("pairedDevices")
        .and_then(Value::as_array_mut)
    {
        for device in devices {
            if device
                .get("mobileToken")
                .and_then(Value::as_str)
                .is_some_and(is_unredacted_secret)
            {
                continue;
            }
            let Some(handle_key) = paired_device_token_secret_store_key(device) else {
                continue;
            };
            let handle = native_secret_store_handle_for_namespace(namespace, &handle_key)?;
            let Some(secret) = store.get_secret_with_session(session, &handle)? else {
                continue;
            };
            let secret = secret.trim();
            if !is_unredacted_secret(secret) {
                continue;
            }
            device["mobileToken"] = json!(secret);
            device["credentialPresent"] = json!(true);
            hydrated_any = true;
            overrides
                .paired_device_tokens
                .push(PairedDeviceSecretOverride {
                    id: paired_device_id(device),
                    pairing_id: paired_device_pairing_id(device),
                });
        }
    }
    if hydrated_any {
        overrides.mark_e2ee_secret_store(store.backend());
    }
    Ok(())
}

fn persist_config_secret_material_to_native_store(config: &mut Value) -> Result<()> {
    if let Some(store) = mobile_relay_secret_store_override() {
        return persist_config_secret_material_to_secret_store(
            config,
            store.as_ref(),
            MOBILE_RELAY_PLATFORM_SECRET_STORE_NAMESPACE,
        );
    }
    let store = selected_mobile_relay_secret_store();
    let namespace = native_secret_store_namespace()?;
    persist_config_secret_material_to_secret_store(config, store.as_ref(), &namespace)
}

fn persist_config_secret_material_to_native_store_with_batch(
    config: &mut Value,
    batch: &mut MobileRelaySecretStoreAuthBatch,
) -> Result<()> {
    let Some((store, session, namespace)) = batch.authorization()? else {
        return Ok(());
    };
    persist_config_secret_material_to_secret_store_with_session(
        config,
        store.as_ref(),
        &session,
        &namespace,
    )
}

fn persist_config_secret_material_to_secret_store(
    config: &mut Value,
    store: &dyn SecureMeshSecretStore,
    namespace: &str,
) -> Result<()> {
    ensure!(
        store.supported(),
        "mobile relay native secret store backend is unsupported"
    );
    let session = store.begin_authorized_session(&SecretStoreAuthorizationRequest::new(
        "Mobile Relay E2EE secret bundle persistence",
        mobile_relay_e2ee_secret_store_authorization_batch_operation_count(),
    ))?;
    persist_config_secret_material_to_secret_store_with_session(config, store, &session, namespace)
}

fn persist_config_secret_material_to_secret_store_with_session(
    config: &mut Value,
    store: &dyn SecureMeshSecretStore,
    session: &SecretStoreAuthorizationSession,
    namespace: &str,
) -> Result<()> {
    persist_config_token_secret_material_to_secret_store_with_session(
        config, store, session, namespace,
    )?;
    let Some(e2ee) = config
        .get_mut("mobileRelayE2ee")
        .and_then(Value::as_object_mut)
    else {
        return Ok(());
    };
    let incoming = collect_unredacted_e2ee_secret_fields(e2ee);
    if incoming.is_empty() {
        return Ok(());
    }
    let complete = incoming.len() == MOBILE_RELAY_E2EE_NATIVE_SECRET_FIELDS.len();
    let bundle = if complete {
        incoming
    } else {
        merge_e2ee_secret_bundles(
            read_native_e2ee_secret_bundle(store, &session, namespace)?.unwrap_or_default(),
            incoming,
        )
    };
    let handle = native_e2ee_secret_bundle_handle_for_namespace(namespace)?;
    store.set_secret_with_session(
        &session,
        &handle,
        &serialize_native_e2ee_secret_bundle(&bundle)?,
    )?;
    for (field, material_field) in MOBILE_RELAY_E2EE_NATIVE_SECRET_FIELDS {
        if bundle
            .iter()
            .any(|(bundle_field, _)| *bundle_field == field)
        {
            e2ee.remove(field);
            e2ee.insert(material_field.to_string(), json!("redacted"));
        }
    }
    e2ee.insert("secretStorageStatus".to_string(), json!(store.backend()));
    config["secretStorageStatus"] = json!({
        "tokenMaterial": "redacted",
        "mobileRelayPrivateKeyMaterial": "redacted",
        "selectedBackend": store.backend(),
        "unsafePersistenceForbidden": true
    });
    Ok(())
}

fn persist_config_token_secret_material_to_secret_store_with_session(
    config: &mut Value,
    store: &dyn SecureMeshSecretStore,
    session: &SecretStoreAuthorizationSession,
    namespace: &str,
) -> Result<()> {
    let mut persisted = false;
    for field in MOBILE_RELAY_NATIVE_TOKEN_SECRET_FIELDS {
        let Some(secret) = config
            .get(field)
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|value| is_unredacted_secret(value))
            .map(str::to_string)
        else {
            continue;
        };
        let handle = native_secret_store_handle_for_namespace(namespace, field)?;
        store.set_secret_with_session(session, &handle, &secret)?;
        config[field] = json!("");
        config[format!("{field}Present")] = json!(true);
        persisted = true;
    }

    if let Some(devices) = config
        .get_mut("pairedDevices")
        .and_then(Value::as_array_mut)
    {
        for device in devices {
            let Some(secret) = device
                .get("mobileToken")
                .and_then(Value::as_str)
                .map(str::trim)
                .filter(|value| is_unredacted_secret(value))
                .map(str::to_string)
            else {
                continue;
            };
            let Some(handle_key) = paired_device_token_secret_store_key(device) else {
                continue;
            };
            let handle = native_secret_store_handle_for_namespace(namespace, &handle_key)?;
            store.set_secret_with_session(session, &handle, &secret)?;
            device["mobileToken"] = json!("");
            device["credentialPresent"] = json!(true);
            persisted = true;
        }
    }

    if persisted {
        config["secretStorageStatus"] = json!({
            "tokenMaterial": "redacted",
            "mobileRelayPrivateKeyMaterial": "redacted",
            "selectedBackend": store.backend(),
            "unsafePersistenceForbidden": true
        });
    }
    Ok(())
}

#[allow(dead_code)] // unit-tested; matrix source check requires the symbol
fn cleanup_native_secret_store_fields_for_store(
    config: &Value,
    store: &dyn SecureMeshSecretStore,
    namespace: &str,
) -> Result<()> {
    ensure!(
        store.supported(),
        "mobile relay native secret store backend is unsupported"
    );
    let handles = disposable_cleanup_root_secret_handles(config, namespace)?;
    let session = store.begin_authorized_session(&SecretStoreAuthorizationRequest::new(
        "Mobile Relay E2EE secret store cleanup authorization batch",
        handles.len().max(1),
    ))?;
    cleanup_native_secret_store_fields_for_store_with_session(config, store, &session, namespace)
}

fn cleanup_native_secret_store_fields_for_store_with_session(
    config: &Value,
    store: &dyn SecureMeshSecretStore,
    session: &SecretStoreAuthorizationSession,
    namespace: &str,
) -> Result<()> {
    let handles = disposable_cleanup_root_secret_handles(config, namespace)?;
    for handle in &handles {
        store.delete_secret_with_session(session, handle)?;
    }
    Ok(())
}

fn collect_unredacted_e2ee_secret_fields(
    e2ee: &serde_json::Map<String, Value>,
) -> Vec<(&'static str, String)> {
    MOBILE_RELAY_E2EE_NATIVE_SECRET_FIELDS
        .iter()
        .filter_map(|(field, _)| {
            e2ee.get(*field)
                .and_then(Value::as_str)
                .map(str::trim)
                .filter(|value| is_unredacted_secret(value))
                .map(|secret| (*field, secret.to_string()))
        })
        .collect()
}

fn read_native_e2ee_secret_bundle(
    store: &dyn SecureMeshSecretStore,
    session: &SecretStoreAuthorizationSession,
    namespace: &str,
) -> Result<Option<Vec<(&'static str, String)>>> {
    let handle = native_e2ee_secret_bundle_handle_for_namespace(namespace)?;
    let Some(raw) = store.get_secret_with_session(session, &handle)? else {
        return Ok(None);
    };
    parse_native_e2ee_secret_bundle(&raw).map(Some)
}

fn merge_e2ee_secret_bundles(
    existing: Vec<(&'static str, String)>,
    incoming: Vec<(&'static str, String)>,
) -> Vec<(&'static str, String)> {
    let mut merged = Vec::new();
    for (field, _) in MOBILE_RELAY_E2EE_NATIVE_SECRET_FIELDS {
        if let Some((_, secret)) = incoming
            .iter()
            .find(|(incoming_field, _)| *incoming_field == field)
        {
            merged.push((field, secret.clone()));
        } else if let Some((_, secret)) = existing
            .iter()
            .find(|(existing_field, _)| *existing_field == field)
        {
            merged.push((field, secret.clone()));
        }
    }
    merged
}

fn serialize_native_e2ee_secret_bundle(secrets: &[(&'static str, String)]) -> Result<String> {
    ensure!(
        !secrets.is_empty(),
        "mobile relay native E2EE secret bundle cannot be empty"
    );
    let mut secret_values = serde_json::Map::new();
    for (field, _) in MOBILE_RELAY_E2EE_NATIVE_SECRET_FIELDS {
        if let Some((_, secret)) = secrets
            .iter()
            .find(|(secret_field, _)| *secret_field == field)
        {
            secret_values.insert(field.to_string(), json!(secret));
        }
    }
    ensure!(
        !secret_values.is_empty(),
        "mobile relay native E2EE secret bundle has no supported fields"
    );
    Ok(serde_json::to_string(&json!({
        "schemaVersion": MOBILE_RELAY_E2EE_NATIVE_SECRET_BUNDLE_SCHEMA_VERSION,
        "secrets": secret_values
    }))?)
}

fn parse_native_e2ee_secret_bundle(raw: &str) -> Result<Vec<(&'static str, String)>> {
    let parsed = serde_json::from_str::<Value>(raw)
        .map_err(|_| anyhow!("mobile relay native E2EE secret bundle is invalid"))?;
    ensure!(
        parsed.get("schemaVersion").and_then(Value::as_str)
            == Some(MOBILE_RELAY_E2EE_NATIVE_SECRET_BUNDLE_SCHEMA_VERSION),
        "mobile relay native E2EE secret bundle schema is invalid"
    );
    let secrets = parsed
        .get("secrets")
        .and_then(Value::as_object)
        .ok_or_else(|| anyhow!("mobile relay native E2EE secret bundle is missing secrets"))?;
    let mut bundle = Vec::new();
    for (field, _) in MOBILE_RELAY_E2EE_NATIVE_SECRET_FIELDS {
        if let Some(secret) = secrets
            .get(field)
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|value| is_unredacted_secret(value))
        {
            bundle.push((field, secret.to_string()));
        }
    }
    ensure!(
        !bundle.is_empty(),
        "mobile relay native E2EE secret bundle has no usable secret fields"
    );
    Ok(bundle)
}

fn mark_native_secret_override(overrides: &mut RuntimeSecretOverrides, field: &str) {
    match field {
        "pcToken" => overrides.pc_token = true,
        "mobileToken" => overrides.mobile_token = true,
        "privateKeyBase64url" => overrides.e2ee_private_key = true,
        "signingKeyBase64url" => overrides.e2ee_signing_key = true,
        "signedPrekeyPrivateKeyBase64url" => overrides.e2ee_signed_prekey_private_key = true,
        "oneTimePrekeyPrivateKeyBase64url" => overrides.e2ee_one_time_prekey_private_key = true,
        "oneTimeMlKem1024PrekeySeedBase64url" => {
            overrides.e2ee_one_time_mlkem1024_prekey_seed = true
        }
        "pairingSecretBase64url" => overrides.e2ee_pairing_secret = true,
        _ => {}
    }
}

fn native_secret_store_enabled() -> bool {
    native_secret_store_permitted() && native_secret_store_supported()
}

fn native_secret_store_permitted() -> bool {
    if cfg!(test) {
        return false;
    }
    if matches!(
        env::var(NATIVE_SECRET_STORE_MODE_ENV)
            .unwrap_or_default()
            .trim()
            .to_ascii_lowercase()
            .as_str(),
        "0" | "false" | "off" | "disabled" | "portable"
    ) {
        return false;
    }
    true
}

fn native_secret_store_supported() -> bool {
    platform_native_secret_store_supported()
}

pub fn e2ee_secret_store_cleanup(params: &Value) -> Result<Value> {
    ensure!(
        params
            .get("disposableProof")
            .and_then(Value::as_str)
            .map(str::trim)
            == Some("true"),
        "mobile relay secret-store cleanup requires explicit --disposable-proof true"
    );

    let config = load_config_for_disposable_cleanup()?;
    let pairwise_path = mobile_relay_pairwise_store_path()?;
    let pairwise_database_present_before = pairwise_path.exists();
    let pairwise_handles = if pairwise_database_present_before {
        let store = mobile_relay_pairwise_store()?;
        let handles = store.referenced_secret_snapshot_handles()?;
        drop(store);
        handles
    } else {
        Vec::new()
    };
    let pairwise_snapshot_handle_count = pairwise_handles.len();

    let (store, namespace) = disposable_cleanup_secret_store()?;
    ensure!(
        store.supported(),
        "mobile relay native secret store backend is unsupported"
    );
    let mut handles = disposable_cleanup_root_secret_handles(&config, &namespace)?;
    let root_secret_handle_count = handles.len();
    handles.extend(pairwise_handles);
    handles.sort_by(|left, right| {
        left.namespace()
            .cmp(right.namespace())
            .then_with(|| left.key().cmp(right.key()))
    });
    handles.dedup();
    let operation_count = handles.len();
    ensure!(
        operation_count > 0,
        "mobile relay disposable cleanup has no bounded secret-store operations"
    );

    let session =
        store.begin_authorized_session(&SecretStoreAuthorizationRequest::noninteractive(
            "Mobile Relay disposable proof secret cleanup",
            operation_count,
        ))?;
    for handle in &handles {
        store
            .delete_secret_with_session(&session, handle)
            .context("mobile relay disposable secret cleanup failed")?;
    }
    ensure!(
        session.consumed_operation_count() == operation_count
            && session.authorization_batch_within_budget()
            && session.remaining_operation_count() == 0,
        "mobile relay disposable cleanup operation budget mismatch"
    );

    let removed_pairwise_database_file_count =
        remove_mobile_relay_pairwise_store_files(&pairwise_path)?;
    Ok(json!({
        "ok": true,
        "status": "cleaned",
        "disposableProof": true,
        "deletedSecretHandleCount": operation_count,
        "rootSecretHandleCount": root_secret_handle_count,
        "pairwiseSnapshotHandleCount": pairwise_snapshot_handle_count,
        "pairwiseDatabasePresentBefore": pairwise_database_present_before,
        "pairwiseDatabaseRemoved": !pairwise_path.exists(),
        "removedPairwiseDatabaseFileCount": removed_pairwise_database_file_count,
        "secretStoreAuthorization": {
            "backend": session.backend(),
            "allowInteraction": session.allow_interaction(),
            "operationCount": session.operation_count(),
            "consumedOperationCount": session.consumed_operation_count(),
            "remainingOperationCount": session.remaining_operation_count(),
            "authorizationBatchWithinBudget": session.authorization_batch_within_budget()
        }
    }))
}

fn load_config_for_disposable_cleanup() -> Result<Value> {
    let path = config_path()?;
    if !path.exists() {
        return Ok(normalize_config(json!({})));
    }
    let raw =
        fs::read_to_string(&path).context("mobile relay disposable cleanup config read failed")?;
    let parsed = serde_json::from_str::<Value>(&raw)
        .context("mobile relay disposable cleanup config is invalid")?;
    Ok(normalize_config(parsed))
}

fn disposable_cleanup_secret_store() -> Result<(Arc<dyn SecureMeshSecretStore>, String)> {
    if let Some(store) = mobile_relay_secret_store_override() {
        return Ok((
            store,
            MOBILE_RELAY_PLATFORM_SECRET_STORE_NAMESPACE.to_string(),
        ));
    }
    ensure!(
        native_secret_store_enabled(),
        "mobile relay native secret store is required for disposable cleanup"
    );
    Ok((
        Arc::new(native_secret_store()),
        native_secret_store_namespace()?,
    ))
}

fn disposable_cleanup_root_secret_handles(
    config: &Value,
    namespace: &str,
) -> Result<Vec<SecretStoreHandle>> {
    let mut handles = vec![native_e2ee_secret_bundle_handle_for_namespace(namespace)?];
    for field in MOBILE_RELAY_NATIVE_TOKEN_SECRET_FIELDS {
        handles.push(native_secret_store_handle_for_namespace(namespace, field)?);
    }
    for (field, _) in MOBILE_RELAY_E2EE_NATIVE_SECRET_FIELDS {
        handles.push(native_secret_store_handle_for_namespace(namespace, field)?);
    }
    if let Some(devices) = config.get("pairedDevices").and_then(Value::as_array) {
        for device in devices {
            if let Some(key) = paired_device_token_secret_store_key(device) {
                handles.push(native_secret_store_handle_for_namespace(namespace, &key)?);
            }
        }
    }
    handles.sort_by(|left, right| {
        left.namespace()
            .cmp(right.namespace())
            .then_with(|| left.key().cmp(right.key()))
    });
    handles.dedup();
    Ok(handles)
}

fn remove_mobile_relay_pairwise_store_files(path: &Path) -> Result<usize> {
    let mut removed = 0usize;
    let mut candidates = vec![path.to_path_buf()];
    for suffix in ["-wal", "-shm", "-journal"] {
        let mut candidate = path.as_os_str().to_os_string();
        candidate.push(suffix);
        candidates.push(PathBuf::from(candidate));
    }
    for candidate in candidates {
        match fs::remove_file(&candidate) {
            Ok(()) => removed = removed.saturating_add(1),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            Err(error) => {
                return Err(error)
                    .context("mobile relay disposable pairwise database cleanup failed");
            }
        }
    }
    Ok(removed)
}

fn native_secret_store() -> PlatformSecretStore {
    PlatformSecretStore::new(
        NATIVE_SECRET_STORE_SERVICE,
        NATIVE_SECRET_STORE_ACCOUNT_PREFIX,
    )
}

fn native_secret_store_namespace() -> Result<String> {
    let path = config_path()?;
    Ok(sha256_hex(path.to_string_lossy().as_bytes()))
}

fn native_secret_store_handle_for_namespace(
    namespace: &str,
    field: &str,
) -> Result<SecretStoreHandle> {
    SecretStoreHandle::new(
        format!("{}:{}", NATIVE_SECRET_STORE_ACCOUNT_PREFIX, namespace),
        field,
    )
}

fn native_e2ee_secret_bundle_handle_for_namespace(namespace: &str) -> Result<SecretStoreHandle> {
    native_secret_store_handle_for_namespace(namespace, MOBILE_RELAY_E2EE_NATIVE_SECRET_BUNDLE_KEY)
}

fn native_secret_store_shared_secret_classes_namespace() -> Result<String> {
    let path = config_path()?;
    Ok(format!(
        "{}:sharedSecretClasses",
        sha256_hex(path.to_string_lossy().as_bytes())
    ))
}

fn verify_secret_class_round_trip_with_session(
    store: &dyn SecureMeshSecretStore,
    session: &SecretStoreAuthorizationSession,
    namespace: impl Into<String>,
    secret_classes: &[&str],
) -> Result<SecretClassPersistenceProof> {
    let namespace = namespace.into();
    let mut stored_class_count = 0usize;
    let mut deleted_class_count = 0usize;
    let mut handles = Vec::new();
    for secret_class in secret_classes {
        let handle = SecretStoreHandle::new(&namespace, *secret_class)?;
        let proof_secret = format!("secure-mesh-secret-class-proof:{}", Uuid::new_v4());
        store.set_secret_with_session(session, &handle, &proof_secret)?;
        if store.get_secret_with_session(session, &handle)?.as_deref()
            == Some(proof_secret.as_str())
        {
            stored_class_count = stored_class_count.saturating_add(1);
        }
        handles.push(handle);
    }
    for handle in &handles {
        store.delete_secret_with_session(session, handle)?;
        if store.get_secret_with_session(session, handle)?.is_none() {
            deleted_class_count = deleted_class_count.saturating_add(1);
        }
    }
    Ok(SecretClassPersistenceProof {
        backend: store.backend(),
        secret_classes: secret_classes
            .iter()
            .map(|secret_class| (*secret_class).to_string())
            .collect(),
        requested_class_count: secret_classes.len(),
        persisted_class_count: stored_class_count,
        deleted_class_count,
        all_classes_persisted: stored_class_count == secret_classes.len(),
        all_classes_deleted: deleted_class_count == secret_classes.len(),
        raw_secret_material_included: false,
    })
}

fn save_config_with_runtime_secret_overrides(
    config: &mut Value,
    overrides: &RuntimeSecretOverrides,
) -> Result<()> {
    prepare_gateway_fields_for_persistence(config)?;
    let mut persistable = config.clone();
    persist_config_secret_material_to_native_store(&mut persistable)?;
    strip_runtime_secret_overrides(&mut persistable, overrides);
    save_config_raw(&mut persistable)?;
    copy_committed_security_generations(config, &persistable)
}

fn save_config_with_runtime_secret_context(
    config: &mut Value,
    context: &mut RuntimeSecretContext,
) -> Result<()> {
    prepare_gateway_fields_for_persistence(config)?;
    let mut persistable = config.clone();
    persist_config_secret_material_to_native_store_with_batch(
        &mut persistable,
        &mut context.secret_store_batch,
    )?;
    strip_runtime_secret_overrides(&mut persistable, &context.overrides);
    save_config_raw(&mut persistable)?;
    copy_committed_security_generations(config, &persistable)
}

fn save_config_with_runtime_secret_context_for_authority_reset(
    config: &mut Value,
    context: &mut RuntimeSecretContext,
) -> Result<()> {
    prepare_gateway_fields_for_persistence(config)?;
    let mut persistable = config.clone();
    persist_config_secret_material_to_native_store_with_batch(
        &mut persistable,
        &mut context.secret_store_batch,
    )?;
    strip_runtime_secret_overrides(&mut persistable, &context.overrides);
    save_config_raw_with_reset_policy(&mut persistable, true)?;
    copy_committed_security_generations(config, &persistable)
}

fn copy_committed_security_generations(target: &mut Value, committed: &Value) -> Result<()> {
    validate_config_generations(committed)?;
    target[CONFIG_GENERATION_FIELD] = committed
        .get(CONFIG_GENERATION_FIELD)
        .cloned()
        .ok_or_else(|| anyhow!("mobile relay committed config generation is missing"))?;
    target[AUTHORITY_GENERATION_FIELD] = committed
        .get(AUTHORITY_GENERATION_FIELD)
        .cloned()
        .ok_or_else(|| anyhow!("mobile relay committed authority generation is missing"))?;
    Ok(())
}

fn strip_runtime_secret_overrides(config: &mut Value, overrides: &RuntimeSecretOverrides) {
    if overrides.pc_token {
        config["pcToken"] = json!("");
    }
    if overrides.mobile_token || !overrides.paired_device_tokens.is_empty() {
        config["mobileToken"] = json!("");
    }
    if let Some(e2ee) = config
        .get_mut("mobileRelayE2ee")
        .and_then(Value::as_object_mut)
    {
        if overrides.e2ee_private_key {
            e2ee.remove("privateKeyBase64url");
            e2ee.insert("privateKeyMaterial".to_string(), json!("redacted"));
        }
        if overrides.e2ee_signing_key {
            e2ee.remove("signingKeyBase64url");
            e2ee.insert("signingKeyMaterial".to_string(), json!("redacted"));
        }
        if overrides.e2ee_signed_prekey_private_key {
            e2ee.remove("signedPrekeyPrivateKeyBase64url");
            e2ee.insert(
                "signedPrekeyPrivateKeyMaterial".to_string(),
                json!("redacted"),
            );
        }
        if overrides.e2ee_one_time_prekey_private_key {
            e2ee.remove("oneTimePrekeyPrivateKeyBase64url");
            e2ee.insert(
                "oneTimePrekeyPrivateKeyMaterial".to_string(),
                json!("redacted"),
            );
        }
        if overrides.e2ee_one_time_mlkem1024_prekey_seed {
            e2ee.remove("oneTimeMlKem1024PrekeySeedBase64url");
            e2ee.insert(
                "oneTimeMlKem1024PrekeySeedMaterial".to_string(),
                json!("redacted"),
            );
        }
        if overrides.e2ee_pairing_secret {
            e2ee.remove("pairingSecretBase64url");
            e2ee.insert("pairingSecretMaterial".to_string(), json!("redacted"));
        }
        if overrides.e2ee_private_key
            || overrides.e2ee_signing_key
            || overrides.e2ee_signed_prekey_private_key
            || overrides.e2ee_one_time_prekey_private_key
            || overrides.e2ee_one_time_mlkem1024_prekey_seed
            || overrides.e2ee_pairing_secret
        {
            e2ee.insert(
                "secretStorageStatus".to_string(),
                json!(secret_storage_backend_for_overrides(overrides)),
            );
        }
    }
    if let Some(devices) = config
        .get_mut("pairedDevices")
        .and_then(Value::as_array_mut)
    {
        for device in devices {
            let should_strip = overrides
                .paired_device_tokens
                .iter()
                .any(|entry| paired_device_override_matches(device, entry));
            if should_strip {
                device["mobileToken"] = json!("");
                device["credentialPresent"] = json!(true);
            }
        }
    }
    if has_runtime_secret_overrides(overrides) {
        config["secretStorageStatus"] = json!({
            "tokenMaterial": "redacted",
            "mobileRelayPrivateKeyMaterial": "redacted",
            "selectedBackend": secret_storage_backend_for_overrides(overrides),
            "unsafePersistenceForbidden": true
        });
    }
}

fn secret_storage_backend_for_overrides(overrides: &RuntimeSecretOverrides) -> &'static str {
    overrides
        .secret_storage_backend
        .unwrap_or("memory-only-ephemeral")
}

fn paired_device_override_matches(device: &Value, entry: &PairedDeviceSecretOverride) -> bool {
    let id_matches = !entry.id.is_empty()
        && device
            .get("id")
            .or_else(|| device.get("pcClientId"))
            .and_then(Value::as_str)
            .map(str::trim)
            == Some(entry.id.as_str());
    let pairing_matches = !entry.pairing_id.is_empty()
        && device
            .get("pairingId")
            .and_then(Value::as_str)
            .map(str::trim)
            == Some(entry.pairing_id.as_str());
    id_matches || pairing_matches
}

fn paired_device_token_secret_store_key(device: &Value) -> Option<String> {
    let suffix = first_non_blank(&[
        paired_device_pairing_id(device),
        paired_device_id(device),
        "unknown".to_string(),
    ])?;
    Some(format!(
        "pairedDevices.{}.mobileToken",
        sha256_hex(suffix.as_bytes())
    ))
}

fn paired_device_id(device: &Value) -> String {
    device
        .get("id")
        .or_else(|| device.get("pcClientId"))
        .and_then(Value::as_str)
        .unwrap_or_default()
        .trim()
        .to_string()
}

fn paired_device_pairing_id(device: &Value) -> String {
    device
        .get("pairingId")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .trim()
        .to_string()
}

fn first_non_blank(values: &[String]) -> Option<String> {
    values
        .iter()
        .map(|value| value.trim())
        .find(|value| !value.is_empty())
        .map(str::to_string)
}

fn has_runtime_secret_overrides(overrides: &RuntimeSecretOverrides) -> bool {
    overrides.pc_token
        || overrides.mobile_token
        || overrides.e2ee_private_key
        || overrides.e2ee_signing_key
        || overrides.e2ee_signed_prekey_private_key
        || overrides.e2ee_one_time_prekey_private_key
        || overrides.e2ee_one_time_mlkem1024_prekey_seed
        || overrides.e2ee_pairing_secret
        || !overrides.paired_device_tokens.is_empty()
}

fn config_path() -> Result<PathBuf> {
    Ok(ClientStateStore::portable()?
        .root()
        .join("mobile-relay")
        .join("config.json"))
}

fn config_lock_path() -> Result<PathBuf> {
    Ok(ClientStateStore::portable()?
        .root()
        .join("mobile-relay")
        .join("config.writer.lock"))
}

fn kt_authority_reset_guard_path() -> Result<PathBuf> {
    Ok(ClientStateStore::portable()?
        .root()
        .join("mobile-relay")
        .join("secure-mesh-kt-authority-reset.guard"))
}

fn kt_authority_reset_in_progress() -> Result<bool> {
    let path = kt_authority_reset_guard_path()?;
    if !private_state_marker_exists(&path)? {
        return Ok(false);
    }
    let raw = read_private_state_marker(&path)?
        .ok_or_else(|| anyhow!("secure mesh KT authority reset guard disappeared"))?;
    let guard: Value = serde_json::from_slice(&raw)
        .map_err(|_| anyhow!("secure mesh KT authority reset guard is invalid"))?;
    ensure!(
        guard.get("schemaVersion").and_then(Value::as_u64)
            == Some(KT_AUTHORITY_RESET_GUARD_SCHEMA_VERSION)
            && guard.get("state").and_then(Value::as_str) == Some(KT_AUTHORITY_RESET_GUARD_STATE),
        "secure mesh KT authority reset guard is invalid"
    );
    Ok(true)
}

fn ensure_no_kt_authority_reset_in_progress() -> Result<()> {
    ensure!(
        !kt_authority_reset_in_progress()?,
        "secure mesh KT authority reset is incomplete; security operations remain blocked"
    );
    Ok(())
}

pub(crate) fn ensure_secure_mesh_protected_operation_allowed() -> Result<()> {
    ensure_no_kt_authority_reset_in_progress()
}

#[cfg(not(test))]
fn kt_authority_reset_failpoint(_name: &str) -> Result<()> {
    Ok(())
}

#[cfg(test)]
fn kt_authority_reset_failpoint(name: &str) -> Result<()> {
    KT_AUTHORITY_RESET_FAILPOINT.with(|slot| {
        ensure!(
            slot.borrow().as_ref().copied() != Some(name),
            "secure mesh KT authority reset failpoint"
        );
        Ok(())
    })
}

#[cfg(test)]
struct KtAuthorityResetFailpointGuard {
    previous: Option<&'static str>,
}

#[cfg(test)]
impl Drop for KtAuthorityResetFailpointGuard {
    fn drop(&mut self) {
        KT_AUTHORITY_RESET_FAILPOINT.with(|slot| {
            slot.replace(self.previous.take());
        });
    }
}

#[cfg(test)]
fn set_kt_authority_reset_failpoint(name: &'static str) -> KtAuthorityResetFailpointGuard {
    let previous = KT_AUTHORITY_RESET_FAILPOINT.with(|slot| slot.replace(Some(name)));
    KtAuthorityResetFailpointGuard { previous }
}

fn begin_kt_authority_reset() -> Result<()> {
    let path = kt_authority_reset_guard_path()?;
    let content = serde_json::to_vec(&json!({
        "schemaVersion": KT_AUTHORITY_RESET_GUARD_SCHEMA_VERSION,
        "state": KT_AUTHORITY_RESET_GUARD_STATE
    }))?;
    create_private_state_marker(&path, &content)
        .map_err(|_| anyhow!("secure mesh KT authority reset guard could not be created"))
}

fn complete_kt_authority_reset() -> Result<()> {
    let path = kt_authority_reset_guard_path()?;
    ensure!(
        kt_authority_reset_in_progress()?,
        "secure mesh KT authority reset guard is missing"
    );
    ensure!(
        remove_private_state_marker(&path)?,
        "secure mesh KT authority reset guard is missing"
    );
    Ok(())
}

fn normalize_config(value: Value) -> Value {
    let defaults = default_config();
    let object = value.as_object().cloned().unwrap_or_default();
    let mut merged = defaults.as_object().cloned().unwrap_or_default();
    for (key, value) in object {
        merged.insert(key, value);
    }
    merged.insert("schemaVersion".to_string(), json!(CONFIG_SCHEMA_VERSION));
    let mut config = Value::Object(merged);
    normalize_gateway_fields(&mut config);
    reset_incompatible_local_pairwise_protocol(&mut config);
    if let Some(object) = config.as_object_mut() {
        object.insert("lastPairingCode".to_string(), json!(""));
        object.insert("lastPairingExpiresAt".to_string(), json!(""));
        object.remove("mobileRelayPairingInvite");
    }
    config
}

fn normalize_gateway_fields(config: &mut Value) {
    let default_gateway_value = config
        .get("defaultGatewayUrl")
        .and_then(Value::as_str)
        .unwrap_or(DEFAULT_GATEWAY_URL)
        .to_string();
    config["defaultGatewayUrl"] = json!(sanitized_default_gateway(&default_gateway_value));
    let custom_gateway = config
        .get("customGatewayUrl")
        .and_then(Value::as_str)
        .and_then(canonical_https_or_loopback_http_origin)
        .unwrap_or_default();
    if custom_gateway.is_empty() || is_ephemeral_custom_gateway(&custom_gateway) {
        config["customGatewayUrl"] = json!("");
        config["useCustomGateway"] = json!(false);
    } else {
        config["customGatewayUrl"] = json!(custom_gateway);
    }
}

fn default_config() -> Value {
    json!({
        "schemaVersion": CONFIG_SCHEMA_VERSION,
        "configGeneration": 0,
        "securityAuthorityGeneration": 0,
        "defaultGatewayUrl": sanitized_default_gateway(
            &env::var("LICO_MOBILE_RELAY_GATEWAY_URL").unwrap_or_default()
        ),
        "useCustomGateway": false,
        "customGatewayUrl": "",
        "pcClientId": format!("pc_{}", Uuid::new_v4()),
        "pcClientName": "Lico Arc",
        "pairingId": "",
        "relayTenantId": "",
        "relayAccountId": "",
        "relayWorkspaceId": "",
        "pcToken": "",
        "lastPairingCode": "",
        "lastPairingExpiresAt": "",
        "paired": false,
        "relayEnabled": false,
        "pollIntervalSeconds": 5
    })
}

fn effective_gateway_url(config: &Value) -> Result<String> {
    let fallback_value = config
        .get("defaultGatewayUrl")
        .and_then(Value::as_str)
        .unwrap_or(DEFAULT_GATEWAY_URL);
    let fallback = validated_default_gateway(fallback_value)?;
    let url = if config
        .get("useCustomGateway")
        .and_then(Value::as_bool)
        .unwrap_or(false)
    {
        let custom = validated_optional_custom_gateway(
            config
                .get("customGatewayUrl")
                .and_then(Value::as_str)
                .unwrap_or_default(),
        )?;
        if custom.is_empty() || is_ephemeral_custom_gateway(&custom) {
            fallback
        } else {
            custom
        }
    } else {
        fallback
    };
    Ok(url)
}

struct CanonicalRelayContext {
    transport: SecureClientRelayTransport,
    scope: SecureClientRelayScope,
}

fn canonical_relay_context(params: &Value, config: &Value) -> Result<CanonicalRelayContext> {
    let tenant_id = relay_scope_value(params, config, "relayTenantId")
        .ok_or_else(|| anyhow!("secure client relay tenant id is missing"))?;
    let account_id = relay_scope_value(params, config, "relayAccountId")
        .ok_or_else(|| anyhow!("secure client relay account id is missing"))?;
    let workspace_id = relay_scope_value(params, config, "relayWorkspaceId");
    let session_token = text_param(params, &["relaySessionToken"])
        .filter(|value| !value.is_empty())
        .ok_or_else(|| anyhow!("secure client relay session token is missing"))?;
    let csrf_token = text_param(params, &["relayCsrfToken"])
        .filter(|value| !value.is_empty())
        .ok_or_else(|| anyhow!("secure client relay CSRF token is missing"))?;
    let auth = SecureClientRelayAuth::new(session_token, csrf_token)?;
    let scope = SecureClientRelayScope::new(tenant_id, account_id, workspace_id)?;
    let transport = SecureClientRelayTransport::new(effective_gateway_url(config)?, auth)?;
    Ok(CanonicalRelayContext { transport, scope })
}

fn relay_scope_value(params: &Value, config: &Value, key: &str) -> Option<String> {
    text_param(params, &[key])
        .or_else(|| {
            config
                .get(key)
                .and_then(Value::as_str)
                .map(str::trim)
                .filter(|value| !value.is_empty())
                .map(str::to_string)
        })
        .filter(|value| !value.is_empty())
}

fn remember_relay_scope(config: &mut Value, scope: &SecureClientRelayScope) {
    config["relayTenantId"] = json!(scope.tenant_id);
    config["relayAccountId"] = json!(scope.account_id);
    config["relayWorkspaceId"] = json!(scope.workspace_id.clone().unwrap_or_default());
}

fn current_mailbox_rotation_epoch() -> Result<u64> {
    let now = u64::try_from(OffsetDateTime::now_utc().unix_timestamp())
        .map_err(|_| anyhow!("secure client relay mailbox clock is before unix epoch"))?;
    Ok(now / SECURE_MESH_MAILBOX_ROTATION_WINDOW_SECONDS)
}

fn canonical_mailbox_token(
    config: &Value,
    endpoint_id: &str,
    endpoint_kind: &str,
    rotation_epoch: u64,
) -> Result<String> {
    let pairing_secret = config
        .get("mobileRelayE2ee")
        .and_then(|state| state.get("pairingSecretBase64url"))
        .and_then(Value::as_str)
        .ok_or_else(|| anyhow!("secure client relay mailbox delivery secret is missing"))?;
    let delivery_secret = SecureMeshDeliverySecret::from_bytes(decode_key_32(
        pairing_secret,
        "secure client relay mailbox delivery secret",
    )?);
    let direction = if endpoint_kind == "mobile" {
        SecureMeshMailboxDirection::PairwiseInitiatorToResponder
    } else {
        SecureMeshMailboxDirection::PairwiseResponderToInitiator
    };
    let binding: [u8; 32] = Sha256::digest(
        format!("secure-client-relay-channel:v1:{endpoint_kind}:{endpoint_id}").as_bytes(),
    )
    .into();
    let schedule = SecureMeshMailboxSchedule::new(
        delivery_secret,
        direction,
        SecureMeshRelayChannelBinding::from_bytes(binding),
    );
    let epoch_seconds = rotation_epoch
        .checked_mul(SECURE_MESH_MAILBOX_ROTATION_WINDOW_SECONDS)
        .ok_or_else(|| anyhow!("secure client relay mailbox rotation epoch overflow"))?;
    Ok(schedule
        .token_for_unix_seconds(epoch_seconds)?
        .as_str()
        .to_string())
}

fn local_canonical_mailbox_token(config: &Value) -> Result<String> {
    let endpoint = local_endpoint_state(config)?;
    canonical_mailbox_token(
        config,
        &endpoint.endpoint_id,
        &endpoint.endpoint_kind,
        endpoint.mailbox_rotation_epoch,
    )
}

fn register_local_relay_endpoint(
    params: &Value,
    config: &mut Value,
    endpoint_kind: &str,
) -> Result<(Value, Value)> {
    let descriptor = ensure_mobile_relay_endpoint_descriptor(config, endpoint_kind)?;
    let endpoint = local_endpoint_state(config)?;
    let relay = canonical_relay_context(params, config)?;
    let signing_public_key =
        SecureClientRelayPublicJwk::ed25519(endpoint.signing_public_key.clone())?;
    let challenge = relay.transport.endpoint_challenge(
        &relay.scope,
        &endpoint.endpoint_id,
        &signing_public_key,
    )?;
    ensure!(
        challenge.get("challengeEncoding").and_then(Value::as_str) == Some("utf-8")
            && challenge.get("signatureAlgorithm").and_then(Value::as_str) == Some("Ed25519"),
        "secure client relay endpoint challenge profile is invalid"
    );
    let challenge_id = challenge
        .get("challengeId")
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty())
        .ok_or_else(|| anyhow!("secure client relay challenge id is missing"))?;
    let challenge_text = challenge
        .get("challenge")
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty())
        .ok_or_else(|| anyhow!("secure client relay challenge is missing"))?;
    let signature = endpoint.signing_key()?.sign(challenge_text.as_bytes());
    let mailbox_token = canonical_mailbox_token(
        config,
        &endpoint.endpoint_id,
        &endpoint.endpoint_kind,
        endpoint.mailbox_rotation_epoch,
    )?;
    let registration = SecureClientRelayEndpointRegistration {
        endpoint_id: endpoint.endpoint_id.clone(),
        endpoint_kind: endpoint.endpoint_kind.clone(),
        identity_public_key: SecureClientRelayPublicJwk::x25519(endpoint.public_key.clone())?,
        signing_public_key,
        mailbox_token: mailbox_token.clone(),
        rotation_epoch: Some(endpoint.mailbox_rotation_epoch),
        challenge_id: challenge_id.to_string(),
        challenge_signature: general_purpose::URL_SAFE_NO_PAD.encode(signature.to_bytes()),
    };
    let response = relay
        .transport
        .endpoint_register(&relay.scope, &registration)?;
    remember_relay_scope(config, &relay.scope);
    config["relayMailboxToken"] = json!(mailbox_token);
    config["relayRegisteredEndpointId"] = json!(endpoint.endpoint_id);
    config["relayCoreContractDigest"] = json!(
        crate::platform::secure_client_relay_transport::SECURE_CLIENT_RELAY_CORE_CONTRACT_DIGEST
    );
    Ok((response, descriptor))
}

fn relay_envelope_from_value(value: &Value) -> Result<SecureMeshRelayEnvelope> {
    let wire = serde_json::to_string(value)
        .context("secure client relay envelope serialization failed")?;
    SecureMeshRelayEnvelope::from_json(&wire)
}

fn relay_envelope_from_delivery(value: &Value) -> Result<SecureMeshRelayEnvelope> {
    let object = value
        .as_object()
        .ok_or_else(|| anyhow!("secure client relay delivery must be an object"))?;
    let mut envelope = serde_json::Map::new();
    for field in crate::core::secure_mesh_relay_envelope::SECURE_MESH_RELAY_OUTER_FIELDS {
        envelope.insert(
            field.to_string(),
            object
                .get(field)
                .cloned()
                .ok_or_else(|| anyhow!("secure client relay delivery envelope is incomplete"))?,
        );
    }
    relay_envelope_from_value(&Value::Object(envelope))
}

fn local_command_from_relay_delivery(value: &Value) -> Result<Value> {
    let envelope = relay_envelope_from_delivery(value)?;
    Ok(json!({
        "commandId": envelope.delivery_id(),
        "type": SECURE_MESH_ENVELOPE_COMMAND,
        "envelope": serde_json::from_str::<Value>(&envelope.to_json()?)?,
        "leaseId": value.get("leaseId").cloned().unwrap_or(Value::Null),
        "leaseGeneration": value.get("leaseGeneration").cloned().unwrap_or(Value::Null),
        "deliverySequence": value.get("deliverySequence").cloned().unwrap_or(Value::Null)
    }))
}

fn relay_authorized_providers_param(params: &Value) -> Option<Value> {
    json_param(params, "authorizedProviders")
        .or_else(|| json_param(params, "desktopAuthorizedProviders"))
        .or_else(|| json_param(params, "modelProviders"))
        .filter(Value::is_array)
        .map(|providers| normalize_authorized_providers(&providers, "desktop-config"))
}

fn authorized_providers_from_pairing_invite(invite: &Value) -> Option<Value> {
    if let Some(providers) = invite
        .get("authorizedProviders")
        .filter(|value| value.is_array())
    {
        return Some(normalize_authorized_providers(providers, "desktop-invite"));
    }
    invite
        .get("desktopAuthorizedProviders")
        .filter(|value| value.is_array())
        .map(|providers| normalize_authorized_providers(providers, "desktop-invite"))
}

fn normalize_authorized_providers(value: &Value, fallback_source: &str) -> Value {
    let mut seen = Vec::<String>::new();
    let mut out = Vec::<Value>::new();
    for item in value.as_array().cloned().unwrap_or_default() {
        let provider_id = item
            .get("providerId")
            .or_else(|| item.get("provider"))
            .or_else(|| item.get("target"))
            .or_else(|| item.get("id"))
            .and_then(Value::as_str)
            .and_then(normalize_authorized_provider_id);
        let Some(provider_id) = provider_id else {
            continue;
        };
        let profile_id = item
            .get("profileId")
            .or_else(|| item.get("profile"))
            .or_else(|| item.get("modelProfile"))
            .or_else(|| item.get("id"))
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .unwrap_or(provider_id.as_str());
        let account_id = item
            .get("accountId")
            .or_else(|| item.get("mobileAccountId"))
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .unwrap_or(profile_id);
        let dedupe_key = format!("{provider_id}:{profile_id}");
        if seen.iter().any(|existing| existing == &dedupe_key) {
            continue;
        }
        seen.push(dedupe_key);
        let label = item
            .get("label")
            .or_else(|| item.get("name"))
            .and_then(Value::as_str)
            .filter(|value| !value.trim().is_empty())
            .map(|value| value.trim().to_string())
            .unwrap_or_else(|| authorized_provider_label(&provider_id).to_string());
        let source = item
            .get("source")
            .and_then(Value::as_str)
            .filter(|value| !value.trim().is_empty())
            .unwrap_or(fallback_source);
        let credential_kind = item
            .get("credentialKind")
            .or_else(|| item.get("authKind"))
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .unwrap_or("api-key");
        out.push(json!({
            "accountId": account_id,
            "providerId": provider_id,
            "profileId": profile_id,
            "label": label,
            "credentialPresent": item
                .get("credentialPresent")
                .and_then(Value::as_bool)
                .unwrap_or(true),
            "credentialKind": credential_kind,
            "source": source
        }));
    }
    Value::Array(out)
}

fn normalize_authorized_provider_id(value: &str) -> Option<String> {
    let normalized = value.trim().to_lowercase().replace('_', "-");
    match normalized.as_str() {
        "chatgpt" | "chat-gpt" | "openai" | "gpt" => Some("chatgpt".to_string()),
        "gemini" | "google" | "google-gemini" => Some("gemini".to_string()),
        "kimi" | "moonshot" | "moonshot-ai" => Some("kimi".to_string()),
        "deepseek" | "deep-seek" => Some("deepseek".to_string()),
        _ => None,
    }
}

fn authorized_provider_label(provider_id: &str) -> &'static str {
    match provider_id {
        "chatgpt" => "ChatGPT",
        "gemini" => "Gemini",
        "kimi" => "Kimi",
        "deepseek" => "DeepSeek",
        _ => "Provider",
    }
}

#[cfg(test)]
fn apply_out_of_band_pairing_response(config: &mut Value, response: &Value) -> Result<()> {
    apply_out_of_band_pairing_response_with_context(config, response, None)
}

fn apply_out_of_band_pairing_response_with_context(
    config: &mut Value,
    response: &Value,
    secret_context: Option<&mut RuntimeSecretContext>,
) -> Result<()> {
    let object = response
        .as_object()
        .ok_or_else(|| anyhow!("mobile relay out-of-band pairing response must be an object"))?;
    let actual_fields = object.keys().map(String::as_str).collect::<BTreeSet<_>>();
    let expected_fields = ["mobileSecureMesh", "secureMeshClaimProof"]
        .into_iter()
        .collect::<BTreeSet<_>>();
    ensure!(
        actual_fields == expected_fields,
        "mobile relay out-of-band pairing response shape is invalid"
    );
    let pairing_id = config
        .get("pairingId")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .ok_or_else(|| anyhow!("mobile relay local pending pairing id is missing"))?;
    let mobile_secure_mesh = object
        .get("mobileSecureMesh")
        .filter(|value| value.is_object())
        .ok_or_else(|| anyhow!("mobile relay out-of-band mobile descriptor is missing"))?;
    let claim_proof = object
        .get("secureMeshClaimProof")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .ok_or_else(|| anyhow!("mobile relay out-of-band claim proof is missing"))?;
    let pc_secure_mesh = local_endpoint_state(config)?.public_descriptor()?;
    ensure!(
        mobile_relay_claim_proof_matches(
            config,
            pairing_id,
            mobile_secure_mesh,
            &pc_secure_mesh,
            claim_proof,
        )?,
        "mobile relay out-of-band claim proof is invalid"
    );
    apply_peer_secure_mesh_descriptor_with_context(
        config,
        mobile_secure_mesh,
        true,
        secret_context,
    )?;
    config["paired"] = json!(true);
    Ok(())
}

fn with_config(mut response: Value, config: &Value) -> Value {
    let public = public_config(config);
    if let Some(object) = response.as_object_mut() {
        object.insert("config".to_string(), public);
        return response;
    }
    json!({
        "ok": true,
        "response": response,
        "config": public
    })
}

fn public_config(config: &Value) -> Value {
    let mut public = config.clone();
    let pc_token_present = secret_present(config.get("pcToken"))
        || config.get("pcTokenPresent").and_then(Value::as_bool) == Some(true);
    let mobile_token_present = secret_present(config.get("mobileToken"))
        || config.get("mobileTokenPresent").and_then(Value::as_bool) == Some(true);
    let secret_storage_backend = public_secret_storage_backend(config);
    if let Some(providers) = public_authorized_providers(config) {
        public["authorizedProviders"] = providers;
    }
    public["pcToken"] = json!("");
    public["mobileToken"] = json!("");
    public["lastPairingCode"] = json!("");
    public["lastPairingExpiresAt"] = json!("");
    public["pcTokenPresent"] = json!(pc_token_present);
    public["mobileTokenPresent"] = json!(mobile_token_present);
    if let Some(object) = public.as_object_mut() {
        object.remove("mobileRelayPairingInvite");
    }
    if let Some(state) = public
        .get_mut("mobileRelayE2ee")
        .and_then(Value::as_object_mut)
    {
        state.remove("privateKeyBase64url");
        state.remove("signingKeyBase64url");
        state.remove("signedPrekeyPrivateKeyBase64url");
        state.remove("oneTimePrekeyPrivateKeyBase64url");
        state.remove("oneTimeMlKem1024PrekeySeedBase64url");
        state.remove("pairingSecretBase64url");
        state.insert("privateKeyMaterial".to_string(), json!("redacted"));
        state.insert("signingKeyMaterial".to_string(), json!("redacted"));
        state.insert(
            "signedPrekeyPrivateKeyMaterial".to_string(),
            json!("redacted"),
        );
        state.insert(
            "oneTimePrekeyPrivateKeyMaterial".to_string(),
            json!("redacted"),
        );
        state.insert(
            "oneTimeMlKem1024PrekeySeedMaterial".to_string(),
            json!("redacted"),
        );
        state.insert("pairingSecretMaterial".to_string(), json!("redacted"));
        state.insert(
            "secretStorageStatus".to_string(),
            json!(secret_storage_backend.clone()),
        );
    }
    if let Some(devices) = public
        .get_mut("pairedDevices")
        .and_then(Value::as_array_mut)
    {
        for device in devices {
            if let Some(object) = device.as_object_mut() {
                let credential_present = object
                    .get("credentialPresent")
                    .and_then(Value::as_bool)
                    .unwrap_or_else(|| secret_present(object.get("mobileToken")));
                object.insert("mobileToken".to_string(), json!(""));
                object.insert("credentialPresent".to_string(), json!(credential_present));
            }
        }
    }
    public["secretStorageStatus"] = json!({
        "tokenMaterial": "redacted",
        "mobileRelayPrivateKeyMaterial": "redacted",
        "selectedBackend": secret_storage_backend,
        "unsafePersistenceForbidden": true
    });
    if let Ok(presentation) = public_device_trust_presentation(config) {
        public["deviceTrustPresentation"] = presentation;
    } else if let Some(object) = public.as_object_mut() {
        object.remove("deviceTrustPresentation");
    }
    public
}

fn public_device_trust_presentation(config: &Value) -> Result<Value> {
    let state = config
        .get("mobileRelayE2ee")
        .ok_or_else(|| anyhow!("mobile relay device trust state is missing"))?;
    let local_identity = DeviceTrustPublicIdentity::new(
        descriptor_text(state, "endpointId")?,
        decode_key_32(
            &descriptor_text(state, "publicKeyBase64url")?,
            "mobile relay local trust identity public key",
        )?,
        decode_key_32(
            &descriptor_text(state, "signingPublicKeyBase64url")?,
            "mobile relay local trust signing public key",
        )?,
        state
            .get("rotationEpoch")
            .and_then(Value::as_u64)
            .unwrap_or(1),
    )?;
    let peer_identity = peer_device_identity_from_state(state)?;
    let safety_number_groups = sas_decimal_chunks(&local_identity, &peer_identity)?;
    let trust_record = state.get("peerTrustRecord");
    let now_epoch_seconds = mobile_relay_trust_record_now_epoch()?;
    let trust_record_verified = trust_record.is_some_and(|record| {
        verify_device_trust_record_json(&local_identity, &peer_identity, record, now_epoch_seconds)
            .is_ok()
    });
    let trust_state = trust_record
        .and_then(|record| record.get("trustState"))
        .and_then(Value::as_str)
        .unwrap_or("unverified");
    let verification_method = trust_record
        .and_then(|record| record.get("verificationMethod"))
        .and_then(Value::as_str)
        .unwrap_or("unverified");
    Ok(json!({
        "schemaVersion": "licolite.secure-mesh.device-trust-presentation.v1",
        "protocolVersion": crate::core::secure_mesh_trust::SECURE_MESH_DEVICE_TRUST_PROTOCOL_VERSION,
        "localFingerprint": local_identity.fingerprint()?,
        "peerFingerprint": peer_identity.fingerprint()?,
        "safetyNumberGroups": safety_number_groups,
        "qrPayload": qr_verification_payload(&local_identity, &peer_identity, 0)?,
        "trustState": trust_state,
        "verificationMethod": verification_method,
        "verified": trust_record_verified && trust_state == "verified",
        "keyMaterial": "redacted"
    }))
}

fn public_secret_storage_backend(config: &Value) -> String {
    config
        .get("mobileRelayE2ee")
        .and_then(|value| value.get("secretStorageStatus"))
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .or_else(|| {
            config
                .get("secretStorageStatus")
                .and_then(|value| value.get("selectedBackend"))
                .and_then(Value::as_str)
                .map(str::trim)
                .filter(|value| !value.is_empty())
        })
        .unwrap_or("portable_config_pending_platform_secret_store")
        .to_string()
}

fn public_authorized_providers(config: &Value) -> Option<Value> {
    let stored = config
        .get("authorizedProviders")
        .filter(|value| value.as_array().is_some_and(|items| !items.is_empty()))
        .map(|providers| normalize_authorized_providers(providers, "desktop-config"))
        .map(public_authorized_provider_summaries);
    if stored
        .as_ref()
        .is_some_and(|providers| providers.as_array().is_some_and(|items| !items.is_empty()))
    {
        return stored;
    }
    stored
}

fn public_authorized_provider_summaries(providers: Value) -> Value {
    let mut out = Vec::<Value>::new();
    for provider in providers.as_array().cloned().unwrap_or_default() {
        let Some(object) = provider.as_object() else {
            continue;
        };
        let mut public = serde_json::Map::new();
        for key in [
            "providerId",
            "profileId",
            "label",
            "credentialPresent",
            "credentialKind",
            "source",
        ] {
            if let Some(value) = object.get(key) {
                public.insert(key.to_string(), value.clone());
            }
        }
        out.push(Value::Object(public));
    }
    Value::Array(out)
}

fn secret_store_authorization_report(session: &SecretStoreAuthorizationSession) -> Value {
    json!({
        "backend": session.backend(),
        "operationCount": session.operation_count(),
        "consumedOperationCount": session.consumed_operation_count(),
        "remainingOperationCount": session.remaining_operation_count(),
        "authorizationBatchWithinBudget": session.authorization_batch_within_budget(),
        "allowInteraction": session.allow_interaction(),
        "sharedSystemAuthorizationContextRequired": session.shared_system_context_required(),
        "sharedSystemAuthorizationContextAvailable": session.shared_system_context_available(),
        "singleSystemAuthorizationContextVerified": session.single_system_authorization_context_verified(),
        "systemAuthorizationAttemptCount": session.system_authorization_attempt_count(),
        "systemAuthorizationCompleted": session.system_authorization_completed(),
        "authorizationBatchPromptBudgetReady": !session.shared_system_context_required() ||
            (session.system_authorization_attempt_count() == 1 &&
                session.system_authorization_completed()),
        "appCredentialPromptUsed": false,
        "appPasswordPromptUsed": session.app_password_prompt_used(),
        "keyMaterialExported": false
    })
}

fn mobile_relay_e2ee_secret_store_status(
    config: &Value,
    overrides: &RuntimeSecretOverrides,
) -> Value {
    let e2ee = config.get("mobileRelayE2ee").unwrap_or(&Value::Null);
    let portable_private_key_present =
        !overrides.e2ee_private_key && secret_present(e2ee.get("privateKeyBase64url"));
    let portable_signing_key_present =
        !overrides.e2ee_signing_key && secret_present(e2ee.get("signingKeyBase64url"));
    let portable_signed_prekey_private_key_present = !overrides.e2ee_signed_prekey_private_key
        && secret_present(e2ee.get("signedPrekeyPrivateKeyBase64url"));
    let portable_one_time_prekey_private_key_present = !overrides.e2ee_one_time_prekey_private_key
        && secret_present(e2ee.get("oneTimePrekeyPrivateKeyBase64url"));
    let portable_one_time_mlkem1024_prekey_seed_present = !overrides
        .e2ee_one_time_mlkem1024_prekey_seed
        && secret_present(e2ee.get("oneTimeMlKem1024PrekeySeedBase64url"));
    let portable_pairing_secret_present =
        !overrides.e2ee_pairing_secret && secret_present(e2ee.get("pairingSecretBase64url"));
    let any_portable_private_key_present = portable_private_key_present
        || portable_signing_key_present
        || portable_signed_prekey_private_key_present
        || portable_one_time_prekey_private_key_present
        || portable_one_time_mlkem1024_prekey_seed_present;
    let any_private_key_missing = (!overrides.e2ee_private_key
        && !secret_present(e2ee.get("privateKeyBase64url")))
        || (!overrides.e2ee_signing_key && !secret_present(e2ee.get("signingKeyBase64url")))
        || (!overrides.e2ee_signed_prekey_private_key
            && !secret_present(e2ee.get("signedPrekeyPrivateKeyBase64url")))
        || (!overrides.e2ee_one_time_prekey_private_key
            && !secret_present(e2ee.get("oneTimePrekeyPrivateKeyBase64url")))
        || (!overrides.e2ee_one_time_mlkem1024_prekey_seed
            && !secret_present(e2ee.get("oneTimeMlKem1024PrekeySeedBase64url")));
    let all_private_keys_in_selected_custody = overrides.e2ee_private_key
        && overrides.e2ee_signing_key
        && overrides.e2ee_signed_prekey_private_key
        && overrides.e2ee_one_time_prekey_private_key
        && overrides.e2ee_one_time_mlkem1024_prekey_seed;
    let any_portable_secret_present =
        any_portable_private_key_present || portable_pairing_secret_present;
    let selected_backend = if all_private_keys_in_selected_custody {
        secret_storage_backend_for_overrides(overrides)
    } else if any_portable_private_key_present {
        "unsafe_portable_config"
    } else {
        "selected_custody_unavailable"
    };
    let custody_reason = if any_portable_secret_present {
        "secret_material_in_portable_config"
    } else if any_portable_private_key_present {
        "secret_material_in_portable_config"
    } else if any_private_key_missing {
        "endpoint_private_key_material_missing"
    } else {
        "custody_operational"
    };
    let authorization = overrides.secret_store_authorization.as_ref();
    let shared_system_context_required = authorization
        .map(|proof| proof.shared_system_context_required)
        .unwrap_or(false);
    let shared_system_context_available = authorization
        .map(|proof| proof.shared_system_context_available)
        .unwrap_or(false);
    let system_authorization_attempt_count = authorization
        .map(|proof| proof.system_authorization_attempt_count)
        .unwrap_or(0);
    let system_authorization_completed = authorization
        .map(|proof| proof.system_authorization_completed)
        .unwrap_or(false);
    let app_password_prompt_used = authorization
        .map(|proof| proof.app_password_prompt_used)
        .unwrap_or(false);
    let app_credential_prompt_used = authorization
        .map(|proof| proof.app_credential_prompt_used)
        .unwrap_or(false);
    let single_system_authorization_context_verified = authorization
        .map(|proof| {
            proof.single_system_authorization_context_verified && !app_credential_prompt_used
        })
        .unwrap_or(
            shared_system_context_required
                && shared_system_context_available
                && system_authorization_attempt_count == 1
                && system_authorization_completed
                && !app_password_prompt_used
                && !app_credential_prompt_used,
        );
    let authorization_batch_within_prompt_budget = !shared_system_context_required
        || (system_authorization_attempt_count == 1
            && system_authorization_completed
            && !app_password_prompt_used
            && !app_credential_prompt_used);
    let authorization_backend = authorization
        .map(|proof| proof.backend)
        .unwrap_or(selected_backend);
    let authorization_batch_operation_count = authorization
        .map(|proof| proof.operation_count)
        .unwrap_or(0);
    let authorization_batch_consumed_operation_count = authorization
        .map(|proof| proof.consumed_operation_count)
        .unwrap_or(0);
    let authorization_batch_remaining_operation_count = authorization
        .map(|proof| proof.remaining_operation_count)
        .unwrap_or(0);
    let authorization_batch_within_budget = authorization
        .map(|proof| proof.authorization_batch_within_budget)
        .unwrap_or(true);
    let authorization_batch_allow_interaction = authorization
        .map(|proof| proof.allow_interaction)
        .unwrap_or(false);
    let capability_report = authorization
        .and_then(|proof| proof.capability_report.clone())
        .or_else(|| {
            selected_mobile_relay_capability_evaluation()
                .ok()
                .map(|evaluation| evaluation.report())
        });
    let user_presence_enabled = capability_report
        .as_ref()
        .is_some_and(|report| report.enabled.contains(&SecurityCapability::OsUserPresence));
    let authorization_claim_consistent = !user_presence_enabled
        || (single_system_authorization_context_verified
            && authorization_batch_within_prompt_budget
            && authorization_batch_within_budget);
    let custody_operational = all_private_keys_in_selected_custody
        && !any_portable_secret_present
        && capability_report
            .as_ref()
            .and_then(|report| report.custody.as_ref())
            .is_some();
    let capability_report_value = capability_report
        .and_then(|report| serde_json::to_value(report).ok())
        .unwrap_or(Value::Null);
    json!({
        "capabilityReport": capability_report_value,
        "custodyOperational": custody_operational,
        "custodyReason": custody_reason,
        "selectedBackend": selected_backend,
        "privateKeyInSelectedCustody": overrides.e2ee_private_key,
        "signingKeyInSelectedCustody": overrides.e2ee_signing_key,
        "signedPrekeyPrivateKeyInSelectedCustody": overrides.e2ee_signed_prekey_private_key,
        "oneTimePrekeyPrivateKeyInSelectedCustody": overrides.e2ee_one_time_prekey_private_key,
        "oneTimeMlKem1024PrekeySeedInSelectedCustody": overrides.e2ee_one_time_mlkem1024_prekey_seed,
        "allPrivateKeysInSelectedCustody": all_private_keys_in_selected_custody,
        "pairingSecretInSelectedCustody": overrides.e2ee_pairing_secret,
        "unsafePersistenceDetected": any_portable_secret_present,
        "portableConfigPrivateKeyPresent": portable_private_key_present,
        "portableConfigSigningKeyPresent": portable_signing_key_present,
        "portableConfigSignedPrekeyPrivateKeyPresent": portable_signed_prekey_private_key_present,
        "portableConfigOneTimePrekeyPrivateKeyPresent": portable_one_time_prekey_private_key_present,
        "portableConfigOneTimeMlKem1024PrekeySeedPresent": portable_one_time_mlkem1024_prekey_seed_present,
        "portableConfigPairingSecretPresent": portable_pairing_secret_present,
        "authorization": {
            "sharedSystemContextRequired": shared_system_context_required,
            "sharedSystemContextAvailable": shared_system_context_available,
            "singleSystemAuthorizationContextVerified": single_system_authorization_context_verified,
            "systemAuthorizationAttemptCount": system_authorization_attempt_count,
            "systemAuthorizationCompleted": system_authorization_completed,
            "withinPromptBudget": authorization_batch_within_prompt_budget,
            "operationCount": authorization_batch_operation_count,
            "consumedOperationCount": authorization_batch_consumed_operation_count,
            "remainingOperationCount": authorization_batch_remaining_operation_count,
            "withinOperationBudget": authorization_batch_within_budget,
            "allowInteraction": authorization_batch_allow_interaction,
            "backend": authorization_backend,
            "claimConsistent": authorization_claim_consistent,
            "appCredentialPromptUsed": app_credential_prompt_used,
            "appPasswordPromptUsed": app_password_prompt_used
        },
        "keyMaterial": "redacted",
    })
}

fn redacted_pairing_invite(invite: Option<&Value>) -> Value {
    let Some(invite) = invite else {
        return Value::Null;
    };
    let mut public = invite.clone();
    if let Some(object) = public.as_object_mut() {
        if secret_present(object.get("e2eePairingSecret")) {
            object.remove("e2eePairingSecret");
            object.insert("e2eePairingSecretMaterial".to_string(), json!("redacted"));
        }
    }
    public
}

fn secret_present(value: Option<&Value>) -> bool {
    value
        .and_then(Value::as_str)
        .map(is_unredacted_secret)
        .unwrap_or(false)
}

fn is_unredacted_secret(value: &str) -> bool {
    let trimmed = value.trim();
    !trimmed.is_empty() && trimmed != "redacted" && trimmed != "***" && trimmed != "********"
}

fn apply_selected_paired_device_credentials(config: &mut Value) {
    let pairing_id = config
        .get("pairingId")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .trim()
        .to_string();
    if pairing_id.is_empty() {
        return;
    }
    let matching_device = config
        .get("pairedDevices")
        .and_then(Value::as_array)
        .and_then(|devices| {
            devices.iter().find(|device| {
                device
                    .get("pairingId")
                    .and_then(Value::as_str)
                    .map(str::trim)
                    == Some(pairing_id.as_str())
            })
        })
        .cloned();
    let Some(device) = matching_device else {
        return;
    };
    if let Some(token) = device
        .get("mobileToken")
        .and_then(Value::as_str)
        .filter(|value| is_unredacted_secret(value))
    {
        config["mobileToken"] = json!(token);
    }
    if let Some(pc_client_id) = device
        .get("pcClientId")
        .or_else(|| device.get("id"))
        .and_then(Value::as_str)
        .filter(|value| !value.trim().is_empty())
    {
        config["pcClientId"] = json!(pc_client_id.trim());
    }
    if let Some(pc_client_name) = device
        .get("pcClientName")
        .or_else(|| device.get("label"))
        .or_else(|| device.get("name"))
        .and_then(Value::as_str)
        .filter(|value| !value.trim().is_empty())
    {
        config["pcClientName"] = json!(pc_client_name.trim());
    }
    if let Some(providers) = device
        .get("authorizedProviders")
        .and_then(Value::as_array)
        .cloned()
    {
        config["authorizedProviders"] = Value::Array(providers);
    }
}

fn clear_pairing_presentation(config: &mut Value) {
    config["lastPairingCode"] = json!("");
    config["lastPairingExpiresAt"] = json!("");
    if let Some(object) = config.as_object_mut() {
        object.remove("mobileRelayPairingInvite");
    }
}

fn clear_mobile_relay_pairing_state(config: &mut Value) -> Result<()> {
    config["pairingId"] = json!("");
    config["pcToken"] = json!("");
    config["mobileToken"] = json!("");
    clear_pairing_presentation(config);
    config["paired"] = json!(false);
    config["relayEnabled"] = json!(false);
    if let Some(object) = config.as_object_mut() {
        object.remove("pairedDevices");
        object.remove("authorizedProviders");
        object.remove("pcTokenPresent");
        object.remove("mobileTokenPresent");
        object.remove("secretStorageStatus");
    }
    if let Some(state) = config
        .get_mut("mobileRelayE2ee")
        .and_then(Value::as_object_mut)
    {
        let next_mailbox_rotation_epoch = state
            .get("mailboxRotationEpoch")
            .and_then(Value::as_u64)
            .unwrap_or(current_mailbox_rotation_epoch()?)
            .checked_add(1)
            .ok_or_else(|| anyhow!("secure client relay mailbox rotation epoch overflow"))?;
        for key in [
            "peerEndpointId",
            "peerEndpointKind",
            "peerPublicKeyBase64url",
            "peerFingerprint",
            "peerSessionId",
            "peerPreKeyBundle",
            "peerPairwiseIntro",
            "peerPairwiseAccepted",
            "peerPairwiseFinished",
            "peerSigningPublicKeyBase64url",
            "peerRotationEpoch",
            "peerMailboxRotationEpoch",
            "peerDeviceTrustFingerprint",
            "peerTrustRecord",
            "pendingPairwiseIntro",
            "pairwiseAccepted",
            "pairwiseFinished",
        ] {
            state.remove(key);
        }
        state.insert("peerVerified".to_string(), json!(false));
        state.insert(
            "sessionId".to_string(),
            json!(format!("mrelay_session_{}", Uuid::new_v4())),
        );
        state.insert(
            "pairingSecretBase64url".to_string(),
            json!(random_base64url(MOBILE_RELAY_KEY_BYTES)),
        );
        state.insert(
            "mailboxRotationEpoch".to_string(),
            json!(next_mailbox_rotation_epoch),
        );
    }
    purge_mobile_relay_pairwise_sessions()?;
    Ok(())
}

fn delete_mobile_relay_pairing_token_secrets(
    config: &Value,
    batch: &mut MobileRelaySecretStoreAuthBatch,
) -> Result<()> {
    let Some((store, session, namespace)) = batch.authorization()? else {
        return Ok(());
    };
    let mut handles = MOBILE_RELAY_NATIVE_TOKEN_SECRET_FIELDS
        .iter()
        .map(|field| native_secret_store_handle_for_namespace(&namespace, field))
        .collect::<Result<Vec<_>>>()?;
    if let Some(devices) = config.get("pairedDevices").and_then(Value::as_array) {
        for device in devices {
            if let Some(key) = paired_device_token_secret_store_key(device) {
                handles.push(native_secret_store_handle_for_namespace(&namespace, &key)?);
            }
        }
    }
    handles.sort_by(|left, right| left.key().cmp(right.key()));
    handles.dedup();
    for handle in handles {
        store.delete_secret_with_session(&session, &handle)?;
    }
    Ok(())
}

fn ensure_mobile_relay_endpoint_descriptor(
    config: &mut Value,
    endpoint_kind: &str,
) -> Result<Value> {
    ensure_mobile_relay_endpoint_material(config, endpoint_kind)?;
    ensure_mobile_relay_key_transparency(config)?;
    let endpoint = local_endpoint_state(config)?;
    endpoint.public_descriptor()
}

fn ensure_mobile_relay_endpoint_material(config: &mut Value, endpoint_kind: &str) -> Result<()> {
    reset_incompatible_local_pairwise_protocol(config);
    if config
        .get("mobileRelayE2ee")
        .and_then(Value::as_object)
        .is_none()
    {
        config["mobileRelayE2ee"] = json!({});
    }
    if let Some(object) = config
        .get_mut("mobileRelayE2ee")
        .and_then(Value::as_object_mut)
    {
        let mut private = [0u8; MOBILE_RELAY_KEY_BYTES];
        if !object
            .get("privateKeyBase64url")
            .and_then(Value::as_str)
            .is_some_and(is_unredacted_secret)
        {
            OsRng.fill_bytes(&mut private);
            let secret = StaticSecret::from(private);
            let public = PublicKey::from(&secret).to_bytes();
            object.insert(
                "privateKeyBase64url".to_string(),
                json!(general_purpose::URL_SAFE_NO_PAD.encode(private)),
            );
            object.insert(
                "publicKeyBase64url".to_string(),
                json!(general_purpose::URL_SAFE_NO_PAD.encode(public)),
            );
            object.insert(
                "fingerprint".to_string(),
                json!(public_key_fingerprint(&public)),
            );
        }
        if !object
            .get("endpointId")
            .and_then(Value::as_str)
            .is_some_and(|value| !value.trim().is_empty())
        {
            object.insert(
                "endpointId".to_string(),
                json!(format!(
                    "{}_{}",
                    if endpoint_kind == "mobile" {
                        "mobile"
                    } else {
                        "pc"
                    },
                    Uuid::new_v4()
                )),
            );
        }
        if !object
            .get("sessionId")
            .and_then(Value::as_str)
            .is_some_and(|value| !value.trim().is_empty())
        {
            object.insert(
                "sessionId".to_string(),
                json!(format!("mrelay_session_{}", Uuid::new_v4())),
            );
        }
        object.insert(
            "protocolVersion".to_string(),
            json!(MOBILE_RELAY_E2EE_PROTOCOL_VERSION),
        );
        object.insert("endpointKind".to_string(), json!(endpoint_kind));
        object
            .entry("peerVerified".to_string())
            .or_insert_with(|| json!(false));
        if object
            .get("mailboxRotationEpoch")
            .and_then(Value::as_u64)
            .is_none()
        {
            object.insert(
                "mailboxRotationEpoch".to_string(),
                json!(current_mailbox_rotation_epoch()?),
            );
        }
        if !object
            .get("pairingSecretBase64url")
            .and_then(Value::as_str)
            .map(|value| !value.trim().is_empty())
            .unwrap_or(false)
        {
            object.insert(
                "pairingSecretBase64url".to_string(),
                json!(random_base64url(MOBILE_RELAY_KEY_BYTES)),
            );
        }
    }
    ensure_mobile_relay_pqxdh_material(config)
}

fn reset_incompatible_local_pairwise_protocol(config: &mut Value) {
    let incompatible = config
        .get("mobileRelayE2ee")
        .and_then(|state| state.get("protocolVersion"))
        .and_then(Value::as_str)
        .map(str::trim)
        .is_some_and(|protocol| protocol != MOBILE_RELAY_E2EE_PROTOCOL_VERSION);
    if !incompatible {
        return;
    }
    config["mobileRelayE2ee"] = json!({});
    config["pairingId"] = json!("");
    config["pcToken"] = json!("");
    config["mobileToken"] = json!("");
    config["paired"] = json!(false);
    config["relayEnabled"] = json!(false);
    clear_pairing_presentation(config);
    if let Some(root) = config.as_object_mut() {
        for key in [
            "mobileTokenPresent",
            "pairedDevices",
            "pcTokenPresent",
            "relayRegisteredEndpointId",
            "secretStorageStatus",
        ] {
            root.remove(key);
        }
    }
}

fn ensure_mobile_relay_pqxdh_material(config: &mut Value) -> Result<()> {
    let object = config
        .get_mut("mobileRelayE2ee")
        .and_then(Value::as_object_mut)
        .ok_or_else(|| anyhow!("mobile relay E2EE endpoint state is missing"))?;
    let endpoint_id = object
        .get("endpointId")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .ok_or_else(|| anyhow!("mobile relay endpoint id is missing"))?
        .to_string();
    let private_key = object
        .get("privateKeyBase64url")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .ok_or_else(|| anyhow!("mobile relay local private key is missing"))?
        .to_string();
    let identity_secret = StaticSecret::from(decode_key_32(
        &private_key,
        "mobile relay local private key",
    )?);
    let identity_public = PublicKey::from(&identity_secret).to_bytes();
    let public_key = general_purpose::URL_SAFE_NO_PAD.encode(identity_public);
    object.insert("publicKeyBase64url".to_string(), json!(public_key));
    object.insert(
        "fingerprint".to_string(),
        json!(public_key_fingerprint(&identity_public)),
    );

    let signing_key = match object
        .get("signingKeyBase64url")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
    {
        Some(value) => SigningKey::from_bytes(&decode_key_32(value, "mobile relay signing key")?),
        None => {
            let generated = SigningKey::generate(&mut OsRng);
            object.insert(
                "signingKeyBase64url".to_string(),
                json!(general_purpose::URL_SAFE_NO_PAD.encode(generated.to_bytes())),
            );
            generated
        }
    };
    let signing_public = signing_key.verifying_key().to_bytes();
    object.insert(
        "signingPublicKeyBase64url".to_string(),
        json!(general_purpose::URL_SAFE_NO_PAD.encode(signing_public)),
    );
    let rotation_epoch = object
        .get("rotationEpoch")
        .and_then(Value::as_u64)
        .unwrap_or(1);
    object.insert("rotationEpoch".to_string(), json!(rotation_epoch));
    let prekey_publication_version = object
        .get("prekeyPublicationVersion")
        .and_then(Value::as_u64)
        .unwrap_or(1);
    object.insert(
        "prekeyPublicationVersion".to_string(),
        json!(prekey_publication_version),
    );
    let identity = DeviceTrustPublicIdentity::new(
        endpoint_id,
        identity_public,
        signing_public,
        rotation_epoch,
    )?;

    ensure_mobile_relay_prekey_material(
        object,
        &signing_key,
        &identity,
        SecureMeshPreKeyKind::SignedPreKey,
        MobileRelayPreKeyFieldNames {
            id: "signedPrekeyId",
            private_key: "signedPrekeyPrivateKeyBase64url",
            public_key: "signedPrekeyPublicKeyBase64url",
            signature: "signedPrekeySignatureBase64url",
            created_at: "signedPrekeyCreatedAt",
            expires_at: "signedPrekeyExpiresAt",
        },
        "spk",
    )?;
    ensure_mobile_relay_prekey_material(
        object,
        &signing_key,
        &identity,
        SecureMeshPreKeyKind::OneTimePreKey,
        MobileRelayPreKeyFieldNames {
            id: "oneTimePrekeyId",
            private_key: "oneTimePrekeyPrivateKeyBase64url",
            public_key: "oneTimePrekeyPublicKeyBase64url",
            signature: "oneTimePrekeySignatureBase64url",
            created_at: "oneTimePrekeyCreatedAt",
            expires_at: "oneTimePrekeyExpiresAt",
        },
        "otpk",
    )?;
    ensure_mobile_relay_mlkem1024_prekey_material(object, &signing_key, &identity)?;
    Ok(())
}

fn ensure_mobile_relay_key_transparency(config: &mut Value) -> Result<()> {
    #[cfg(test)]
    provision_mobile_relay_test_key_transparency(config)?;

    let bundle = local_pairwise_prekey_bundle_from_config(config)?;
    let response = config
        .get("mobileRelayE2ee")
        .and_then(|state| state.get("keyTransparencyResponse"))
        .filter(|value| value.is_object())
        .cloned()
        .ok_or_else(|| {
            anyhow!("mobile relay endpoint has no externally provisioned key transparency response")
        })?;
    let now = OffsetDateTime::now_utc();
    let self_monitor = authorize_pairwise_directory_response_for_purpose(
        config,
        &bundle,
        response.clone(),
        now,
        DirectoryAuthorizationPurpose::SelfMonitor,
    )?;
    let signed_prekey = authorize_pairwise_directory_response_for_purpose(
        config,
        &bundle,
        response.clone(),
        now,
        DirectoryAuthorizationPurpose::PairwiseSignedPrekey,
    )?;
    let one_time_prekey = authorize_pairwise_directory_response_for_purpose(
        config,
        &bundle,
        response.clone(),
        now,
        DirectoryAuthorizationPurpose::PairwiseOneTimePrekey,
    )?;
    let mls_key_package = match (
        config
            .get("mobileRelayE2ee")
            .and_then(|state| state.get("mlsKeyPackageDigest"))
            .and_then(Value::as_str),
        config
            .get("mobileRelayE2ee")
            .and_then(|state| state.get("mlsKeyPackageVersion"))
            .and_then(Value::as_u64)
            .filter(|version| *version > 0),
    ) {
        (Some(digest), Some(version)) => {
            validate_canonical_sha256_hex(digest, "MLS KeyPackage digest")?;
            let local_endpoint_id = descriptor_text(
                config
                    .get("mobileRelayE2ee")
                    .ok_or_else(|| anyhow!("mobile relay local endpoint state is missing"))?,
                "endpointId",
            )?;
            let mut authority = open_mobile_relay_directory_authority(config, &local_endpoint_id)?;
            let now_epoch_seconds = current_secure_mesh_kt_gate_epoch_seconds()?;
            #[cfg(test)]
            let response = if config
                .get("secureMeshKeyTransparency")
                .and_then(|settings| settings.get("pin"))
                .and_then(|pin| pin.get("provenance"))
                .and_then(Value::as_str)
                == Some("local-acceptance-mock")
            {
                refresh_mobile_relay_test_directory_response(
                    response,
                    authority
                        .latest_checkpoint()?
                        .map(|checkpoint| checkpoint.tree_size),
                    now_epoch_seconds,
                )?
            } else {
                response
            };
            let response: UntrustedDirectoryResponse = serde_json::from_value(response)
                .map_err(|_| anyhow!("mobile relay key transparency response is invalid"))?;
            #[cfg(test)]
            if config
                .get("secureMeshKeyTransparency")
                .and_then(|settings| settings.get("pin"))
                .and_then(|pin| pin.get("provenance"))
                .and_then(Value::as_str)
                == Some("local-acceptance-mock")
            {
                authority.observe_response_gossip_for_test(&response, now_epoch_seconds)?;
            }
            Some(authority.authorize_request(
                response.clone(),
                DirectoryAuthorizationRequest::for_mls(
                    DirectoryAuthorizationPurpose::MlsKeyPackage,
                    configured_directory_scope_commitment(config)?,
                    &bundle.endpoint_identity,
                    response.claim.directory_version,
                    digest,
                    version,
                ),
                now_epoch_seconds,
            )?)
        }
        _ => None,
    };
    config["mobileRelayE2ee"]["keyTransparencyAuthorization"] = json!({
        "provenance": self_monitor.provenance().stable_code(),
        "productionAuthority": self_monitor.provenance().production_service_claim_allowed(),
        "selfMonitorDigest": self_monitor.authorization_digest(),
        "signedPrekeyDigest": signed_prekey.authorization_digest(),
        "oneTimePrekeyDigest": one_time_prekey.authorization_digest(),
        "mlsKeyPackageDigest": mls_key_package
            .as_ref()
            .map(AuthorizedDirectoryLeaf::authorization_digest)
    });
    Ok(())
}

#[cfg(test)]
pub(crate) fn refresh_secure_mesh_mls_test_directory_authority(config: &mut Value) -> Result<()> {
    if config
        .get("secureMeshKeyTransparency")
        .and_then(|settings| settings.get("pin"))
        .and_then(|pin| pin.get("provenance"))
        .and_then(Value::as_str)
        != Some("local-acceptance-mock")
    {
        return Ok(());
    }
    ensure_mobile_relay_key_transparency(config)
}

fn local_pairwise_prekey_bundle_from_config(
    config: &Value,
) -> Result<SecureMeshPairwisePreKeyBundle> {
    let state = config
        .get("mobileRelayE2ee")
        .ok_or_else(|| anyhow!("mobile relay E2EE endpoint state is missing"))?;
    let identity = DeviceTrustPublicIdentity::new(
        descriptor_text(state, "endpointId")?,
        decode_key_32(
            &descriptor_text(state, "publicKeyBase64url")?,
            "mobile relay identity public key",
        )?,
        decode_key_32(
            &descriptor_text(state, "signingPublicKeyBase64url")?,
            "mobile relay signing public key",
        )?,
        state
            .get("rotationEpoch")
            .and_then(Value::as_u64)
            .ok_or_else(|| anyhow!("mobile relay identity rotation epoch is missing"))?,
    )?;
    Ok(SecureMeshPairwisePreKeyBundle {
        endpoint_identity: identity,
        trust_state: DeviceTrustState::Verified,
        signed_prekey: SecureMeshPreKeyRecord {
            prekey_id: descriptor_text(state, "signedPrekeyId")?,
            public_key: decode_key_32(
                &descriptor_text(state, "signedPrekeyPublicKeyBase64url")?,
                "mobile relay signed prekey public key",
            )?
            .to_vec(),
            signature: descriptor_text(state, "signedPrekeySignatureBase64url")?,
            created_at: descriptor_text(state, "signedPrekeyCreatedAt")?,
            expires_at: descriptor_text(state, "signedPrekeyExpiresAt")?,
        },
        one_time_prekey: Some(SecureMeshPreKeyRecord {
            prekey_id: descriptor_text(state, "oneTimePrekeyId")?,
            public_key: decode_key_32(
                &descriptor_text(state, "oneTimePrekeyPublicKeyBase64url")?,
                "mobile relay one-time prekey public key",
            )?
            .to_vec(),
            signature: descriptor_text(state, "oneTimePrekeySignatureBase64url")?,
            created_at: descriptor_text(state, "oneTimePrekeyCreatedAt")?,
            expires_at: descriptor_text(state, "oneTimePrekeyExpiresAt")?,
        }),
        one_time_mlkem1024_prekey: SecureMeshPreKeyRecord {
            prekey_id: descriptor_text(state, "oneTimeMlKem1024PrekeyId")?,
            public_key: decode_fixed_base64url::<ML_KEM_1024_PUBLIC_KEY_BYTES>(
                &descriptor_text(state, "oneTimeMlKem1024PrekeyPublicKeyBase64url")?,
                "mobile relay ML-KEM-1024 one-time prekey public key",
            )?
            .to_vec(),
            signature: descriptor_text(state, "oneTimeMlKem1024PrekeySignatureBase64url")?,
            created_at: descriptor_text(state, "oneTimeMlKem1024PrekeyCreatedAt")?,
            expires_at: descriptor_text(state, "oneTimeMlKem1024PrekeyExpiresAt")?,
        },
        prekey_publication_version: state
            .get("prekeyPublicationVersion")
            .and_then(Value::as_u64)
            .ok_or_else(|| anyhow!("mobile relay prekey publication version is missing"))?,
    })
}

fn build_local_directory_claim(
    config: &Value,
    directory_scope_commitment: &str,
    directory_version: u64,
    directory_state: &str,
    mls_key_package_digest: &str,
    mls_key_package_version: u64,
) -> Result<SecureMeshDirectoryLeafClaim> {
    validate_canonical_sha256_hex(directory_scope_commitment, "directory scope commitment")?;
    validate_canonical_sha256_hex(mls_key_package_digest, "MLS KeyPackage digest")?;
    let bundle = local_pairwise_prekey_bundle_from_config(config)?;
    let state = config
        .get("mobileRelayE2ee")
        .ok_or_else(|| anyhow!("mobile relay E2EE endpoint state is missing"))?;
    Ok(SecureMeshDirectoryLeafClaim {
        endpoint: SecureMeshTransparencyLeafBody {
            directory_scope_commitment: directory_scope_commitment.to_string(),
            endpoint_id: bundle.endpoint_identity.endpoint_id.clone(),
            endpoint_kind: descriptor_text(state, "endpointKind")?,
            identity_public_key: hex_encode_bytes(&bundle.endpoint_identity.identity_public_key),
            signing_public_key: hex_encode_bytes(&bundle.endpoint_identity.signing_public_key),
            fingerprint: bundle.endpoint_identity.fingerprint()?,
            rotation_epoch: bundle.endpoint_identity.rotation_epoch,
            directory_state: directory_state.to_string(),
            updated_at: now_iso(),
        },
        key_material: SecureMeshDirectoryKeyMaterialCommitment {
            signed_prekey_bundle_digest: signed_prekey_bundle_digest(&bundle)?,
            one_time_prekey_batch_digest: one_time_prekey_batch_digest(&bundle)?,
            pairwise_prekey_version: bundle.prekey_publication_version,
            mls_key_package_digest: mls_key_package_digest.to_string(),
            mls_key_package_version,
        },
        directory_version,
    })
}

fn configured_kt_verifier(config: &Value) -> Result<SecureMeshKtVerifierConfiguration> {
    ensure_no_kt_authority_reset_in_progress()?;
    let settings = config
        .get("secureMeshKeyTransparency")
        .filter(|value| value.is_object())
        .cloned()
        .ok_or_else(|| anyhow!("secure mesh KT authority must be configured before publication"))?;
    let configuration: SecureMeshKtVerifierConfiguration = serde_json::from_value(settings)
        .map_err(|_| anyhow!("secure mesh KT local verifier configuration is invalid"))?;
    configuration.validate()?;
    Ok(configuration)
}

fn configured_kt_pin(config: &Value) -> Result<PinnedKtLogKey> {
    configured_kt_verifier(config)?.pin.into_pin()
}

fn configured_directory_scope_commitment(config: &Value) -> Result<&str> {
    let scope = config
        .get("secureMeshDirectoryScopeCommitment")
        .and_then(Value::as_str)
        .ok_or_else(|| {
            anyhow!("secure mesh opaque directory scope commitment is not configured")
        })?;
    validate_canonical_sha256_hex(scope, "directory scope commitment")?;
    Ok(scope)
}

fn derive_local_publication_purpose(
    config: &Value,
    pending: &SecureMeshDirectoryLeafClaim,
) -> Result<DirectoryAuthorizationPurpose> {
    let Some(response_value) = config
        .get("mobileRelayE2ee")
        .and_then(|state| state.get("keyTransparencyResponse"))
        .filter(|value| value.is_object())
    else {
        return Ok(DirectoryAuthorizationPurpose::SelfMonitor);
    };
    let current: UntrustedDirectoryResponse = serde_json::from_value(response_value.clone())
        .map_err(|_| anyhow!("secure mesh current KT directory response is invalid"))?;
    ensure!(
        !current.claim.revoked(),
        "secure mesh revoked directory identity cannot be republished as active"
    );
    ensure!(
        current.claim.endpoint.endpoint_id == pending.endpoint.endpoint_id
            && current.claim.endpoint.directory_scope_commitment
                == pending.endpoint.directory_scope_commitment,
        "secure mesh pending directory identity scope differs from current authority"
    );
    let identity_changed = current.claim.endpoint.identity_public_key
        != pending.endpoint.identity_public_key
        || current.claim.endpoint.signing_public_key != pending.endpoint.signing_public_key
        || current.claim.endpoint.fingerprint != pending.endpoint.fingerprint
        || current.claim.endpoint.rotation_epoch != pending.endpoint.rotation_epoch;
    if identity_changed {
        return Ok(DirectoryAuthorizationPurpose::IdentityKeyChange);
    }
    if current.claim.key_material.mls_key_package_digest
        != pending.key_material.mls_key_package_digest
        || current.claim.key_material.mls_key_package_version
            != pending.key_material.mls_key_package_version
    {
        return Ok(DirectoryAuthorizationPurpose::MlsKeyPackage);
    }
    Ok(DirectoryAuthorizationPurpose::SelfMonitor)
}

fn parse_local_directory_authorization_purpose(
    value: &str,
) -> Result<DirectoryAuthorizationPurpose> {
    match value.trim() {
        "self-monitor" => Ok(DirectoryAuthorizationPurpose::SelfMonitor),
        "identity-key-change" => Ok(DirectoryAuthorizationPurpose::IdentityKeyChange),
        "revocation" => Ok(DirectoryAuthorizationPurpose::Revocation),
        "mls-key-package" => Ok(DirectoryAuthorizationPurpose::MlsKeyPackage),
        "pairwise-signed-prekey" => Ok(DirectoryAuthorizationPurpose::PairwiseSignedPrekey),
        "pairwise-one-time-prekey" => Ok(DirectoryAuthorizationPurpose::PairwiseOneTimePrekey),
        _ => Err(anyhow!(
            "secure mesh local directory authorization purpose is unsupported"
        )),
    }
}

fn validate_canonical_sha256_hex(value: &str, label: &str) -> Result<()> {
    ensure!(
        value.len() == 64
            && value
                .bytes()
                .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte)),
        "secure mesh {label} must be canonical lowercase SHA-256 hex"
    );
    Ok(())
}

#[cfg(test)]
static MOBILE_RELAY_TEST_KT_LOGS: OnceLock<
    Mutex<std::collections::BTreeMap<PathBuf, SecureMeshKtLog>>,
> = OnceLock::new();

#[cfg(test)]
fn with_mobile_relay_test_kt_log<T>(
    operation: impl FnOnce(&mut SecureMeshKtLog) -> Result<T>,
) -> Result<T> {
    // The acceptance authority is test-instance state, never process-global authority. Keying it
    // by the isolated portable root keeps parallel fixtures independent while preserving the same
    // authority across the PC/mobile endpoint switches inside one fixture.
    let authority_root = ClientStateStore::portable()?
        .root()
        .join("mobile-relay")
        .join("secure-mesh-kt");
    let logs =
        MOBILE_RELAY_TEST_KT_LOGS.get_or_init(|| Mutex::new(std::collections::BTreeMap::new()));
    let mut logs = logs
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    let log = logs.entry(authority_root).or_insert_with(|| {
        SecureMeshKtLog::with_identity(
            SigningKey::generate(&mut OsRng),
            "local-mock-kt-log",
            "local-mock-kt-key",
        )
    });
    operation(log)
}

#[cfg(test)]
fn provision_mobile_relay_test_key_transparency(config: &mut Value) -> Result<()> {
    let desired_mls_key_package_digest = config
        .get("mobileRelayE2ee")
        .and_then(|state| state.get("mlsKeyPackageDigest"))
        .and_then(Value::as_str)
        .map(str::to_string)
        .unwrap_or_else(|| hex_encode_bytes(&[0u8; 32]));
    let desired_mls_key_package_version = config
        .get("mobileRelayE2ee")
        .and_then(|state| state.get("mlsKeyPackageVersion"))
        .and_then(Value::as_u64)
        .unwrap_or(0);
    let existing_response = config
        .get("mobileRelayE2ee")
        .and_then(|state| state.get("keyTransparencyResponse"))
        .filter(|value| value.is_object())
        .cloned()
        .map(serde_json::from_value::<UntrustedDirectoryResponse>)
        .transpose()
        .map_err(|_| anyhow!("mobile relay test KT response is invalid"))?;
    if existing_response.as_ref().is_some_and(|response| {
        response.claim.key_material.mls_key_package_digest == desired_mls_key_package_digest
            && response.claim.key_material.mls_key_package_version
                == desired_mls_key_package_version
    }) && config
        .get("secureMeshKeyTransparency")
        .and_then(|settings| settings.get("pin"))
        .is_some_and(Value::is_object)
    {
        return Ok(());
    }
    let bundle = local_pairwise_prekey_bundle_from_config(config)?;
    let state = config
        .get("mobileRelayE2ee")
        .ok_or_else(|| anyhow!("mobile relay E2EE endpoint state is missing"))?;
    let endpoint_kind = descriptor_text(state, "endpointKind")?;
    let previous_tree_size = state
        .get("keyTransparencyLastTreeSize")
        .and_then(Value::as_u64);
    let directory_version = existing_response
        .as_ref()
        .map(|response| response.claim.directory_version.saturating_add(1))
        .unwrap_or(bundle.prekey_publication_version);
    let claim = SecureMeshDirectoryLeafClaim {
        endpoint: SecureMeshTransparencyLeafBody {
            directory_scope_commitment: directory_scope_commitment(
                "local-test-tenant",
                "local-test-account",
                "local-test-workspace",
            ),
            endpoint_id: bundle.endpoint_identity.endpoint_id.clone(),
            endpoint_kind,
            identity_public_key: hex_encode_bytes(&bundle.endpoint_identity.identity_public_key),
            signing_public_key: hex_encode_bytes(&bundle.endpoint_identity.signing_public_key),
            fingerprint: bundle.endpoint_identity.fingerprint()?,
            rotation_epoch: bundle.endpoint_identity.rotation_epoch,
            directory_state: "active".to_string(),
            updated_at: now_iso(),
        },
        key_material: SecureMeshDirectoryKeyMaterialCommitment {
            signed_prekey_bundle_digest: signed_prekey_bundle_digest(&bundle)?,
            one_time_prekey_batch_digest: one_time_prekey_batch_digest(&bundle)?,
            pairwise_prekey_version: bundle.prekey_publication_version,
            mls_key_package_digest: desired_mls_key_package_digest,
            mls_key_package_version: desired_mls_key_package_version,
        },
        directory_version,
    };
    let now_epoch_seconds = mobile_relay_trust_record_now_epoch()?;
    let (response, pin, tree_size) = with_mobile_relay_test_kt_log(|log| {
        let index = log.append_hashed_directory_leaf(
            &claim.stable_label(),
            claim.version(),
            claim.revoked(),
            claim.leaf_hash()?,
        )?;
        let response = UntrustedDirectoryResponse {
            claim: claim.clone(),
            inclusion: log.inclusion_proof_at(index, now_epoch_seconds)?,
            latest_map: log.map_proof_at(&claim.stable_label(), now_epoch_seconds)?,
            consistency: previous_tree_size
                .filter(|first| *first < log.tree_size())
                .map(|first| log.consistency_proof_at(first, now_epoch_seconds))
                .transpose()?,
        };
        Ok((response, log.pin(), log.tree_size()))
    })?;
    config["secureMeshKeyTransparency"] = json!({
        "pin": {
            "logId": pin.log_id(),
            "keyId": pin.key_id(),
            "publicKeyHex": pin.public_key_hex(),
            "provenance": pin.provenance().stable_code()
        },
        "maxSthAgeSeconds": 3600,
        "maxFutureSkewSeconds": 300
    });
    config["secureMeshDirectoryScopeCommitment"] =
        json!(&claim.endpoint.directory_scope_commitment);
    config["mobileRelayE2ee"]["keyTransparencyResponse"] = serde_json::to_value(response)?;
    config["mobileRelayE2ee"]["keyTransparencyLastTreeSize"] = json!(tree_size);
    Ok(())
}

fn hex_encode_bytes(bytes: &[u8]) -> String {
    bytes.iter().map(|byte| format!("{byte:02x}")).collect()
}

struct MobileRelayPreKeyFieldNames {
    id: &'static str,
    private_key: &'static str,
    public_key: &'static str,
    signature: &'static str,
    created_at: &'static str,
    expires_at: &'static str,
}

fn ensure_mobile_relay_prekey_material(
    object: &mut serde_json::Map<String, Value>,
    signing_key: &SigningKey,
    identity: &DeviceTrustPublicIdentity,
    kind: SecureMeshPreKeyKind,
    fields: MobileRelayPreKeyFieldNames,
    id_prefix: &str,
) -> Result<()> {
    let private_key = match object
        .get(fields.private_key)
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
    {
        Some(value) => value.to_string(),
        None => {
            let generated = random_base64url(MOBILE_RELAY_KEY_BYTES);
            object.insert(fields.private_key.to_string(), json!(generated.clone()));
            generated
        }
    };
    let private_bytes = decode_key_32(&private_key, "mobile relay prekey private key")?;
    let prekey_secret = SecureMeshPairwisePrivateKey::from_bytes(private_bytes);
    let public_key = prekey_secret.public_key();
    let prekey_id = object
        .get(fields.id)
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(str::to_string)
        .unwrap_or_else(|| format!("mrelay_{}_{}", id_prefix, Uuid::new_v4()));
    let created_at = object
        .get(fields.created_at)
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(str::to_string)
        .unwrap_or_else(now_iso);
    let expires_at = object
        .get(fields.expires_at)
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(str::to_string)
        .unwrap_or_else(|| {
            (OffsetDateTime::now_utc() + Duration::days(MOBILE_RELAY_PREKEY_VALIDITY_DAYS))
                .format(&Rfc3339)
                .unwrap_or_else(|_| "1970-01-31T00:00:00Z".to_string())
        });
    let record = sign_prekey_record(
        signing_key,
        identity,
        kind,
        prekey_id.clone(),
        public_key,
        created_at.clone(),
        expires_at.clone(),
    )?;
    object.insert(fields.id.to_string(), json!(prekey_id));
    object.insert(
        fields.public_key.to_string(),
        json!(general_purpose::URL_SAFE_NO_PAD.encode(public_key)),
    );
    object.insert(fields.signature.to_string(), json!(record.signature));
    object.insert(fields.created_at.to_string(), json!(created_at));
    object.insert(fields.expires_at.to_string(), json!(expires_at));
    Ok(())
}

fn ensure_mobile_relay_mlkem1024_prekey_material(
    object: &mut serde_json::Map<String, Value>,
    signing_key: &SigningKey,
    identity: &DeviceTrustPublicIdentity,
) -> Result<()> {
    let prekey_seed = match object
        .get("oneTimeMlKem1024PrekeySeedBase64url")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
    {
        Some(value) => SecureMeshMlKem1024PreKeySeed::from_bytes(decode_fixed_base64url(
            value,
            "mobile relay ML-KEM-1024 one-time prekey seed",
        )?),
        None => {
            let generated = SecureMeshMlKem1024PreKeySeed::generate();
            object.insert(
                "oneTimeMlKem1024PrekeySeedBase64url".to_string(),
                json!(general_purpose::URL_SAFE_NO_PAD.encode(generated.expose_for_secret_store())),
            );
            generated
        }
    };
    let public_key = prekey_seed.public_key();
    ensure!(
        public_key.len() == ML_KEM_1024_PUBLIC_KEY_BYTES,
        "mobile relay ML-KEM-1024 one-time prekey public key length is invalid"
    );
    let prekey_id = object
        .get("oneTimeMlKem1024PrekeyId")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(str::to_string)
        .unwrap_or_else(|| format!("mrelay_pqotpk_{}", Uuid::new_v4()));
    let created_at = object
        .get("oneTimeMlKem1024PrekeyCreatedAt")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(str::to_string)
        .unwrap_or_else(now_iso);
    let expires_at = object
        .get("oneTimeMlKem1024PrekeyExpiresAt")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(str::to_string)
        .unwrap_or_else(|| {
            (OffsetDateTime::now_utc() + Duration::days(MOBILE_RELAY_PREKEY_VALIDITY_DAYS))
                .format(&Rfc3339)
                .unwrap_or_else(|_| "1970-01-31T00:00:00Z".to_string())
        });
    let record = sign_prekey_record(
        signing_key,
        identity,
        SecureMeshPreKeyKind::OneTimeMlKem1024PreKey,
        prekey_id.clone(),
        public_key.clone(),
        created_at.clone(),
        expires_at.clone(),
    )?;
    object.insert("oneTimeMlKem1024PrekeyId".to_string(), json!(prekey_id));
    object.insert(
        "oneTimeMlKem1024PrekeyPublicKeyBase64url".to_string(),
        json!(general_purpose::URL_SAFE_NO_PAD.encode(public_key)),
    );
    object.insert(
        "oneTimeMlKem1024PrekeySignatureBase64url".to_string(),
        json!(record.signature),
    );
    object.insert(
        "oneTimeMlKem1024PrekeyCreatedAt".to_string(),
        json!(created_at),
    );
    object.insert(
        "oneTimeMlKem1024PrekeyExpiresAt".to_string(),
        json!(expires_at),
    );
    Ok(())
}

fn rotate_mobile_relay_one_time_prekeys(config: &mut Value) -> Result<()> {
    let object = config
        .get_mut("mobileRelayE2ee")
        .and_then(Value::as_object_mut)
        .ok_or_else(|| anyhow!("mobile relay E2EE endpoint state is missing"))?;
    for key in [
        "oneTimePrekeyId",
        "oneTimePrekeyPrivateKeyBase64url",
        "oneTimePrekeyPublicKeyBase64url",
        "oneTimePrekeySignatureBase64url",
        "oneTimePrekeyCreatedAt",
        "oneTimePrekeyExpiresAt",
        "oneTimeMlKem1024PrekeyId",
        "oneTimeMlKem1024PrekeySeedBase64url",
        "oneTimeMlKem1024PrekeySeedMaterial",
        "oneTimeMlKem1024PrekeyPublicKeyBase64url",
        "oneTimeMlKem1024PrekeySignatureBase64url",
        "oneTimeMlKem1024PrekeyCreatedAt",
        "oneTimeMlKem1024PrekeyExpiresAt",
    ] {
        object.remove(key);
    }
    let next_publication_version = object
        .get("prekeyPublicationVersion")
        .and_then(Value::as_u64)
        .unwrap_or(0)
        .checked_add(1)
        .ok_or_else(|| anyhow!("mobile relay prekey publication version overflow"))?;
    object.insert(
        "prekeyPublicationVersion".to_string(),
        json!(next_publication_version),
    );
    object.remove("keyTransparencyResponse");
    ensure_mobile_relay_pqxdh_material(config)
}

#[cfg(test)]
fn rotate_mobile_relay_local_identity_for_repair(config: &mut Value) -> Result<()> {
    let object = config
        .get_mut("mobileRelayE2ee")
        .and_then(Value::as_object_mut)
        .ok_or_else(|| anyhow!("mobile relay E2EE endpoint state is missing"))?;
    let next_rotation_epoch = object
        .get("rotationEpoch")
        .and_then(Value::as_u64)
        .unwrap_or(0)
        .checked_add(1)
        .ok_or_else(|| anyhow!("mobile relay identity rotation epoch overflow"))?;
    let next_publication_version = object
        .get("prekeyPublicationVersion")
        .and_then(Value::as_u64)
        .unwrap_or(0)
        .checked_add(1)
        .ok_or_else(|| anyhow!("mobile relay prekey publication version overflow"))?;
    for key in [
        "privateKeyBase64url",
        "privateKeyMaterial",
        "publicKeyBase64url",
        "fingerprint",
        "signingKeyBase64url",
        "signingKeyMaterial",
        "signingPublicKeyBase64url",
        "signedPrekeyId",
        "signedPrekeyPrivateKeyBase64url",
        "signedPrekeyPrivateKeyMaterial",
        "signedPrekeyPublicKeyBase64url",
        "signedPrekeySignatureBase64url",
        "signedPrekeyCreatedAt",
        "signedPrekeyExpiresAt",
        "oneTimePrekeyId",
        "oneTimePrekeyPrivateKeyBase64url",
        "oneTimePrekeyPrivateKeyMaterial",
        "oneTimePrekeyPublicKeyBase64url",
        "oneTimePrekeySignatureBase64url",
        "oneTimePrekeyCreatedAt",
        "oneTimePrekeyExpiresAt",
        "oneTimeMlKem1024PrekeyId",
        "oneTimeMlKem1024PrekeySeedBase64url",
        "oneTimeMlKem1024PrekeySeedMaterial",
        "oneTimeMlKem1024PrekeyPublicKeyBase64url",
        "oneTimeMlKem1024PrekeySignatureBase64url",
        "oneTimeMlKem1024PrekeyCreatedAt",
        "oneTimeMlKem1024PrekeyExpiresAt",
        "keyTransparencyResponse",
    ] {
        object.remove(key);
    }
    object.insert(
        "privateKeyBase64url".to_string(),
        json!(random_base64url(MOBILE_RELAY_KEY_BYTES)),
    );
    object.insert("rotationEpoch".to_string(), json!(next_rotation_epoch));
    object.insert(
        "prekeyPublicationVersion".to_string(),
        json!(next_publication_version),
    );
    ensure_mobile_relay_pqxdh_material(config)
}

fn stable_json_sha256(value: &Value) -> String {
    sha256_hex(serde_json::to_string(value).unwrap_or_default().as_bytes())
}

fn one_time_pairing_invite(config: &Value, response: &Value) -> Option<Value> {
    let Some(pairing_id) = response.get("pairingId").and_then(Value::as_str) else {
        return None;
    };
    let Some(pairing_code) = response.get("pairingCode").and_then(Value::as_str) else {
        return None;
    };
    let Some(secret) = config
        .get("mobileRelayE2ee")
        .and_then(|state| state.get("pairingSecretBase64url"))
        .and_then(Value::as_str)
    else {
        return None;
    };
    local_endpoint_state(config).ok().and_then(|endpoint| {
        let pc_secure_mesh = endpoint.public_descriptor().ok()?;
        let authorized_providers =
            public_authorized_providers(config).unwrap_or_else(|| Value::Array(Vec::new()));
        Some(json!({
            "protocolVersion": MOBILE_RELAY_E2EE_PROTOCOL_VERSION,
            "oneTime": true,
            "createdAt": now_iso(),
            "gatewayUrl": effective_gateway_url(config).unwrap_or_else(|_| DEFAULT_GATEWAY_URL.to_string()),
            "pcClientId": config.get("pcClientId").and_then(Value::as_str).unwrap_or_default(),
            "pcClientName": config.get("pcClientName").and_then(Value::as_str).unwrap_or("Lico Arc"),
            "pairingId": pairing_id,
            "pairingCode": pairing_code,
            "pairingCodeHash": sha256_hex(pairing_code.as_bytes()),
            "authorizedProviders": authorized_providers,
            "pcSecureMesh": pc_secure_mesh,
            "e2eePairingSecret": secret
        }))
    })
}

#[allow(dead_code)]
fn apply_pairing_invite_params(config: &mut Value, params: &Value) -> Result<()> {
    apply_pairing_invite_params_with_context(config, params, None)
}

#[allow(dead_code)]
fn apply_pairing_invite_params_with_context(
    config: &mut Value,
    params: &Value,
    mut secret_context: Option<&mut RuntimeSecretContext>,
) -> Result<()> {
    let invite = json_param(params, "invite")
        .or_else(|| json_param(params, "pairingInvite"))
        .or_else(|| json_param(params, "inviteJson"))
        .or(json_file_param(
            params,
            &[
                "inviteFile",
                "invitePath",
                "pairingInviteFile",
                "pairingInvitePath",
                "inviteJsonFile",
                "inviteJsonPath",
            ],
        )?);
    if let Some(invite) = invite {
        if !invite.is_object() {
            return Err(anyhow!("mobile relay pairing invite must be a JSON object"));
        }
        let validated_invite_gateway = match invite.get("gatewayUrl") {
            None => None,
            Some(Value::String(value)) => Some(validated_gateway(value)?),
            Some(_) => {
                return Err(anyhow!(
                    "mobile relay pairing invite gateway must be a valid URL"
                ));
            }
        };
        ensure!(
            descriptor_text(&invite, "protocolVersion")? == MOBILE_RELAY_E2EE_PROTOCOL_VERSION,
            "mobile relay pairing invite protocol is unsupported; a new pairing invite is required"
        );
        ensure!(
            invite.get("oneTime").and_then(Value::as_bool) == Some(true),
            "mobile relay pairing invite must be one-time"
        );
        if pairing_invite_requires_state_reset(config, &invite) {
            let runtime_pairing_secret = config
                .get("mobileRelayE2ee")
                .and_then(|state| state.get("pairingSecretBase64url"))
                .and_then(Value::as_str)
                .map(str::trim)
                .filter(|value| is_unredacted_secret(value))
                .map(str::to_string);
            clear_mobile_relay_pairing_state(config)?;
            if let Some(secret) = runtime_pairing_secret {
                config["mobileRelayE2ee"]["pairingSecretBase64url"] = json!(secret);
            }
        }
        if let Some(pairing_id) = invite.get("pairingId").and_then(Value::as_str) {
            config["pairingId"] = json!(pairing_id);
        }
        if let Some(pairing_code) = invite.get("pairingCode").and_then(Value::as_str) {
            config["lastPairingCode"] = json!(pairing_code);
        }
        if let Some(gateway_url) = validated_invite_gateway {
            config["customGatewayUrl"] = json!(gateway_url);
            config["useCustomGateway"] = json!(true);
            normalize_gateway_fields(config);
        }
        if let Some(pc_client_id) = invite.get("pcClientId").and_then(Value::as_str) {
            config["pcClientId"] = json!(pc_client_id);
        }
        if let Some(pc_client_name) = invite.get("pcClientName").and_then(Value::as_str) {
            config["pcClientName"] = json!(pc_client_name);
        }
        if let Some(providers) = authorized_providers_from_pairing_invite(&invite) {
            config["authorizedProviders"] = providers;
        }
        if let Some(secret) = invite.get("e2eePairingSecret").and_then(Value::as_str) {
            ensure_mobile_relay_endpoint_descriptor(config, "mobile")?;
            config["mobileRelayE2ee"]["pairingSecretBase64url"] = json!(secret.trim());
        }
        if let Some(pc_secure_mesh) = invite.get("pcSecureMesh") {
            ensure_mobile_relay_endpoint_descriptor(config, "mobile")?;
            apply_peer_secure_mesh_descriptor_with_context(
                config,
                pc_secure_mesh,
                true,
                secret_context.as_deref_mut(),
            )?;
        }
    }
    if let Some(secret) = text_param(params, &["e2eePairingSecret", "pairingSecret"]) {
        ensure_mobile_relay_endpoint_descriptor(config, "mobile")?;
        config["mobileRelayE2ee"]["pairingSecretBase64url"] = json!(secret);
    }
    if let Some(pc_secure_mesh) = json_param(params, "pcSecureMesh") {
        ensure_mobile_relay_endpoint_descriptor(config, "mobile")?;
        apply_peer_secure_mesh_descriptor_with_context(
            config,
            &pc_secure_mesh,
            true,
            secret_context.as_deref_mut(),
        )?;
    }
    if let Some(pc_secure_mesh) = json_file_param(
        params,
        &[
            "pcSecureMeshFile",
            "pcSecureMeshPath",
            "pcSecureMeshJsonFile",
            "pcSecureMeshJsonPath",
        ],
    )? {
        ensure_mobile_relay_endpoint_descriptor(config, "mobile")?;
        apply_peer_secure_mesh_descriptor_with_context(
            config,
            &pc_secure_mesh,
            true,
            secret_context.as_deref_mut(),
        )?;
    }
    Ok(())
}

fn pairing_claim_secure_mesh_descriptor_from_params(params: &Value) -> Result<Option<Value>> {
    let invite = json_param(params, "invite")
        .or_else(|| json_param(params, "pairingInvite"))
        .or_else(|| json_param(params, "inviteJson"))
        .or(json_file_param(
            params,
            &[
                "inviteFile",
                "invitePath",
                "pairingInviteFile",
                "pairingInvitePath",
                "inviteJsonFile",
                "inviteJsonPath",
            ],
        )?);
    if let Some(pc_secure_mesh) = invite
        .as_ref()
        .and_then(|invite| invite.get("pcSecureMesh"))
        .cloned()
    {
        return Ok(Some(pc_secure_mesh));
    }
    if let Some(pc_secure_mesh) = json_param(params, "pcSecureMesh") {
        return Ok(Some(pc_secure_mesh));
    }
    json_file_param(
        params,
        &[
            "pcSecureMeshFile",
            "pcSecureMeshPath",
            "pcSecureMeshJsonFile",
            "pcSecureMeshJsonPath",
        ],
    )
}

fn pairing_invite_requires_state_reset(config: &Value, invite: &Value) -> bool {
    let Some(next_pairing_id) = invite
        .get("pairingId")
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
    else {
        return false;
    };
    let current_pairing_id = config
        .get("pairingId")
        .and_then(Value::as_str)
        .map(str::trim)
        .unwrap_or_default();
    if !current_pairing_id.is_empty() {
        return current_pairing_id != next_pairing_id;
    }
    config
        .get("mobileRelayE2ee")
        .and_then(Value::as_object)
        .is_some_and(|state| {
            state
                .get("peerEndpointId")
                .and_then(Value::as_str)
                .is_some_and(|value| !value.trim().is_empty())
                || state.get("pendingPairwiseIntro").is_some()
                || state.get("pairwiseAccepted").is_some()
                || state.get("pairwiseFinished").is_some()
        })
}

#[allow(dead_code)]
fn apply_peer_secure_mesh_descriptor(
    config: &mut Value,
    descriptor: &Value,
    verified: bool,
) -> Result<()> {
    apply_peer_secure_mesh_descriptor_with_context(config, descriptor, verified, None)
}

#[allow(dead_code)]
fn apply_peer_secure_mesh_descriptor_with_context(
    config: &mut Value,
    descriptor: &Value,
    verified: bool,
    mut secret_context: Option<&mut RuntimeSecretContext>,
) -> Result<()> {
    ensure_secure_mesh_protected_operation_allowed()?;
    let endpoint_id = descriptor_text(descriptor, "endpointId")?;
    let endpoint_kind = descriptor_text(descriptor, "endpointKind")?;
    let public_key = descriptor_text(descriptor, "publicKeyBase64url")?;
    let decoded = decode_key_32(&public_key, "mobile relay peer public key")?;
    let mut candidate = config.clone();
    let local_endpoint_kind = candidate
        .get("mobileRelayE2ee")
        .and_then(|state| state.get("endpointKind"))
        .and_then(Value::as_str)
        .unwrap_or("desktop_sidecar")
        .to_string();
    ensure_mobile_relay_endpoint_descriptor(&mut candidate, &local_endpoint_kind)?;
    let local_endpoint_id = candidate
        .get("mobileRelayE2ee")
        .and_then(|state| state.get("endpointId"))
        .and_then(Value::as_str)
        .unwrap_or_default();
    if endpoint_id == local_endpoint_id {
        return Err(anyhow!(
            "mobile relay peer secure mesh descriptor points at the local endpoint"
        ));
    }
    let prior_peer_identity = candidate
        .get("mobileRelayE2ee")
        .and_then(|state| peer_device_identity_from_state(state).ok());
    let prior_peer_verified = candidate
        .get("mobileRelayE2ee")
        .and_then(|state| state.get("peerVerified"))
        .and_then(Value::as_bool)
        .unwrap_or(false);
    let first_pairing = prior_peer_identity
        .as_ref()
        .is_none_or(|prior| prior.endpoint_id != endpoint_id);
    candidate["mobileRelayE2ee"]["peerEndpointId"] = json!(endpoint_id);
    candidate["mobileRelayE2ee"]["peerEndpointKind"] = json!(endpoint_kind);
    candidate["mobileRelayE2ee"]["peerPublicKeyBase64url"] = json!(public_key);
    candidate["mobileRelayE2ee"]["peerFingerprint"] = json!(public_key_fingerprint(&decoded));
    candidate["mobileRelayE2ee"]["peerVerified"] = json!(verified);
    let peer_mailbox_rotation_epoch = descriptor
        .get("mailboxRotationEpoch")
        .and_then(Value::as_u64)
        .ok_or_else(|| anyhow!("mobile relay peer mailbox rotation epoch is missing"))?;
    candidate["mobileRelayE2ee"]["peerMailboxRotationEpoch"] = json!(peer_mailbox_rotation_epoch);
    let peer_prekey_bundle = pairwise_prekey_bundle_from_descriptor(descriptor)?;
    let peer_identity = peer_prekey_bundle.endpoint_identity.clone();
    ensure!(
        peer_identity.endpoint_id == endpoint_id,
        "mobile relay peer trust identity endpoint mismatch"
    );
    ensure!(
        peer_identity.identity_public_key == decoded,
        "mobile relay peer trust identity key mismatch"
    );
    let identity_changed = prior_peer_identity.as_ref().is_some_and(|prior| {
        prior.endpoint_id == peer_identity.endpoint_id
            && (prior.identity_public_key != peer_identity.identity_public_key
                || prior.signing_public_key != peer_identity.signing_public_key)
    });
    let untrusted_directory_response: UntrustedDirectoryResponse = serde_json::from_value(
        descriptor
            .get("preKeyBundle")
            .and_then(|bundle| bundle.get("keyTransparency"))
            .cloned()
            .ok_or_else(|| anyhow!("mobile relay peer key transparency response is missing"))?,
    )
    .map_err(|_| anyhow!("mobile relay peer key transparency response is invalid"))?;
    let directory_purpose = if untrusted_directory_response.claim.revoked() {
        DirectoryAuthorizationPurpose::Revocation
    } else if identity_changed {
        DirectoryAuthorizationPurpose::IdentityKeyChange
    } else if first_pairing {
        DirectoryAuthorizationPurpose::Pairing
    } else {
        DirectoryAuthorizationPurpose::SelfMonitor
    };
    let peer_directory_authorization = authorize_peer_pairwise_directory_for_purpose(
        &candidate,
        descriptor,
        &peer_prekey_bundle,
        OffsetDateTime::now_utc(),
        directory_purpose,
    )?;
    if let Some(prior) = prior_peer_identity
        .as_ref()
        .filter(|prior| prior.endpoint_id == peer_identity.endpoint_id)
    {
        validate_peer_identity_transition(prior, &peer_identity)?;
    }
    let directory_revoked = peer_directory_authorization.claim().revoked();
    let signed_prekey_directory_authorization = if !directory_revoked && !identity_changed {
        Some(authorize_peer_pairwise_directory_for_purpose(
            &candidate,
            descriptor,
            &peer_prekey_bundle,
            OffsetDateTime::now_utc(),
            DirectoryAuthorizationPurpose::PairwiseSignedPrekey,
        )?)
    } else {
        None
    };
    let one_time_prekey_directory_authorization = if !directory_revoked && !identity_changed {
        Some(authorize_peer_pairwise_directory_for_purpose(
            &candidate,
            descriptor,
            &peer_prekey_bundle,
            OffsetDateTime::now_utc(),
            DirectoryAuthorizationPurpose::PairwiseOneTimePrekey,
        )?)
    } else {
        None
    };
    candidate["mobileRelayE2ee"]["peerSigningPublicKeyBase64url"] =
        json!(general_purpose::URL_SAFE_NO_PAD.encode(peer_identity.signing_public_key));
    candidate["mobileRelayE2ee"]["peerRotationEpoch"] = json!(peer_identity.rotation_epoch);
    candidate["mobileRelayE2ee"]["peerDeviceTrustFingerprint"] =
        json!(peer_identity.fingerprint()?);
    candidate["mobileRelayE2ee"]["peerKeyTransparencyAuthorization"] = json!({
        "purpose": directory_purpose.stable_code(),
        "provenance": peer_directory_authorization.provenance().stable_code(),
        "productionAuthority": peer_directory_authorization
            .provenance()
            .production_service_claim_allowed(),
        "authorizationDigest": peer_directory_authorization.authorization_digest(),
        "signedPrekeyAuthorizationDigest": signed_prekey_directory_authorization
            .as_ref()
            .map(AuthorizedDirectoryLeaf::authorization_digest),
        "oneTimePrekeyAuthorizationDigest": one_time_prekey_directory_authorization
            .as_ref()
            .map(AuthorizedDirectoryLeaf::authorization_digest)
    });
    if let Some(e2ee) = candidate
        .get_mut("mobileRelayE2ee")
        .and_then(Value::as_object_mut)
    {
        if let Some(session_id) = descriptor
            .get("sessionId")
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|value| !value.is_empty())
        {
            e2ee.insert("peerSessionId".to_string(), json!(session_id));
        } else {
            e2ee.remove("peerSessionId");
        }
        e2ee.insert(
            "peerPreKeyBundle".to_string(),
            descriptor
                .get("preKeyBundle")
                .filter(|value| value.is_object())
                .cloned()
                .unwrap_or(Value::Null),
        );
        if let Some(pairwise_intro) = descriptor
            .get("pairwiseIntro")
            .filter(|value| value.is_object())
            .cloned()
        {
            e2ee.insert("peerPairwiseIntro".to_string(), pairwise_intro);
        } else {
            e2ee.remove("peerPairwiseIntro");
        }
        if let Some(pairwise_accepted) = descriptor
            .get("pairwiseAccepted")
            .filter(|value| value.is_object())
            .cloned()
        {
            e2ee.insert("peerPairwiseAccepted".to_string(), pairwise_accepted);
        } else {
            e2ee.remove("peerPairwiseAccepted");
        }
        if let Some(pairwise_finished) = descriptor
            .get("pairwiseFinished")
            .filter(|value| value.is_object())
            .cloned()
        {
            e2ee.insert("peerPairwiseFinished".to_string(), pairwise_finished);
        } else {
            e2ee.remove("peerPairwiseFinished");
        }
    }
    let directory_trust_state = if directory_revoked {
        DeviceTrustState::Revoked
    } else if identity_changed {
        DeviceTrustState::KeyChanged
    } else if first_pairing && verified {
        DeviceTrustState::Verified
    } else if prior_peer_verified {
        DeviceTrustState::Verified
    } else {
        DeviceTrustState::Unverified
    };
    candidate["mobileRelayE2ee"]["peerVerified"] =
        json!(directory_trust_state == DeviceTrustState::Verified);
    if directory_trust_state == DeviceTrustState::Verified
        && (first_pairing || identity_changed || directory_revoked)
    {
        let local_endpoint = local_endpoint_state(&candidate)?;
        let issued_at = mobile_relay_trust_record_now_epoch()?;
        let expires_at = mobile_relay_trust_record_expiry_epoch(issued_at)?;
        let trust_record = sign_device_trust_record(
            &local_endpoint.signing_key()?,
            &local_endpoint.device_identity()?,
            &peer_identity,
            DeviceTrustState::Verified,
            peer_identity.rotation_epoch,
            "pairing_claim_proof_and_key_transparency",
            issued_at,
            expires_at,
        )?;
        candidate["mobileRelayE2ee"]["peerTrustRecord"] =
            device_trust_record_to_json(&trust_record);
    } else if directory_trust_state == DeviceTrustState::Unverified
        && first_pairing
        && let Some(e2ee) = candidate
            .get_mut("mobileRelayE2ee")
            .and_then(Value::as_object_mut)
    {
        e2ee.remove("peerTrustRecord");
    }
    if matches!(
        directory_trust_state,
        DeviceTrustState::KeyChanged | DeviceTrustState::Revoked
    ) {
        let terminal_state = match directory_trust_state {
            DeviceTrustState::KeyChanged => "key_changed",
            DeviceTrustState::Revoked => "revoked",
            _ => unreachable!("terminal directory state checked above"),
        };
        candidate["pairingId"] = json!("");
        candidate["pcToken"] = json!("");
        candidate["mobileToken"] = json!("");
        candidate["paired"] = json!(false);
        candidate["relayEnabled"] = json!(false);
        clear_pairing_presentation(&mut candidate);
        if let Some(root) = candidate.as_object_mut() {
            for key in [
                "pairedDevices",
                "authorizedProviders",
                "pcTokenPresent",
                "mobileTokenPresent",
                "secretStorageStatus",
            ] {
                root.remove(key);
            }
        }
        if let Some(e2ee) = candidate
            .get_mut("mobileRelayE2ee")
            .and_then(Value::as_object_mut)
        {
            for key in [
                "peerEndpointId",
                "peerEndpointKind",
                "peerPublicKeyBase64url",
                "peerFingerprint",
                "peerSessionId",
                "peerPreKeyBundle",
                "peerPairwiseIntro",
                "peerPairwiseAccepted",
                "peerPairwiseFinished",
                "peerSigningPublicKeyBase64url",
                "peerRotationEpoch",
                "peerDeviceTrustFingerprint",
                "peerTrustRecord",
                "peerKeyTransparencyAuthorization",
                "pendingPairwiseIntro",
                "pairwiseAccepted",
                "pairwiseFinished",
                "sessionId",
                "pairingSecretBase64url",
            ] {
                e2ee.remove(key);
            }
            e2ee.insert("peerVerified".to_string(), json!(false));
            e2ee.insert(
                "keyTransparencyTerminalPeerBlock".to_string(),
                json!({
                    "schemaVersion": 1,
                    "state": terminal_state,
                    "stableDirectoryLabel": stable_directory_label(
                        &peer_directory_authorization
                            .claim()
                            .endpoint
                            .directory_scope_commitment,
                        &peer_identity.endpoint_id,
                    ),
                    "directoryVersion": peer_directory_authorization.claim().directory_version,
                    "rotationEpoch": peer_identity.rotation_epoch,
                    "treeSize": peer_directory_authorization.signed_tree_head().tree_size,
                    "authorizationDigest": peer_directory_authorization.authorization_digest(),
                    "redacted": true,
                }),
            );
        }
        if let Some(context) = secret_context.as_deref_mut() {
            save_config_with_runtime_secret_context(&mut candidate, context)?;
        } else {
            save_config(&mut candidate)?;
        }
        *config = candidate;
        purge_mobile_relay_pairwise_sessions()?;
        if let Some(context) = secret_context.as_deref_mut() {
            let local_identity = local_endpoint_state(config)?.device_identity()?;
            let (secret_store, authorization, namespace) = context
                .secret_store_batch
                .authorization()?
                .ok_or_else(|| anyhow!("secure mesh MLS selected custody is unavailable"))?;
            crate::domain::secure_mesh_mls::reset_selected_custody_for_kt_authority_change(
                &local_identity,
                secret_store.as_ref(),
                &authorization,
                &namespace,
            )?;
        }
        crate::domain::secure_mesh_mls::reset_durable_state_for_kt_authority_change()?;
        return Err(anyhow!(
            "mobile relay peer directory trust is terminal ({terminal_state}); re-pairing is required"
        ));
    }
    if candidate["mobileRelayE2ee"]
        .get("sessionId")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .trim()
        .is_empty()
    {
        candidate["mobileRelayE2ee"]["sessionId"] =
            json!(format!("mrelay_session_{}", Uuid::new_v4()));
    }
    initialize_mobile_relay_pairwise_session(&mut candidate, descriptor, &peer_identity)?;
    *config = candidate;
    Ok(())
}

fn validate_peer_identity_transition(
    prior: &DeviceTrustPublicIdentity,
    next: &DeviceTrustPublicIdentity,
) -> Result<()> {
    ensure!(
        prior.endpoint_id == next.endpoint_id,
        "mobile relay peer identity transition endpoint mismatch"
    );
    let key_material_changed = prior.identity_public_key != next.identity_public_key
        || prior.signing_public_key != next.signing_public_key;
    if key_material_changed {
        ensure!(
            next.rotation_epoch > prior.rotation_epoch,
            "mobile relay peer identity key change requires strict rotation epoch advance"
        );
    } else {
        ensure!(
            next.rotation_epoch == prior.rotation_epoch,
            "mobile relay unchanged peer identity cannot change rotation epoch"
        );
    }
    Ok(())
}

fn peer_secure_mesh_descriptor(config: &Value) -> Option<Value> {
    let state = config.get("mobileRelayE2ee")?;
    let endpoint_id = state.get("peerEndpointId")?.as_str()?.trim();
    let endpoint_kind = state.get("peerEndpointKind")?.as_str()?.trim();
    let public_key = state.get("peerPublicKeyBase64url")?.as_str()?.trim();
    if endpoint_id.is_empty() || endpoint_kind.is_empty() || public_key.is_empty() {
        return None;
    }
    let mut descriptor = json!({
        "protocolVersion": MOBILE_RELAY_E2EE_PROTOCOL_VERSION,
        "endpointId": endpoint_id,
        "endpointKind": endpoint_kind,
        "publicKeyBase64url": public_key,
        "fingerprint": state.get("peerFingerprint").and_then(Value::as_str).unwrap_or_default(),
        "keyAgreement": "pqxdh-x25519-ed25519-mlkem1024-triple-ratchet",
        "payloadCipher": SECURE_MESH_PAIRWISE_CIPHER_SUITE,
        "sessionId": state
            .get("peerSessionId")
            .or_else(|| state.get("sessionId"))
            .and_then(Value::as_str)
            .unwrap_or_default()
    });
    if let Some(prekey_bundle) = state
        .get("peerPreKeyBundle")
        .filter(|value| value.is_object())
        .cloned()
    {
        descriptor["preKeyBundle"] = prekey_bundle;
    }
    if let Some(pairwise_intro) = state
        .get("peerPairwiseIntro")
        .filter(|value| value.is_object())
        .cloned()
    {
        descriptor["pairwiseIntro"] = pairwise_intro;
    }
    if let Some(pairwise_accepted) = state
        .get("peerPairwiseAccepted")
        .filter(|value| value.is_object())
        .cloned()
    {
        descriptor["pairwiseAccepted"] = pairwise_accepted;
    }
    if let Some(pairwise_finished) = state
        .get("peerPairwiseFinished")
        .filter(|value| value.is_object())
        .cloned()
    {
        descriptor["pairwiseFinished"] = pairwise_finished;
    }
    Some(descriptor)
}

fn ensure_peer_verified(config: &Value) -> Result<()> {
    let _authorization =
        ensure_peer_authorized_for_protected_send(config, ProtectedSendPayloadKind::Command)?;
    Ok(())
}

fn ensure_peer_authorized_for_protected_send(
    config: &Value,
    payload_kind: ProtectedSendPayloadKind,
) -> Result<ProtectedSendAuthorization> {
    ensure_secure_mesh_protected_operation_allowed()?;
    require_current_pairwise_directory_authority(
        config,
        current_secure_mesh_kt_gate_epoch_seconds()?,
    )?;
    ensure_peer_trust_authorized_for_protected_send(config, payload_kind)
}

fn ensure_peer_trust_authorized_for_protected_send(
    config: &Value,
    payload_kind: ProtectedSendPayloadKind,
) -> Result<ProtectedSendAuthorization> {
    ensure_secure_mesh_protected_operation_allowed()?;
    let Some(state) = config.get("mobileRelayE2ee") else {
        return Err(anyhow!(
            "mobile relay E2EE peer is not verified; refusing to process server-relayed commands"
        ));
    };
    let verified = state
        .get("peerVerified")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    if !verified {
        return Err(anyhow!(
            "mobile relay E2EE peer is not verified; refusing to process server-relayed commands"
        ));
    }
    let local_identity = local_endpoint_state(config)?.device_identity()?;
    let peer_identity = peer_device_identity_from_state(state)?;
    let trust_record = state
        .get("peerTrustRecord")
        .ok_or_else(|| anyhow!("mobile relay E2EE peer trust record is missing"))?;
    let record = crate::core::secure_mesh_trust::device_trust_record_from_json(trust_record)?;
    authorize_protected_send_from_trust_record(
        &local_identity,
        &peer_identity,
        &record,
        mobile_relay_trust_record_now_epoch()?,
        payload_kind,
    )
    .map_err(|failure| {
        let message = format!("{failure}");
        if message.contains("peer trust record") || message.contains("trust record") {
            anyhow!("mobile relay E2EE peer trust record is invalid")
        } else if message.contains("verification_required")
            || message.contains("identity_key_changed")
            || message.contains("device_revoked")
            || message.contains("cross_signature_requires_durable_epoch_validation")
        {
            failure
        } else {
            anyhow!("mobile relay E2EE peer trust record is invalid")
        }
    })
}

#[derive(Clone, Debug)]
struct PairwiseDirectoryFreshness {
    tree_size: u64,
    expires_at_epoch_seconds: u64,
}

fn require_current_pairwise_directory_authority(
    config: &Value,
    now_epoch_seconds: u64,
) -> Result<PairwiseDirectoryFreshness> {
    let local = local_endpoint_state(config)?;
    let peer = peer_device_identity_from_state(
        config
            .get("mobileRelayE2ee")
            .ok_or_else(|| anyhow!("mobile relay E2EE endpoint state is missing"))?,
    )?;
    let scope = configured_directory_scope_commitment(config)?;
    let local_label = stable_directory_label(scope, &local.endpoint_id);
    let peer_label = stable_directory_label(scope, &peer.endpoint_id);
    let mut authority = open_mobile_relay_directory_authority(config, &local.endpoint_id)?;
    let local_monitor = authority.require_current_authorization(
        &local_label,
        DirectoryAuthorizationPurpose::SelfMonitor,
        now_epoch_seconds,
    )?;
    let peer_signed_prekey = authority.require_current_authorization(
        &peer_label,
        DirectoryAuthorizationPurpose::PairwiseSignedPrekey,
        now_epoch_seconds,
    )?;
    let peer_one_time_prekey = authority.require_current_authorization(
        &peer_label,
        DirectoryAuthorizationPurpose::PairwiseOneTimePrekey,
        now_epoch_seconds,
    )?;
    let current = authority
        .latest_checkpoint()?
        .ok_or_else(|| anyhow!("secure mesh KT current checkpoint is unavailable"))?;
    for receipt in [&local_monitor, &peer_signed_prekey, &peer_one_time_prekey] {
        ensure_pairwise_authorization_receipt_current(receipt, current.tree_size)?;
    }
    Ok(PairwiseDirectoryFreshness {
        tree_size: current.tree_size,
        expires_at_epoch_seconds: [
            local_monitor.expires_at_epoch_seconds,
            peer_signed_prekey.expires_at_epoch_seconds,
            peer_one_time_prekey.expires_at_epoch_seconds,
        ]
        .into_iter()
        .min()
        .ok_or_else(|| anyhow!("secure mesh KT freshness receipt is unavailable"))?,
    })
}

fn ensure_pairwise_authorization_receipt_current(
    receipt: &SecureMeshKtAuthorizationReceipt,
    current_tree_size: u64,
) -> Result<()> {
    ensure!(
        !receipt.revoked && receipt.tree_size == current_tree_size,
        "secure mesh KT Pairwise authorization requires a current active directory claim"
    );
    Ok(())
}

fn current_secure_mesh_kt_gate_epoch_seconds() -> Result<u64> {
    #[cfg(test)]
    if let Some(now) = KT_FRESHNESS_NOW_OVERRIDE.with(|slot| *slot.borrow()) {
        return Ok(now);
    }
    mobile_relay_trust_record_now_epoch()
}

#[cfg(test)]
struct KtFreshnessNowOverrideGuard {
    previous: Option<u64>,
}

#[cfg(test)]
impl Drop for KtFreshnessNowOverrideGuard {
    fn drop(&mut self) {
        KT_FRESHNESS_NOW_OVERRIDE.with(|slot| {
            slot.replace(self.previous.take());
        });
    }
}

#[cfg(test)]
fn set_kt_freshness_now_override(now: u64) -> KtFreshnessNowOverrideGuard {
    let previous = KT_FRESHNESS_NOW_OVERRIDE.with(|slot| slot.replace(Some(now)));
    KtFreshnessNowOverrideGuard { previous }
}

fn protected_send_kind_from_payload(
    kind: crate::core::secure_mesh_crypto::SecureMeshPayloadKind,
) -> ProtectedSendPayloadKind {
    match kind {
        crate::core::secure_mesh_crypto::SecureMeshPayloadKind::Command => {
            ProtectedSendPayloadKind::Command
        }
        crate::core::secure_mesh_crypto::SecureMeshPayloadKind::ResultPayload
        | crate::core::secure_mesh_crypto::SecureMeshPayloadKind::Error => {
            ProtectedSendPayloadKind::Result
        }
        crate::core::secure_mesh_crypto::SecureMeshPayloadKind::FileChunk
        | crate::core::secure_mesh_crypto::SecureMeshPayloadKind::FileManifest => {
            ProtectedSendPayloadKind::File
        }
        crate::core::secure_mesh_crypto::SecureMeshPayloadKind::ServiceAction
        | crate::core::secure_mesh_crypto::SecureMeshPayloadKind::TypingIndicator
        | crate::core::secure_mesh_crypto::SecureMeshPayloadKind::ReadReceipt => {
            ProtectedSendPayloadKind::Lifecycle
        }
    }
}

fn peer_device_identity_from_state(state: &Value) -> Result<DeviceTrustPublicIdentity> {
    DeviceTrustPublicIdentity::new(
        descriptor_text(state, "peerEndpointId")?,
        decode_key_32(
            &descriptor_text(state, "peerPublicKeyBase64url")?,
            "mobile relay peer trust identity public key",
        )?,
        decode_key_32(
            &descriptor_text(state, "peerSigningPublicKeyBase64url")?,
            "mobile relay peer trust signing public key",
        )?,
        state
            .get("peerRotationEpoch")
            .and_then(Value::as_u64)
            .unwrap_or(1),
    )
}

fn mobile_relay_trust_record_now_epoch() -> Result<u64> {
    u64::try_from(OffsetDateTime::now_utc().unix_timestamp())
        .map_err(|_| anyhow!("mobile relay trust record clock is before unix epoch"))
}

fn mobile_relay_trust_record_expiry_epoch(issued_at_epoch_seconds: u64) -> Result<u64> {
    let expires_at = OffsetDateTime::from_unix_timestamp(
        i64::try_from(issued_at_epoch_seconds)
            .map_err(|_| anyhow!("mobile relay trust record issue time is invalid"))?,
    )
    .map_err(|_| anyhow!("mobile relay trust record issue time is invalid"))?
        + Duration::days(MOBILE_RELAY_TRUST_RECORD_VALIDITY_DAYS);
    u64::try_from(expires_at.unix_timestamp())
        .map_err(|_| anyhow!("mobile relay trust record expiry is invalid"))
}

fn is_peer_trust_record_verified(config: &Value) -> bool {
    config
        .get("mobileRelayE2ee")
        .and_then(|state| {
            let local_identity = local_endpoint_state(config).ok()?.device_identity().ok()?;
            let peer_identity = peer_device_identity_from_state(state).ok()?;
            let trust_record = state.get("peerTrustRecord")?;
            verify_device_trust_record_json(
                &local_identity,
                &peer_identity,
                trust_record,
                mobile_relay_trust_record_now_epoch().ok()?,
            )
            .ok()
        })
        .is_some()
}

struct LocalEndpointState {
    endpoint_id: String,
    endpoint_kind: String,
    private_key: String,
    public_key: String,
    signing_key: String,
    signing_public_key: String,
    rotation_epoch: u64,
    mailbox_rotation_epoch: u64,
    prekey_publication_version: u64,
    signed_prekey_id: String,
    signed_prekey_private_key: String,
    signed_prekey_public_key: String,
    signed_prekey_signature: String,
    signed_prekey_created_at: String,
    signed_prekey_expires_at: String,
    one_time_prekey_id: String,
    one_time_prekey_private_key: String,
    one_time_prekey_public_key: String,
    one_time_prekey_signature: String,
    one_time_prekey_created_at: String,
    one_time_prekey_expires_at: String,
    one_time_mlkem1024_prekey_id: String,
    one_time_mlkem1024_prekey_seed: String,
    one_time_mlkem1024_prekey_public_key: String,
    one_time_mlkem1024_prekey_signature: String,
    one_time_mlkem1024_prekey_created_at: String,
    one_time_mlkem1024_prekey_expires_at: String,
    fingerprint: String,
    session_id: String,
    pending_pairwise_intro: Option<Value>,
    pairwise_accepted: Option<Value>,
    pairwise_finished: Option<Value>,
    key_transparency_response: Option<Value>,
}

impl LocalEndpointState {
    fn public_descriptor(&self) -> Result<Value> {
        let identity = self.device_identity()?;
        Ok(json!({
            "protocolVersion": MOBILE_RELAY_E2EE_PROTOCOL_VERSION,
            "endpointId": self.endpoint_id,
            "endpointKind": self.endpoint_kind,
            "publicKeyBase64url": self.public_key,
            "fingerprint": self.fingerprint,
            "deviceTrustFingerprint": identity.fingerprint()?,
            "identityPublicKeyBase64url": self.public_key,
            "signingPublicKeyBase64url": self.signing_public_key,
            "rotationEpoch": self.rotation_epoch,
            "mailboxRotationEpoch": self.mailbox_rotation_epoch,
            "prekeyPublicationVersion": self.prekey_publication_version,
            "sessionId": self.session_id,
            "keyAgreement": "pqxdh-x25519-ed25519-mlkem1024-triple-ratchet",
            "payloadCipher": SECURE_MESH_PAIRWISE_CIPHER_SUITE,
            "preKeyBundle": self.prekey_bundle_descriptor()?,
            "pairwiseIntro": self.pending_pairwise_intro_descriptor(),
            "pairwiseAccepted": self.pairwise_accepted_descriptor(),
            "pairwiseFinished": self.pairwise_finished_descriptor()
        }))
    }

    fn device_identity(&self) -> Result<DeviceTrustPublicIdentity> {
        DeviceTrustPublicIdentity::new(
            self.endpoint_id.clone(),
            decode_key_32(&self.public_key, "mobile relay identity public key")?,
            decode_key_32(&self.signing_public_key, "mobile relay signing public key")?,
            self.rotation_epoch,
        )
    }

    fn identity_secret(&self) -> Result<SecureMeshPairwisePrivateKey> {
        Ok(SecureMeshPairwisePrivateKey::from_bytes(decode_key_32(
            &self.private_key,
            "mobile relay local private key",
        )?))
    }

    fn signing_key(&self) -> Result<SigningKey> {
        Ok(SigningKey::from_bytes(&decode_key_32(
            &self.signing_key,
            "mobile relay local signing key",
        )?))
    }

    fn pairwise_prekey_bundle(&self) -> Result<SecureMeshPairwisePreKeyBundle> {
        Ok(SecureMeshPairwisePreKeyBundle {
            endpoint_identity: self.device_identity()?,
            trust_state: DeviceTrustState::Verified,
            signed_prekey: SecureMeshPreKeyRecord {
                prekey_id: self.signed_prekey_id.clone(),
                public_key: decode_key_32(
                    &self.signed_prekey_public_key,
                    "mobile relay signed prekey public key",
                )?
                .to_vec(),
                signature: self.signed_prekey_signature.clone(),
                created_at: self.signed_prekey_created_at.clone(),
                expires_at: self.signed_prekey_expires_at.clone(),
            },
            one_time_prekey: Some(SecureMeshPreKeyRecord {
                prekey_id: self.one_time_prekey_id.clone(),
                public_key: decode_key_32(
                    &self.one_time_prekey_public_key,
                    "mobile relay one-time prekey public key",
                )?
                .to_vec(),
                signature: self.one_time_prekey_signature.clone(),
                created_at: self.one_time_prekey_created_at.clone(),
                expires_at: self.one_time_prekey_expires_at.clone(),
            }),
            one_time_mlkem1024_prekey: SecureMeshPreKeyRecord {
                prekey_id: self.one_time_mlkem1024_prekey_id.clone(),
                public_key: decode_fixed_base64url::<ML_KEM_1024_PUBLIC_KEY_BYTES>(
                    &self.one_time_mlkem1024_prekey_public_key,
                    "mobile relay ML-KEM-1024 one-time prekey public key",
                )?
                .to_vec(),
                signature: self.one_time_mlkem1024_prekey_signature.clone(),
                created_at: self.one_time_mlkem1024_prekey_created_at.clone(),
                expires_at: self.one_time_mlkem1024_prekey_expires_at.clone(),
            },
            prekey_publication_version: self.prekey_publication_version,
        })
    }

    fn signed_prekey_secret(&self) -> Result<SecureMeshPairwisePrivateKey> {
        Ok(SecureMeshPairwisePrivateKey::from_bytes(decode_key_32(
            &self.signed_prekey_private_key,
            "mobile relay signed prekey private key",
        )?))
    }

    fn one_time_prekey_secret_for(
        &self,
        requested_id: Option<&str>,
    ) -> Result<Option<SecureMeshPairwisePrivateKey>> {
        match requested_id {
            Some(id) if id == self.one_time_prekey_id => Ok(Some(
                SecureMeshPairwisePrivateKey::from_bytes(decode_key_32(
                    &self.one_time_prekey_private_key,
                    "mobile relay one-time prekey private key",
                )?),
            )),
            Some(_) => Err(anyhow!(
                "mobile relay one-time prekey secret does not match pairwise intro"
            )),
            None => Ok(None),
        }
    }

    fn one_time_mlkem1024_prekey_seed_for(
        &self,
        requested_id: &str,
    ) -> Result<SecureMeshMlKem1024PreKeySeed> {
        ensure!(
            requested_id == self.one_time_mlkem1024_prekey_id,
            "mobile relay ML-KEM-1024 one-time prekey seed does not match pairwise intro"
        );
        Ok(SecureMeshMlKem1024PreKeySeed::from_bytes(
            decode_fixed_base64url::<ML_KEM_1024_KEY_GENERATION_SEED_BYTES>(
                &self.one_time_mlkem1024_prekey_seed,
                "mobile relay ML-KEM-1024 one-time prekey seed",
            )?,
        ))
    }

    fn prekey_bundle_descriptor(&self) -> Result<Value> {
        let identity = self.device_identity()?;
        let key_transparency_response = self
            .key_transparency_response
            .as_ref()
            .ok_or_else(|| anyhow!("mobile relay key transparency response is missing"))?;
        Ok(json!({
            "protocolVersion": crate::core::secure_mesh_prekey::SECURE_MESH_PREKEY_PROTOCOL_VERSION,
            "endpointIdentity": device_identity_to_json(&identity)?,
            "signedPrekey": {
                "prekeyId": self.signed_prekey_id,
                "publicKeyBase64url": self.signed_prekey_public_key,
                "signatureBase64url": self.signed_prekey_signature,
                "createdAt": self.signed_prekey_created_at,
                "expiresAt": self.signed_prekey_expires_at
            },
            "oneTimePrekey": {
                "prekeyId": self.one_time_prekey_id,
                "publicKeyBase64url": self.one_time_prekey_public_key,
                "signatureBase64url": self.one_time_prekey_signature,
                "createdAt": self.one_time_prekey_created_at,
                "expiresAt": self.one_time_prekey_expires_at
            },
            "oneTimeMlKem1024Prekey": {
                "prekeyId": self.one_time_mlkem1024_prekey_id,
                "publicKeyBase64url": self.one_time_mlkem1024_prekey_public_key,
                "signatureBase64url": self.one_time_mlkem1024_prekey_signature,
                "createdAt": self.one_time_mlkem1024_prekey_created_at,
                "expiresAt": self.one_time_mlkem1024_prekey_expires_at
            },
            "prekeyPublicationVersion": self.prekey_publication_version,
            "keyTransparency": key_transparency_response
        }))
    }

    fn pending_pairwise_intro_descriptor(&self) -> Value {
        self.pending_pairwise_intro.clone().unwrap_or(Value::Null)
    }

    fn pairwise_accepted_descriptor(&self) -> Value {
        self.pairwise_accepted.clone().unwrap_or(Value::Null)
    }

    fn pairwise_finished_descriptor(&self) -> Value {
        self.pairwise_finished.clone().unwrap_or(Value::Null)
    }
}

fn local_endpoint_public_descriptor(config: &Value) -> Result<Value> {
    let state = config
        .get("mobileRelayE2ee")
        .ok_or_else(|| anyhow!("mobile relay E2EE endpoint state is missing"))?;
    let endpoint_id = descriptor_text(state, "endpointId")?;
    let endpoint_kind = descriptor_text(state, "endpointKind")?;
    let public_key = descriptor_text(state, "publicKeyBase64url")?;
    let signing_public_key = descriptor_text(state, "signingPublicKeyBase64url")?;
    let rotation_epoch = state
        .get("rotationEpoch")
        .and_then(Value::as_u64)
        .unwrap_or(1);
    let mailbox_rotation_epoch = state
        .get("mailboxRotationEpoch")
        .and_then(Value::as_u64)
        .ok_or_else(|| anyhow!("secure client relay mailbox rotation epoch is missing"))?;
    let prekey_publication_version = state
        .get("prekeyPublicationVersion")
        .and_then(Value::as_u64)
        .ok_or_else(|| anyhow!("mobile relay prekey publication version is missing"))?;
    let public_bytes = decode_key_32(&public_key, "mobile relay public key")?;
    let signing_public_bytes =
        decode_key_32(&signing_public_key, "mobile relay signing public key")?;
    let identity = DeviceTrustPublicIdentity::new(
        endpoint_id.clone(),
        public_bytes,
        signing_public_bytes,
        rotation_epoch,
    )?;
    Ok(json!({
        "protocolVersion": MOBILE_RELAY_E2EE_PROTOCOL_VERSION,
        "endpointId": endpoint_id,
        "endpointKind": endpoint_kind,
        "publicKeyBase64url": public_key,
        "fingerprint": public_key_fingerprint(&public_bytes),
        "deviceTrustFingerprint": identity.fingerprint()?,
        "identityPublicKeyBase64url": public_key,
        "signingPublicKeyBase64url": signing_public_key,
        "rotationEpoch": rotation_epoch,
        "mailboxRotationEpoch": mailbox_rotation_epoch,
        "prekeyPublicationVersion": prekey_publication_version,
        "sessionId": descriptor_text(state, "sessionId")?,
        "keyAgreement": "pqxdh-x25519-ed25519-mlkem1024-triple-ratchet",
        "payloadCipher": SECURE_MESH_PAIRWISE_CIPHER_SUITE,
        "preKeyBundle": {
            "protocolVersion": crate::core::secure_mesh_prekey::SECURE_MESH_PREKEY_PROTOCOL_VERSION,
            "endpointIdentity": device_identity_to_json(&identity)?,
            "signedPrekey": {
                "prekeyId": descriptor_text(state, "signedPrekeyId")?,
                "publicKeyBase64url": descriptor_text(state, "signedPrekeyPublicKeyBase64url")?,
                "signatureBase64url": descriptor_text(state, "signedPrekeySignatureBase64url")?,
                "createdAt": descriptor_text(state, "signedPrekeyCreatedAt")?,
                "expiresAt": descriptor_text(state, "signedPrekeyExpiresAt")?
            },
            "oneTimePrekey": {
                "prekeyId": descriptor_text(state, "oneTimePrekeyId")?,
                "publicKeyBase64url": descriptor_text(state, "oneTimePrekeyPublicKeyBase64url")?,
                "signatureBase64url": descriptor_text(state, "oneTimePrekeySignatureBase64url")?,
                "createdAt": descriptor_text(state, "oneTimePrekeyCreatedAt")?,
                "expiresAt": descriptor_text(state, "oneTimePrekeyExpiresAt")?
            },
            "oneTimeMlKem1024Prekey": {
                "prekeyId": descriptor_text(state, "oneTimeMlKem1024PrekeyId")?,
                "publicKeyBase64url": descriptor_text(state, "oneTimeMlKem1024PrekeyPublicKeyBase64url")?,
                "signatureBase64url": descriptor_text(state, "oneTimeMlKem1024PrekeySignatureBase64url")?,
                "createdAt": descriptor_text(state, "oneTimeMlKem1024PrekeyCreatedAt")?,
                "expiresAt": descriptor_text(state, "oneTimeMlKem1024PrekeyExpiresAt")?
            },
            "prekeyPublicationVersion": state
                .get("prekeyPublicationVersion")
                .and_then(Value::as_u64)
                .ok_or_else(|| anyhow!("mobile relay prekey publication version is missing"))?,
            "keyTransparency": state
                .get("keyTransparencyResponse")
                .filter(|value| value.is_object())
                .cloned()
                .ok_or_else(|| anyhow!("mobile relay key transparency response is missing"))?
        },
        "pairwiseIntro": state
            .get("pendingPairwiseIntro")
            .cloned()
            .unwrap_or(Value::Null),
        "pairwiseAccepted": state
            .get("pairwiseAccepted")
            .cloned()
            .unwrap_or(Value::Null),
        "pairwiseFinished": state
            .get("pairwiseFinished")
            .cloned()
            .unwrap_or(Value::Null)
    }))
}

struct PeerEndpointState {
    endpoint_id: String,
    endpoint_kind: String,
    fingerprint: String,
    mailbox_rotation_epoch: u64,
}

fn local_endpoint_state(config: &Value) -> Result<LocalEndpointState> {
    let state = config
        .get("mobileRelayE2ee")
        .ok_or_else(|| anyhow!("mobile relay E2EE endpoint state is missing"))?;
    let endpoint_id = descriptor_text(state, "endpointId")?;
    let endpoint_kind = descriptor_text(state, "endpointKind")?;
    let private_key = descriptor_text(state, "privateKeyBase64url")?;
    let public_key = descriptor_text(state, "publicKeyBase64url")?;
    let signing_key = descriptor_text(state, "signingKeyBase64url")?;
    let signing_public_key = descriptor_text(state, "signingPublicKeyBase64url")?;
    let rotation_epoch = state
        .get("rotationEpoch")
        .and_then(Value::as_u64)
        .unwrap_or(1);
    let mailbox_rotation_epoch = state
        .get("mailboxRotationEpoch")
        .and_then(Value::as_u64)
        .ok_or_else(|| anyhow!("secure client relay mailbox rotation epoch is missing"))?;
    let prekey_publication_version = state
        .get("prekeyPublicationVersion")
        .and_then(Value::as_u64)
        .ok_or_else(|| anyhow!("mobile relay prekey publication version is missing"))?;
    let signed_prekey_id = descriptor_text(state, "signedPrekeyId")?;
    let signed_prekey_private_key = descriptor_text(state, "signedPrekeyPrivateKeyBase64url")?;
    let signed_prekey_public_key = descriptor_text(state, "signedPrekeyPublicKeyBase64url")?;
    let signed_prekey_signature = descriptor_text(state, "signedPrekeySignatureBase64url")?;
    let signed_prekey_created_at = descriptor_text(state, "signedPrekeyCreatedAt")?;
    let signed_prekey_expires_at = descriptor_text(state, "signedPrekeyExpiresAt")?;
    let one_time_prekey_id = descriptor_text(state, "oneTimePrekeyId")?;
    let one_time_prekey_private_key = descriptor_text(state, "oneTimePrekeyPrivateKeyBase64url")?;
    let one_time_prekey_public_key = descriptor_text(state, "oneTimePrekeyPublicKeyBase64url")?;
    let one_time_prekey_signature = descriptor_text(state, "oneTimePrekeySignatureBase64url")?;
    let one_time_prekey_created_at = descriptor_text(state, "oneTimePrekeyCreatedAt")?;
    let one_time_prekey_expires_at = descriptor_text(state, "oneTimePrekeyExpiresAt")?;
    let one_time_mlkem1024_prekey_id = descriptor_text(state, "oneTimeMlKem1024PrekeyId")?;
    let one_time_mlkem1024_prekey_seed =
        descriptor_text(state, "oneTimeMlKem1024PrekeySeedBase64url")?;
    let one_time_mlkem1024_prekey_public_key =
        descriptor_text(state, "oneTimeMlKem1024PrekeyPublicKeyBase64url")?;
    let one_time_mlkem1024_prekey_signature =
        descriptor_text(state, "oneTimeMlKem1024PrekeySignatureBase64url")?;
    let one_time_mlkem1024_prekey_created_at =
        descriptor_text(state, "oneTimeMlKem1024PrekeyCreatedAt")?;
    let one_time_mlkem1024_prekey_expires_at =
        descriptor_text(state, "oneTimeMlKem1024PrekeyExpiresAt")?;
    let public_bytes = decode_key_32(&public_key, "mobile relay public key")?;
    let session_id = descriptor_text(state, "sessionId")?;
    let key_transparency_response = state
        .get("keyTransparencyResponse")
        .filter(|value| value.is_object())
        .cloned();
    Ok(LocalEndpointState {
        endpoint_id,
        endpoint_kind,
        private_key,
        public_key,
        signing_key,
        signing_public_key,
        rotation_epoch,
        mailbox_rotation_epoch,
        prekey_publication_version,
        signed_prekey_id,
        signed_prekey_private_key,
        signed_prekey_public_key,
        signed_prekey_signature,
        signed_prekey_created_at,
        signed_prekey_expires_at,
        one_time_prekey_id,
        one_time_prekey_private_key,
        one_time_prekey_public_key,
        one_time_prekey_signature,
        one_time_prekey_created_at,
        one_time_prekey_expires_at,
        one_time_mlkem1024_prekey_id,
        one_time_mlkem1024_prekey_seed,
        one_time_mlkem1024_prekey_public_key,
        one_time_mlkem1024_prekey_signature,
        one_time_mlkem1024_prekey_created_at,
        one_time_mlkem1024_prekey_expires_at,
        fingerprint: public_key_fingerprint(&public_bytes),
        session_id,
        pending_pairwise_intro: state.get("pendingPairwiseIntro").cloned(),
        pairwise_accepted: state.get("pairwiseAccepted").cloned(),
        pairwise_finished: state.get("pairwiseFinished").cloned(),
        key_transparency_response,
    })
}

fn peer_endpoint_state(config: &Value) -> Result<PeerEndpointState> {
    let state = config
        .get("mobileRelayE2ee")
        .ok_or_else(|| anyhow!("mobile relay E2EE endpoint state is missing"))?;
    let endpoint_id = descriptor_text(state, "peerEndpointId")?;
    let endpoint_kind = descriptor_text(state, "peerEndpointKind")?;
    let public_key = descriptor_text(state, "peerPublicKeyBase64url")?;
    let mailbox_rotation_epoch = state
        .get("peerMailboxRotationEpoch")
        .and_then(Value::as_u64)
        .ok_or_else(|| anyhow!("secure client relay peer mailbox rotation epoch is missing"))?;
    let public_bytes = decode_key_32(&public_key, "mobile relay peer public key")?;
    Ok(PeerEndpointState {
        endpoint_id,
        endpoint_kind,
        fingerprint: public_key_fingerprint(&public_bytes),
        mailbox_rotation_epoch,
    })
}

fn pairwise_prekey_bundle_from_descriptor(
    descriptor: &Value,
) -> Result<SecureMeshPairwisePreKeyBundle> {
    ensure!(
        descriptor_text(descriptor, "protocolVersion")? == MOBILE_RELAY_E2EE_PROTOCOL_VERSION,
        "mobile relay peer secure mesh descriptor protocol is unsupported; re-pairing is required"
    );
    ensure!(
        descriptor_text(descriptor, "keyAgreement")?
            == "pqxdh-x25519-ed25519-mlkem1024-triple-ratchet",
        "mobile relay peer secure mesh key agreement is unsupported"
    );
    ensure!(
        descriptor_text(descriptor, "payloadCipher")? == SECURE_MESH_PAIRWISE_CIPHER_SUITE,
        "mobile relay peer secure mesh payload cipher is unsupported"
    );
    let bundle = descriptor
        .get("preKeyBundle")
        .filter(|value| value.is_object())
        .ok_or_else(|| anyhow!("mobile relay peer secure mesh descriptor missing preKeyBundle"))?;
    require_exact_object_fields(
        bundle,
        &[
            "endpointIdentity",
            "keyTransparency",
            "oneTimeMlKem1024Prekey",
            "oneTimePrekey",
            "prekeyPublicationVersion",
            "protocolVersion",
            "signedPrekey",
        ],
        "mobile relay peer prekey bundle",
    )?;
    ensure!(
        descriptor_text(bundle, "protocolVersion")?
            == crate::core::secure_mesh_prekey::SECURE_MESH_PREKEY_PROTOCOL_VERSION,
        "mobile relay peer prekey bundle protocol is unsupported"
    );
    let identity_value = bundle
        .get("endpointIdentity")
        .filter(|value| value.is_object())
        .ok_or_else(|| anyhow!("mobile relay peer prekey bundle missing endpointIdentity"))?;
    let endpoint_identity = device_identity_from_descriptor(identity_value)?;
    let signed_prekey = prekey_record_from_descriptor::<MOBILE_RELAY_KEY_BYTES>(
        bundle
            .get("signedPrekey")
            .ok_or_else(|| anyhow!("mobile relay peer prekey bundle missing signedPrekey"))?,
        "signed prekey",
    )?;
    let one_time_prekey = Some(prekey_record_from_descriptor::<MOBILE_RELAY_KEY_BYTES>(
        bundle
            .get("oneTimePrekey")
            .filter(|value| value.is_object())
            .ok_or_else(|| anyhow!("mobile relay peer prekey bundle missing oneTimePrekey"))?,
        "one-time curve prekey",
    )?);
    let one_time_mlkem1024_prekey = prekey_record_from_descriptor::<ML_KEM_1024_PUBLIC_KEY_BYTES>(
        bundle
            .get("oneTimeMlKem1024Prekey")
            .filter(|value| value.is_object())
            .ok_or_else(|| {
                anyhow!(
                    "mobile relay peer prekey bundle missing oneTimeMlKem1024Prekey; re-pairing is required"
                )
            })?,
        "ML-KEM-1024 one-time prekey",
    )?;
    Ok(SecureMeshPairwisePreKeyBundle {
        endpoint_identity,
        // Trust is local state established by the out-of-band pairing proof and the
        // locally signed peer trust record. A relay-provided descriptor cannot assert it.
        trust_state: DeviceTrustState::Unverified,
        signed_prekey,
        one_time_prekey,
        one_time_mlkem1024_prekey,
        prekey_publication_version: bundle
            .get("prekeyPublicationVersion")
            .and_then(Value::as_u64)
            .ok_or_else(|| anyhow!("mobile relay peer prekey publication version is missing"))?,
    })
}

fn authorize_peer_pairwise_directory(
    config: &Value,
    descriptor: &Value,
    bundle: &SecureMeshPairwisePreKeyBundle,
    now: OffsetDateTime,
) -> Result<AuthorizedDirectoryLeaf> {
    authorize_peer_pairwise_directory_for_purpose(
        config,
        descriptor,
        bundle,
        now,
        DirectoryAuthorizationPurpose::PairwiseSessionBootstrap,
    )
}

fn authorize_peer_pairwise_directory_for_purpose(
    config: &Value,
    descriptor: &Value,
    bundle: &SecureMeshPairwisePreKeyBundle,
    now: OffsetDateTime,
    purpose: DirectoryAuthorizationPurpose,
) -> Result<AuthorizedDirectoryLeaf> {
    let response_value = descriptor
        .get("preKeyBundle")
        .and_then(|value| value.get("keyTransparency"))
        .filter(|value| value.is_object())
        .cloned()
        .ok_or_else(|| anyhow!("mobile relay peer key transparency response is missing"))?;
    authorize_pairwise_directory_response_for_purpose(config, bundle, response_value, now, purpose)
}

fn authorize_local_pairwise_directory(
    config: &Value,
    endpoint: &LocalEndpointState,
    now: OffsetDateTime,
) -> Result<AuthorizedDirectoryLeaf> {
    authorize_pairwise_directory_response_for_purpose(
        config,
        &endpoint.pairwise_prekey_bundle()?,
        endpoint
            .key_transparency_response
            .clone()
            .ok_or_else(|| anyhow!("mobile relay key transparency response is missing"))?,
        now,
        DirectoryAuthorizationPurpose::PairwiseSessionBootstrap,
    )
}

fn authorize_pairwise_directory_response_for_purpose(
    config: &Value,
    bundle: &SecureMeshPairwisePreKeyBundle,
    response_value: Value,
    now: OffsetDateTime,
    purpose: DirectoryAuthorizationPurpose,
) -> Result<AuthorizedDirectoryLeaf> {
    let local_endpoint_id = descriptor_text(
        config
            .get("mobileRelayE2ee")
            .ok_or_else(|| anyhow!("mobile relay local endpoint state is missing"))?,
        "endpointId",
    )?;
    let mut authority = open_mobile_relay_directory_authority(config, &local_endpoint_id)?;
    let now_epoch_seconds = u64::try_from(now.unix_timestamp())
        .map_err(|_| anyhow!("mobile relay key transparency clock is before unix epoch"))?;
    #[cfg(test)]
    let response_value = if config
        .get("secureMeshKeyTransparency")
        .and_then(|settings| settings.get("pin"))
        .and_then(|pin| pin.get("provenance"))
        .and_then(Value::as_str)
        == Some("local-acceptance-mock")
    {
        refresh_mobile_relay_test_directory_response(
            response_value,
            authority
                .latest_checkpoint()?
                .map(|checkpoint| checkpoint.tree_size),
            now_epoch_seconds,
        )?
    } else {
        response_value
    };
    let response: UntrustedDirectoryResponse = serde_json::from_value(response_value)
        .map_err(|_| anyhow!("mobile relay key transparency response is invalid"))?;
    #[cfg(test)]
    if config
        .get("secureMeshKeyTransparency")
        .and_then(|settings| settings.get("pin"))
        .and_then(|pin| pin.get("provenance"))
        .and_then(Value::as_str)
        == Some("local-acceptance-mock")
    {
        authority.observe_response_gossip_for_test(&response, now_epoch_seconds)?;
    }
    let signed_prekey_digest = signed_prekey_bundle_digest(bundle)?;
    let one_time_prekey_digest = one_time_prekey_batch_digest(bundle)?;
    authority.authorize_request(
        response,
        DirectoryAuthorizationRequest::for_pairwise(
            purpose,
            configured_directory_scope_commitment(config)?,
            &bundle.endpoint_identity,
            &signed_prekey_digest,
            &one_time_prekey_digest,
            bundle.prekey_publication_version,
        ),
        now_epoch_seconds,
    )
}

fn authorize_exact_local_directory_response(
    config: &Value,
    response_value: Value,
    expected_claim: &SecureMeshDirectoryLeafClaim,
    now: OffsetDateTime,
    purpose: DirectoryAuthorizationPurpose,
) -> Result<AuthorizedDirectoryLeaf> {
    let local_endpoint_id = descriptor_text(
        config
            .get("mobileRelayE2ee")
            .ok_or_else(|| anyhow!("mobile relay local endpoint state is missing"))?,
        "endpointId",
    )?;
    let mut authority = open_mobile_relay_directory_authority(config, &local_endpoint_id)?;
    let now_epoch_seconds = u64::try_from(now.unix_timestamp())
        .map_err(|_| anyhow!("mobile relay key transparency clock is before unix epoch"))?;
    #[cfg(test)]
    let response_value = if config
        .get("secureMeshKeyTransparency")
        .and_then(|settings| settings.get("pin"))
        .and_then(|pin| pin.get("provenance"))
        .and_then(Value::as_str)
        == Some("local-acceptance-mock")
    {
        refresh_mobile_relay_test_directory_response(
            response_value,
            authority
                .latest_checkpoint()?
                .map(|checkpoint| checkpoint.tree_size),
            now_epoch_seconds,
        )?
    } else {
        response_value
    };
    let response: UntrustedDirectoryResponse = serde_json::from_value(response_value)
        .map_err(|_| anyhow!("mobile relay key transparency response is invalid"))?;
    #[cfg(test)]
    if config
        .get("secureMeshKeyTransparency")
        .and_then(|settings| settings.get("pin"))
        .and_then(|pin| pin.get("provenance"))
        .and_then(Value::as_str)
        == Some("local-acceptance-mock")
    {
        authority.observe_response_gossip_for_test(&response, now_epoch_seconds)?;
    }
    authority.authorize_request(
        response,
        DirectoryAuthorizationRequest::for_exact_claim(
            purpose,
            configured_directory_scope_commitment(config)?,
            expected_claim,
        ),
        now_epoch_seconds,
    )
}

#[cfg(test)]
fn refresh_mobile_relay_test_directory_response(
    response_value: Value,
    previous_tree_size: Option<u64>,
    now_epoch_seconds: u64,
) -> Result<Value> {
    // Product code consumes a fresh response from the configured external directory. The
    // in-process test authority has no HTTP query surface, so model that query here instead of
    // treating the static response embedded in a peer descriptor as a permanently current view.
    let stale_response: UntrustedDirectoryResponse = serde_json::from_value(response_value)
        .map_err(|_| anyhow!("mobile relay test key transparency response is invalid"))?;
    let stable_label = stale_response.claim.stable_label();
    let response = with_mobile_relay_test_kt_log(|log| {
        if let Some(previous_tree_size) = previous_tree_size {
            ensure!(
                previous_tree_size <= log.tree_size(),
                "mobile relay test KT checkpoint is ahead of the local mock authority"
            );
        }
        let current_tree_size = log.tree_size();
        ensure!(
            current_tree_size > 0,
            "mobile relay test KT authority has no authenticated map checkpoint"
        );
        let index = current_tree_size - 1;
        Ok(UntrustedDirectoryResponse {
            claim: stale_response.claim,
            inclusion: log.inclusion_proof_at(index, now_epoch_seconds)?,
            latest_map: log.map_proof_at(&stable_label, now_epoch_seconds)?,
            consistency: previous_tree_size
                .filter(|size| *size < current_tree_size)
                .map(|size| log.consistency_proof_at(size, now_epoch_seconds))
                .transpose()?,
        })
    })?;
    serde_json::to_value(response).map_err(Into::into)
}

fn open_mobile_relay_directory_authority(
    config: &Value,
    local_endpoint_id: &str,
) -> Result<SecureMeshDirectoryAuthority> {
    ensure_no_kt_authority_reset_in_progress()?;
    let settings = configured_kt_verifier(config)?;
    SecureMeshDirectoryAuthority::open(
        secure_mesh_kt_authority_path(local_endpoint_id)?,
        settings.pin.into_pin()?,
        KtFreshnessPolicy::strict(
            settings.max_sth_age_seconds,
            settings.max_future_skew_seconds,
        )?,
    )
}

fn prekey_record_from_descriptor<const PUBLIC_KEY_BYTES: usize>(
    value: &Value,
    label: &str,
) -> Result<SecureMeshPreKeyRecord> {
    require_exact_object_fields(
        value,
        &[
            "createdAt",
            "expiresAt",
            "prekeyId",
            "publicKeyBase64url",
            "signatureBase64url",
        ],
        &format!("mobile relay peer {label}"),
    )?;
    Ok(SecureMeshPreKeyRecord {
        prekey_id: descriptor_text(value, "prekeyId")
            .map_err(|_| anyhow!("mobile relay peer {label} id is missing"))?,
        public_key: decode_fixed_base64url::<PUBLIC_KEY_BYTES>(
            &descriptor_text(value, "publicKeyBase64url")?,
            &format!("mobile relay peer {label} public key"),
        )?
        .to_vec(),
        signature: descriptor_text(value, "signatureBase64url")?,
        created_at: descriptor_text(value, "createdAt")?,
        expires_at: descriptor_text(value, "expiresAt")?,
    })
}

fn device_identity_to_json(identity: &DeviceTrustPublicIdentity) -> Result<Value> {
    Ok(json!({
        "endpointId": identity.endpoint_id,
        "identityPublicKeyBase64url": general_purpose::URL_SAFE_NO_PAD.encode(identity.identity_public_key),
        "signingPublicKeyBase64url": general_purpose::URL_SAFE_NO_PAD.encode(identity.signing_public_key),
        "rotationEpoch": identity.rotation_epoch,
        "fingerprint": identity.fingerprint()?
    }))
}

fn device_identity_from_descriptor(value: &Value) -> Result<DeviceTrustPublicIdentity> {
    require_exact_object_fields(
        value,
        &[
            "endpointId",
            "fingerprint",
            "identityPublicKeyBase64url",
            "rotationEpoch",
            "signingPublicKeyBase64url",
        ],
        "mobile relay peer endpoint identity",
    )?;
    let identity = DeviceTrustPublicIdentity::new(
        descriptor_text(value, "endpointId")?,
        decode_key_32(
            &descriptor_text(value, "identityPublicKeyBase64url")?,
            "mobile relay peer identity public key",
        )?,
        decode_key_32(
            &descriptor_text(value, "signingPublicKeyBase64url")?,
            "mobile relay peer signing public key",
        )?,
        value
            .get("rotationEpoch")
            .and_then(Value::as_u64)
            .ok_or_else(|| anyhow!("mobile relay peer identity rotation epoch is missing"))?,
    )?;
    ensure!(
        descriptor_text(value, "fingerprint")? == identity.fingerprint()?,
        "mobile relay peer endpoint identity fingerprint mismatch"
    );
    Ok(identity)
}

fn require_exact_object_fields(value: &Value, expected: &[&str], label: &str) -> Result<()> {
    let object = value
        .as_object()
        .ok_or_else(|| anyhow!("{label} must be an object"))?;
    let actual = object.keys().map(String::as_str).collect::<BTreeSet<_>>();
    let expected = expected.iter().copied().collect::<BTreeSet<_>>();
    ensure!(actual == expected, "{label} shape is invalid");
    Ok(())
}

fn validate_pairwise_intro_targets_local_prekeys(
    config: &Value,
    endpoint: &LocalEndpointState,
    local_identity: &DeviceTrustPublicIdentity,
    peer_identity: &DeviceTrustPublicIdentity,
    intro: &SecureMeshPairwiseSessionIntro,
) -> Result<()> {
    ensure!(
        intro.initiator_endpoint_id == peer_identity.endpoint_id,
        "mobile relay pairwise intro initiator endpoint does not match verified peer"
    );
    ensure!(
        intro.initiator_identity_public_key == peer_identity.identity_public_key,
        "mobile relay pairwise intro initiator identity does not match verified peer"
    );
    ensure!(
        intro.responder_endpoint_id == endpoint.endpoint_id,
        "mobile relay pairwise intro responder endpoint does not match local endpoint"
    );
    ensure!(
        intro.responder_signed_prekey_id == endpoint.signed_prekey_id,
        "mobile relay pairwise intro signed prekey id does not match local endpoint"
    );
    let one_time_prekey_id = intro
        .responder_one_time_prekey_id
        .as_deref()
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .ok_or_else(|| anyhow!("mobile relay pairwise intro one-time prekey id is required"))?;
    ensure!(
        one_time_prekey_id == endpoint.one_time_prekey_id,
        "mobile relay pairwise intro one-time prekey id does not match local endpoint"
    );
    ensure!(
        intro.responder_one_time_mlkem1024_prekey_id == endpoint.one_time_mlkem1024_prekey_id,
        "mobile relay pairwise intro ML-KEM-1024 one-time prekey id does not match local endpoint"
    );
    let local_directory =
        authorize_local_pairwise_directory(config, endpoint, OffsetDateTime::now_utc())?;
    local_directory.require_device_identity(local_identity)?;
    ensure!(
        intro.directory_authorization_digest == local_directory.transcript_binding_digest(),
        "mobile relay pairwise intro directory authorization does not match local endpoint"
    );
    Ok(())
}

fn pairwise_intro_from_descriptor(
    descriptor: &Value,
) -> Result<Option<SecureMeshPairwiseSessionIntro>> {
    let Some(value) = descriptor
        .get("pairwiseIntro")
        .filter(|value| value.is_object())
    else {
        return Ok(None);
    };
    require_exact_object_fields(
        value,
        &[
            "cipherSuite",
            "directoryAuthorizationDigest",
            "initiatorCapabilityProof",
            "initiatorEphemeralPublicKeyBase64url",
            "initiatorIdentityPublicKeyBase64url",
            "initiatorInitialRatchetPublicKeyBase64url",
            "initiatorEndpointId",
            "initiatorSignatureBase64url",
            "mlkem1024CiphertextBase64url",
            "protocolVersion",
            "responderEndpointId",
            "responderOneTimeMlKem1024PrekeyId",
            "responderOneTimePrekeyId",
            "responderSignedPrekeyId",
            "sessionId",
        ],
        "mobile relay pairwise intro",
    )?;
    Ok(Some(SecureMeshPairwiseSessionIntro {
        protocol_version: descriptor_text(value, "protocolVersion")?,
        cipher_suite: descriptor_text(value, "cipherSuite")?,
        session_id: descriptor_text(value, "sessionId")?,
        initiator_endpoint_id: descriptor_text(value, "initiatorEndpointId")?,
        responder_endpoint_id: descriptor_text(value, "responderEndpointId")?,
        initiator_identity_public_key: decode_key_32(
            &descriptor_text(value, "initiatorIdentityPublicKeyBase64url")?,
            "mobile relay pairwise intro identity public key",
        )?
        .to_vec(),
        initiator_ephemeral_public_key: decode_key_32(
            &descriptor_text(value, "initiatorEphemeralPublicKeyBase64url")?,
            "mobile relay pairwise intro ephemeral public key",
        )?
        .to_vec(),
        initiator_initial_ratchet_public_key: decode_key_32(
            &descriptor_text(value, "initiatorInitialRatchetPublicKeyBase64url")?,
            "mobile relay pairwise intro ratchet public key",
        )?
        .to_vec(),
        responder_signed_prekey_id: descriptor_text(value, "responderSignedPrekeyId")?,
        responder_one_time_prekey_id: value
            .get("responderOneTimePrekeyId")
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .map(str::to_string),
        responder_one_time_mlkem1024_prekey_id: descriptor_text(
            value,
            "responderOneTimeMlKem1024PrekeyId",
        )?,
        mlkem1024_ciphertext: decode_fixed_base64url::<ML_KEM_1024_CIPHERTEXT_BYTES>(
            &descriptor_text(value, "mlkem1024CiphertextBase64url")?,
            "mobile relay pairwise intro ML-KEM-1024 ciphertext",
        )?
        .to_vec(),
        directory_authorization_digest: descriptor_sha256_hex(
            value,
            "directoryAuthorizationDigest",
        )?,
        initiator_capability_proof: serde_json::from_value(
            value
                .get("initiatorCapabilityProof")
                .cloned()
                .ok_or_else(|| {
                    anyhow!("mobile relay pairwise intro capability proof is missing")
                })?,
        )
        .map_err(|_| anyhow!("mobile relay pairwise intro capability proof is invalid"))?,
        initiator_signature: descriptor_text(value, "initiatorSignatureBase64url")?,
    }))
}

fn pairwise_intro_to_json(intro: &SecureMeshPairwiseSessionIntro) -> Value {
    json!({
        "protocolVersion": intro.protocol_version,
        "cipherSuite": intro.cipher_suite,
        "sessionId": intro.session_id,
        "initiatorEndpointId": intro.initiator_endpoint_id,
        "responderEndpointId": intro.responder_endpoint_id,
        "initiatorIdentityPublicKeyBase64url": general_purpose::URL_SAFE_NO_PAD.encode(&intro.initiator_identity_public_key),
        "initiatorEphemeralPublicKeyBase64url": general_purpose::URL_SAFE_NO_PAD.encode(&intro.initiator_ephemeral_public_key),
        "initiatorInitialRatchetPublicKeyBase64url": general_purpose::URL_SAFE_NO_PAD.encode(&intro.initiator_initial_ratchet_public_key),
        "responderSignedPrekeyId": intro.responder_signed_prekey_id,
        "responderOneTimePrekeyId": intro.responder_one_time_prekey_id,
        "responderOneTimeMlKem1024PrekeyId": intro.responder_one_time_mlkem1024_prekey_id,
        "mlkem1024CiphertextBase64url": general_purpose::URL_SAFE_NO_PAD.encode(&intro.mlkem1024_ciphertext),
        "directoryAuthorizationDigest": intro.directory_authorization_digest,
        "initiatorCapabilityProof": intro.initiator_capability_proof,
        "initiatorSignatureBase64url": intro.initiator_signature
    })
}

fn pairwise_accepted_from_descriptor(
    descriptor: &Value,
) -> Result<Option<SecureMeshPairwiseSessionAccepted>> {
    let Some(value) = descriptor
        .get("pairwiseAccepted")
        .filter(|value| value.is_object())
    else {
        return Ok(None);
    };
    require_exact_object_fields(
        value,
        &[
            "capabilityBinding",
            "cipherSuite",
            "handshakeTranscriptHashBase64url",
            "keyConfirmationBase64url",
            "protocolVersion",
            "responderCapabilityProof",
            "responderEndpointId",
            "responderInitialRatchetPublicKeyBase64url",
            "responderSignatureBase64url",
            "sessionId",
        ],
        "mobile relay pairwise accepted message",
    )?;
    Ok(Some(SecureMeshPairwiseSessionAccepted {
        protocol_version: descriptor_text(value, "protocolVersion")?,
        cipher_suite: descriptor_text(value, "cipherSuite")?,
        session_id: descriptor_text(value, "sessionId")?,
        responder_endpoint_id: descriptor_text(value, "responderEndpointId")?,
        responder_initial_ratchet_public_key: decode_key_32(
            &descriptor_text(value, "responderInitialRatchetPublicKeyBase64url")?,
            "mobile relay pairwise accepted ratchet public key",
        )?
        .to_vec(),
        handshake_transcript_hash: descriptor_text(value, "handshakeTranscriptHashBase64url")?,
        responder_capability_proof: serde_json::from_value(
            value
                .get("responderCapabilityProof")
                .cloned()
                .ok_or_else(|| {
                    anyhow!("mobile relay pairwise accepted capability proof is missing")
                })?,
        )
        .map_err(|_| anyhow!("mobile relay pairwise accepted capability proof is invalid"))?,
        capability_binding: serde_json::from_value(
            value.get("capabilityBinding").cloned().ok_or_else(|| {
                anyhow!("mobile relay pairwise accepted capability binding is missing")
            })?,
        )
        .map_err(|_| anyhow!("mobile relay pairwise accepted capability binding is invalid"))?,
        responder_signature: descriptor_text(value, "responderSignatureBase64url")?,
        key_confirmation: descriptor_text(value, "keyConfirmationBase64url")?,
    }))
}

fn pairwise_accepted_to_json(accepted: &SecureMeshPairwiseSessionAccepted) -> Value {
    json!({
        "protocolVersion": accepted.protocol_version,
        "cipherSuite": accepted.cipher_suite,
        "sessionId": accepted.session_id,
        "responderEndpointId": accepted.responder_endpoint_id,
        "responderInitialRatchetPublicKeyBase64url": general_purpose::URL_SAFE_NO_PAD.encode(&accepted.responder_initial_ratchet_public_key),
        "handshakeTranscriptHashBase64url": accepted.handshake_transcript_hash,
        "responderCapabilityProof": accepted.responder_capability_proof,
        "capabilityBinding": accepted.capability_binding,
        "responderSignatureBase64url": accepted.responder_signature,
        "keyConfirmationBase64url": accepted.key_confirmation
    })
}

fn pairwise_finished_from_descriptor(
    descriptor: &Value,
) -> Result<Option<SecureMeshPairwiseSessionFinished>> {
    let Some(value) = descriptor
        .get("pairwiseFinished")
        .filter(|value| value.is_object())
    else {
        return Ok(None);
    };
    require_exact_object_fields(
        value,
        &[
            "capabilityTranscriptDigest",
            "cipherSuite",
            "handshakeTranscriptHashBase64url",
            "initiatorEndpointId",
            "keyConfirmationBase64url",
            "protocolVersion",
            "responderEndpointId",
            "sessionId",
        ],
        "mobile relay pairwise finished message",
    )?;
    Ok(Some(SecureMeshPairwiseSessionFinished {
        protocol_version: descriptor_text(value, "protocolVersion")?,
        cipher_suite: descriptor_text(value, "cipherSuite")?,
        session_id: descriptor_text(value, "sessionId")?,
        initiator_endpoint_id: descriptor_text(value, "initiatorEndpointId")?,
        responder_endpoint_id: descriptor_text(value, "responderEndpointId")?,
        handshake_transcript_hash: descriptor_text(value, "handshakeTranscriptHashBase64url")?,
        capability_transcript_digest: descriptor_text(value, "capabilityTranscriptDigest")?,
        key_confirmation: descriptor_text(value, "keyConfirmationBase64url")?,
    }))
}

fn pairwise_finished_to_json(finished: &SecureMeshPairwiseSessionFinished) -> Value {
    json!({
        "protocolVersion": finished.protocol_version,
        "cipherSuite": finished.cipher_suite,
        "sessionId": finished.session_id,
        "initiatorEndpointId": finished.initiator_endpoint_id,
        "responderEndpointId": finished.responder_endpoint_id,
        "handshakeTranscriptHashBase64url": finished.handshake_transcript_hash,
        "capabilityTranscriptDigest": finished.capability_transcript_digest,
        "keyConfirmationBase64url": finished.key_confirmation
    })
}

fn session_id(config: &Value) -> Result<String> {
    config
        .get("mobileRelayE2ee")
        .and_then(|state| state.get("sessionId"))
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(str::to_string)
        .ok_or_else(|| anyhow!("mobile relay E2EE session id is missing"))
}

fn mobile_relay_claim_proof(
    config: &Value,
    pairing_id: &str,
    descriptor: &Value,
) -> Result<String> {
    mobile_relay_claim_proof_for(config, pairing_id, descriptor)
}

fn mobile_relay_claim_proof_for(
    config: &Value,
    pairing_id: &str,
    mobile_descriptor: &Value,
) -> Result<String> {
    let pc_descriptor = peer_secure_mesh_descriptor(config)
        .ok_or_else(|| anyhow!("mobile relay PC secure mesh descriptor is missing"))?;
    mobile_relay_claim_proof_for_pair(config, pairing_id, mobile_descriptor, &pc_descriptor)
}

fn mobile_relay_claim_proof_for_pair(
    config: &Value,
    pairing_id: &str,
    mobile_descriptor: &Value,
    pc_descriptor: &Value,
) -> Result<String> {
    let mac = mobile_relay_claim_proof_mac(config, pairing_id, mobile_descriptor, pc_descriptor)?;
    Ok(general_purpose::URL_SAFE_NO_PAD.encode(mac.finalize().into_bytes()))
}

fn mobile_relay_claim_proof_matches(
    config: &Value,
    pairing_id: &str,
    mobile_descriptor: &Value,
    pc_descriptor: &Value,
    provided_proof: &str,
) -> Result<bool> {
    let Ok(provided) = general_purpose::URL_SAFE_NO_PAD.decode(provided_proof) else {
        return Ok(false);
    };
    if provided.len() != MOBILE_RELAY_KEY_BYTES {
        return Ok(false);
    }
    let mac = mobile_relay_claim_proof_mac(config, pairing_id, mobile_descriptor, pc_descriptor)?;
    Ok(mac.verify_slice(&provided).is_ok())
}

fn mobile_relay_claim_proof_mac(
    config: &Value,
    pairing_id: &str,
    mobile_descriptor: &Value,
    pc_descriptor: &Value,
) -> Result<MobileRelayClaimMac> {
    let secret = config
        .get("mobileRelayE2ee")
        .and_then(|state| state.get("pairingSecretBase64url"))
        .and_then(Value::as_str)
        .filter(|value| !value.trim().is_empty())
        .ok_or_else(|| anyhow!("mobile relay E2EE pairing secret is missing"))?;
    let secret_bytes = general_purpose::URL_SAFE_NO_PAD
        .decode(secret)
        .map_err(|_| anyhow!("mobile relay E2EE pairing secret is not base64url"))?;
    ensure!(
        secret_bytes.len() == MOBILE_RELAY_KEY_BYTES,
        "mobile relay E2EE pairing secret length is invalid"
    );
    let mobile_binding =
        serde_json::to_vec(&mobile_relay_claim_descriptor_binding(mobile_descriptor)?)?;
    let pc_binding = serde_json::to_vec(&mobile_relay_claim_descriptor_binding(pc_descriptor)?)?;
    let mut mac = <MobileRelayClaimMac as Mac>::new_from_slice(&secret_bytes)
        .map_err(|_| anyhow!("mobile relay claim proof initialization failed"))?;
    mac.update(b"licolite.mobile-relay.e2ee.claim-proof.v2");
    update_mobile_relay_claim_mac_field(&mut mac, MOBILE_RELAY_E2EE_PROTOCOL_VERSION.as_bytes())?;
    update_mobile_relay_claim_mac_field(&mut mac, pairing_id.as_bytes())?;
    update_mobile_relay_claim_mac_field(&mut mac, &mobile_binding)?;
    update_mobile_relay_claim_mac_field(&mut mac, &pc_binding)?;
    Ok(mac)
}

fn update_mobile_relay_claim_mac_field(mac: &mut MobileRelayClaimMac, value: &[u8]) -> Result<()> {
    let length = u32::try_from(value.len())
        .map_err(|_| anyhow!("mobile relay claim proof field is too large"))?;
    mac.update(&length.to_be_bytes());
    mac.update(value);
    Ok(())
}

fn mobile_relay_claim_descriptor_binding(descriptor: &Value) -> Result<Value> {
    let prekey_bundle = pairwise_prekey_bundle_from_descriptor(descriptor)?;
    let prekey_bundle_json = descriptor
        .get("preKeyBundle")
        .filter(|value| value.is_object())
        .ok_or_else(|| anyhow!("mobile relay peer secure mesh descriptor missing preKeyBundle"))?;
    let pairwise_intro = descriptor
        .get("pairwiseIntro")
        .cloned()
        .unwrap_or(Value::Null);
    let pairwise_accepted = descriptor
        .get("pairwiseAccepted")
        .cloned()
        .unwrap_or(Value::Null);
    let pairwise_finished = descriptor
        .get("pairwiseFinished")
        .cloned()
        .unwrap_or(Value::Null);
    let identity = prekey_bundle.endpoint_identity;
    Ok(json!({
        "endpointId": descriptor_text(descriptor, "endpointId")?,
        "endpointKind": descriptor_text(descriptor, "endpointKind")?,
        "publicKeyBase64url": descriptor_text(descriptor, "publicKeyBase64url")?,
        "identityPublicKeyBase64url": general_purpose::URL_SAFE_NO_PAD.encode(identity.identity_public_key),
        "signingPublicKeyBase64url": general_purpose::URL_SAFE_NO_PAD.encode(identity.signing_public_key),
        "rotationEpoch": identity.rotation_epoch,
        "deviceTrustFingerprint": identity.fingerprint()?,
        "preKeyBundleHash": stable_json_sha256(prekey_bundle_json),
        "pairwiseIntroHash": stable_json_sha256(&pairwise_intro),
        "pairwiseAcceptedHash": stable_json_sha256(&pairwise_accepted),
        "pairwiseFinishedHash": stable_json_sha256(&pairwise_finished)
    }))
}

fn descriptor_text(value: &Value, key: &str) -> Result<String> {
    value
        .get(key)
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(str::to_string)
        .ok_or_else(|| anyhow!("mobile relay secure mesh descriptor missing {}", key))
}

fn descriptor_sha256_hex(value: &Value, key: &str) -> Result<String> {
    let digest = descriptor_text(value, key)?;
    ensure!(
        digest.len() == 64
            && digest
                .bytes()
                .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte)),
        "mobile relay descriptor {key} must be canonical lowercase SHA-256 hex"
    );
    Ok(digest)
}

fn decode_key_32(value: &str, label: &str) -> Result<[u8; MOBILE_RELAY_KEY_BYTES]> {
    decode_fixed_base64url(value, label)
}

fn decode_fixed_base64url<const BYTES: usize>(value: &str, label: &str) -> Result<[u8; BYTES]> {
    let bytes = general_purpose::URL_SAFE_NO_PAD
        .decode(value)
        .map_err(|_| anyhow!("{} is not base64url", label))?;
    ensure!(
        general_purpose::URL_SAFE_NO_PAD.encode(&bytes) == value,
        "{} must use canonical unpadded base64url",
        label
    );
    let fixed: [u8; BYTES] = bytes
        .try_into()
        .map_err(|_| anyhow!("{} must be {} bytes", label, BYTES))?;
    Ok(fixed)
}

fn public_key_fingerprint(bytes: &[u8; MOBILE_RELAY_KEY_BYTES]) -> String {
    format!("sha256:{}", sha256_hex(bytes))
}

fn random_base64url(len: usize) -> String {
    let mut bytes = vec![0u8; len];
    OsRng.fill_bytes(&mut bytes);
    general_purpose::URL_SAFE_NO_PAD.encode(bytes)
}

fn sha256_hex(bytes: &[u8]) -> String {
    let digest = Sha256::digest(bytes);
    digest.iter().map(|byte| format!("{:02x}", byte)).collect()
}

fn prekey_public_key_hash(public_key: &[u8]) -> String {
    let mut material = b"LCOSM-ONE-TIME-PREKEY-PUBLIC-v1".to_vec();
    material.extend_from_slice(public_key);
    format!("sha256:{}", sha256_hex(&material))
}

fn now_iso() -> String {
    OffsetDateTime::now_utc()
        .format(&Rfc3339)
        .unwrap_or_else(|_| "1970-01-01T00:00:00Z".to_string())
}

fn timestamp_after_seconds(seconds: i64) -> Result<String> {
    Ok((OffsetDateTime::now_utc() + Duration::seconds(seconds)).format(&Rfc3339)?)
}

fn text_param(params: &Value, keys: &[&str]) -> Option<String> {
    keys.iter()
        .find_map(|key| params.get(*key).and_then(Value::as_str))
        .map(|value| value.trim().to_string())
}

fn bool_param(params: &Value, keys: &[&str]) -> Option<bool> {
    for key in keys {
        if let Some(value) = params.get(*key) {
            if let Some(bool_value) = value.as_bool() {
                return Some(bool_value);
            }
            if let Some(text) = value.as_str() {
                return match text.trim().to_lowercase().as_str() {
                    "true" | "1" | "yes" | "on" => Some(true),
                    "false" | "0" | "no" | "off" => Some(false),
                    _ => None,
                };
            }
        }
    }
    None
}

fn ensure_only_known_params(params: &Value, allowed: &[&str], label: &str) -> Result<()> {
    let object = params
        .as_object()
        .ok_or_else(|| anyhow!("{label} parameters must be an object"))?;
    ensure!(
        object.keys().all(|key| allowed.contains(&key.as_str())),
        "{label} contains an unsupported field"
    );
    Ok(())
}

fn json_param(params: &Value, key: &str) -> Option<Value> {
    let value = params.get(key)?;
    if value.is_object() || value.is_array() {
        return Some(value.clone());
    }
    value.as_str().and_then(parse_json_value_param)
}

fn json_file_param(params: &Value, keys: &[&str]) -> Result<Option<Value>> {
    let Some(path) = text_param(params, keys).filter(|value| !value.trim().is_empty()) else {
        return Ok(None);
    };
    let text = fs::read_to_string(&path)
        .map_err(|error| anyhow!("failed to read JSON parameter file {}: {}", path, error))?;
    let text = text.trim_start_matches('\u{feff}');
    let value = serde_json::from_str::<Value>(text)
        .map_err(|error| anyhow!("failed to parse JSON parameter file {}: {}", path, error))?;
    Ok(Some(value))
}

fn parse_json_value_param(text: &str) -> Option<Value> {
    let parsed = serde_json::from_str::<Value>(text).ok()?;
    if let Some(inner) = parsed.as_str() {
        let trimmed = inner.trim();
        if trimmed.starts_with('{') || trimmed.starts_with('[') {
            return serde_json::from_str::<Value>(trimmed).ok().or(Some(parsed));
        }
    }
    Some(parsed)
}

fn validated_gateway(value: &str) -> Result<String> {
    canonical_https_or_loopback_http_origin(value).ok_or_else(|| {
        anyhow!(
            "mobile relay gateway must be a canonical HTTPS origin or exact loopback HTTP origin"
        )
    })
}

fn validated_optional_custom_gateway(value: &str) -> Result<String> {
    if value.trim().is_empty() {
        Ok(String::new())
    } else {
        validated_gateway(value)
    }
}

fn validated_default_gateway(value: &str) -> Result<String> {
    if value.trim().is_empty() {
        Ok(DEFAULT_GATEWAY_URL.to_string())
    } else {
        validated_gateway(value)
    }
}

fn sanitized_default_gateway(value: &str) -> String {
    validated_default_gateway(value).unwrap_or_else(|_| DEFAULT_GATEWAY_URL.to_string())
}

fn prepare_gateway_fields_for_persistence(config: &mut Value) -> Result<()> {
    let default_gateway = validated_default_gateway(
        config
            .get("defaultGatewayUrl")
            .and_then(Value::as_str)
            .unwrap_or_default(),
    )?;
    let custom_gateway = validated_optional_custom_gateway(
        config
            .get("customGatewayUrl")
            .and_then(Value::as_str)
            .unwrap_or_default(),
    )?;
    config["defaultGatewayUrl"] = json!(default_gateway);
    if custom_gateway.is_empty() || is_ephemeral_custom_gateway(&custom_gateway) {
        config["customGatewayUrl"] = json!("");
        config["useCustomGateway"] = json!(false);
    } else {
        config["customGatewayUrl"] = json!(custom_gateway);
    }
    Ok(())
}

fn is_ephemeral_custom_gateway(value: &str) -> bool {
    let host = https_or_loopback_http_host(value)
        .unwrap_or_default()
        .to_ascii_lowercase();
    EPHEMERAL_CUSTOM_GATEWAY_HOST_SUFFIXES
        .iter()
        .any(|suffix| host.ends_with(suffix))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::core::secure_mesh_capability::{
        CapabilityEvidenceKind, CapabilityFact, capability_catalog, mandatory_protocol_facts,
    };
    use crate::platform::paths::set_portable_data_dir_override;
    use crate::platform::secure_client_relay_transport::SecureClientRelayOperation;
    use crate::platform::secure_mesh_secret_store::EphemeralSecretStore;
    use std::env;
    use std::io::{BufRead, BufReader, Read, Write};
    use std::net::{TcpListener, TcpStream};
    use std::sync::{Arc, Mutex};
    use std::thread;

    #[test]
    fn read_only_session_binding_uses_packaged_agents_without_send_readiness() {
        let all = allowed_agent_ids(&json!({}), "agent.sessions.list").unwrap();
        let ids = all.as_array().unwrap();
        assert_eq!(
            ids.len(),
            crate::platform::runtime_adapters::PACKAGED_RUNTIME_ADAPTER_IDS.len()
        );
        assert!(ids.iter().any(|id| id == "codex"));

        let narrowed = allowed_agent_ids(
            &json!({"allowedAgentIds": ["codex", "unsupported-fixture-agent"]}),
            "agent.sessions.list",
        )
        .unwrap();
        assert_eq!(narrowed, json!(["codex"]));
    }

    #[test]
    fn mobile_relay_config_defaults_and_private_gateway() {
        let dir = temp_dir("mobile-relay");
        let previous = set_portable_data_dir_override(Some(dir));

        let config = config_get(&json!({})).unwrap();
        assert_eq!(
            config["config"]["defaultGatewayUrl"],
            json!(DEFAULT_GATEWAY_URL)
        );
        assert_eq!(config["config"]["relayEnabled"], false);

        let saved = config_set(&json!({
            "useCustomGateway": "true",
            "customGatewayUrl": "https://relay.example.test/",
            "relayEnabled": "true"
        }))
        .unwrap();
        assert_eq!(saved["config"]["useCustomGateway"], true);
        assert_eq!(
            saved["config"]["customGatewayUrl"],
            "https://relay.example.test"
        );
        assert_eq!(saved["config"]["relayEnabled"], true);

        set_portable_data_dir_override(previous);
    }

    #[test]
    fn mobile_relay_config_disables_ephemeral_custom_gateway() {
        let dir = temp_dir("mobile-relay-ephemeral-gateway");
        let previous = set_portable_data_dir_override(Some(dir));

        save_config(&mut json!({
            "schemaVersion": CONFIG_SCHEMA_VERSION,
            "defaultGatewayUrl": DEFAULT_GATEWAY_URL,
            "useCustomGateway": true,
            "customGatewayUrl": "https://old-relay.trycloudflare.com/",
            "pcClientId": "pc-ephemeral",
            "pcClientName": "Ephemeral PC",
            "pairingId": "pair-ephemeral",
            "pcToken": "pc-token-ephemeral",
            "relayEnabled": true
        }))
        .unwrap();

        let config = config_get(&json!({})).unwrap();
        assert_eq!(config["config"]["useCustomGateway"], false);
        assert_eq!(config["config"]["customGatewayUrl"], "");

        let loaded = load_config().unwrap();
        assert_eq!(effective_gateway_url(&loaded).unwrap(), DEFAULT_GATEWAY_URL);
        let persisted =
            serde_json::from_str::<Value>(&fs::read_to_string(config_path().unwrap()).unwrap())
                .unwrap();
        assert_eq!(persisted["useCustomGateway"], false);
        assert_eq!(persisted["customGatewayUrl"], "");

        set_portable_data_dir_override(previous);
    }

    #[test]
    fn mobile_relay_existing_corrupt_config_fails_closed_without_replacement() {
        let dir = temp_dir("mobile-relay-corrupt-config-fails-closed");
        let previous = set_portable_data_dir_override(Some(dir));
        let path = config_path().unwrap();
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            fs::set_permissions(path.parent().unwrap(), fs::Permissions::from_mode(0o700)).unwrap();
        }
        let corrupt = b"{not-valid-json";
        fs::write(&path, corrupt).unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            fs::set_permissions(&path, fs::Permissions::from_mode(0o600)).unwrap();
        }

        let error = load_config().unwrap_err().to_string();
        assert!(error.contains("exists but is invalid"));
        assert_eq!(fs::read(&path).unwrap(), corrupt);

        set_portable_data_dir_override(previous);
    }

    #[cfg(unix)]
    #[test]
    fn mobile_relay_existing_insecure_config_permissions_fail_closed() {
        use std::os::unix::fs::PermissionsExt;

        let dir = temp_dir("mobile-relay-insecure-config-permissions");
        let previous = set_portable_data_dir_override(Some(dir));
        let path = config_path().unwrap();
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::set_permissions(path.parent().unwrap(), fs::Permissions::from_mode(0o700)).unwrap();
        fs::write(&path, serde_json::to_vec(&default_config()).unwrap()).unwrap();
        fs::set_permissions(&path, fs::Permissions::from_mode(0o644)).unwrap();

        let error = load_config().unwrap_err().to_string();
        assert!(error.contains("owner-only") || error.contains("permissions"));
        assert_eq!(
            fs::metadata(&path).unwrap().permissions().mode() & 0o777,
            0o644
        );

        set_portable_data_dir_override(previous);
    }

    #[test]
    fn mobile_relay_stale_config_snapshot_cannot_overwrite_newer_commit() {
        let dir = temp_dir("mobile-relay-stale-config-cas");
        let previous = set_portable_data_dir_override(Some(dir));
        let mut winner = load_config().unwrap();
        let mut stale = winner.clone();
        winner["pcClientName"] = json!("winner");
        save_config(&mut winner).unwrap();
        stale["pcClientName"] = json!("stale-loser");

        let error = save_config(&mut stale).unwrap_err().to_string();
        assert!(error.contains("snapshot is stale"));
        let durable = load_config_without_persistence().unwrap();
        assert_eq!(durable["pcClientName"], "winner");
        assert_eq!(
            durable[CONFIG_GENERATION_FIELD],
            winner[CONFIG_GENERATION_FIELD]
        );

        set_portable_data_dir_override(previous);
    }

    #[test]
    fn mobile_relay_concurrent_config_writers_commit_exactly_one_snapshot() {
        use std::sync::Barrier;

        let dir = temp_dir("mobile-relay-concurrent-config-cas");
        let previous = set_portable_data_dir_override(Some(dir.clone()));
        let snapshot = load_config().unwrap();
        let barrier = Arc::new(Barrier::new(2));
        let mut handles = Vec::new();
        for label in ["writer-a", "writer-b"] {
            let root = dir.clone();
            let barrier = barrier.clone();
            let mut candidate = snapshot.clone();
            candidate["pcClientName"] = json!(label);
            handles.push(thread::spawn(move || {
                let prior = set_portable_data_dir_override(Some(root));
                barrier.wait();
                let result = save_config(&mut candidate).map(|_| label.to_string());
                set_portable_data_dir_override(prior);
                result
            }));
        }
        let results = handles
            .into_iter()
            .map(|handle| handle.join().unwrap())
            .collect::<Vec<_>>();
        assert_eq!(results.iter().filter(|result| result.is_ok()).count(), 1);
        assert_eq!(results.iter().filter(|result| result.is_err()).count(), 1);
        let durable = load_config_without_persistence().unwrap();
        assert!(matches!(
            durable["pcClientName"].as_str(),
            Some("writer-a" | "writer-b")
        ));

        set_portable_data_dir_override(previous);
    }

    #[test]
    fn completed_authority_generation_cannot_be_overwritten_by_pre_reset_snapshot() {
        let dir = temp_dir("mobile-relay-authority-generation-cas");
        let previous = set_portable_data_dir_override(Some(dir));
        let mut durable = load_config().unwrap();
        let mut pre_reset = durable.clone();
        begin_kt_authority_reset().unwrap();
        durable[AUTHORITY_GENERATION_FIELD] = json!(
            config_generation(&durable, AUTHORITY_GENERATION_FIELD)
                .unwrap()
                .checked_add(1)
                .unwrap()
        );
        save_config_raw_with_reset_policy(&mut durable, true).unwrap();
        complete_kt_authority_reset().unwrap();
        pre_reset["pcClientName"] = json!("stale-before-reset");

        let error = save_config(&mut pre_reset).unwrap_err().to_string();
        assert!(error.contains("snapshot is stale") || error.contains("authority generation"));
        let reloaded = load_config_without_persistence().unwrap();
        assert_eq!(
            reloaded[AUTHORITY_GENERATION_FIELD],
            durable[AUTHORITY_GENERATION_FIELD]
        );

        set_portable_data_dir_override(previous);
    }

    #[test]
    fn kt_authority_configuration_requires_bound_two_phase_foreground_confirmation() {
        let dir = temp_dir("mobile-relay-kt-two-phase-confirmation");
        let previous = set_portable_data_dir_override(Some(dir));
        let store = Arc::new(EphemeralSecretStore::new());
        let selected: Arc<dyn SecureMeshSecretStore> = store.clone();
        let signing_key = SigningKey::generate(&mut OsRng);
        let proposal = json!({
            "operation": "prepare",
            "directoryScopeCommitment": sha256_hex(b"two-phase-directory-scope"),
            "pin": {
                "logId": "two-phase-log",
                "keyId": "two-phase-key",
                "publicKeyHex": hex_encode_bytes(signing_key.verifying_key().as_bytes()),
                "provenance": "user-configured-external"
            },
            "maxSthAgeSeconds": 3600,
            "maxFutureSkewSeconds": 300
        });

        with_mobile_relay_secret_store_override(selected, || {
            let mut forbidden_one_step = proposal.clone();
            forbidden_one_step["confirmAuthorityConfiguration"] = json!(true);
            assert!(
                key_transparency_configure_authority(&forbidden_one_step)
                    .unwrap_err()
                    .to_string()
                    .contains("cannot confirm its own challenge")
            );
            assert_eq!(store.authorization_session_count(), 0);

            let prepared = key_transparency_configure_authority(&proposal)?;
            assert_eq!(prepared["status"], "confirmation_required");
            assert_eq!(prepared["requiresUserPresence"], true);
            assert_eq!(store.authorization_session_count(), 0);
            let repeated = key_transparency_configure_authority(&proposal)?;
            assert_eq!(
                repeated["authorityChallengeId"],
                prepared["authorityChallengeId"]
            );

            let mut background_confirmation = proposal.clone();
            background_confirmation["operation"] = json!("confirm");
            background_confirmation["authorityChallengeId"] =
                prepared["authorityChallengeId"].clone();
            background_confirmation["confirmAuthorityConfiguration"] = json!(true);
            background_confirmation["allowInteraction"] = json!(false);
            assert!(
                key_transparency_configure_authority(&background_confirmation)
                    .unwrap_err()
                    .to_string()
                    .contains("foreground user interaction")
            );
            assert_eq!(store.authorization_session_count(), 0);

            let mut confirmation = background_confirmation;
            confirmation["allowInteraction"] = json!(true);
            let confirmed = key_transparency_configure_authority(&confirmation)?;
            assert_eq!(confirmed["scopeCommitted"], true);
            assert_eq!(store.authorization_session_count(), 1);
            assert!(read_kt_authority_challenge()?.is_none());
            assert!(authority_configuration_matches(
                &load_config_without_persistence()?,
                &parse_kt_authority_proposal(&proposal)?,
            ));
            Ok(())
        })
        .unwrap();

        set_portable_data_dir_override(previous);
    }

    #[test]
    fn kt_authority_challenge_rejects_stale_config_generation() {
        let dir = temp_dir("mobile-relay-kt-stale-challenge-generation");
        let previous = set_portable_data_dir_override(Some(dir));
        let store = Arc::new(EphemeralSecretStore::new());
        let selected: Arc<dyn SecureMeshSecretStore> = store.clone();
        let signing_key = SigningKey::generate(&mut OsRng);
        let proposal = json!({
            "operation": "prepare",
            "directoryScopeCommitment": sha256_hex(b"stale-challenge-directory-scope"),
            "pin": {
                "logId": "stale-challenge-log",
                "keyId": "stale-challenge-key",
                "publicKeyHex": hex_encode_bytes(signing_key.verifying_key().as_bytes()),
                "provenance": "user-configured-external"
            },
            "maxSthAgeSeconds": 3600,
            "maxFutureSkewSeconds": 300
        });
        with_mobile_relay_secret_store_override(selected, || {
            let prepared = key_transparency_configure_authority(&proposal)?;
            let mut unrelated = load_config()?;
            unrelated["pcClientName"] = json!("concurrent-config-update");
            save_config(&mut unrelated)?;
            let mut confirmation = proposal.clone();
            confirmation["operation"] = json!("confirm");
            confirmation["authorityChallengeId"] = prepared["authorityChallengeId"].clone();
            confirmation["confirmAuthorityConfiguration"] = json!(true);
            confirmation["allowInteraction"] = json!(true);
            let error = key_transparency_configure_authority(&confirmation)
                .unwrap_err()
                .to_string();
            assert!(error.contains("generation is stale"));
            assert!(
                load_config_without_persistence()?
                    .get("secureMeshKeyTransparency")
                    .is_none()
            );
            Ok(())
        })
        .unwrap();
        set_portable_data_dir_override(previous);
    }

    #[test]
    fn mobile_relay_config_set_disables_ephemeral_custom_gateway_before_save() {
        let dir = temp_dir("mobile-relay-ephemeral-gateway-set");
        let previous = set_portable_data_dir_override(Some(dir));

        let saved = config_set(&json!({
            "useCustomGateway": true,
            "customGatewayUrl": "https://old-relay.trycloudflare.com/"
        }))
        .unwrap();

        assert_eq!(saved["config"]["useCustomGateway"], false);
        assert_eq!(saved["config"]["customGatewayUrl"], "");

        let persisted =
            serde_json::from_str::<Value>(&fs::read_to_string(config_path().unwrap()).unwrap())
                .unwrap();
        assert_eq!(persisted["useCustomGateway"], false);
        assert_eq!(persisted["customGatewayUrl"], "");

        set_portable_data_dir_override(previous);
    }

    #[test]
    fn config_reset_pairing_clears_local_pairing_without_resetting_identity_or_gateway() {
        let dir = temp_dir("mobile-relay-reset-pairing");
        let previous = set_portable_data_dir_override(Some(dir));
        let mut config = default_config();
        config["useCustomGateway"] = json!(true);
        config["customGatewayUrl"] = json!("https://relay.example.test");
        config["pcClientId"] = json!("pc-stable");
        config["pcClientName"] = json!("Stable Mac");
        config["pairingId"] = json!("pair-stale");
        config["pcToken"] = json!("pc-token-stale");
        config["mobileToken"] = json!("mobile-token-stale");
        config["lastPairingCode"] = json!("123456");
        config["lastPairingExpiresAt"] = json!("2099-01-01T00:00:00Z");
        config["paired"] = json!(true);
        config["relayEnabled"] = json!(true);
        ensure_mobile_relay_endpoint_descriptor(&mut config, "desktop_sidecar").unwrap();
        let endpoint_id = config["mobileRelayE2ee"]["endpointId"]
            .as_str()
            .unwrap()
            .to_string();
        let public_key = config["mobileRelayE2ee"]["publicKeyBase64url"]
            .as_str()
            .unwrap()
            .to_string();
        let session_id = config["mobileRelayE2ee"]["sessionId"]
            .as_str()
            .unwrap()
            .to_string();
        let pairing_secret = config["mobileRelayE2ee"]["pairingSecretBase64url"]
            .as_str()
            .unwrap()
            .to_string();
        config["mobileRelayE2ee"]["peerEndpointId"] = json!("mobile-stale");
        config["mobileRelayE2ee"]["peerEndpointKind"] = json!("mobile");
        config["mobileRelayE2ee"]["peerPublicKeyBase64url"] = json!(random_base64url(32));
        config["mobileRelayE2ee"]["peerFingerprint"] = json!("peer-fingerprint-stale");
        config["mobileRelayE2ee"]["peerVerified"] = json!(true);
        config["mobileRelayPairingInvite"] = json!({"pairingId": "pair-stale"});
        config["pairedDevices"] = json!([{"pairingId": "pair-stale"}]);
        save_config(&mut config).unwrap();

        let saved = config_set(&json!({"resetPairing": true})).unwrap();
        assert_eq!(saved["config"]["useCustomGateway"], true);
        assert_eq!(
            saved["config"]["customGatewayUrl"],
            "https://relay.example.test"
        );
        assert_eq!(saved["config"]["pcClientId"], "pc-stable");
        assert_eq!(saved["config"]["pcClientName"], "Stable Mac");
        assert_eq!(saved["config"]["pairingId"], "");
        assert_eq!(saved["config"]["pcTokenPresent"], false);
        assert_eq!(saved["config"]["mobileTokenPresent"], false);
        assert_eq!(saved["config"]["paired"], false);
        assert_eq!(saved["config"]["relayEnabled"], false);
        assert!(saved["config"].get("pairedDevices").is_none());
        assert!(saved["config"].get("mobileRelayPairingInvite").is_none());

        let (internal, _) = load_config_with_runtime_secret_overrides(&json!({})).unwrap();
        assert_eq!(internal["mobileRelayE2ee"]["endpointId"], endpoint_id);
        assert_eq!(
            internal["mobileRelayE2ee"]["publicKeyBase64url"],
            public_key
        );
        assert_eq!(internal["mobileRelayE2ee"]["peerVerified"], false);
        assert!(internal["mobileRelayE2ee"].get("peerEndpointId").is_none());
        assert_ne!(internal["mobileRelayE2ee"]["sessionId"], session_id);
        assert_ne!(
            internal["mobileRelayE2ee"]["pairingSecretBase64url"],
            pairing_secret
        );

        set_portable_data_dir_override(previous);
    }

    #[test]
    fn mobile_relay_public_config_redacts_secret_material() {
        let dir = temp_dir("mobile-relay-redacted-config");
        let previous = set_portable_data_dir_override(Some(dir));
        let mut config = default_config();
        config["pairingId"] = json!("pair-redacted");
        config["pcToken"] = json!("pc-token-redaction-canary");
        config["mobileToken"] = json!("mobile-token-redaction-canary");
        ensure_mobile_relay_endpoint_descriptor(&mut config, "mobile").unwrap();
        config["pairedDevices"] = json!([
            {
                "id": "pc-redacted",
                "pcClientId": "pc-redacted",
                "pcClientName": "Mac",
                "pairingId": "pair-redacted",
                "mobileToken": "paired-device-token-redaction-canary",
                "gatewayUrl": "https://api.licolite.app"
            }
        ]);
        let private_key = config["mobileRelayE2ee"]["privateKeyBase64url"]
            .as_str()
            .unwrap()
            .to_string();
        let signing_key = config["mobileRelayE2ee"]["signingKeyBase64url"]
            .as_str()
            .unwrap()
            .to_string();
        let signed_prekey_private_key =
            config["mobileRelayE2ee"]["signedPrekeyPrivateKeyBase64url"]
                .as_str()
                .unwrap()
                .to_string();
        let one_time_prekey_private_key =
            config["mobileRelayE2ee"]["oneTimePrekeyPrivateKeyBase64url"]
                .as_str()
                .unwrap()
                .to_string();
        let one_time_mlkem1024_prekey_seed =
            config["mobileRelayE2ee"]["oneTimeMlKem1024PrekeySeedBase64url"]
                .as_str()
                .unwrap()
                .to_string();
        let pairing_secret = config["mobileRelayE2ee"]["pairingSecretBase64url"]
            .as_str()
            .unwrap()
            .to_string();
        save_config(&mut config).unwrap();

        let output = config_get(&json!({})).unwrap();
        let serialized = serde_json::to_string(&output).unwrap();
        for secret in [
            "pc-token-redaction-canary",
            "mobile-token-redaction-canary",
            "paired-device-token-redaction-canary",
            private_key.as_str(),
            signing_key.as_str(),
            signed_prekey_private_key.as_str(),
            one_time_prekey_private_key.as_str(),
            one_time_mlkem1024_prekey_seed.as_str(),
            pairing_secret.as_str(),
        ] {
            assert!(
                !serialized.contains(secret),
                "public mobile relay config leaked secret canary: {secret}"
            );
        }
        assert_eq!(output["config"]["pcToken"], "");
        assert_eq!(output["config"]["mobileToken"], "");
        assert_eq!(output["config"]["pcTokenPresent"], true);
        assert_eq!(output["config"]["mobileTokenPresent"], true);
        assert_eq!(
            output["config"]["mobileRelayE2ee"]["privateKeyMaterial"],
            "redacted"
        );
        assert_eq!(
            output["config"]["mobileRelayE2ee"]["signingKeyMaterial"],
            "redacted"
        );
        assert_eq!(
            output["config"]["mobileRelayE2ee"]["signedPrekeyPrivateKeyMaterial"],
            "redacted"
        );
        assert_eq!(
            output["config"]["mobileRelayE2ee"]["oneTimePrekeyPrivateKeyMaterial"],
            "redacted"
        );
        assert_eq!(
            output["config"]["mobileRelayE2ee"]["oneTimeMlKem1024PrekeySeedMaterial"],
            "redacted"
        );
        assert_eq!(
            output["config"]["mobileRelayE2ee"]["pairingSecretMaterial"],
            "redacted"
        );
        assert_eq!(output["config"]["pairedDevices"][0]["mobileToken"], "");
        assert_eq!(
            output["config"]["pairedDevices"][0]["credentialPresent"],
            true
        );

        set_portable_data_dir_override(previous);
    }

    #[test]
    fn mobile_relay_public_config_exposes_verified_trust_presentation_without_keys() {
        let dir = temp_dir("mobile-relay-public-trust-presentation");
        let previous = set_portable_data_dir_override(Some(dir));
        let mut desktop_config = default_config();
        let mut mobile_config = default_config();
        pair_mobile_relay_configs(&mut desktop_config, &mut mobile_config);

        let public = public_config(&desktop_config);
        let presentation = &public["deviceTrustPresentation"];
        assert_eq!(
            presentation["schemaVersion"],
            "licolite.secure-mesh.device-trust-presentation.v1"
        );
        assert_eq!(presentation["verified"], true);
        assert_eq!(presentation["trustState"], "verified");
        assert_eq!(
            presentation["safetyNumberGroups"].as_array().map(Vec::len),
            Some(12)
        );
        assert!(
            presentation["safetyNumberGroups"]
                .as_array()
                .unwrap()
                .iter()
                .all(|group| group.as_str().is_some_and(
                    |value| value.len() == 5 && value.bytes().all(|byte| byte.is_ascii_digit())
                ))
        );
        assert!(
            presentation["qrPayload"]
                .as_str()
                .is_some_and(|value| !value.is_empty())
        );
        let serialized = serde_json::to_string(presentation).unwrap();
        for forbidden in [
            "privateKeyBase64url",
            "signingKeyBase64url",
            "publicKeyBase64url",
            "signingPublicKeyBase64url",
        ] {
            assert!(!serialized.contains(forbidden));
        }

        set_portable_data_dir_override(previous);
    }

    #[test]
    fn mobile_relay_native_secret_store_boundary_invariant_persists_and_hydrates_redacted_config() {
        // store_secret_boundary_invariant: persisted config keeps redacted markers while E2EE
        // key material moves through SecureMeshSecretStore handles.
        let store = EphemeralSecretStore::new();
        let namespace = "native-secret-store-boundary-invariant";
        let secret_values = [
            "native-private-key-canary",
            "native-signing-key-canary",
            "native-signed-prekey-canary",
            "native-one-time-prekey-canary",
            "native-mlkem1024-prekey-seed-canary",
            "native-pairing-secret-canary",
        ];
        let mut config = json!({
            "mobileRelayE2ee": {}
        });
        for ((field, _), secret) in MOBILE_RELAY_E2EE_NATIVE_SECRET_FIELDS
            .iter()
            .copied()
            .zip(secret_values.iter().copied())
        {
            config["mobileRelayE2ee"][field] = json!(secret);
        }

        assert_eq!(store.authorization_session_count(), 0);
        persist_config_secret_material_to_secret_store(&mut config, &store, namespace).unwrap();
        assert_eq!(store.authorization_session_count(), 1);
        assert_eq!(
            store.authorization_session_reasons()[0],
            "Mobile Relay E2EE secret bundle persistence"
        );
        assert_eq!(
            store.authorization_session_operation_counts()[0],
            mobile_relay_e2ee_secret_store_authorization_batch_operation_count()
        );

        let serialized = serde_json::to_string(&config).unwrap();
        let bundle_handle = native_e2ee_secret_bundle_handle_for_namespace(namespace).unwrap();
        let bundle_raw = store
            .get_secret(&bundle_handle)
            .unwrap()
            .expect("native E2EE secret bundle should be persisted");
        let bundle = parse_native_e2ee_secret_bundle(&bundle_raw).unwrap();
        for ((field, material_field), secret) in MOBILE_RELAY_E2EE_NATIVE_SECRET_FIELDS
            .iter()
            .copied()
            .zip(secret_values.iter().copied())
        {
            assert!(config["mobileRelayE2ee"].get(field).is_none());
            assert_eq!(config["mobileRelayE2ee"][material_field], "redacted");
            assert!(!serialized.contains(field));
            assert!(!serialized.contains(secret));
            assert_eq!(
                bundle
                    .iter()
                    .find(|(bundle_field, _)| *bundle_field == field)
                    .map(|(_, bundle_secret)| bundle_secret.as_str()),
                Some(secret)
            );
            let handle = native_secret_store_handle_for_namespace(namespace, field).unwrap();
            assert!(store.get_secret(&handle).unwrap().is_none());
        }
        assert_eq!(
            config["mobileRelayE2ee"]["secretStorageStatus"],
            "memory-only-ephemeral"
        );
        assert_eq!(
            config["secretStorageStatus"]["selectedBackend"],
            "memory-only-ephemeral"
        );

        let mut overrides = RuntimeSecretOverrides::default();
        hydrate_config_secret_material_from_secret_store(
            &mut config,
            &mut overrides,
            &store,
            namespace,
        )
        .unwrap();
        assert_eq!(store.authorization_session_count(), 2);
        assert_eq!(
            store.authorization_session_reasons()[1],
            "Mobile Relay E2EE secret bundle hydration"
        );
        assert_eq!(
            store.authorization_session_operation_counts()[1],
            mobile_relay_e2ee_secret_store_authorization_batch_operation_count()
        );

        for ((field, _), secret) in MOBILE_RELAY_E2EE_NATIVE_SECRET_FIELDS
            .iter()
            .copied()
            .zip(secret_values.iter().copied())
        {
            assert_eq!(config["mobileRelayE2ee"][field], secret);
        }
        assert!(has_runtime_secret_overrides(&overrides));
        assert_eq!(
            secret_storage_backend_for_overrides(&overrides),
            "memory-only-ephemeral"
        );
    }

    #[test]
    fn mobile_ffi_dispatcher_callback_store_keeps_public_reads_no_auth_until_authorized() {
        let files_dir = temp_dir("mobile-ffi-dispatcher-secret-store");
        let portable_dir = files_dir.join("portable-data");
        let previous = set_portable_data_dir_override(Some(portable_dir));
        let store = Arc::new(EphemeralSecretStore::new());

        let mut pc_config = default_config();
        let pc_descriptor =
            ensure_mobile_relay_endpoint_descriptor(&mut pc_config, "desktop_sidecar").unwrap();
        let mut mobile_config = default_config();
        ensure_mobile_relay_endpoint_descriptor(&mut mobile_config, "mobile").unwrap();
        apply_peer_secure_mesh_descriptor(&mut mobile_config, &pc_descriptor, true).unwrap();
        let secret_values: Vec<String> = MOBILE_RELAY_E2EE_NATIVE_SECRET_FIELDS
            .iter()
            .map(|(field, _)| {
                mobile_config["mobileRelayE2ee"][*field]
                    .as_str()
                    .unwrap()
                    .to_string()
            })
            .collect();
        save_config_raw(&mut mobile_config).unwrap();
        set_portable_data_dir_override(previous);

        let store_override: Arc<dyn SecureMeshSecretStore> = store.clone();
        let public_config =
            crate::ffi::secure_mesh_mobile_ffi::dispatch_json_with_files_dir_and_pairwise_secret_store(
                &json!({
                    "action": "mobile.relay.config.get",
                    "params": {}
                })
                .to_string(),
                files_dir.to_string_lossy().as_ref(),
                "ios_secure_mesh_native_json_action_unsupported",
                store_override,
            )
            .unwrap();

        assert_eq!(public_config["ok"], true);
        assert_eq!(store.authorization_session_count(), 0);
        let public_config_text = serde_json::to_string(&public_config).unwrap();
        for secret in secret_values.iter() {
            assert!(!public_config_text.contains(secret));
        }

        let store_override: Arc<dyn SecureMeshSecretStore> = store.clone();
        let public_status =
            crate::ffi::secure_mesh_mobile_ffi::dispatch_json_with_files_dir_and_pairwise_secret_store(
                &json!({
                    "action": "mobile.relay.e2ee.status",
                    "params": {}
                })
                .to_string(),
                files_dir.to_string_lossy().as_ref(),
                "ios_secure_mesh_native_json_action_unsupported",
                store_override,
            )
            .unwrap();

        assert_eq!(public_status["ok"], true);
        assert_eq!(public_status["fullStatusAuthorized"], false);
        assert_eq!(public_status["authorizationRequiredForFullStatus"], true);
        assert!(public_status["local"].is_object());
        assert_eq!(store.authorization_session_count(), 0);
        let public_status_text = serde_json::to_string(&public_status).unwrap();
        for secret in secret_values.iter() {
            assert!(!public_status_text.contains(secret));
        }
        let bundle_handle = native_e2ee_secret_bundle_handle_for_namespace(
            MOBILE_RELAY_PLATFORM_SECRET_STORE_NAMESPACE,
        )
        .unwrap();
        assert!(store.get_secret(&bundle_handle).unwrap().is_none());

        let store_override: Arc<dyn SecureMeshSecretStore> = store.clone();
        let response =
            crate::ffi::secure_mesh_mobile_ffi::dispatch_json_with_files_dir_and_pairwise_secret_store(
                &json!({
                    "action": "mobile.relay.e2ee.status",
                    "params": {
                        "authorize": true
                    }
                })
                .to_string(),
                files_dir.to_string_lossy().as_ref(),
                "ios_secure_mesh_native_json_action_unsupported",
                store_override,
            )
            .unwrap();

        assert_eq!(response["ok"], true);
        assert_eq!(response["fullStatusAuthorized"], true);
        assert_eq!(
            response["secretStore"]["selectedBackend"],
            "memory-only-ephemeral"
        );
        assert_eq!(
            response["secretStore"]["allPrivateKeysInSelectedCustody"],
            true
        );
        assert_eq!(
            response["secretStore"]["capabilityReport"]["custody"]["strategy"],
            "memory_only_ephemeral"
        );
        assert_eq!(store.authorization_session_count(), 2);
        assert_eq!(
            store.authorization_session_reasons(),
            vec![
                "Mobile Relay E2EE secret bundle persistence".to_string(),
                "Mobile Relay E2EE status authorization batch".to_string()
            ]
        );
        assert!(store.get_secret(&bundle_handle).unwrap().is_some());

        let previous = set_portable_data_dir_override(Some(files_dir.join("portable-data")));
        let persisted =
            serde_json::from_str::<Value>(&fs::read_to_string(config_path().unwrap()).unwrap())
                .unwrap();
        let persisted_text = serde_json::to_string(&persisted).unwrap();
        for ((field, material_field), secret) in MOBILE_RELAY_E2EE_NATIVE_SECRET_FIELDS
            .iter()
            .zip(secret_values.iter())
        {
            assert!(persisted["mobileRelayE2ee"].get(*field).is_none());
            assert_eq!(persisted["mobileRelayE2ee"][*material_field], "redacted");
            assert!(!persisted_text.contains(*field));
            assert!(!persisted_text.contains(secret));
        }
        set_portable_data_dir_override(previous);
    }

    #[test]
    fn mobile_relay_user_level_config_mutation_reuses_single_secret_store_authorization_batch() {
        let dir = temp_dir("mobile-relay-user-level-secret-store-batch");
        let previous = set_portable_data_dir_override(Some(dir));
        let store = Arc::new(EphemeralSecretStore::new());
        let mut config = default_config();
        ensure_mobile_relay_endpoint_descriptor(&mut config, "mobile").unwrap();
        persist_config_secret_material_to_secret_store(
            &mut config,
            store.as_ref(),
            MOBILE_RELAY_PLATFORM_SECRET_STORE_NAMESPACE,
        )
        .unwrap();
        save_config(&mut config).unwrap();
        let baseline_session_count = store.authorization_session_count();

        let store_override: Arc<dyn SecureMeshSecretStore> = store.clone();
        let output = with_mobile_relay_secret_store_override(store_override, || {
            config_set(&json!({
                "relayEnabled": false
            }))
        })
        .unwrap();

        assert_eq!(output["ok"], true);
        assert_eq!(
            store.authorization_session_count(),
            baseline_session_count + 1
        );
        assert_eq!(
            store.authorization_session_reasons()[baseline_session_count],
            "Mobile Relay E2EE secret store authorization batch"
        );
        assert_eq!(
            store.authorization_session_operation_counts()[baseline_session_count],
            mobile_relay_e2ee_secret_store_authorization_batch_operation_count()
        );
        let persisted = fs::read_to_string(config_path().unwrap()).unwrap();
        for (field, _) in MOBILE_RELAY_E2EE_NATIVE_SECRET_FIELDS {
            assert!(!persisted.contains(field));
        }

        set_portable_data_dir_override(previous);
    }

    #[test]
    fn mobile_relay_native_secret_store_cleanup_uses_single_authorization_batch() {
        let store = EphemeralSecretStore::new();
        let namespace = "native-secret-store-cleanup-batch";
        let mut config = json!({
            "pcToken": "cleanup-pc-token-canary",
            "mobileToken": "cleanup-mobile-token-canary",
            "mobileRelayE2ee": {},
            "pairedDevices": [
                {
                    "id": "cleanup-device",
                    "pairingId": "cleanup-pairing",
                    "mobileToken": "cleanup-paired-token-canary"
                }
            ]
        });
        for ((field, _), secret) in MOBILE_RELAY_E2EE_NATIVE_SECRET_FIELDS.iter().copied().zip(
            [
                "cleanup-private-key-canary",
                "cleanup-signing-key-canary",
                "cleanup-signed-prekey-canary",
                "cleanup-one-time-prekey-canary",
                "cleanup-pairing-secret-canary",
            ]
            .into_iter(),
        ) {
            config["mobileRelayE2ee"][field] = json!(secret);
        }
        persist_config_secret_material_to_secret_store(&mut config, &store, namespace).unwrap();
        let handles = disposable_cleanup_root_secret_handles(&config, namespace).unwrap();
        assert!(!handles.is_empty());
        // Root cleanup deletes the full handle set (bundle + token + field + paired-device
        // keys). Seed any missing handles so the single-batch delete budget is observable.
        for handle in &handles {
            if store.get_secret(handle).unwrap().is_none() {
                store
                    .set_secret(handle, "cleanup-batch-seed-canary")
                    .unwrap();
            }
            assert!(store.get_secret(handle).unwrap().is_some());
        }
        let baseline_session_count = store.authorization_session_count();

        cleanup_native_secret_store_fields_for_store(&config, &store, namespace).unwrap();

        assert_eq!(
            store.authorization_session_count(),
            baseline_session_count + 1
        );
        assert_eq!(
            store.authorization_session_reasons()[baseline_session_count],
            "Mobile Relay E2EE secret store cleanup authorization batch"
        );
        assert_eq!(
            store.authorization_session_operation_counts()[baseline_session_count],
            handles.len()
        );
        assert_eq!(
            store.authorization_session_consumed_operation_counts()[baseline_session_count],
            handles.len()
        );
        for handle in &handles {
            assert!(store.get_secret(handle).unwrap().is_none());
        }
    }

    #[test]
    fn mobile_relay_disposable_secret_cleanup_is_complete_noninteractive_and_exactly_budgeted() {
        let dir = temp_dir("mobile-relay-disposable-secret-cleanup");
        let previous = set_portable_data_dir_override(Some(dir));
        let secret_store = Arc::new(EphemeralSecretStore::new());
        let mobile_store_override: Arc<dyn SecureMeshSecretStore> = secret_store.clone();
        let pairwise_store_override: Arc<dyn SecureMeshSecretStore> = secret_store.clone();

        with_mobile_relay_secret_store_override(mobile_store_override, || {
            with_pairwise_secret_store_override(pairwise_store_override, || {
                let mut pc_config = default_config();
                let mut mobile_config = default_config();
                pair_mobile_relay_configs(&mut pc_config, &mut mobile_config);

                let pairwise_path = mobile_relay_pairwise_store_path()?;
                assert!(pairwise_path.exists());
                let pairwise_handles = {
                    let store = mobile_relay_pairwise_store()?;
                    store.referenced_secret_snapshot_handles()?
                };
                assert!(!pairwise_handles.is_empty());
                for handle in &pairwise_handles {
                    assert!(secret_store.get_secret(handle)?.is_some());
                }

                let mut config = normalize_config(json!({
                    "pairedDevices": [
                        {
                            "id": "cleanup-device-a",
                            "pairingId": "cleanup-pairing-a",
                            "mobileToken": "",
                            "credentialPresent": true
                        },
                        {
                            "id": "cleanup-device-b",
                            "pairingId": "cleanup-pairing-b",
                            "mobileToken": "",
                            "credentialPresent": true
                        }
                    ]
                }));
                save_config_raw(&mut config)?;
                let root_handles = disposable_cleanup_root_secret_handles(
                    &config,
                    MOBILE_RELAY_PLATFORM_SECRET_STORE_NAMESPACE,
                )?;
                assert_eq!(
                    root_handles.len(),
                    1 + MOBILE_RELAY_NATIVE_TOKEN_SECRET_FIELDS.len()
                        + MOBILE_RELAY_E2EE_NATIVE_SECRET_FIELDS.len()
                        + 2
                );
                for handle in &root_handles {
                    secret_store.set_secret(handle, "disposable-cleanup-secret-canary")?;
                }

                let mut all_handles = root_handles.clone();
                all_handles.extend(pairwise_handles.clone());
                let baseline_session_count = secret_store.authorization_session_count();
                let output = e2ee_secret_store_cleanup(&json!({
                    "disposableProof": "true"
                }))?;

                let operation_count = all_handles.len();
                assert_eq!(output["ok"], true);
                assert_eq!(output["status"], "cleaned");
                assert_eq!(output["rootSecretHandleCount"], root_handles.len());
                assert_eq!(
                    output["pairwiseSnapshotHandleCount"],
                    pairwise_handles.len()
                );
                assert_eq!(output["deletedSecretHandleCount"], operation_count);
                assert_eq!(output["pairwiseDatabasePresentBefore"], true);
                assert_eq!(output["pairwiseDatabaseRemoved"], true);
                assert!(!pairwise_path.exists());
                assert_eq!(
                    secret_store.authorization_session_count(),
                    baseline_session_count + 1
                );
                assert_eq!(
                    secret_store.authorization_session_reasons()[baseline_session_count],
                    "Mobile Relay disposable proof secret cleanup"
                );
                assert_eq!(
                    secret_store.authorization_session_operation_counts()[baseline_session_count],
                    operation_count
                );
                assert_eq!(
                    secret_store.authorization_session_consumed_operation_counts()
                        [baseline_session_count],
                    operation_count
                );
                assert!(
                    !secret_store.authorization_session_allow_interactions()
                        [baseline_session_count]
                );
                for handle in &all_handles {
                    assert!(secret_store.get_secret(handle)?.is_none());
                }

                let second_baseline = secret_store.authorization_session_count();
                let second = e2ee_secret_store_cleanup(&json!({
                    "disposableProof": "true"
                }))?;
                assert_eq!(second["ok"], true);
                assert_eq!(second["pairwiseSnapshotHandleCount"], 0);
                assert_eq!(second["pairwiseDatabasePresentBefore"], false);
                assert_eq!(second["pairwiseDatabaseRemoved"], true);
                assert_eq!(second["deletedSecretHandleCount"], root_handles.len());
                assert_eq!(
                    secret_store.authorization_session_count(),
                    second_baseline + 1
                );
                assert_eq!(
                    secret_store.authorization_session_operation_counts()[second_baseline],
                    root_handles.len()
                );
                assert_eq!(
                    secret_store.authorization_session_consumed_operation_counts()[second_baseline],
                    root_handles.len()
                );
                assert!(!secret_store.authorization_session_allow_interactions()[second_baseline]);
                Ok(())
            })
        })
        .unwrap();

        set_portable_data_dir_override(previous);
    }

    #[test]
    fn mobile_relay_disposable_secret_cleanup_requires_exact_confirmation_and_accepts_empty_root() {
        let dir = temp_dir("mobile-relay-disposable-secret-cleanup-empty-root");
        let previous = set_portable_data_dir_override(Some(dir));
        let secret_store = Arc::new(EphemeralSecretStore::new());

        for params in [
            json!({}),
            json!({"disposableProof": false}),
            json!({"disposableProof": true}),
            json!({"disposableProof": "false"}),
        ] {
            let error = e2ee_secret_store_cleanup(&params).unwrap_err().to_string();
            assert!(error.contains("--disposable-proof true"));
        }
        assert_eq!(secret_store.authorization_session_count(), 0);

        let store_override: Arc<dyn SecureMeshSecretStore> = secret_store.clone();
        let output = with_mobile_relay_secret_store_override(store_override, || {
            e2ee_secret_store_cleanup(&json!({
                "disposableProof": "true"
            }))
        })
        .unwrap();
        assert_eq!(output["ok"], true);
        assert_eq!(output["pairwiseSnapshotHandleCount"], 0);
        assert_eq!(output["pairwiseDatabasePresentBefore"], false);
        assert_eq!(output["pairwiseDatabaseRemoved"], true);
        assert_eq!(secret_store.authorization_session_count(), 1);
        assert_eq!(
            secret_store.authorization_session_operation_counts()[0],
            1 + MOBILE_RELAY_NATIVE_TOKEN_SECRET_FIELDS.len()
                + MOBILE_RELAY_E2EE_NATIVE_SECRET_FIELDS.len()
        );
        assert_eq!(
            secret_store.authorization_session_operation_counts(),
            secret_store.authorization_session_consumed_operation_counts()
        );
        assert_eq!(
            secret_store.authorization_session_allow_interactions(),
            vec![false]
        );

        set_portable_data_dir_override(previous);
    }

    #[test]
    fn mobile_relay_disposable_secret_cleanup_propagates_delete_failures() {
        struct DeleteFailingSecretStore {
            inner: EphemeralSecretStore,
            rejected_key: &'static str,
        }

        impl SecureMeshSecretStore for DeleteFailingSecretStore {
            fn backend(&self) -> &'static str {
                self.inner.backend()
            }

            fn supported(&self) -> bool {
                self.inner.supported()
            }

            fn begin_authorized_session(
                &self,
                request: &SecretStoreAuthorizationRequest,
            ) -> Result<SecretStoreAuthorizationSession> {
                self.inner.begin_authorized_session(request)
            }

            fn set_secret(&self, handle: &SecretStoreHandle, secret: &str) -> Result<()> {
                self.inner.set_secret(handle, secret)
            }

            fn get_secret(&self, handle: &SecretStoreHandle) -> Result<Option<String>> {
                self.inner.get_secret(handle)
            }

            fn delete_secret(&self, handle: &SecretStoreHandle) -> Result<()> {
                if handle.key() == self.rejected_key {
                    return Err(anyhow!("injected disposable cleanup delete failure"));
                }
                self.inner.delete_secret(handle)
            }
        }

        let dir = temp_dir("mobile-relay-disposable-secret-cleanup-delete-failure");
        let previous = set_portable_data_dir_override(Some(dir));
        let store = Arc::new(DeleteFailingSecretStore {
            inner: EphemeralSecretStore::new(),
            rejected_key: "mobileToken",
        });
        let rejected_handle = native_secret_store_handle_for_namespace(
            MOBILE_RELAY_PLATFORM_SECRET_STORE_NAMESPACE,
            "mobileToken",
        )
        .unwrap();
        store
            .set_secret(&rejected_handle, "delete-failure-secret-canary")
            .unwrap();
        let store_override: Arc<dyn SecureMeshSecretStore> = store.clone();

        let error = with_mobile_relay_secret_store_override(store_override, || {
            e2ee_secret_store_cleanup(&json!({
                "disposableProof": "true"
            }))
        })
        .unwrap_err()
        .to_string();

        assert!(error.contains("disposable secret cleanup failed"));
        assert!(store.get_secret(&rejected_handle).unwrap().is_some());
        assert_eq!(store.inner.authorization_session_count(), 1);
        assert_eq!(
            store.inner.authorization_session_allow_interactions(),
            vec![false]
        );

        set_portable_data_dir_override(previous);
    }

    #[test]
    fn public_config_save_preserves_internal_mobile_token() {
        let dir = temp_dir("mobile-relay-preserve-token");
        let previous = set_portable_data_dir_override(Some(dir));
        let mut config = default_config();
        config["pairingId"] = json!("pair-preserve");
        config["mobileToken"] = json!("mobile-token-preserve-canary");
        save_config(&mut config).unwrap();

        let saved = config_set(&json!({
            "pairingId": "pair-preserve",
            "mobileToken": "",
            "paired": true
        }))
        .unwrap();
        assert_eq!(saved["config"]["mobileToken"], "");
        assert_eq!(saved["config"]["mobileTokenPresent"], true);

        let (internal, _) = load_config_with_runtime_secret_overrides(&json!({})).unwrap();
        assert_eq!(internal["mobileToken"], "mobile-token-preserve-canary");
        set_portable_data_dir_override(previous);
    }

    #[test]
    fn selected_public_paired_device_restores_internal_token_without_exposure() {
        let dir = temp_dir("mobile-relay-select-redacted-device");
        let previous = set_portable_data_dir_override(Some(dir));
        let mut config = default_config();
        config["pairingId"] = json!("pair-active");
        config["mobileToken"] = json!("mobile-token-active-canary");
        config["pairedDevices"] = json!([
            {
                "id": "pc-active",
                "pcClientId": "pc-active",
                "pcClientName": "Active Mac",
                "pairingId": "pair-active",
                "mobileToken": "mobile-token-active-canary",
                "gatewayUrl": "https://api.licolite.app"
            },
            {
                "id": "pc-selected",
                "pcClientId": "pc-selected",
                "pcClientName": "Selected Mac",
                "pairingId": "pair-selected",
                "mobileToken": "mobile-token-selected-canary",
                "gatewayUrl": "https://api.licolite.app"
            }
        ]);
        save_config(&mut config).unwrap();

        let saved = config_set(&json!({
            "pairingId": "pair-selected",
            "mobileToken": "",
            "paired": true
        }))
        .unwrap();
        let (internal, _) = load_config_with_runtime_secret_overrides(&json!({})).unwrap();
        assert_eq!(internal["pairingId"], "pair-selected");
        assert_eq!(internal["mobileToken"], "mobile-token-selected-canary");
        assert_eq!(internal["pcClientId"], "pc-selected");
        assert_eq!(internal["pcClientName"], "Selected Mac");
        let serialized = serde_json::to_string(&saved).unwrap();
        assert!(!serialized.contains("mobile-token-selected-canary"));
        assert_eq!(saved["config"]["mobileTokenPresent"], true);

        set_portable_data_dir_override(previous);
    }

    #[test]
    fn native_secret_store_restores_selected_device_without_raw_json_overrides() {
        let dir = temp_dir("mobile-relay-native-secret-store-selected-device");
        let previous = set_portable_data_dir_override(Some(dir));
        let store = Arc::new(EphemeralSecretStore::new());
        let mut config = default_config();
        config["pairingId"] = json!("pair-active");
        config["mobileToken"] = json!("");
        config["pairedDevices"] = json!([
            {
                "id": "pc-selected",
                "pcClientId": "pc-selected",
                "pcClientName": "Selected Mac",
                "pairingId": "pair-selected",
                "mobileToken": "paired-device-secret-store-canary",
                "credentialPresent": true,
                "gatewayUrl": "https://api.licolite.app"
            }
        ]);
        persist_config_secret_material_to_secret_store(
            &mut config,
            store.as_ref(),
            MOBILE_RELAY_PLATFORM_SECRET_STORE_NAMESPACE,
        )
        .unwrap();
        save_config(&mut config).unwrap();
        let baseline_session_count = store.authorization_session_count();

        let store_override: Arc<dyn SecureMeshSecretStore> = store.clone();
        let saved = with_mobile_relay_secret_store_override(store_override, || {
            config_set(&json!({
                "pairingId": "pair-selected",
                "mobileToken": "",
                "paired": true,
                "secretOverrideTransport": RUNTIME_SECRET_OVERRIDE_TRANSPORT,
                "secretOverrides": {
                    "mobileRelayE2eeSecretStore": {
                        "contract": "rust_secure_mesh_secret_store_handle_v1",
                        "namespace": MOBILE_RELAY_PLATFORM_SECRET_STORE_NAMESPACE,
                        "rawJsonSecretOverridesUsed": false
                    }
                }
            }))
        })
        .unwrap();

        assert_eq!(saved["config"]["mobileTokenPresent"], true);
        assert_eq!(
            saved["config"]["pairedDevices"][0]["credentialPresent"],
            true
        );
        assert_eq!(
            store.authorization_session_count(),
            baseline_session_count + 1
        );
        let persisted = load_config().unwrap();
        let serialized = serde_json::to_string(&persisted).unwrap();
        assert_eq!(persisted["mobileToken"], "");
        assert_eq!(persisted["pairedDevices"][0]["mobileToken"], "");
        assert!(!serialized.contains("paired-device-secret-store-canary"));
        assert_eq!(
            persisted["secretStorageStatus"]["selectedBackend"],
            "memory-only-ephemeral"
        );

        set_portable_data_dir_override(previous);
    }

    #[test]
    fn runtime_secret_overrides_require_platform_transport_marker() {
        let dir = temp_dir("mobile-relay-runtime-secret-overrides-marker");
        let previous = set_portable_data_dir_override(Some(dir));
        let mut config = default_config();
        config["pairingId"] = json!("pair-active");
        config["mobileToken"] = json!("");
        config["pairedDevices"] = json!([
            {
                "id": "pc-selected",
                "pcClientId": "pc-selected",
                "pcClientName": "Selected Mac",
                "pairingId": "pair-selected",
                "mobileToken": "",
                "credentialPresent": true,
                "gatewayUrl": "https://api.licolite.app"
            }
        ]);
        save_config(&mut config).unwrap();

        let saved = config_set(&json!({
            "pairingId": "pair-selected",
            "mobileToken": "",
            "paired": true,
            "secretOverrides": {
                "pairedDevices": [
                    {
                        "id": "pc-selected",
                        "pairingId": "pair-selected",
                        "mobileToken": "untrusted-runtime-override-canary"
                    }
                ]
            }
        }))
        .unwrap();

        assert_eq!(saved["config"]["mobileTokenPresent"], false);
        assert_eq!(
            saved["config"]["pairedDevices"][0]["credentialPresent"],
            true
        );
        let persisted = load_config().unwrap();
        let serialized = serde_json::to_string(&persisted).unwrap();
        assert_eq!(persisted["mobileToken"], "");
        assert_eq!(persisted["pairedDevices"][0]["mobileToken"], "");
        assert!(!serialized.contains("untrusted-runtime-override-canary"));
        assert!(persisted.get("secretStorageStatus").is_none());

        set_portable_data_dir_override(previous);
    }

    #[test]
    fn runtime_secret_overrides_reject_raw_token_fields() {
        let mut config = default_config();
        let token_error = match apply_runtime_secret_overrides(
            &mut config,
            &json!({
                "secretOverrideTransport": RUNTIME_SECRET_OVERRIDE_TRANSPORT,
                "secretOverrides": {
                    "mobileToken": "mobile-token-raw-override-canary"
                }
            }),
        ) {
            Ok(_) => panic!("raw token secretOverrides must be rejected"),
            Err(error) => format!("{error}"),
        };
        assert!(token_error.contains("raw token secretOverrides are disabled"));

        let paired_error = match apply_runtime_secret_overrides(
            &mut config,
            &json!({
                "secretOverrideTransport": RUNTIME_SECRET_OVERRIDE_TRANSPORT,
                "secretOverrides": {
                    "pairedDevices": [
                        {
                            "id": "pc-selected",
                            "pairingId": "pair-selected",
                            "mobileToken": "paired-token-raw-override-canary"
                        }
                    ]
                }
            }),
        ) {
            Ok(_) => panic!("raw paired-device token secretOverrides must be rejected"),
            Err(error) => format!("{error}"),
        };
        assert!(paired_error.contains("raw token secretOverrides are disabled"));
    }

    #[test]
    fn e2ee_status_rejects_private_key_material_in_portable_config() {
        let dir = temp_dir("mobile-relay-e2ee-status-portable-secret-store");
        let previous = set_portable_data_dir_override(Some(dir));
        let mut pc_config = default_config();
        let pc_descriptor =
            ensure_mobile_relay_endpoint_descriptor(&mut pc_config, "desktop_sidecar").unwrap();
        let mut mobile_config = default_config();
        ensure_mobile_relay_endpoint_descriptor(&mut mobile_config, "mobile").unwrap();
        apply_peer_secure_mesh_descriptor(&mut mobile_config, &pc_descriptor, true).unwrap();
        let private_key = mobile_config["mobileRelayE2ee"]["privateKeyBase64url"]
            .as_str()
            .unwrap()
            .to_string();
        save_config_raw(&mut mobile_config).unwrap();

        let status = e2ee_status(&json!({})).unwrap();

        assert_eq!(status["secureSessionEstablished"], false);
        assert_eq!(
            status["secretStore"]["selectedBackend"],
            "unsafe_portable_config"
        );
        assert_eq!(status["secretStore"]["privateKeyInSelectedCustody"], false);
        assert_eq!(
            status["secretStore"]["portableConfigPrivateKeyPresent"],
            true
        );
        assert_eq!(status["secretStore"]["unsafePersistenceDetected"], true);
        assert_eq!(
            status["secretStore"]["authorization"]["appPasswordPromptUsed"],
            false
        );
        assert_eq!(
            status["secretStore"]["custodyReason"],
            "secret_material_in_portable_config"
        );
        let serialized = serde_json::to_string(&status).unwrap();
        assert!(!serialized.contains(&private_key));

        set_portable_data_dir_override(previous);
    }

    #[test]
    fn e2ee_status_accepts_memory_only_custody_but_does_not_overclaim_missing_session() {
        let dir = temp_dir("mobile-relay-e2ee-status-platform-secret-store");
        let previous = set_portable_data_dir_override(Some(dir));
        let store = Arc::new(EphemeralSecretStore::new());
        let mut pc_config = default_config();
        let pc_descriptor =
            ensure_mobile_relay_endpoint_descriptor(&mut pc_config, "desktop_sidecar").unwrap();
        let mut mobile_config = default_config();
        ensure_mobile_relay_endpoint_descriptor(&mut mobile_config, "mobile").unwrap();
        apply_peer_secure_mesh_descriptor(&mut mobile_config, &pc_descriptor, true).unwrap();
        let private_key = mobile_config["mobileRelayE2ee"]["privateKeyBase64url"]
            .as_str()
            .unwrap()
            .to_string();
        let signing_key = mobile_config["mobileRelayE2ee"]["signingKeyBase64url"]
            .as_str()
            .unwrap()
            .to_string();
        let signed_prekey_private_key =
            mobile_config["mobileRelayE2ee"]["signedPrekeyPrivateKeyBase64url"]
                .as_str()
                .unwrap()
                .to_string();
        let one_time_prekey_private_key =
            mobile_config["mobileRelayE2ee"]["oneTimePrekeyPrivateKeyBase64url"]
                .as_str()
                .unwrap()
                .to_string();
        let one_time_mlkem1024_prekey_seed =
            mobile_config["mobileRelayE2ee"]["oneTimeMlKem1024PrekeySeedBase64url"]
                .as_str()
                .unwrap()
                .to_string();
        let pairing_secret = mobile_config["mobileRelayE2ee"]["pairingSecretBase64url"]
            .as_str()
            .unwrap()
            .to_string();
        persist_config_secret_material_to_secret_store(
            &mut mobile_config,
            store.as_ref(),
            MOBILE_RELAY_PLATFORM_SECRET_STORE_NAMESPACE,
        )
        .unwrap();
        save_config(&mut mobile_config).unwrap();
        assert_eq!(store.authorization_session_count(), 1);
        assert_eq!(
            store.authorization_session_operation_counts()[0],
            mobile_relay_e2ee_secret_store_authorization_batch_operation_count()
        );

        let store_override: Arc<dyn SecureMeshSecretStore> = store.clone();
        let status = with_mobile_relay_secret_store_override(store_override, || {
            e2ee_status(&json!({
                "authorize": true
            }))
        })
        .unwrap();

        assert_eq!(status["peerVerified"], true);
        assert_eq!(status["secureSessionEstablished"], false);
        assert_eq!(status["capabilityProjection"], Value::Null);
        assert!(
            status["blockers"]
                .as_array()
                .unwrap()
                .iter()
                .any(|blocker| blocker == "pairwise_session_missing")
        );
        assert_eq!(
            status["secretStore"]["selectedBackend"],
            "memory-only-ephemeral"
        );
        assert_eq!(
            status["secretStore"]["capabilityReport"]["custody"]["strategy"],
            "memory_only_ephemeral"
        );
        assert_eq!(
            status["secretStore"]["capabilityReport"]["custody"]["restartSemantics"],
            "re_pair_rekey_after_restart"
        );
        assert_eq!(status["secretStore"]["privateKeyInSelectedCustody"], true);
        assert_eq!(
            status["secretStore"]["oneTimeMlKem1024PrekeySeedInSelectedCustody"],
            true
        );
        assert_eq!(
            status["secretStore"]["allPrivateKeysInSelectedCustody"],
            true
        );
        assert_eq!(
            status["secretStore"]["pairingSecretInSelectedCustody"],
            true
        );
        assert_eq!(
            status["secretStore"]["portableConfigPrivateKeyPresent"],
            false
        );
        assert_eq!(status["secretStore"]["unsafePersistenceDetected"], false);
        assert_eq!(
            status["secretStore"]["authorization"]["appPasswordPromptUsed"],
            false
        );
        assert_eq!(
            status["secretStore"]["custodyReason"],
            "custody_operational"
        );
        assert_eq!(store.authorization_session_count(), 2);
        assert_eq!(
            store.authorization_session_operation_counts()[1],
            mobile_relay_e2ee_secret_store_authorization_batch_operation_count().saturating_add(2)
        );
        let serialized = serde_json::to_string(&status).unwrap();
        assert!(!serialized.contains(&private_key));
        assert!(!serialized.contains(&signing_key));
        assert!(!serialized.contains(&signed_prekey_private_key));
        assert!(!serialized.contains(&one_time_prekey_private_key));
        assert!(!serialized.contains(&one_time_mlkem1024_prekey_seed));
        assert!(!serialized.contains(&pairing_secret));

        set_portable_data_dir_override(previous);
    }

    #[test]
    fn e2ee_status_reports_only_confirmed_negotiated_durable_session() {
        let dir = temp_dir("mobile-relay-e2ee-status-confirmed-session");
        let previous = set_portable_data_dir_override(Some(dir));
        let store = Arc::new(EphemeralSecretStore::new());
        let store_override: Arc<dyn SecureMeshSecretStore> = store.clone();
        with_mobile_relay_secret_store_override(store_override, || {
            let mut pc_config = default_config();
            let mut mobile_config = default_config();
            pair_mobile_relay_configs(&mut pc_config, &mut mobile_config);
            persist_config_secret_material_to_secret_store(
                &mut mobile_config,
                store.as_ref(),
                MOBILE_RELAY_PLATFORM_SECRET_STORE_NAMESPACE,
            )?;
            save_config(&mut mobile_config)?;

            let status = e2ee_status(&json!({"authorize": true}))?;
            assert_eq!(status["secureSessionEstablished"], true);
            assert!(status["capabilityProjection"].is_object());
            assert!(status["capabilityProjection"]["local"].is_object());
            assert!(status["capabilityProjection"]["peer"].is_object());
            assert!(
                status["capabilityProjection"]["negotiatedProtocolCapabilities"]
                    .as_array()
                    .is_some_and(|values| !values.is_empty())
            );
            assert!(
                !status["blockers"]
                    .as_array()
                    .unwrap()
                    .iter()
                    .any(|blocker| blocker
                        .as_str()
                        .unwrap_or_default()
                        .starts_with("pairwise_"))
            );
            Ok(())
        })
        .unwrap();
        set_portable_data_dir_override(previous);
    }

    #[test]
    fn production_pairwise_store_reuses_selected_memory_custody_and_purges_after_restart() {
        let dir = temp_dir("mobile-relay-pairwise-selected-memory-restart");
        let previous = set_portable_data_dir_override(Some(dir));
        let first_store = Arc::new(EphemeralSecretStore::new());
        let first_override: Arc<dyn SecureMeshSecretStore> = first_store.clone();
        let (session_id, local_endpoint_id) =
            with_mobile_relay_secret_store_override(first_override, || {
                let mut pc_config = default_config();
                let mut mobile_config = default_config();
                pair_mobile_relay_configs(&mut pc_config, &mut mobile_config);
                let endpoint = local_endpoint_state(&mobile_config)?;
                let pairwise_store = mobile_relay_pairwise_store()?;
                assert_eq!(pairwise_store.secret_store_backend(), first_store.backend());
                let handles = pairwise_store.referenced_secret_snapshot_handles()?;
                assert!(!handles.is_empty());
                assert!(
                    handles
                        .iter()
                        .all(|handle| first_store.get_secret(handle).unwrap().is_some())
                );
                Ok((endpoint.session_id, endpoint.endpoint_id))
            })
            .unwrap();
        drop(first_store);

        let restarted_store: Arc<dyn SecureMeshSecretStore> = Arc::new(EphemeralSecretStore::new());
        with_mobile_relay_secret_store_override(restarted_store, || {
            let pairwise_store = mobile_relay_pairwise_store()?;
            assert!(
                pairwise_store
                    .read_record(&session_id, &local_endpoint_id)?
                    .is_none()
            );
            assert!(
                pairwise_store
                    .referenced_secret_snapshot_handles()?
                    .is_empty()
            );
            Ok(())
        })
        .unwrap();
        set_portable_data_dir_override(previous);
    }

    #[test]
    fn public_config_get_does_not_begin_secret_store_authorization_session() {
        let dir = temp_dir("mobile-relay-public-config-no-authorization");
        let previous = set_portable_data_dir_override(Some(dir));
        let store = Arc::new(EphemeralSecretStore::new());
        let mut config = default_config();
        config["pairingId"] = json!("pair-public-no-auth");
        config["pcToken"] = json!("pc-token-public-no-auth-canary");
        config["mobileToken"] = json!("mobile-token-public-no-auth-canary");
        ensure_mobile_relay_endpoint_descriptor(&mut config, "mobile").unwrap();
        persist_config_secret_material_to_secret_store(
            &mut config,
            store.as_ref(),
            MOBILE_RELAY_PLATFORM_SECRET_STORE_NAMESPACE,
        )
        .unwrap();
        config["lastPairingCode"] = json!("NOAUTH-CODE");
        save_config_raw(&mut config).unwrap();
        let before_read = fs::read_to_string(config_path().unwrap()).unwrap();
        let baseline_session_count = store.authorization_session_count();

        let store_override: Arc<dyn SecureMeshSecretStore> = store.clone();
        let output = with_mobile_relay_secret_store_override(store_override, || {
            config_get(&json!({
                "authorize": false,
                "hydrateSecrets": false
            }))
        })
        .unwrap();

        assert_eq!(store.authorization_session_count(), baseline_session_count);
        assert_eq!(output["config"]["pcTokenPresent"], true);
        assert_eq!(output["config"]["mobileTokenPresent"], true);
        assert_eq!(output["config"]["lastPairingCode"], "");
        let after_read = fs::read_to_string(config_path().unwrap()).unwrap();
        assert_eq!(after_read, before_read);
        let serialized = serde_json::to_string(&output).unwrap();
        assert!(!serialized.contains("pc-token-public-no-auth-canary"));
        assert!(!serialized.contains("mobile-token-public-no-auth-canary"));

        set_portable_data_dir_override(previous);
    }

    #[test]
    fn e2ee_status_without_authorization_does_not_begin_secret_store_session() {
        let dir = temp_dir("mobile-relay-e2ee-status-no-authorization");
        let previous = set_portable_data_dir_override(Some(dir));
        let store = Arc::new(EphemeralSecretStore::new());
        let mut pc_config = default_config();
        let pc_descriptor =
            ensure_mobile_relay_endpoint_descriptor(&mut pc_config, "desktop_sidecar").unwrap();
        let mut mobile_config = default_config();
        ensure_mobile_relay_endpoint_descriptor(&mut mobile_config, "mobile").unwrap();
        apply_peer_secure_mesh_descriptor(&mut mobile_config, &pc_descriptor, true).unwrap();
        let private_key = mobile_config["mobileRelayE2ee"]["privateKeyBase64url"]
            .as_str()
            .unwrap()
            .to_string();
        persist_config_secret_material_to_secret_store(
            &mut mobile_config,
            store.as_ref(),
            MOBILE_RELAY_PLATFORM_SECRET_STORE_NAMESPACE,
        )
        .unwrap();
        save_config_raw(&mut mobile_config).unwrap();
        let baseline_session_count = store.authorization_session_count();

        let store_override: Arc<dyn SecureMeshSecretStore> = store.clone();
        let status = with_mobile_relay_secret_store_override(store_override, || {
            e2ee_status(&json!({
                "authorize": false,
                "hydrateSecrets": false
            }))
        })
        .unwrap();

        assert_eq!(store.authorization_session_count(), baseline_session_count);
        assert_eq!(status["fullStatusAuthorized"], false);
        assert_eq!(status["authorizationRequiredForFullStatus"], true);
        assert_eq!(status["secureSessionEstablished"], false);
        assert!(
            status["blockers"]
                .as_array()
                .unwrap()
                .iter()
                .any(|blocker| {
                    blocker == "pairwise_session_verification_requires_authorization"
                })
        );
        assert_eq!(
            status["secretStore"]["authorizationRequiredForFullStatus"],
            true
        );
        assert_eq!(
            status["secretStore"]["authorization"]["systemAuthorizationAttemptCount"],
            0
        );
        assert_eq!(
            status["secretStore"]["capabilityReport"]["custody"]["strategy"],
            "memory_only_ephemeral"
        );
        assert!(
            !status["secretStore"]["capabilityReport"]["enabled"]
                .as_array()
                .unwrap()
                .iter()
                .any(|capability| capability == "custody.os_secure_store")
        );
        let serialized = serde_json::to_string(&status).unwrap();
        assert!(!serialized.contains(&private_key));

        set_portable_data_dir_override(previous);
    }

    #[test]
    fn e2ee_status_requires_single_system_authorization_prompt_budget() {
        let config = json!({});
        let mut capability_facts =
            mandatory_protocol_facts(CapabilityEvidenceKind::TestFixture).unwrap();
        capability_facts.extend([
            CapabilityFact::supported(
                SecurityCapability::OsSecureStore,
                CapabilityEvidenceKind::TestFixture,
            ),
            CapabilityFact::supported(
                SecurityCapability::UnlockedDeviceRequired,
                CapabilityEvidenceKind::TestFixture,
            ),
            CapabilityFact::supported(
                SecurityCapability::OsUserPresence,
                CapabilityEvidenceKind::TestFixture,
            ),
        ]);
        let user_presence_report = capability_catalog()
            .unwrap()
            .evaluate(&capability_facts)
            .unwrap()
            .report();
        let mut overrides = RuntimeSecretOverrides {
            pc_token: false,
            mobile_token: false,
            e2ee_private_key: true,
            e2ee_pairing_secret: true,
            e2ee_signing_key: true,
            e2ee_signed_prekey_private_key: true,
            e2ee_one_time_prekey_private_key: true,
            e2ee_one_time_mlkem1024_prekey_seed: true,
            secret_storage_backend: Some("macos-keychain"),
            secret_store_authorization: Some(RuntimeSecretStoreAuthorizationProof {
                backend: "macos-keychain",
                operation_count: 7,
                consumed_operation_count: 5,
                remaining_operation_count: 2,
                authorization_batch_within_budget: true,
                allow_interaction: true,
                shared_system_context_required: true,
                shared_system_context_available: true,
                system_authorization_attempt_count: 1,
                system_authorization_completed: true,
                single_system_authorization_context_verified: true,
                app_password_prompt_used: false,
                app_credential_prompt_used: false,
                capability_report: Some(user_presence_report),
            }),
            paired_device_tokens: Vec::new(),
        };

        let ready = mobile_relay_e2ee_secret_store_status(&config, &overrides);
        assert_eq!(
            ready["authorization"]["singleSystemAuthorizationContextVerified"],
            true
        );
        assert_eq!(ready["authorization"]["withinPromptBudget"], true);
        assert_eq!(ready["authorization"]["consumedOperationCount"], 5);
        assert_eq!(ready["authorization"]["remainingOperationCount"], 2);
        assert_eq!(ready["authorization"]["withinOperationBudget"], true);
        assert_eq!(ready["authorization"]["claimConsistent"], true);
        assert_eq!(ready["authorization"]["appPasswordPromptUsed"], false);
        assert_eq!(ready["authorization"]["appCredentialPromptUsed"], false);

        let authorization = overrides.secret_store_authorization.as_mut().unwrap();
        authorization.system_authorization_attempt_count = 2;
        authorization.single_system_authorization_context_verified = false;
        let repeated = mobile_relay_e2ee_secret_store_status(&config, &overrides);
        assert_eq!(
            repeated["authorization"]["singleSystemAuthorizationContextVerified"],
            false
        );
        assert_eq!(repeated["authorization"]["withinPromptBudget"], false);
        assert_eq!(repeated["authorization"]["claimConsistent"], false);

        let authorization = overrides.secret_store_authorization.as_mut().unwrap();
        authorization.system_authorization_attempt_count = 1;
        authorization.single_system_authorization_context_verified = false;
        authorization.app_password_prompt_used = true;
        let app_prompt = mobile_relay_e2ee_secret_store_status(&config, &overrides);
        assert_eq!(app_prompt["authorization"]["withinPromptBudget"], false);
        assert_eq!(app_prompt["authorization"]["claimConsistent"], false);
        assert_eq!(app_prompt["authorization"]["appPasswordPromptUsed"], true);

        let authorization = overrides.secret_store_authorization.as_mut().unwrap();
        authorization.app_password_prompt_used = false;
        authorization.single_system_authorization_context_verified = true;
        authorization.consumed_operation_count = 8;
        authorization.remaining_operation_count = 0;
        authorization.authorization_batch_within_budget = false;
        let over_budget = mobile_relay_e2ee_secret_store_status(&config, &overrides);
        assert_eq!(over_budget["authorization"]["withinOperationBudget"], false);
        assert_eq!(over_budget["authorization"]["claimConsistent"], false);
    }

    #[test]
    fn adaptive_secret_store_self_test_accepts_memory_only_without_persistence() {
        let report = e2ee_secret_store_self_test(&json!({})).unwrap();
        assert_eq!(report["ok"], true);
        assert_eq!(report["selfTestPassed"], true);
        assert_eq!(report["selectedBackend"], "memory-only-ephemeral");
        assert_eq!(
            report["capabilityReport"]["custody"]["strategy"],
            "memory_only_ephemeral"
        );
        assert_eq!(
            report["capabilityReport"]["custody"]["restartSemantics"],
            "re_pair_rekey_after_restart"
        );
        assert_eq!(report["ordinaryFileSecretArtifactCount"], 0);
        assert_eq!(
            report["restartProof"]["staleSessionRestorationRejected"],
            true
        );
        assert_eq!(report["restartProof"]["rePairRekeyRequired"], true);
        assert_eq!(report["sharedSecretClassRoundTripPassed"], true);
        assert_eq!(report["sharedSecretClassPersistenceReady"], false);
    }

    #[test]
    fn e2ee_status_redacts_pairing_invite_secret() {
        let dir = temp_dir("mobile-relay-e2ee-status-redacts-pairing-invite");
        let previous = set_portable_data_dir_override(Some(dir));
        let mut config = default_config();
        let endpoint =
            ensure_mobile_relay_endpoint_descriptor(&mut config, "desktop_sidecar").unwrap();
        config["mobileRelayPairingInvite"] = json!({
            "protocolVersion": MOBILE_RELAY_E2EE_PROTOCOL_VERSION,
            "oneTime": true,
            "createdAt": "2026-07-04T00:00:00Z",
            "gatewayUrl": "https://api.licolite.app",
            "pcClientId": "pc-redacted-invite",
            "pcClientName": "Lico Arc",
            "pairingId": "pair-redacted-invite",
            "pairingCode": "ABCDE-FGHIJ-KLMNO-PQRST",
            "pairingCodeHash": sha256_hex("ABCDE-FGHIJ-KLMNO-PQRST".as_bytes()),
            "pcSecureMesh": endpoint,
            "e2eePairingSecret": "pairing-invite-e2ee-secret-redaction-canary"
        });

        let pairing_invite = redacted_pairing_invite(config.get("mobileRelayPairingInvite"));
        assert_eq!(pairing_invite["e2eePairingSecretMaterial"], "redacted");
        assert!(pairing_invite.get("e2eePairingSecret").is_none());

        save_config(&mut config).unwrap();

        let status = e2ee_status(&json!({})).unwrap();

        let serialized = serde_json::to_string(&status).unwrap();
        assert!(!serialized.contains("pairing-invite-e2ee-secret-redaction-canary"));

        set_portable_data_dir_override(previous);
    }

    #[test]
    fn config_load_clears_persisted_pairing_invite_and_code() {
        let dir = temp_dir("mobile-relay-clears-persisted-invite");
        let previous = set_portable_data_dir_override(Some(dir));
        let mut config = default_config();
        ensure_mobile_relay_endpoint_descriptor(&mut config, "desktop_sidecar").unwrap();
        config["lastPairingCode"] = json!("ABCDE-FGHIJ-KLMNO-PQRST");
        config["lastPairingExpiresAt"] = json!("2099-01-01T00:00:00Z");
        config["mobileRelayPairingInvite"] = json!({
            "protocolVersion": MOBILE_RELAY_E2EE_PROTOCOL_VERSION,
            "pairingId": "pair-redacted-invite",
            "pairingCode": "ABCDE-FGHIJ-KLMNO-PQRST",
            "e2eePairingSecret": "pairing-invite-secret-status-canary"
        });
        save_config(&mut config).unwrap();

        let loaded = config_get(&json!({
            "authorize": true
        }))
        .unwrap();

        assert_eq!(loaded["config"]["lastPairingCode"], "");
        assert_eq!(loaded["config"]["lastPairingExpiresAt"], "");
        assert!(loaded["config"].get("mobileRelayPairingInvite").is_none());
        let persisted =
            serde_json::from_str::<Value>(&fs::read_to_string(config_path().unwrap()).unwrap())
                .unwrap();
        assert_eq!(persisted["lastPairingCode"], "");
        assert_eq!(persisted["lastPairingExpiresAt"], "");
        assert!(persisted.get("mobileRelayPairingInvite").is_none());
        let serialized = serde_json::to_string(&loaded).unwrap();
        assert!(!serialized.contains("pairing-invite-secret-status-canary"));

        set_portable_data_dir_override(previous);
    }

    #[test]
    fn desktop_public_config_does_not_probe_model_profiles_for_authorized_providers() {
        let dir = temp_dir("mobile-relay-public-model-providers");
        let previous = set_portable_data_dir_override(Some(dir));
        let mut config = default_config();
        config["pairingId"] = json!("pair-public-model-providers");
        config["pcToken"] = json!("pc-token-public-model-providers");
        config["paired"] = json!(true);
        save_config(&mut config).unwrap();
        crate::domain::forwarding::save_model_profile(&json!({
            "profile": "deepseek",
            "provider": "deepseek",
            "apiKey": concat!("desktop-deepseek-profile", "-secret"),
            "model": "deepseek-v4-flash"
        }))
        .unwrap();
        crate::domain::forwarding::save_model_profile(&json!({
            "profile": "gemini",
            "provider": "gemini",
            "apiKey": concat!("desktop-gemini-profile", "-secret"),
            "model": "gemini-3.5-flash"
        }))
        .unwrap();

        let loaded = config_get(&json!({})).unwrap();

        assert!(loaded["config"].get("authorizedProviders").is_none());
        assert!(
            !loaded
                .to_string()
                .contains("desktop-deepseek-profile-secret")
        );
        assert!(!loaded.to_string().contains("desktop-gemini-profile-secret"));

        set_portable_data_dir_override(previous);
    }

    #[test]
    fn mobile_public_config_does_not_advertise_local_profiles_as_desktop_providers() {
        let dir = temp_dir("mobile-relay-public-mobile-profile-isolation");
        let previous = set_portable_data_dir_override(Some(dir));
        let mut config = default_config();
        config["pairingId"] = json!("pair-mobile-profile-isolation");
        config["mobileToken"] = json!("mobile-token-profile-isolation");
        config["paired"] = json!(true);
        save_config(&mut config).unwrap();
        crate::domain::forwarding::save_model_profile(&json!({
            "profile": "deepseek",
            "provider": "deepseek",
            "apiKey": concat!("phone-local-deepseek-profile", "-secret"),
            "model": "deepseek-v4-flash"
        }))
        .unwrap();

        let loaded = config_get(&json!({})).unwrap();

        assert!(loaded["config"].get("authorizedProviders").is_none());
        assert!(
            !loaded
                .to_string()
                .contains("phone-local-deepseek-profile-secret")
        );

        set_portable_data_dir_override(previous);
    }

    #[test]
    fn invalid_gateway_is_rejected_before_config_persistence() {
        let dir = temp_dir("mobile-relay-invalid");
        let previous = set_portable_data_dir_override(Some(dir));
        for denied in [
            "https://",
            "https://?gateway=relay.example.test",
            "https://user@relay.example.test",
            "https://relay.example.test#fragment",
            "https://relay.example.test:invalid",
            "https://relay.example.test/api",
            "https://relay.example.test?tenant=one",
            "https://relay.example.test\\@evil.test",
            "http://example.test",
            "http://localhost.evil.test",
            "http://127.0.0.1@evil.test",
            "http://127.1",
        ] {
            let result = config_set(&json!({
                "useCustomGateway": true,
                "customGatewayUrl": denied
            }));
            assert!(result.is_err(), "accepted disallowed gateway");
            assert!(!config_path().unwrap().exists());
        }
        set_portable_data_dir_override(previous);
    }

    #[test]
    fn gateway_origins_are_canonicalized_and_exact_loopback_http_is_allowed() {
        for (input, expected) in [
            (
                "HTTPS://Relay.Example.Test:443/",
                "https://relay.example.test",
            ),
            ("http://127.0.0.1:7228/", "http://127.0.0.1:7228"),
            ("http://localhost:7228", "http://localhost:7228"),
            ("http://[::1]:7228/", "http://[::1]:7228"),
        ] {
            assert_eq!(validated_gateway(input).unwrap(), expected);
        }
    }

    #[test]
    fn invalid_pairing_invite_gateway_cannot_mutate_existing_pairing_state() {
        let mut config = default_config();
        config["pairingId"] = json!("existing-pairing");
        config["paired"] = json!(true);
        let before = config.clone();

        let result = apply_pairing_invite_params(
            &mut config,
            &json!({
                "invite": {
                    "pairingId": "replacement-pairing",
                    "gatewayUrl": "https://trusted.example@evil.test#fragment"
                }
            }),
        );

        assert!(result.is_err());
        assert_eq!(config, before);
    }

    #[test]
    fn pairing_create_returns_one_time_invite_without_persisting_code() {
        let gateway = CanonicalRelayGateway::start(2, Vec::new());
        let dir = temp_dir("mobile-relay-one-time-create");
        let previous = set_portable_data_dir_override(Some(dir));

        config_set(&json!({
            "useCustomGateway": true,
            "customGatewayUrl": gateway.url(),
            "pcClientId": "pc-one-time",
            "pcClientName": "Lico Arc",
            "authorizedProviders": [
                {
                    "accountId": "desktop-local-account-identifier",
                    "providerId": "gemini",
                    "profileId": "gemini",
                    "label": "Gemini",
                    "credentialPresent": true,
                    "credentialKind": "api-key",
                    "source": "desktop-config"
                }
            ]
        }))
        .unwrap();
        crate::domain::forwarding::save_model_profile(&json!({
            "profile": "gemini",
            "provider": "gemini",
            "apiKey": concat!("desktop-gemini-invite", "-secret"),
            "model": "gemini-3.5-flash"
        }))
        .unwrap();

        let output = pairing_create(&with_canonical_relay_params(json!({"targets": []}))).unwrap();

        assert_eq!(
            output["mobileRelayPairingInvite"]["pairingCode"],
            output["pairingCode"]
        );
        assert!(
            output["pairingCode"]
                .as_str()
                .is_some_and(|value| value.len() == 16)
        );
        assert_eq!(output["mobileRelayPairingInvite"]["oneTime"], true);
        assert_eq!(
            output["mobileRelayPairingInvite"]["authorizedProviders"][0]["providerId"],
            "gemini"
        );
        assert!(
            output["mobileRelayPairingInvite"]["authorizedProviders"][0]
                .get("accountId")
                .is_none()
        );
        assert!(!output.to_string().contains("desktop-gemini-invite-secret"));
        assert_eq!(output["config"]["lastPairingCode"], "");
        assert_eq!(output["config"]["lastPairingExpiresAt"], "");
        assert!(output["config"].get("mobileRelayPairingInvite").is_none());

        let persisted =
            serde_json::from_str::<Value>(&fs::read_to_string(config_path().unwrap()).unwrap())
                .unwrap();
        assert_eq!(persisted["lastPairingCode"], "");
        assert_eq!(persisted["lastPairingExpiresAt"], "");
        assert!(persisted.get("mobileRelayPairingInvite").is_none());

        let invite = &output["mobileRelayPairingInvite"];
        assert!(invite["createdAt"].as_str().unwrap().contains('T'));
        assert!(invite["pairingCodeHash"].as_str().unwrap().len() >= 64);
        assert!(invite["pcSecureMesh"].is_object());
        assert!(
            invite["e2eePairingSecret"]
                .as_str()
                .is_some_and(|value| !value.is_empty())
        );
        for index in 0..2 {
            let body = gateway.request_body(index);
            for forbidden in [
                "pairingId",
                "pairingCode",
                "pairingContext",
                "authorizedProviders",
                "desktop-local-account-identifier",
            ] {
                assert!(!body.contains(forbidden));
            }
        }
        gateway.assert_operations(&[
            SecureClientRelayOperation::EndpointChallenge,
            SecureClientRelayOperation::EndpointRegister,
        ]);

        gateway.join();
        set_portable_data_dir_override(previous);
    }

    #[test]
    fn pc_check_in_echoes_public_authorized_provider_summaries_without_account_ids() {
        let gateway = CanonicalRelayGateway::start(2, Vec::new());
        let dir = temp_dir("mobile-relay-check-in-public-providers");
        let previous = set_portable_data_dir_override(Some(dir));
        let mut config = default_config();
        config["useCustomGateway"] = json!(true);
        config["customGatewayUrl"] = json!(gateway.url());
        config["pairingId"] = json!("pair-check-in-public-providers");
        config["pcToken"] = json!("pc-token-check-in-public-providers");
        config["pcClientId"] = json!("pc-check-in-public-providers");
        config["pcClientName"] = json!("Lico Arc");
        config["paired"] = json!(true);
        save_config(&mut config).unwrap();

        let output = pc_check_in(&with_canonical_relay_params(json!({
            "targets": [],
            "authorizedProviders": [
                {
                    "accountId": "desktop-local-account-identifier",
                    "providerId": "gemini",
                    "profileId": "gemini-work",
                    "label": "Gemini",
                    "credentialPresent": true,
                    "credentialKind": "api-key",
                    "source": "desktop-config"
                }
            ]
        })))
        .unwrap();

        assert_eq!(output["ok"], true);
        assert_eq!(output["authorizedProviders"][0]["providerId"], "gemini");
        assert_eq!(output["authorizedProviders"][0]["profileId"], "gemini-work");
        assert!(output["authorizedProviders"][0].get("accountId").is_none());
        assert!(
            !output
                .to_string()
                .contains("desktop-local-account-identifier")
        );

        for index in 0..2 {
            let body = gateway.request_body(index);
            assert!(!body.contains("authorizedProviders"));
            assert!(!body.contains("desktop-local-account-identifier"));
            assert!(!body.contains("providerId"));
            assert!(!body.contains("pairingId"));
        }
        gateway.assert_operations(&[
            SecureClientRelayOperation::EndpointChallenge,
            SecureClientRelayOperation::EndpointRegister,
        ]);

        gateway.join();
        set_portable_data_dir_override(previous);
    }

    #[test]
    fn pairing_claim_sends_one_time_context_and_clears_code() {
        let gateway = CanonicalRelayGateway::start(2, Vec::new());
        let dir = temp_dir("mobile-relay-one-time-claim");
        let previous = set_portable_data_dir_override(Some(dir));

        let mut pc_config = default_config();
        let pc_descriptor =
            ensure_mobile_relay_endpoint_descriptor(&mut pc_config, "desktop_sidecar").unwrap();
        let pairing_secret = random_base64url(MOBILE_RELAY_KEY_BYTES);

        config_set(&json!({
            "useCustomGateway": true,
            "customGatewayUrl": gateway.url(),
            "pcClientName": "Lico Arc"
        }))
        .unwrap();

        let output = pairing_claim(&with_canonical_relay_params(json!({
            "invite": {
                "protocolVersion": MOBILE_RELAY_E2EE_PROTOCOL_VERSION,
                "oneTime": true,
                "gatewayUrl": gateway.url(),
                "pcClientId": "pc-one-time",
                "pcClientName": "Lico Arc",
                "pairingId": "pair-one-time",
                "pairingCode": "ABCDE-FGHIJ-KLMNO-PQRST",
                "authorizedProviders": [
                    {
                        "providerId": "gemini",
                        "label": "Gemini",
                        "profileId": "gemini",
                        "credentialPresent": true,
                        "source": "desktop-model-profile"
                    }
                ],
                "pcSecureMesh": pc_descriptor,
                "e2eePairingSecret": pairing_secret
            },
            "mobileDeviceName": "Lico Arc Mobile",
            "mobileDeviceId": "mobile-one-time",
            "platform": "ios"
        })))
        .unwrap();

        assert_eq!(output["ok"], true);
        assert_eq!(output["config"]["lastPairingCode"], "");
        assert_eq!(output["config"]["lastPairingExpiresAt"], "");
        assert!(output["config"].get("mobileRelayPairingInvite").is_none());
        let persisted =
            serde_json::from_str::<Value>(&fs::read_to_string(config_path().unwrap()).unwrap())
                .unwrap();
        assert_eq!(persisted["lastPairingCode"], "");
        assert_eq!(persisted["lastPairingExpiresAt"], "");
        assert!(persisted.get("mobileRelayPairingInvite").is_none());

        for index in 0..2 {
            let body = gateway.request_body(index);
            for forbidden in [
                "oneTimePairing",
                "pairingId",
                "pairingCode",
                "claimContext",
                "secureMeshClaimProof",
            ] {
                assert!(!body.contains(forbidden));
            }
        }
        gateway.assert_operations(&[
            SecureClientRelayOperation::EndpointChallenge,
            SecureClientRelayOperation::EndpointRegister,
        ]);

        gateway.join();
        set_portable_data_dir_override(previous);
    }

    #[test]
    fn pairing_claim_invite_e2ee_secret_completes_mobile_endpoint_descriptor() {
        let gateway = CanonicalRelayGateway::start(2, Vec::new());
        let dir = temp_dir("mobile-relay-one-time-claim-invite-e2ee-secret");
        let previous = set_portable_data_dir_override(Some(dir));

        let mut pc_config = default_config();
        let pc_descriptor =
            ensure_mobile_relay_endpoint_descriptor(&mut pc_config, "desktop_sidecar").unwrap();
        let pairing_secret = random_base64url(MOBILE_RELAY_KEY_BYTES);

        config_set(&json!({
            "useCustomGateway": true,
            "customGatewayUrl": gateway.url(),
            "pcClientName": "Lico Arc"
        }))
        .unwrap();

        let output = pairing_claim(&with_canonical_relay_params(json!({
            "invite": {
                "protocolVersion": MOBILE_RELAY_E2EE_PROTOCOL_VERSION,
                "oneTime": true,
                "gatewayUrl": gateway.url(),
                "pcClientId": "pc-runtime-override",
                "pcClientName": "Lico Arc",
                "pairingId": "pair-one-time",
                "pairingCode": "ABCDE-FGHIJ-KLMNO-PQRST",
                "pcSecureMesh": pc_descriptor,
                "e2eePairingSecret": pairing_secret
            },
            "mobileDeviceName": "Lico Arc Android",
            "mobileDeviceId": "mobile-invite-e2ee-secret",
            "platform": "android"
        })))
        .unwrap();

        assert_eq!(output["ok"], true);
        assert_eq!(
            output["config"]["mobileRelayE2ee"]["endpointKind"],
            "mobile"
        );
        assert!(
            output["config"]["mobileRelayE2ee"]["endpointId"]
                .as_str()
                .unwrap()
                .starts_with("mobile_")
        );
        assert_eq!(
            output["config"]["mobileRelayE2ee"]["peerEndpointId"],
            pc_descriptor["endpointId"]
        );
        assert_eq!(
            output["config"]["mobileRelayE2ee"]["pairingSecretMaterial"],
            "redacted"
        );
        assert!(
            output["config"]["mobileRelayE2ee"]
                .get("pairingSecretBase64url")
                .is_none()
        );

        let registration = serde_json::from_str::<Value>(&gateway.request_body(1)).unwrap();
        assert_eq!(registration["endpointKind"], "mobile");
        assert!(
            registration["endpointId"]
                .as_str()
                .unwrap()
                .starts_with("mobile_")
        );
        assert_eq!(
            output["outOfBandPairingResponse"]["mobileSecureMesh"]["endpointId"],
            registration["endpointId"]
        );
        let serialized_output = serde_json::to_string(&output).unwrap();
        let serialized_request = gateway.request_body(0) + &gateway.request_body(1);
        assert!(!serialized_output.contains(&pairing_secret));
        assert!(!serialized_request.contains(&pairing_secret));
        for forbidden in ["pairingId", "pairingCode", "claimContext", "secureMesh"] {
            assert!(!serialized_request.contains(forbidden));
        }
        gateway.assert_operations(&[
            SecureClientRelayOperation::EndpointChallenge,
            SecureClientRelayOperation::EndpointRegister,
        ]);

        gateway.join();
        set_portable_data_dir_override(previous);
    }

    #[test]
    fn new_pairing_invite_resets_stale_mobile_pairwise_state() {
        let dir = temp_dir("mobile-relay-new-invite-resets-pairwise-state");
        let previous = set_portable_data_dir_override(Some(dir));

        let mut pc_config = default_config();
        let mut mobile_config = default_config();
        pair_mobile_relay_configs(&mut pc_config, &mut mobile_config);
        pc_config["pairingId"] = json!("pair-old");
        mobile_config["pairingId"] = json!("pair-old");
        let stale_session_id = mobile_config["mobileRelayE2ee"]["sessionId"]
            .as_str()
            .unwrap()
            .to_string();
        assert!(
            mobile_config["mobileRelayE2ee"]
                .get("pendingPairwiseIntro")
                .is_none()
        );

        let pc_descriptor =
            ensure_mobile_relay_endpoint_descriptor(&mut pc_config, "desktop_sidecar").unwrap();
        let pairing_secret = random_base64url(MOBILE_RELAY_KEY_BYTES);
        let invite_params = json!({
            "invite": {
                "protocolVersion": MOBILE_RELAY_E2EE_PROTOCOL_VERSION,
                "oneTime": true,
                "gatewayUrl": "https://api.licolite.app",
                "pcClientId": "pc-repairing",
                "pcClientName": "Lico Arc",
                "pairingId": "pair-new",
                "pairingCode": "ABCDE-FGHIJ-KLMNO-PQRST",
                "pcSecureMesh": pc_descriptor.clone(),
                "e2eePairingSecret": pairing_secret
            }
        });
        apply_pairing_invite_params(&mut mobile_config, &invite_params).unwrap();

        assert_eq!(mobile_config["pairingId"], "pair-new");
        assert_eq!(
            mobile_config["mobileRelayE2ee"]["pairingSecretBase64url"],
            pairing_secret
        );
        assert_eq!(mobile_config["mobileRelayE2ee"]["peerVerified"], true);
        assert_ne!(
            mobile_config["mobileRelayE2ee"]["sessionId"],
            stale_session_id
        );
        assert!(
            mobile_config["mobileRelayE2ee"]["pendingPairwiseIntro"].is_object(),
            "new mobile pairing must advertise a fresh pairwise intro"
        );
        assert!(
            mobile_config["mobileRelayE2ee"]
                .get("pairwiseAccepted")
                .is_none()
        );

        pc_config["pairingId"] = json!("pair-new");
        pc_config["mobileRelayE2ee"]["pairingSecretBase64url"] = json!(pairing_secret);
        let mobile_descriptor =
            ensure_mobile_relay_endpoint_descriptor(&mut mobile_config, "mobile").unwrap();
        assert!(mobile_descriptor["pairwiseIntro"].is_object());
        let proof = mobile_relay_claim_proof_for_pair(
            &pc_config,
            "pair-new",
            &mobile_descriptor,
            &pc_descriptor,
        )
        .unwrap();
        apply_out_of_band_pairing_response(
            &mut pc_config,
            &json!({
                "mobileSecureMesh": mobile_descriptor,
                "secureMeshClaimProof": proof
            }),
        )
        .unwrap();

        assert_eq!(pc_config["mobileRelayE2ee"]["peerVerified"], true);
        assert!(pc_config["mobileRelayE2ee"]["pairwiseAccepted"].is_object());

        set_portable_data_dir_override(previous);
    }

    #[test]
    fn new_pairing_invite_resets_blank_pairing_id_with_stale_peer_state() {
        let dir = temp_dir("mobile-relay-new-invite-resets-blank-pairing-stale-peer");
        let previous = set_portable_data_dir_override(Some(dir));

        let mut pc_config = default_config();
        let mut mobile_config = default_config();
        pair_mobile_relay_configs(&mut pc_config, &mut mobile_config);
        mobile_config["pairingId"] = json!("");
        let stale_session_id = mobile_config["mobileRelayE2ee"]["sessionId"]
            .as_str()
            .unwrap()
            .to_string();
        assert!(
            mobile_config["mobileRelayE2ee"]["peerEndpointId"]
                .as_str()
                .unwrap()
                .starts_with("pc_")
        );

        let pc_descriptor =
            ensure_mobile_relay_endpoint_descriptor(&mut pc_config, "desktop_sidecar").unwrap();
        let pairing_secret = random_base64url(MOBILE_RELAY_KEY_BYTES);
        let invite_params = json!({
            "invite": {
                "protocolVersion": MOBILE_RELAY_E2EE_PROTOCOL_VERSION,
                "oneTime": true,
                "gatewayUrl": "https://api.licolite.app",
                "pcClientId": "pc-repairing-blank",
                "pcClientName": "Lico Arc",
                "pairingId": "pair-new-blank",
                "pairingCode": "ABCDE-FGHIJ-KLMNO-PQRST",
                "pcSecureMesh": pc_descriptor,
                "e2eePairingSecret": pairing_secret
            }
        });
        apply_pairing_invite_params(&mut mobile_config, &invite_params).unwrap();

        assert_eq!(mobile_config["pairingId"], "pair-new-blank");
        assert_eq!(
            mobile_config["mobileRelayE2ee"]["pairingSecretBase64url"],
            pairing_secret
        );
        assert_ne!(
            mobile_config["mobileRelayE2ee"]["sessionId"],
            stale_session_id
        );
        assert!(mobile_config["mobileRelayE2ee"]["pendingPairwiseIntro"].is_object());
        assert!(
            mobile_config["mobileRelayE2ee"]
                .get("pairwiseAccepted")
                .is_none()
        );

        set_portable_data_dir_override(previous);
    }

    #[test]
    fn pairing_claim_ignores_ephemeral_invite_gateway() {
        let gateway = CanonicalRelayGateway::start(2, Vec::new());
        let dir = temp_dir("mobile-relay-ephemeral-invite-claim");
        let previous = set_portable_data_dir_override(Some(dir));

        let mut pc_config = default_config();
        let pc_descriptor =
            ensure_mobile_relay_endpoint_descriptor(&mut pc_config, "desktop_sidecar").unwrap();
        let pairing_secret = random_base64url(MOBILE_RELAY_KEY_BYTES);

        config_set(&json!({
            "defaultGatewayUrl": gateway.url(),
            "useCustomGateway": false,
            "pcClientName": "Lico Arc"
        }))
        .unwrap();

        let output = pairing_claim(&with_canonical_relay_params(json!({
            "invite": {
                "protocolVersion": MOBILE_RELAY_E2EE_PROTOCOL_VERSION,
                "oneTime": true,
                "gatewayUrl": "https://old-relay.trycloudflare.com/",
                "pcClientId": "pc-one-time",
                "pcClientName": "Lico Arc",
                "pairingId": "pair-one-time",
                "pairingCode": "ABCDE-FGHIJ-KLMNO-PQRST",
                "pcSecureMesh": pc_descriptor,
                "e2eePairingSecret": pairing_secret
            },
            "mobileDeviceName": "Lico Arc Mobile",
            "mobileDeviceId": "mobile-one-time",
            "platform": "android"
        })))
        .unwrap();

        assert_eq!(output["ok"], true);
        assert_eq!(output["config"]["useCustomGateway"], false);
        assert_eq!(output["config"]["customGatewayUrl"], "");

        for index in 0..2 {
            let body = gateway.request_body(index);
            assert!(!body.contains("pairingId"));
            assert!(!body.contains("pairingCode"));
        }

        let persisted =
            serde_json::from_str::<Value>(&fs::read_to_string(config_path().unwrap()).unwrap())
                .unwrap();
        assert_eq!(persisted["useCustomGateway"], false);
        assert_eq!(persisted["customGatewayUrl"], "");

        gateway.assert_operations(&[
            SecureClientRelayOperation::EndpointChallenge,
            SecureClientRelayOperation::EndpointRegister,
        ]);
        gateway.join();
        set_portable_data_dir_override(previous);
    }

    #[test]
    fn secure_mesh_envelope_command_is_transport_only() {
        let dir = temp_dir("mobile-relay-unverified-secure-command");
        let previous = set_portable_data_dir_override(Some(dir));
        let command = json!({
            "type": SECURE_MESH_ENVELOPE_COMMAND,
            "payload": {
                "envelope": secure_envelope_fixture()
            }
        });
        let visible_command = redacted_relay_command(&command);
        assert_eq!(visible_command["secureEnvelopePresent"], true);
        let error = execute_secure_envelope_command(&command, &json!({}))
            .unwrap_err()
            .to_string();
        assert!(
            error.contains("mobile relay E2EE endpoint state is missing"),
            "unexpected redacted secure command rejection: {error}"
        );
        assert!(
            secure_envelope_param(&json!({
                "envelope": secure_envelope_fixture()
            }))
            .is_some()
        );
        set_portable_data_dir_override(previous);
    }

    #[test]
    fn secure_envelope_validation_rejects_malicious_relay_shapes_before_decrypt() {
        // v2 envelope rejects extra fields via deny_unknown_fields.
        let mut oversized = secure_envelope_fixture();
        oversized["unknownField"] = json!("should be rejected");
        assert!(
            validate_secure_envelope(&oversized)
                .unwrap_err()
                .to_string()
                .contains("JSON is invalid")
        );

        let mut invalid_base64 = secure_envelope_fixture();
        invalid_base64["ciphertext"] = json!("not base64!");
        assert!(
            validate_secure_envelope(&invalid_base64)
                .unwrap_err()
                .to_string()
                .contains("base64")
        );

        let mut mismatched_size = secure_envelope_fixture();
        mismatched_size["ciphertextBucket"] = json!(65536u64);
        assert!(
            validate_secure_envelope(&mismatched_size)
                .unwrap_err()
                .to_string()
                .contains("ciphertext")
        );

        let mut bad_schema = secure_envelope_fixture();
        bad_schema["schema"] = json!("unsupported.v1");
        assert!(
            validate_secure_envelope(&bad_schema)
                .unwrap_err()
                .to_string()
                .contains("schema")
        );

        // v2 rejects the retired metadata-rich (10-field) shape.
        let retired = json!({
            "protocolVersion": "1.0",
            "envelopeId": "env_test",
            "opaqueMailboxId": "mailbox_test",
            "messageId": "msg_test",
            "cipherSuite": "AES-256-GCM",
            "createdAt": "2026-01-01T00:00:00Z",
            "expiresAt": "2026-01-01T00:10:00Z",
            "ciphertextSize": 32,
            "encryptedHeader": "AAAA",
            "ciphertext": "AAAA"
        });
        assert!(validate_secure_envelope(&retired).is_err());
    }

    #[test]
    fn mobile_relay_e2ee_round_trips_command_and_result_without_plaintext() {
        let dir = temp_dir("mobile-relay-e2ee-roundtrip");
        let previous = set_portable_data_dir_override(Some(dir));
        let mut pc_config = default_config();
        let mut mobile_config = default_config();
        pair_mobile_relay_configs(&mut pc_config, &mut mobile_config);

        assert_eq!(
            session_id(&pc_config).unwrap(),
            session_id(&mobile_config).unwrap()
        );

        let command_body = json!({
            "schema": crate::core::secure_mesh::SECURE_MESH_COMMAND_PROTOCOL_VERSION,
            "commandId": "cmd_mobile_test",
            "commandKind": "agent.message.send",
            "senderIdentity": {
                "endpointId": local_endpoint_state(&mobile_config).unwrap().endpoint_id,
                "identityFingerprint": local_endpoint_state(&mobile_config).unwrap().fingerprint,
                "trustState": "verified",
                "endpointKind": "mobile"
            },
            "targetBinding": {
                "targetEndpointId": local_endpoint_state(&pc_config).unwrap().endpoint_id,
                "targetAgentId": "codex",
                "workspaceId": "default"
            },
            "riskClass": "safe_write",
            "requiresUserConfirmation": false,
            "idempotencyKey": "idem_mobile_test",
            "createdAt": "2026-01-01T00:00:00Z",
            "expiresAt": "2099-01-01T00:00:00Z",
            "body": {
                "agentId": "codex",
                "text": "plaintext-canary-mobile-relay"
            }
        });
        let command_envelope = seal_mobile_relay_payload(
            &mobile_config,
            crate::core::secure_mesh_crypto::SecureMeshPayloadKind::Command,
            &command_body,
        )
        .unwrap();
        assert_eq!(
            command_envelope["schema"],
            crate::core::secure_mesh_relay_envelope::SECURE_MESH_RELAY_ENVELOPE_SCHEMA
        );
        let command_wire = serde_json::to_string(&command_envelope).unwrap();
        assert!(!command_wire.contains("plaintext-canary-mobile-relay"));
        assert!(!command_wire.contains("agent.message.send"));

        let opened_command = open_mobile_relay_payload(
            &pc_config,
            &command_envelope,
            crate::core::secure_mesh_crypto::SecureMeshPayloadKind::Command,
        )
        .unwrap();
        let opened_command_json: Value = serde_json::from_slice(&opened_command).unwrap();
        assert_eq!(
            opened_command_json["body"]["text"],
            "plaintext-canary-mobile-relay"
        );

        let result_body = json!({
            "ok": true,
            "result": "plaintext-result-canary"
        });
        let result_envelope = seal_mobile_relay_payload(
            &pc_config,
            crate::core::secure_mesh_crypto::SecureMeshPayloadKind::ResultPayload,
            &result_body,
        )
        .unwrap();
        assert_eq!(
            result_envelope["schema"],
            crate::core::secure_mesh_relay_envelope::SECURE_MESH_RELAY_ENVELOPE_SCHEMA
        );
        let result_wire = serde_json::to_string(&result_envelope).unwrap();
        assert!(!result_wire.contains("plaintext-result-canary"));

        let opened_result = open_mobile_relay_payload(
            &mobile_config,
            &result_envelope,
            crate::core::secure_mesh_crypto::SecureMeshPayloadKind::ResultPayload,
        )
        .unwrap();
        let opened_result_json: Value = serde_json::from_slice(&opened_result).unwrap();
        assert_eq!(opened_result_json["result"], "plaintext-result-canary");

        set_portable_data_dir_override(previous);
    }

    #[test]
    fn mobile_relay_file_key_envelope_hides_attachment_key_and_opens_file_after_decrypt() {
        let dir = temp_dir("mobile-relay-file-key-envelope");
        let previous = set_portable_data_dir_override(Some(dir));
        let mut pc_config = default_config();
        let mut mobile_config = default_config();
        pair_mobile_relay_configs(&mut pc_config, &mut mobile_config);

        let file_key_bytes = [93u8; 32];
        let file_key = crate::core::secure_mesh_file::FileRootKey::from_bytes(file_key_bytes);
        let file_key_base64url = general_purpose::URL_SAFE_NO_PAD.encode(file_key_bytes);
        let manifest = crate::core::secure_mesh_file::SecureMeshFileManifest {
            file_id: "relay-file-key-canary-id".to_string(),
            file_name: "relay-private-file-key-canary.txt".to_string(),
            mime_type: "text/plain".to_string(),
            relative_path: "relay/private-file-key-canary".to_string(),
            total_size: 33,
            chunk_size: 33,
            chunk_count: 1,
        };
        let source_endpoint = local_endpoint_state(&mobile_config).unwrap();
        let target_endpoint = local_endpoint_state(&pc_config).unwrap();
        let file_hash = format!(
            "sha256:{}",
            general_purpose::URL_SAFE_NO_PAD
                .encode(Sha256::digest(b"relay file body plaintext canary"))
        );
        let manifest_context =
            crate::core::secure_mesh_file::SecureMeshFileProtectionContext::for_pairwise_device(
                crate::core::secure_mesh_crypto::SecureMeshContentContext::new(
                    "env_relay_file_manifest_key_wrap",
                    "msg_relay_file_manifest_key_wrap",
                    "mailbox_relay_file_key_wrap",
                    &source_endpoint.endpoint_id,
                    &target_endpoint.endpoint_id,
                    session_id(&mobile_config).unwrap(),
                    "2026-01-01T00:00:00.000Z",
                    "2026-01-01T00:10:00.000Z",
                ),
                manifest.file_id.clone(),
                manifest.chunk_count,
                file_hash.clone(),
                1_800_000_000,
            )
            .unwrap();
        let encrypted_manifest = crate::core::secure_mesh_file::seal_file_manifest(
            &file_key,
            &manifest_context,
            &manifest,
        )
        .unwrap();
        let chunk = crate::core::secure_mesh_file::SecureMeshFileChunk {
            file_id: manifest.file_id.clone(),
            chunk_index: 0,
            bytes: b"relay file body plaintext canary".to_vec(),
        };
        let chunk_context =
            crate::core::secure_mesh_file::SecureMeshFileProtectionContext::for_pairwise_device(
                crate::core::secure_mesh_crypto::SecureMeshContentContext::new(
                    "env_relay_file_chunk_key_wrap",
                    "msg_relay_file_chunk_key_wrap",
                    "mailbox_relay_file_key_wrap",
                    &source_endpoint.endpoint_id,
                    &target_endpoint.endpoint_id,
                    session_id(&mobile_config).unwrap(),
                    "2026-01-01T00:00:00.000Z",
                    "2026-01-01T00:10:00.000Z",
                ),
                manifest.file_id.clone(),
                manifest.chunk_count,
                file_hash,
                1_800_000_000,
            )
            .unwrap();
        let encrypted_chunk =
            crate::core::secure_mesh_file::seal_file_chunk(&file_key, &chunk_context, &chunk)
                .unwrap();

        let file_key_payload = json!({
            "kind": "secure_mesh.file_key",
            "fileKeyBase64url": file_key_base64url,
            "fileId": manifest.file_id,
            "fileKeyCanary": "relay-file-key-secret-canary",
            "manifestCiphertextHash": encrypted_manifest.ciphertext_hash,
            "chunkCiphertextHash": encrypted_chunk.ciphertext_hash
        });
        let file_key_envelope = seal_mobile_relay_payload(
            &mobile_config,
            crate::core::secure_mesh_crypto::SecureMeshPayloadKind::Command,
            &file_key_payload,
        )
        .unwrap();
        let server_wire = serde_json::to_string(&file_key_envelope).unwrap();
        for forbidden in [
            "relay-file-key-canary-id",
            "relay-private-file-key-canary.txt",
            "relay/private-file-key-canary",
            "relay-file-key-secret-canary",
            "relay file body plaintext canary",
            file_key_base64url.as_str(),
        ] {
            assert!(
                !server_wire.contains(forbidden),
                "mobile relay file-key envelope leaked {forbidden}"
            );
        }

        let wrong_kind_error = open_mobile_relay_payload(
            &pc_config,
            &file_key_envelope,
            crate::core::secure_mesh_crypto::SecureMeshPayloadKind::ResultPayload,
        )
        .unwrap_err()
        .to_string();
        assert!(wrong_kind_error.contains("AAD hash mismatch"));

        let opened = open_mobile_relay_payload(
            &pc_config,
            &file_key_envelope,
            crate::core::secure_mesh_crypto::SecureMeshPayloadKind::Command,
        )
        .unwrap();
        let opened_json: Value = serde_json::from_slice(&opened).unwrap();
        assert_eq!(opened_json["fileKeyCanary"], "relay-file-key-secret-canary");
        let recovered_key = crate::core::secure_mesh_file::FileRootKey::from_bytes(
            general_purpose::URL_SAFE_NO_PAD
                .decode(opened_json["fileKeyBase64url"].as_str().unwrap())
                .unwrap()
                .try_into()
                .unwrap(),
        );
        let opened_manifest = crate::core::secure_mesh_file::open_file_manifest(
            &recovered_key,
            &manifest_context,
            &encrypted_manifest,
        )
        .unwrap();
        assert_eq!(opened_manifest.file_id, "relay-file-key-canary-id");
        let opened_chunk = crate::core::secure_mesh_file::open_file_chunk(
            &recovered_key,
            &chunk_context,
            &encrypted_chunk,
        )
        .unwrap();
        assert_eq!(opened_chunk.bytes, b"relay file body plaintext canary");

        let replay_error = open_mobile_relay_payload(
            &pc_config,
            &file_key_envelope,
            crate::core::secure_mesh_crypto::SecureMeshPayloadKind::Command,
        )
        .unwrap_err()
        .to_string();
        assert!(replay_error.contains("replay detected"));

        set_portable_data_dir_override(previous);
    }

    #[test]
    fn mobile_relay_file_key_envelope_metadata_boundary_is_exhaustive() {
        let dir = temp_dir("mobile-relay-file-key-envelope-boundary");
        let previous = set_portable_data_dir_override(Some(dir));
        let mut pc_config = default_config();
        let mut mobile_config = default_config();
        pair_mobile_relay_configs(&mut pc_config, &mut mobile_config);

        let file_key_base64url = general_purpose::URL_SAFE_NO_PAD.encode([77u8; 32]);
        let envelope = seal_mobile_relay_payload(
            &mobile_config,
            crate::core::secure_mesh_crypto::SecureMeshPayloadKind::Command,
            &json!({
                "kind": "secure_mesh.file_key",
                "fileKeyBase64url": file_key_base64url,
                "fileId": "relay-file-boundary-private-id",
                "fileName": "relay-file-boundary-private-name.txt",
                "fileKeyCanary": "relay-file-boundary-private-key-canary"
            }),
        )
        .unwrap();
        let object = envelope.as_object().unwrap();
        let mut visible_keys = object.keys().map(String::as_str).collect::<Vec<_>>();
        visible_keys.sort_unstable();
        let mut expected_keys = vec![
            "ciphertext",
            "ciphertextBucket",
            "deliveryId",
            "encryptedHeader",
            "mailboxToken",
            "schema",
        ];
        expected_keys.sort_unstable();
        assert_eq!(visible_keys, expected_keys);
        let server_wire = serde_json::to_string(&envelope).unwrap();
        for forbidden in [
            "\"kind\"",
            "\"fileKeyBase64url\"",
            "\"fileId\"",
            "\"fileName\"",
            "\"fileKeyCanary\"",
            "secure_mesh.file_key",
            "relay-file-boundary-private-id",
            "relay-file-boundary-private-name.txt",
            "relay-file-boundary-private-key-canary",
            file_key_base64url.as_str(),
        ] {
            assert!(
                !server_wire.contains(forbidden),
                "mobile relay file-key metadata boundary leaked {forbidden}"
            );
        }

        set_portable_data_dir_override(previous);
    }

    #[test]
    fn mobile_relay_pairwise_initialization_requires_pqxdh_prekey_bundle() {
        let dir = temp_dir("mobile-relay-pqxdh-prekey-required");
        let previous = set_portable_data_dir_override(Some(dir));
        let mut pc_config = default_config();
        let mut pc_descriptor =
            ensure_mobile_relay_endpoint_descriptor(&mut pc_config, "desktop_sidecar").unwrap();
        pc_descriptor
            .as_object_mut()
            .unwrap()
            .remove("preKeyBundle");

        let mut mobile_config = default_config();
        ensure_mobile_relay_endpoint_descriptor(&mut mobile_config, "mobile").unwrap();
        let error = apply_peer_secure_mesh_descriptor(&mut mobile_config, &pc_descriptor, true)
            .unwrap_err()
            .to_string();
        assert!(error.contains("missing preKeyBundle"));
        assert!(peer_secure_mesh_descriptor(&mobile_config).is_none());

        set_portable_data_dir_override(previous);
    }

    #[test]
    fn mobile_relay_pqxdh_descriptor_publishes_signed_mlkem_prekey_without_seed() {
        let dir = temp_dir("mobile-relay-pqxdh-mlkem-prekey-material");
        let previous = set_portable_data_dir_override(Some(dir));
        let mut config = default_config();
        let descriptor =
            ensure_mobile_relay_endpoint_descriptor(&mut config, "desktop_sidecar").unwrap();
        let state = &config["mobileRelayE2ee"];
        let seed = descriptor_text(state, "oneTimeMlKem1024PrekeySeedBase64url").unwrap();
        let seed_bytes = decode_fixed_base64url::<ML_KEM_1024_KEY_GENERATION_SEED_BYTES>(
            &seed,
            "test ML-KEM-1024 prekey seed",
        )
        .unwrap();
        let curve_secret = decode_key_32(
            &descriptor_text(state, "oneTimePrekeyPrivateKeyBase64url").unwrap(),
            "test curve one-time prekey",
        )
        .unwrap();
        assert_ne!(
            &seed_bytes[..MOBILE_RELAY_KEY_BYTES],
            curve_secret.as_slice()
        );

        let bundle = pairwise_prekey_bundle_from_descriptor(&descriptor).unwrap();
        assert_eq!(
            bundle.one_time_mlkem1024_prekey.public_key.len(),
            ML_KEM_1024_PUBLIC_KEY_BYTES
        );
        assert_eq!(
            bundle.one_time_mlkem1024_prekey.prekey_id,
            descriptor_text(state, "oneTimeMlKem1024PrekeyId").unwrap()
        );
        assert!(!serde_json::to_string(&descriptor).unwrap().contains(&seed));

        set_portable_data_dir_override(previous);
    }

    #[test]
    fn mobile_relay_pqxdh_descriptor_rejects_missing_mlkem_prekey_and_unsupported_protocol() {
        let dir = temp_dir("mobile-relay-pqxdh-strict-descriptor");
        let previous = set_portable_data_dir_override(Some(dir));
        let mut config = default_config();
        let descriptor =
            ensure_mobile_relay_endpoint_descriptor(&mut config, "desktop_sidecar").unwrap();

        let mut missing_mlkem = descriptor.clone();
        missing_mlkem["preKeyBundle"]
            .as_object_mut()
            .unwrap()
            .remove("oneTimeMlKem1024Prekey");
        let error = pairwise_prekey_bundle_from_descriptor(&missing_mlkem)
            .unwrap_err()
            .to_string();
        assert!(error.contains("prekey bundle shape is invalid"));

        let mut unsupported_protocol = descriptor;
        unsupported_protocol["protocolVersion"] = json!("unsupported.secure-mesh.protocol");
        let error = pairwise_prekey_bundle_from_descriptor(&unsupported_protocol)
            .unwrap_err()
            .to_string();
        assert!(error.contains("protocol is unsupported"));

        set_portable_data_dir_override(previous);
    }

    #[test]
    fn mobile_relay_rekeys_and_requires_repair_for_incompatible_local_protocol() {
        let dir = temp_dir("mobile-relay-pqxdh-incompatible-local-protocol");
        let previous = set_portable_data_dir_override(Some(dir));
        let mut config = default_config();
        ensure_mobile_relay_endpoint_descriptor(&mut config, "desktop_sidecar").unwrap();
        let prior_identity =
            descriptor_text(&config["mobileRelayE2ee"], "publicKeyBase64url").unwrap();
        config["mobileRelayE2ee"]["protocolVersion"] = json!("unsupported.secure-mesh.protocol");
        config["paired"] = json!(true);
        config["relayEnabled"] = json!(true);
        config["pcToken"] = json!("local-token-canary");

        ensure_mobile_relay_endpoint_descriptor(&mut config, "desktop_sidecar").unwrap();

        assert_ne!(
            descriptor_text(&config["mobileRelayE2ee"], "publicKeyBase64url").unwrap(),
            prior_identity
        );
        assert_eq!(
            config["mobileRelayE2ee"]["protocolVersion"],
            MOBILE_RELAY_E2EE_PROTOCOL_VERSION
        );
        assert_eq!(config["paired"], false);
        assert_eq!(config["relayEnabled"], false);
        assert_eq!(config["pcToken"], "");

        set_portable_data_dir_override(previous);
    }

    #[test]
    fn mobile_relay_rotates_curve_and_mlkem_one_time_prekeys_together() {
        let dir = temp_dir("mobile-relay-pqxdh-prekey-rotation");
        let previous = set_portable_data_dir_override(Some(dir));
        let mut config = default_config();
        ensure_mobile_relay_endpoint_descriptor(&mut config, "desktop_sidecar").unwrap();
        let before_version = config["mobileRelayE2ee"]["prekeyPublicationVersion"]
            .as_u64()
            .unwrap();
        let before_curve_id =
            descriptor_text(&config["mobileRelayE2ee"], "oneTimePrekeyId").unwrap();
        let before_mlkem_id =
            descriptor_text(&config["mobileRelayE2ee"], "oneTimeMlKem1024PrekeyId").unwrap();
        let before_mlkem_public = descriptor_text(
            &config["mobileRelayE2ee"],
            "oneTimeMlKem1024PrekeyPublicKeyBase64url",
        )
        .unwrap();

        rotate_mobile_relay_one_time_prekeys(&mut config).unwrap();

        assert_eq!(
            config["mobileRelayE2ee"]["prekeyPublicationVersion"],
            before_version + 1
        );
        assert_ne!(
            descriptor_text(&config["mobileRelayE2ee"], "oneTimePrekeyId").unwrap(),
            before_curve_id
        );
        assert_ne!(
            descriptor_text(&config["mobileRelayE2ee"], "oneTimeMlKem1024PrekeyId").unwrap(),
            before_mlkem_id
        );
        assert_ne!(
            descriptor_text(
                &config["mobileRelayE2ee"],
                "oneTimeMlKem1024PrekeyPublicKeyBase64url",
            )
            .unwrap(),
            before_mlkem_public
        );
        assert!(
            config["mobileRelayE2ee"]
                .get("keyTransparencyResponse")
                .is_none()
        );

        set_portable_data_dir_override(previous);
    }

    #[test]
    fn mobile_relay_pqxdh_intro_requires_mlkem_prekey_id_and_ciphertext() {
        let dir = temp_dir("mobile-relay-pqxdh-strict-intro");
        let previous = set_portable_data_dir_override(Some(dir));
        let mut pc_config = default_config();
        let pc_descriptor =
            ensure_mobile_relay_endpoint_descriptor(&mut pc_config, "desktop_sidecar").unwrap();
        let mut mobile_config = default_config();
        ensure_mobile_relay_endpoint_descriptor(&mut mobile_config, "mobile").unwrap();
        apply_peer_secure_mesh_descriptor(&mut mobile_config, &pc_descriptor, true).unwrap();
        let descriptor =
            ensure_mobile_relay_endpoint_descriptor(&mut mobile_config, "mobile").unwrap();

        for field in [
            "responderOneTimeMlKem1024PrekeyId",
            "mlkem1024CiphertextBase64url",
        ] {
            let mut malformed = descriptor.clone();
            malformed["pairwiseIntro"]
                .as_object_mut()
                .unwrap()
                .remove(field);
            let error = pairwise_intro_from_descriptor(&malformed)
                .unwrap_err()
                .to_string();
            assert!(error.contains("pairwise intro shape is invalid"));
        }

        set_portable_data_dir_override(previous);
    }

    #[test]
    fn mobile_relay_pairwise_rejects_relay_asserted_prekey_trust_state() {
        let dir = temp_dir("mobile-relay-pqxdh-prekey-trust-state-required");
        let previous = set_portable_data_dir_override(Some(dir));
        let mut pc_config = default_config();
        let mut pc_descriptor =
            ensure_mobile_relay_endpoint_descriptor(&mut pc_config, "desktop_sidecar").unwrap();
        pc_descriptor["preKeyBundle"]["trustState"] = json!("verified");
        let error = pairwise_prekey_bundle_from_descriptor(&pc_descriptor)
            .unwrap_err()
            .to_string();
        assert!(error.contains("prekey bundle shape is invalid"));

        let mut mobile_config = default_config();
        ensure_mobile_relay_endpoint_descriptor(&mut mobile_config, "mobile").unwrap();
        assert!(
            apply_peer_secure_mesh_descriptor(&mut mobile_config, &pc_descriptor, true).is_err()
        );
        assert_ne!(mobile_config["mobileRelayE2ee"]["peerVerified"], true);

        set_portable_data_dir_override(previous);
    }

    #[test]
    fn mobile_relay_pairwise_rejects_intro_signed_prekey_mismatch() {
        let dir = temp_dir("mobile-relay-pqxdh-intro-signed-prekey-mismatch");
        let previous = set_portable_data_dir_override(Some(dir));
        let mut pc_config = default_config();
        let pc_descriptor =
            ensure_mobile_relay_endpoint_descriptor(&mut pc_config, "desktop_sidecar").unwrap();
        let mut mobile_config = default_config();
        ensure_mobile_relay_endpoint_descriptor(&mut mobile_config, "mobile").unwrap();
        apply_peer_secure_mesh_descriptor(&mut mobile_config, &pc_descriptor, true).unwrap();
        let mut mobile_descriptor =
            ensure_mobile_relay_endpoint_descriptor(&mut mobile_config, "mobile").unwrap();
        mobile_descriptor["pairwiseIntro"]["responderSignedPrekeyId"] = json!("spk-attacker");

        let error = apply_peer_secure_mesh_descriptor(&mut pc_config, &mobile_descriptor, true)
            .unwrap_err()
            .to_string();
        assert!(error.contains("signed prekey id"));
        assert!(
            pc_config["mobileRelayE2ee"]
                .get("pairwiseAccepted")
                .is_none()
        );

        set_portable_data_dir_override(previous);
    }

    #[test]
    fn mobile_relay_pairwise_rejects_intro_directory_authorization_mismatch() {
        let dir = temp_dir("mobile-relay-pqxdh-intro-tree-head-mismatch");
        let previous = set_portable_data_dir_override(Some(dir));
        let mut pc_config = default_config();
        let pc_descriptor =
            ensure_mobile_relay_endpoint_descriptor(&mut pc_config, "desktop_sidecar").unwrap();
        let mut mobile_config = default_config();
        ensure_mobile_relay_endpoint_descriptor(&mut mobile_config, "mobile").unwrap();
        apply_peer_secure_mesh_descriptor(&mut mobile_config, &pc_descriptor, true).unwrap();
        let mut mobile_descriptor =
            ensure_mobile_relay_endpoint_descriptor(&mut mobile_config, "mobile").unwrap();
        mobile_descriptor["pairwiseIntro"]["directoryAuthorizationDigest"] = json!("ab".repeat(32));

        let error = apply_peer_secure_mesh_descriptor(&mut pc_config, &mobile_descriptor, true)
            .unwrap_err()
            .to_string();
        assert!(error.contains("directory authorization"));
        assert!(
            pc_config["mobileRelayE2ee"]
                .get("pairwiseAccepted")
                .is_none()
        );

        set_portable_data_dir_override(previous);
    }

    #[test]
    fn mobile_relay_pairwise_rejects_intro_initiator_identity_mismatch() {
        let dir = temp_dir("mobile-relay-pqxdh-intro-initiator-identity-mismatch");
        let previous = set_portable_data_dir_override(Some(dir));
        let mut pc_config = default_config();
        let pc_descriptor =
            ensure_mobile_relay_endpoint_descriptor(&mut pc_config, "desktop_sidecar").unwrap();
        let mut mobile_config = default_config();
        ensure_mobile_relay_endpoint_descriptor(&mut mobile_config, "mobile").unwrap();
        apply_peer_secure_mesh_descriptor(&mut mobile_config, &pc_descriptor, true).unwrap();
        let mut mobile_descriptor =
            ensure_mobile_relay_endpoint_descriptor(&mut mobile_config, "mobile").unwrap();
        mobile_descriptor["pairwiseIntro"]["initiatorIdentityPublicKeyBase64url"] =
            json!(random_base64url(32));

        let error = apply_peer_secure_mesh_descriptor(&mut pc_config, &mobile_descriptor, true)
            .unwrap_err()
            .to_string();
        assert!(error.contains("initiator identity"));
        assert!(
            pc_config["mobileRelayE2ee"]
                .get("pairwiseAccepted")
                .is_none()
        );

        set_portable_data_dir_override(previous);
    }

    #[test]
    fn mobile_relay_pairwise_rejects_intro_missing_one_time_prekey() {
        let dir = temp_dir("mobile-relay-pqxdh-intro-missing-curve-otpk");
        let previous = set_portable_data_dir_override(Some(dir));
        let mut pc_config = default_config();
        let pc_descriptor =
            ensure_mobile_relay_endpoint_descriptor(&mut pc_config, "desktop_sidecar").unwrap();
        let mut mobile_config = default_config();
        ensure_mobile_relay_endpoint_descriptor(&mut mobile_config, "mobile").unwrap();
        apply_peer_secure_mesh_descriptor(&mut mobile_config, &pc_descriptor, true).unwrap();
        let mut mobile_descriptor =
            ensure_mobile_relay_endpoint_descriptor(&mut mobile_config, "mobile").unwrap();
        mobile_descriptor["pairwiseIntro"]
            .as_object_mut()
            .unwrap()
            .remove("responderOneTimePrekeyId");

        let error = apply_peer_secure_mesh_descriptor(&mut pc_config, &mobile_descriptor, true)
            .unwrap_err()
            .to_string();
        assert!(error.contains("pairwise intro shape is invalid"));
        assert!(
            pc_config["mobileRelayE2ee"]
                .get("pairwiseAccepted")
                .is_none()
        );

        set_portable_data_dir_override(previous);
    }

    #[test]
    fn out_of_band_pairing_response_rejects_tampered_intro_with_replayed_claim_proof() {
        let dir = temp_dir("mobile-relay-claim-proof-binds-intro");
        let previous = set_portable_data_dir_override(Some(dir));
        let pairing_id = "pair_intro_replay_rejected";
        let pairing_secret = random_base64url(MOBILE_RELAY_KEY_BYTES);
        let mut pc_config = default_config();
        pc_config["pairingId"] = json!(pairing_id);
        let pc_descriptor =
            ensure_mobile_relay_endpoint_descriptor(&mut pc_config, "desktop_sidecar").unwrap();
        pc_config["mobileRelayE2ee"]["pairingSecretBase64url"] = json!(pairing_secret.clone());

        let mut mobile_config = default_config();
        mobile_config["pairingId"] = json!(pairing_id);
        ensure_mobile_relay_endpoint_descriptor(&mut mobile_config, "mobile").unwrap();
        mobile_config["mobileRelayE2ee"]["pairingSecretBase64url"] = json!(pairing_secret);
        apply_peer_secure_mesh_descriptor(&mut mobile_config, &pc_descriptor, true).unwrap();
        let mobile_descriptor =
            ensure_mobile_relay_endpoint_descriptor(&mut mobile_config, "mobile").unwrap();
        let proof = mobile_relay_claim_proof_for_pair(
            &pc_config,
            pairing_id,
            &mobile_descriptor,
            &pc_descriptor,
        )
        .unwrap();
        let mut tampered_descriptor = mobile_descriptor;
        tampered_descriptor["pairwiseIntro"]["initiatorIdentityPublicKeyBase64url"] =
            json!(random_base64url(32));

        let error = apply_out_of_band_pairing_response(
            &mut pc_config,
            &json!({
                "mobileSecureMesh": tampered_descriptor,
                "secureMeshClaimProof": proof
            }),
        )
        .unwrap_err()
        .to_string();
        assert!(error.contains("out-of-band claim proof is invalid"));

        assert!(
            peer_secure_mesh_descriptor(&pc_config).is_none(),
            "replayed claim proof must not verify a server-tampered pairwise intro"
        );
        assert_ne!(pc_config["mobileRelayE2ee"]["peerVerified"], true);
        assert!(
            pc_config["mobileRelayE2ee"]
                .get("pairwiseAccepted")
                .is_none()
        );

        set_portable_data_dir_override(previous);
    }

    #[test]
    fn mobile_relay_pairwise_rejects_reused_remote_one_time_prekey() {
        let dir = temp_dir("mobile-relay-pqxdh-reused-remote-otpk");
        let previous = set_portable_data_dir_override(Some(dir));
        let mut pc_config = default_config();
        let pc_descriptor =
            ensure_mobile_relay_endpoint_descriptor(&mut pc_config, "desktop_sidecar").unwrap();
        let mut mobile_config = default_config();
        ensure_mobile_relay_endpoint_descriptor(&mut mobile_config, "mobile").unwrap();
        apply_peer_secure_mesh_descriptor(&mut mobile_config, &pc_descriptor, true).unwrap();

        mobile_config["mobileRelayE2ee"]["sessionId"] =
            json!(format!("mrelay_session_{}", Uuid::new_v4()));
        if let Some(e2ee) = mobile_config
            .get_mut("mobileRelayE2ee")
            .and_then(Value::as_object_mut)
        {
            e2ee.remove("pendingPairwiseIntro");
            e2ee.remove("pairwiseAccepted");
        }

        let error = apply_peer_secure_mesh_descriptor(&mut mobile_config, &pc_descriptor, true)
            .unwrap_err()
            .to_string();
        assert!(error.contains("remote one-time prekey was already used"));

        set_portable_data_dir_override(previous);
    }

    #[test]
    fn mobile_relay_pairwise_rejects_tampered_prekey_signature_via_directory_commitment() {
        let dir = temp_dir("mobile-relay-pqxdh-tampered-prekey");
        let previous = set_portable_data_dir_override(Some(dir));
        let mut pc_config = default_config();
        let mut pc_descriptor =
            ensure_mobile_relay_endpoint_descriptor(&mut pc_config, "desktop_sidecar").unwrap();
        pc_descriptor["preKeyBundle"]["signedPrekey"]["signatureBase64url"] =
            json!(random_base64url(64));

        let mut mobile_config = default_config();
        ensure_mobile_relay_endpoint_descriptor(&mut mobile_config, "mobile").unwrap();
        let error = apply_peer_secure_mesh_descriptor(&mut mobile_config, &pc_descriptor, true)
            .unwrap_err()
            .to_string();
        assert!(error.contains("signed prekey commitment mismatch"));
        assert!(peer_secure_mesh_descriptor(&mobile_config).is_none());

        set_portable_data_dir_override(previous);
    }

    #[test]
    fn out_of_band_pairing_response_persists_revoked_peer_block_and_propagates_terminal_error() {
        let dir = temp_dir("mobile-relay-pairing-status-revoked-peer");
        let previous = set_portable_data_dir_override(Some(dir));
        let store = Arc::new(EphemeralSecretStore::new());
        let mobile_store: Arc<dyn SecureMeshSecretStore> = store.clone();
        let pairwise_store: Arc<dyn SecureMeshSecretStore> = store.clone();

        with_mobile_relay_secret_store_override(mobile_store, || {
            with_pairwise_secret_store_override(pairwise_store, || {
                let pairing_id = "pair-terminal-revocation";
                let pairing_secret = random_base64url(MOBILE_RELAY_KEY_BYTES);
                let mut pc_config = default_config();
                let mut mobile_config = default_config();
                for config in [&mut pc_config, &mut mobile_config] {
                    config["pairingId"] = json!(pairing_id);
                    config["mobileRelayE2ee"]["pairingSecretBase64url"] =
                        json!(pairing_secret.clone());
                }
                pair_mobile_relay_configs(&mut pc_config, &mut mobile_config);
                let local_endpoint_id = local_endpoint_state(&pc_config)?.endpoint_id;
                let old_session_id = session_id(&pc_config)?;
                let mut revoked_mobile =
                    ensure_mobile_relay_endpoint_descriptor(&mut mobile_config, "mobile")?;
                append_test_directory_state(&mut revoked_mobile, "revoked")?;
                let pc_descriptor =
                    ensure_mobile_relay_endpoint_descriptor(&mut pc_config, "desktop_sidecar")?;
                let proof = mobile_relay_claim_proof_for_pair(
                    &pc_config,
                    pairing_id,
                    &revoked_mobile,
                    &pc_descriptor,
                )?;

                let error = apply_out_of_band_pairing_response(
                    &mut pc_config,
                    &json!({
                        "mobileSecureMesh": revoked_mobile,
                        "secureMeshClaimProof": proof,
                    }),
                )
                .unwrap_err()
                .to_string();
                assert!(error.contains("terminal (revoked)"));
                assert_eq!(pc_config["mobileRelayE2ee"]["peerVerified"], false);
                assert!(
                    pc_config["mobileRelayE2ee"]
                        .get("peerTrustRecord")
                        .is_none()
                );
                assert_eq!(
                    pc_config["mobileRelayE2ee"]["keyTransparencyTerminalPeerBlock"]["state"],
                    "revoked"
                );
                assert_eq!(
                    pc_config["mobileRelayE2ee"]["keyTransparencyTerminalPeerBlock"]["redacted"],
                    true
                );
                let durable = load_config_without_persistence()?;
                assert_eq!(
                    durable["mobileRelayE2ee"]["keyTransparencyTerminalPeerBlock"]["state"],
                    "revoked"
                );
                assert!(durable["mobileRelayE2ee"].get("peerTrustRecord").is_none());
                assert!(
                    mobile_relay_pairwise_store_for_authority_reset()?
                        .load_session(&old_session_id, &local_endpoint_id)?
                        .is_none()
                );
                Ok(())
            })
        })
        .unwrap();

        set_portable_data_dir_override(previous);
    }

    #[test]
    fn legitimate_peer_identity_rotation_is_terminal_until_explicit_repair() {
        let dir = temp_dir("mobile-relay-legitimate-rotation-terminal");
        let previous = set_portable_data_dir_override(Some(dir));
        let store = Arc::new(EphemeralSecretStore::new());
        let mobile_store: Arc<dyn SecureMeshSecretStore> = store.clone();
        let pairwise_store: Arc<dyn SecureMeshSecretStore> = store.clone();

        with_mobile_relay_secret_store_override(mobile_store, || {
            with_pairwise_secret_store_override(pairwise_store, || {
                let mut pc_config = default_config();
                let mut mobile_config = default_config();
                pair_mobile_relay_configs(&mut pc_config, &mut mobile_config);
                let prior_identity = local_endpoint_state(&pc_config)?.device_identity()?;
                rotate_mobile_relay_local_identity_for_repair(&mut pc_config)?;
                let rotated_descriptor =
                    ensure_mobile_relay_endpoint_descriptor(&mut pc_config, "desktop_sidecar")?;
                let rotated_identity =
                    pairwise_prekey_bundle_from_descriptor(&rotated_descriptor)?.endpoint_identity;
                assert_eq!(rotated_identity.endpoint_id, prior_identity.endpoint_id);
                assert!(rotated_identity.rotation_epoch > prior_identity.rotation_epoch);
                assert_ne!(
                    rotated_identity.identity_public_key,
                    prior_identity.identity_public_key
                );

                let error = apply_peer_secure_mesh_descriptor(
                    &mut mobile_config,
                    &rotated_descriptor,
                    true,
                )
                .unwrap_err()
                .to_string();
                assert!(error.contains("terminal (key_changed)"));
                assert_eq!(mobile_config["mobileRelayE2ee"]["peerVerified"], false);
                assert!(
                    mobile_config["mobileRelayE2ee"]
                        .get("peerTrustRecord")
                        .is_none()
                );
                assert_eq!(
                    mobile_config["mobileRelayE2ee"]["keyTransparencyTerminalPeerBlock"]["state"],
                    "key_changed"
                );
                let durable = load_config_without_persistence()?;
                assert_eq!(
                    durable["mobileRelayE2ee"]["keyTransparencyTerminalPeerBlock"]["state"],
                    "key_changed"
                );
                Ok(())
            })
        })
        .unwrap();

        set_portable_data_dir_override(previous);
    }

    #[test]
    fn mobile_relay_pairwise_does_not_reinitialize_from_peer_descriptor_session_id() {
        let dir = temp_dir("mobile-relay-pqxdh-stale-peer-session-id");
        let previous = set_portable_data_dir_override(Some(dir));
        let mut pc_config = default_config();
        let mut pc_descriptor =
            ensure_mobile_relay_endpoint_descriptor(&mut pc_config, "desktop_sidecar").unwrap();
        let mut mobile_config = default_config();
        ensure_mobile_relay_endpoint_descriptor(&mut mobile_config, "mobile").unwrap();
        apply_peer_secure_mesh_descriptor(&mut mobile_config, &pc_descriptor, true).unwrap();
        let first_session_id = session_id(&mobile_config).unwrap();
        pc_descriptor["sessionId"] = json!("mrelay_session_stale_server_descriptor");

        apply_peer_secure_mesh_descriptor(&mut mobile_config, &pc_descriptor, true).unwrap();

        assert_eq!(session_id(&mobile_config).unwrap(), first_session_id);
        assert!(mobile_config["mobileRelayE2ee"]["pendingPairwiseIntro"].is_object());

        set_portable_data_dir_override(previous);
    }

    #[test]
    fn mobile_relay_pairwise_store_missing_requires_repair() {
        let dir = temp_dir("mobile-relay-pairwise-store-missing");
        let previous = set_portable_data_dir_override(Some(dir));
        let mut pc_config = default_config();
        let mut mobile_config = default_config();
        pair_mobile_relay_configs(&mut pc_config, &mut mobile_config);

        let store_path = mobile_relay_pairwise_store_path().unwrap();
        assert!(store_path.exists());
        fs::remove_file(&store_path).unwrap();
        let error = seal_mobile_relay_payload(
            &mobile_config,
            crate::core::secure_mesh_crypto::SecureMeshPayloadKind::Command,
            &json!({"body": "must-not-bootstrap"}),
        )
        .unwrap_err()
        .to_string();
        assert!(error.contains("re-pairing is required"));

        set_portable_data_dir_override(previous);
    }

    #[test]
    fn out_of_band_pairing_response_rejects_substituted_peer_without_claim_proof() {
        let dir = temp_dir("out-of-band-pairing-rejects-peer-substitution");
        let previous = set_portable_data_dir_override(Some(dir));
        let mut pc_config = default_config();
        let pc_descriptor =
            ensure_mobile_relay_endpoint_descriptor(&mut pc_config, "desktop_sidecar").unwrap();
        let pairing_id = "pair_peer_substitution";
        pc_config["pairingId"] = json!(pairing_id);

        let mut attacker_config = default_config();
        let attacker_descriptor =
            ensure_mobile_relay_endpoint_descriptor(&mut attacker_config, "mobile").unwrap();
        let error = apply_out_of_band_pairing_response(
            &mut pc_config,
            &json!({
                "mobileSecureMesh": attacker_descriptor,
                "secureMeshClaimProof": "forged-proof"
            }),
        )
        .unwrap_err()
        .to_string();
        assert!(error.contains("out-of-band claim proof is invalid"));

        assert!(
            peer_secure_mesh_descriptor(&pc_config).is_none(),
            "relay-supplied peer descriptor must not be trusted without a valid claim proof"
        );

        let mut mobile_config = default_config();
        ensure_mobile_relay_endpoint_descriptor(&mut mobile_config, "mobile").unwrap();
        apply_peer_secure_mesh_descriptor(&mut mobile_config, &pc_descriptor, true).unwrap();
        let mobile_descriptor =
            ensure_mobile_relay_endpoint_descriptor(&mut mobile_config, "mobile").unwrap();
        let proof = mobile_relay_claim_proof_for_pair(
            &pc_config,
            pairing_id,
            &mobile_descriptor,
            &pc_descriptor,
        )
        .unwrap();
        apply_out_of_band_pairing_response(
            &mut pc_config,
            &json!({
                "mobileSecureMesh": mobile_descriptor,
                "secureMeshClaimProof": proof
            }),
        )
        .unwrap();

        assert_eq!(
            peer_secure_mesh_descriptor(&pc_config)
                .and_then(|descriptor| descriptor.get("endpointKind").cloned())
                .and_then(|value| value.as_str().map(str::to_string)),
            Some("mobile".to_string())
        );
        assert_eq!(pc_config["mobileRelayE2ee"]["peerVerified"], true);
        set_portable_data_dir_override(previous);
    }

    #[test]
    fn out_of_band_mobile_response_cannot_replace_pinned_pc_identity() {
        let dir = temp_dir("out-of-band-mobile-response-pinned-pc");
        let previous = set_portable_data_dir_override(Some(dir));
        let mut pinned_pc_config = default_config();
        let pinned_pc_descriptor =
            ensure_mobile_relay_endpoint_descriptor(&mut pinned_pc_config, "desktop_sidecar")
                .unwrap();
        let mut mobile_config = default_config();
        mobile_config["pairingId"] = json!("pair_pinned_pc");
        ensure_mobile_relay_endpoint_descriptor(&mut mobile_config, "mobile").unwrap();
        apply_peer_secure_mesh_descriptor(&mut mobile_config, &pinned_pc_descriptor, true).unwrap();
        let pinned_descriptor = peer_secure_mesh_descriptor(&mobile_config).unwrap();
        let pinned_fingerprint =
            mobile_config["mobileRelayE2ee"]["peerDeviceTrustFingerprint"].clone();
        let pinned_trust_record = mobile_config["mobileRelayE2ee"]["peerTrustRecord"].clone();

        let mut attacker_pc_config = default_config();
        let attacker_pc_descriptor =
            ensure_mobile_relay_endpoint_descriptor(&mut attacker_pc_config, "desktop_sidecar")
                .unwrap();
        assert_ne!(pinned_pc_descriptor, attacker_pc_descriptor);
        let error = apply_out_of_band_pairing_response(
            &mut mobile_config,
            &json!({
                "mobileSecureMesh": attacker_pc_descriptor,
                "secureMeshClaimProof": "forged-proof"
            }),
        )
        .unwrap_err()
        .to_string();
        assert!(error.contains("out-of-band claim proof is invalid"));

        assert_eq!(
            peer_secure_mesh_descriptor(&mobile_config).unwrap(),
            pinned_descriptor
        );
        assert_eq!(
            mobile_config["mobileRelayE2ee"]["peerDeviceTrustFingerprint"],
            pinned_fingerprint
        );
        assert_eq!(
            mobile_config["mobileRelayE2ee"]["peerTrustRecord"],
            pinned_trust_record
        );
        assert_eq!(mobile_config["mobileRelayE2ee"]["peerVerified"], true);
        set_portable_data_dir_override(previous);
    }

    #[test]
    fn tampered_mobile_relay_command_envelope_is_rejected_before_execution() {
        let dir = temp_dir("mobile-relay-tampered-command");
        let previous = set_portable_data_dir_override(Some(dir));
        let (mut pc_config, _mobile_config, envelope) = paired_command_envelope_fixture();
        save_config(&mut pc_config).unwrap();

        let mut tampered = envelope;
        tampered["deliveryId"] = json!(general_purpose::URL_SAFE_NO_PAD.encode([0x7fu8; 24]));
        let error = execute_secure_envelope_command(
            &json!({
                "type": SECURE_MESH_ENVELOPE_COMMAND,
                "envelope": tampered
            }),
            &json!({}),
        )
        .unwrap_err()
        .to_string();
        assert!(
            error.contains("AAD hash mismatch") || error.contains("authentication failed"),
            "unexpected tamper error: {error}"
        );

        set_portable_data_dir_override(previous);
    }

    #[test]
    fn mobile_relay_secure_command_requires_signed_peer_trust_record() {
        let dir = temp_dir("mobile-relay-signed-trust-record-required");
        let previous = set_portable_data_dir_override(Some(dir));
        let (mut pc_config, _mobile_config, envelope) = paired_command_envelope_fixture();
        pc_config["mobileRelayE2ee"]["peerVerified"] = json!(true);
        pc_config["mobileRelayE2ee"]
            .as_object_mut()
            .unwrap()
            .remove("peerTrustRecord");
        save_config(&mut pc_config).unwrap();

        let error = execute_secure_envelope_command(
            &json!({
                "type": SECURE_MESH_ENVELOPE_COMMAND,
                "envelope": envelope
            }),
            &json!({}),
        )
        .unwrap_err()
        .to_string();
        assert!(error.contains("peer trust record is missing"));

        set_portable_data_dir_override(previous);
    }

    #[test]
    fn mobile_relay_secure_command_rejects_tampered_peer_trust_record() {
        let dir = temp_dir("mobile-relay-signed-trust-record-tamper");
        let previous = set_portable_data_dir_override(Some(dir));
        let (mut pc_config, _mobile_config, envelope) = paired_command_envelope_fixture();
        pc_config["mobileRelayE2ee"]["peerVerified"] = json!(true);
        pc_config["mobileRelayE2ee"]["peerTrustRecord"]["verificationMethod"] =
            json!("server_injected_trust");
        save_config(&mut pc_config).unwrap();

        let error = execute_secure_envelope_command(
            &json!({
                "type": SECURE_MESH_ENVELOPE_COMMAND,
                "envelope": envelope
            }),
            &json!({}),
        )
        .unwrap_err()
        .to_string();
        assert!(error.contains("peer trust record is invalid"));

        set_portable_data_dir_override(previous);
    }

    #[test]
    fn mobile_relay_protected_send_blocks_unverified_key_changed_and_revoked_peers() {
        let dir = temp_dir("mobile-relay-protected-send-trust-blocks");
        let previous = set_portable_data_dir_override(Some(dir));
        let mut pc_config = default_config();
        let mut mobile_config = default_config();
        pair_mobile_relay_configs(&mut pc_config, &mut mobile_config);

        let payload_kinds = [
            crate::core::secure_mesh_crypto::SecureMeshPayloadKind::Command,
            crate::core::secure_mesh_crypto::SecureMeshPayloadKind::ResultPayload,
            crate::core::secure_mesh_crypto::SecureMeshPayloadKind::FileManifest,
            crate::core::secure_mesh_crypto::SecureMeshPayloadKind::ServiceAction,
        ];

        pc_config["mobileRelayE2ee"]["peerVerified"] = json!(false);
        for kind in payload_kinds {
            let error = seal_mobile_relay_payload(&pc_config, kind, &json!({"body": "blocked"}))
                .unwrap_err()
                .to_string();
            assert!(
                error.contains("peer is not verified"),
                "unverified seal should fail closed for {kind:?}: {error}"
            );
        }

        pc_config["mobileRelayE2ee"]["peerVerified"] = json!(true);
        pc_config["mobileRelayE2ee"]["peerTrustRecord"]["trustState"] = json!("key_changed");
        for kind in payload_kinds {
            let error = seal_mobile_relay_payload(&pc_config, kind, &json!({"body": "blocked"}))
                .unwrap_err()
                .to_string();
            assert!(
                error.contains("peer trust record is invalid")
                    || error.contains("identity_key_changed")
                    || error.contains("not trusted for sensitive use"),
                "key-changed seal should fail closed for {kind:?}: {error}"
            );
        }

        pc_config["mobileRelayE2ee"]["peerTrustRecord"]["trustState"] = json!("revoked");
        for kind in payload_kinds {
            let error = seal_mobile_relay_payload(&pc_config, kind, &json!({"body": "blocked"}))
                .unwrap_err()
                .to_string();
            assert!(
                error.contains("peer trust record is invalid")
                    || error.contains("device_revoked")
                    || error.contains("not trusted for sensitive use"),
                "revoked seal should fail closed for {kind:?}: {error}"
            );
        }

        set_portable_data_dir_override(previous);
    }

    #[test]
    fn commands_sync_redacts_malicious_relay_crypto_errors() {
        let gateway = CanonicalRelayGateway::start(3, vec![secure_envelope_fixture()]);
        let dir = temp_dir("mobile-relay-sync-redacted-crypto-error");
        let previous = set_portable_data_dir_override(Some(dir));
        let (mut pc_config, _mobile_config, _envelope) = paired_command_envelope_fixture();
        pc_config["pairingId"] = json!("pair_sync_redacted_crypto_error");
        pc_config["pcToken"] = json!("pc-token-sync-redacted-crypto-error");
        pc_config["useCustomGateway"] = json!(true);
        pc_config["customGatewayUrl"] = json!(gateway.url());
        save_config(&mut pc_config).unwrap();

        let output = commands_sync(&with_canonical_relay_params(json!({"targets": []}))).unwrap();
        assert_eq!(output["completed"][0]["ok"], false);
        assert_eq!(
            output["completed"][0]["completion"]["code"],
            SECURE_MESH_ENDPOINT_CRYPTO_RUNTIME_FAILED_CODE
        );
        assert_eq!(
            output["completed"][0]["error"],
            SECURE_MESH_ENDPOINT_CRYPTO_RUNTIME_FAILED_DETAIL
        );
        let serialized = serde_json::to_string(&output).unwrap();
        assert!(!serialized.contains("authentication failed"));
        assert!(!serialized.contains("AAD hash mismatch"));
        gateway.assert_operations(&[
            SecureClientRelayOperation::EndpointChallenge,
            SecureClientRelayOperation::EndpointRegister,
            SecureClientRelayOperation::EnvelopeSync,
        ]);

        gateway.join();
        set_portable_data_dir_override(previous);
    }

    #[test]
    fn mobile_relay_command_error_result_redacts_internal_detail() {
        let dir = temp_dir("mobile-relay-command-redacted-internal-error");
        let previous = set_portable_data_dir_override(Some(dir));
        let (mut pc_config, mobile_config, _envelope) = paired_command_envelope_fixture();
        save_config(&mut pc_config).unwrap();
        let invalid_command_payload = json!({
            "schema": "unsupported-schema-local-secret-canary",
            "body": {
                "text": "malicious-relay-command-error-canary"
            }
        });
        let envelope = seal_mobile_relay_payload(
            &mobile_config,
            crate::core::secure_mesh_crypto::SecureMeshPayloadKind::Command,
            &invalid_command_payload,
        )
        .unwrap();

        let result_envelope = execute_secure_envelope_command(
            &json!({
                "type": SECURE_MESH_ENVELOPE_COMMAND,
                "envelope": envelope
            }),
            &json!({}),
        )
        .unwrap();
        let result = opened_result_payload(&mobile_config, &result_envelope);
        assert_eq!(result["ok"], false);
        assert_eq!(
            result["code"],
            SECURE_MESH_ENDPOINT_CRYPTO_RUNTIME_FAILED_CODE
        );
        assert_eq!(
            result["error"],
            SECURE_MESH_ENDPOINT_CRYPTO_RUNTIME_FAILED_DETAIL
        );
        assert_eq!(result["bodyRedacted"], true);
        let serialized = serde_json::to_string(&result).unwrap();
        assert!(!serialized.contains("unsupported-schema-local-secret-canary"));
        assert!(!serialized.contains("malicious-relay-command-error-canary"));

        set_portable_data_dir_override(previous);
    }

    #[test]
    fn replayed_mobile_relay_command_envelope_does_not_execute_twice() {
        let dir = temp_dir("mobile-relay-replayed-command");
        let previous = set_portable_data_dir_override(Some(dir));
        let (mut pc_config, mobile_config, envelope) = paired_command_envelope_fixture();
        save_config(&mut pc_config).unwrap();
        let command = json!({
            "type": SECURE_MESH_ENVELOPE_COMMAND,
            "envelope": envelope
        });

        let first_result_envelope = execute_secure_envelope_command(&command, &json!({})).unwrap();
        let first_result = opened_result_payload(&mobile_config, &first_result_envelope);
        assert_eq!(first_result["evaluation"]["code"], "execute");
        assert_eq!(first_result["execution"]["outcome"], "result");

        let second_result = execute_secure_envelope_command(&command, &json!({}));
        assert!(
            second_result
                .unwrap_err()
                .to_string()
                .contains("pairwise message replay detected")
        );

        set_portable_data_dir_override(previous);
    }

    #[test]
    fn mobile_relay_result_replay_proof_rejects_second_open_without_plaintext() {
        let dir = temp_dir("mobile-relay-result-replay-proof");
        let previous = set_portable_data_dir_override(Some(dir));
        let (mut pc_config, mobile_config, envelope) = paired_command_envelope_fixture();
        save_config(&mut pc_config).unwrap();
        let result_envelope = execute_secure_envelope_command(
            &json!({
                "type": SECURE_MESH_ENVELOPE_COMMAND,
                "envelope": envelope
            }),
            &json!({}),
        )
        .unwrap();
        let response_summary = secure_result_response_summary(&json!({
            "ok": true,
            "command": {
                "commandId": "cmd_mobile_relay_replay_fixture",
                "status": "completed",
                "resultEnvelope": result_envelope.clone()
            },
            "ackPurge": {
                "purged": true
            }
        }));
        let proof =
            result_envelope_replay_proof(&mobile_config, &result_envelope, response_summary)
                .unwrap();
        assert_eq!(proof["ok"], true);
        assert_eq!(proof["firstOpenOk"], true);
        assert_eq!(proof["firstOpenBodyRedacted"], true);
        assert_eq!(proof["replayRejected"], true);
        assert_eq!(proof["bodyRedacted"], true);
        let serialized = serde_json::to_string(&proof).unwrap();
        assert!(!serialized.contains("cmd_mobile_relay_replay_fixture"));
        assert!(!serialized.contains("idem_mobile_relay_replay_fixture"));
        assert!(!serialized.contains("limit"));

        set_portable_data_dir_override(previous);
    }

    #[test]
    fn mobile_relay_encrypted_local_effect_command_requires_local_confirmation() {
        let dir = temp_dir("mobile-relay-local-effect-confirmation");
        let previous = set_portable_data_dir_override(Some(dir));
        let mut pc_config = default_config();
        let mut mobile_config = default_config();
        pair_mobile_relay_configs(&mut pc_config, &mut mobile_config);
        let mobile_endpoint = local_endpoint_state(&mobile_config).unwrap();
        let pc_endpoint = local_endpoint_state(&pc_config).unwrap();
        save_config(&mut pc_config).unwrap();

        let command_payload = json!({
            "schema": crate::core::secure_mesh::SECURE_MESH_COMMAND_PROTOCOL_VERSION,
            "commandId": "cmd_mobile_relay_local_effect",
            "commandKind": "secure_mesh.device.verify",
            "senderIdentity": {
                "endpointId": mobile_endpoint.endpoint_id,
                "identityFingerprint": mobile_endpoint.fingerprint,
                "trustState": "verified",
                "endpointKind": mobile_endpoint.endpoint_kind
            },
            "targetBinding": {
                "targetEndpointId": pc_endpoint.endpoint_id,
                "targetAgentId": null,
                "workspaceId": "default"
            },
            "riskClass": "local_effect",
            "requiresUserConfirmation": false,
            "idempotencyKey": "idem_mobile_relay_local_effect",
            "createdAt": now_iso(),
            "expiresAt": timestamp_after_seconds(MOBILE_RELAY_COMMAND_TTL_SECONDS).unwrap(),
            "body": {
                "privateCanary": "local-effect-body-canary"
            }
        });
        let envelope = seal_mobile_relay_payload(
            &mobile_config,
            crate::core::secure_mesh_crypto::SecureMeshPayloadKind::Command,
            &command_payload,
        )
        .unwrap();

        let result_envelope = execute_secure_envelope_command(
            &json!({
                "type": SECURE_MESH_ENVELOPE_COMMAND,
                "envelope": envelope
            }),
            &json!({}),
        )
        .unwrap();
        let result = opened_result_payload(&mobile_config, &result_envelope);
        assert_eq!(result["evaluation"]["accepted"], true);
        assert_eq!(result["evaluation"]["shouldExecute"], false);
        assert_eq!(result["evaluation"]["code"], "user_confirmation_required");
        assert_eq!(result["execution"]["outcome"], "error");
        assert_eq!(result["bodyRedacted"], true);
        let serialized = serde_json::to_string(&result).unwrap();
        assert!(!serialized.contains("local-effect-body-canary"));

        set_portable_data_dir_override(previous);
    }

    #[test]
    fn command_result_secure_consumes_canonical_sync_and_acks_after_open() {
        let dir = temp_dir("mobile-relay-secure-result-canonical-sync");
        let previous = set_portable_data_dir_override(Some(dir));
        let (pc_config, mut mobile_config, _envelope) = paired_command_envelope_fixture();
        let result_envelope = seal_mobile_relay_payload(
            &pc_config,
            crate::core::secure_mesh_crypto::SecureMeshPayloadKind::ResultPayload,
            &json!({
                "ok": true,
                "result": "encrypted-result-canary",
                "bodyRedacted": true
            }),
        )
        .unwrap();
        let expected_delivery_id = result_envelope["deliveryId"].clone();
        let gateway = CanonicalRelayGateway::start(2, vec![result_envelope]);
        mobile_config["pairingId"] = json!("pair_canonical_result_sync");
        mobile_config["mobileToken"] = json!("mobile-token-canonical-result-sync");
        mobile_config["useCustomGateway"] = json!(true);
        mobile_config["customGatewayUrl"] = json!(gateway.url());
        save_config(&mut mobile_config).unwrap();

        let output = command_result_secure(&with_canonical_relay_params(json!({}))).unwrap();

        assert_eq!(output["ok"], true);
        assert_eq!(output["bodyRedacted"], true);
        assert_eq!(output["response"]["bodyRedacted"], true);
        assert_eq!(output["response"]["command"]["resultEnvelopePresent"], true);
        assert!(
            output["response"]["command"]
                .get("resultEnvelope")
                .is_none()
        );
        assert_eq!(output["openedResult"]["result"], "encrypted-result-canary");
        let serialized = serde_json::to_string(&output).unwrap();
        assert!(!serialized.contains("mobile-token-canonical-result-sync"));
        assert_eq!(
            serde_json::from_str::<Value>(&gateway.request_body(1)).unwrap()["deliveryId"],
            expected_delivery_id
        );
        gateway.assert_operations(&[
            SecureClientRelayOperation::EnvelopeSync,
            SecureClientRelayOperation::EnvelopeAck,
        ]);

        gateway.join();
        set_portable_data_dir_override(previous);
    }

    #[test]
    fn command_result_secure_reuses_single_operation_auth_batch_for_fetch_and_result_open() {
        let dir = temp_dir("mobile-relay-secure-result-single-operation-auth-batch");
        let previous = set_portable_data_dir_override(Some(dir));
        let secret_store = Arc::new(EphemeralSecretStore::new());
        let mobile_store_override: Arc<dyn SecureMeshSecretStore> = secret_store.clone();
        let pairwise_store_override: Arc<dyn SecureMeshSecretStore> = secret_store.clone();

        with_mobile_relay_secret_store_override(mobile_store_override, || {
            with_pairwise_secret_store_override(pairwise_store_override, || {
                let (pc_config, mut mobile_config, _envelope) = paired_command_envelope_fixture();
                let result_envelope = seal_mobile_relay_payload(
                    &pc_config,
                    crate::core::secure_mesh_crypto::SecureMeshPayloadKind::ResultPayload,
                    &json!({
                        "ok": true,
                        "result": "single-auth-result-canary",
                        "bodyRedacted": true
                    }),
                )?;
                let gateway = CanonicalRelayGateway::start(2, vec![result_envelope]);
                mobile_config["pairingId"] = json!("pair_secure_result_single_auth_batch");
                mobile_config["mobileToken"] = json!("mobile-token-secure-result-single-auth");
                mobile_config["useCustomGateway"] = json!(true);
                mobile_config["customGatewayUrl"] = json!(gateway.url());
                persist_config_secret_material_to_secret_store(
                    &mut mobile_config,
                    secret_store.as_ref(),
                    MOBILE_RELAY_PLATFORM_SECRET_STORE_NAMESPACE,
                )?;
                save_config(&mut mobile_config)?;
                let baseline_session_count = secret_store.authorization_session_count();

                let output = command_result_secure(&with_canonical_relay_params(json!({})))?;

                assert_eq!(output["ok"], true);
                assert_eq!(
                    output["openedResult"]["result"],
                    "single-auth-result-canary"
                );
                assert_eq!(
                    secret_store.authorization_session_count(),
                    baseline_session_count + 1
                );
                assert_eq!(
                    secret_store.authorization_session_reasons()[baseline_session_count],
                    "Mobile Relay secure result operation authorization batch"
                );
                gateway.assert_operations(&[
                    SecureClientRelayOperation::EnvelopeSync,
                    SecureClientRelayOperation::EnvelopeAck,
                ]);
                gateway.join();
                Ok(())
            })
        })
        .unwrap();

        set_portable_data_dir_override(previous);
    }

    #[test]
    fn command_create_secure_reuses_single_operation_auth_batch_for_hydrate_and_seal() {
        let gateway = CanonicalRelayGateway::start(1, Vec::new());
        let dir = temp_dir("mobile-relay-secure-command-create-single-auth-batch");
        let previous = set_portable_data_dir_override(Some(dir));
        let secret_store = Arc::new(EphemeralSecretStore::new());
        let mobile_store_override: Arc<dyn SecureMeshSecretStore> = secret_store.clone();
        let pairwise_store_override: Arc<dyn SecureMeshSecretStore> = secret_store.clone();

        with_mobile_relay_secret_store_override(mobile_store_override, || {
            with_pairwise_secret_store_override(pairwise_store_override, || {
                let mut pc_config = default_config();
                let mut mobile_config = default_config();
                pair_mobile_relay_configs(&mut pc_config, &mut mobile_config);
                mobile_config["pairingId"] = json!("pair_secure_command_create_single_auth_batch");
                mobile_config["mobileToken"] = json!("mobile-token-single-auth-create");
                mobile_config["useCustomGateway"] = json!(true);
                mobile_config["customGatewayUrl"] = json!(gateway.url());
                persist_config_secret_material_to_secret_store(
                    &mut mobile_config,
                    secret_store.as_ref(),
                    MOBILE_RELAY_PLATFORM_SECRET_STORE_NAMESPACE,
                )?;
                save_config(&mut mobile_config)?;
                let baseline_session_count = secret_store.authorization_session_count();

                let output = command_create_secure(&with_canonical_relay_params(json!({
                    "commandKind": "agent.message.send",
                    "targetAgentId": "codex",
                    "workspaceId": "default",
                    "body": {
                        "agentId": "codex",
                        "text": "single-auth-create-canary"
                    },
                    "secretOverrideTransport": RUNTIME_SECRET_OVERRIDE_TRANSPORT,
                    "secretOverrides": {
                        "mobileRelayE2eeSecretStore": {
                            "contract": "rust_secure_mesh_secret_store_handle_v1",
                            "namespace": MOBILE_RELAY_PLATFORM_SECRET_STORE_NAMESPACE,
                            "rawJsonSecretOverridesUsed": false
                        }
                    }
                })))?;

                assert_eq!(output["ok"], true);
                assert_eq!(
                    output["secureCommandBinding"]["commandKind"],
                    "agent.message.send"
                );
                assert!(
                    output["secureCommandBinding"]["payloadCommandId"]
                        .as_str()
                        .is_some_and(|value| !value.is_empty())
                );
                assert!(
                    output["secureCommandBinding"]["idempotencyKey"]
                        .as_str()
                        .is_some_and(|value| !value.is_empty())
                );
                assert_eq!(
                    secret_store.authorization_session_count(),
                    baseline_session_count + 1
                );
                assert_eq!(
                    secret_store.authorization_session_reasons()[baseline_session_count],
                    "Mobile Relay secure command create authorization batch"
                );
                assert_eq!(
                    secret_store.authorization_session_operation_counts()[baseline_session_count],
                    mobile_relay_e2ee_secret_store_authorization_batch_operation_count()
                        .saturating_add(3)
                );
                let request = gateway.request_body(0);
                let request_body = serde_json::from_str::<Value>(&request).unwrap();
                assert!(request_body["envelope"].is_object());
                assert!(!request.contains(SECURE_MESH_ENVELOPE_COMMAND));
                assert!(!request.contains("single-auth-create-canary"));
                assert!(!request.contains("mobile-token-single-auth-create"));
                assert!(!request.contains("commandId"));
                gateway.assert_operations(&[SecureClientRelayOperation::EnvelopeSend]);
                gateway.join();
                Ok(())
            })
        })
        .unwrap();

        set_portable_data_dir_override(previous);
    }

    #[test]
    fn command_result_replay_proof_reuses_single_operation_auth_batch_for_fetch_and_replay_check() {
        let dir = temp_dir("mobile-relay-result-replay-proof-single-operation-auth-batch");
        let previous = set_portable_data_dir_override(Some(dir));
        let secret_store = Arc::new(EphemeralSecretStore::new());
        let mobile_store_override: Arc<dyn SecureMeshSecretStore> = secret_store.clone();
        let pairwise_store_override: Arc<dyn SecureMeshSecretStore> = secret_store.clone();

        with_mobile_relay_secret_store_override(mobile_store_override, || {
            with_pairwise_secret_store_override(pairwise_store_override, || {
                let (pc_config, mut mobile_config, _envelope) = paired_command_envelope_fixture();
                let result_envelope = seal_mobile_relay_payload(
                    &pc_config,
                    crate::core::secure_mesh_crypto::SecureMeshPayloadKind::ResultPayload,
                    &json!({
                        "ok": true,
                        "evaluation": {
                            "code": "execute"
                        },
                        "execution": {
                            "outcome": "result"
                        },
                        "bodyRedacted": true
                    }),
                )?;
                let gateway = CanonicalRelayGateway::start(1, vec![result_envelope]);
                mobile_config["pairingId"] = json!("pair_result_replay_single_auth_batch");
                mobile_config["mobileToken"] = json!("mobile-token-result-replay-single-auth");
                mobile_config["useCustomGateway"] = json!(true);
                mobile_config["customGatewayUrl"] = json!(gateway.url());
                persist_config_secret_material_to_secret_store(
                    &mut mobile_config,
                    secret_store.as_ref(),
                    MOBILE_RELAY_PLATFORM_SECRET_STORE_NAMESPACE,
                )?;
                save_config(&mut mobile_config)?;
                let baseline_session_count = secret_store.authorization_session_count();

                let proof = command_result_replay_proof(&with_canonical_relay_params(json!({})))?;

                assert_eq!(proof["ok"], true);
                assert_eq!(proof["replayRejected"], true);
                assert_eq!(
                    secret_store.authorization_session_count(),
                    baseline_session_count + 1
                );
                assert_eq!(
                    secret_store.authorization_session_reasons()[baseline_session_count],
                    "Mobile Relay secure result replay proof authorization batch"
                );
                gateway.assert_operations(&[SecureClientRelayOperation::EnvelopeSync]);
                gateway.join();
                Ok(())
            })
        })
        .unwrap();

        set_portable_data_dir_override(previous);
    }

    #[test]
    fn secure_command_create_rejects_raw_runtime_e2ee_secret_overrides() {
        let dir = temp_dir("mobile-relay-secure-command-raw-runtime-e2ee-overrides");
        let previous = set_portable_data_dir_override(Some(dir));

        let mut pc_config = default_config();
        let pc_descriptor =
            ensure_mobile_relay_endpoint_descriptor(&mut pc_config, "desktop_sidecar").unwrap();

        let mut mobile_config = default_config();
        ensure_mobile_relay_endpoint_descriptor(&mut mobile_config, "mobile").unwrap();
        apply_peer_secure_mesh_descriptor(&mut mobile_config, &pc_descriptor, true).unwrap();
        let private_key = mobile_config["mobileRelayE2ee"]["privateKeyBase64url"]
            .as_str()
            .unwrap()
            .to_string();
        let signing_key = mobile_config["mobileRelayE2ee"]["signingKeyBase64url"]
            .as_str()
            .unwrap()
            .to_string();
        let signed_prekey_private_key =
            mobile_config["mobileRelayE2ee"]["signedPrekeyPrivateKeyBase64url"]
                .as_str()
                .unwrap()
                .to_string();
        let one_time_prekey_private_key =
            mobile_config["mobileRelayE2ee"]["oneTimePrekeyPrivateKeyBase64url"]
                .as_str()
                .unwrap()
                .to_string();
        let one_time_mlkem1024_prekey_seed =
            mobile_config["mobileRelayE2ee"]["oneTimeMlKem1024PrekeySeedBase64url"]
                .as_str()
                .unwrap()
                .to_string();
        let pairing_secret = mobile_config["mobileRelayE2ee"]["pairingSecretBase64url"]
            .as_str()
            .unwrap()
            .to_string();
        mobile_config["pairingId"] = json!("pair_raw_runtime_e2ee_override");
        mobile_config["mobileToken"] = json!("");
        mobile_config["mobileRelayE2ee"]
            .as_object_mut()
            .unwrap()
            .remove("privateKeyBase64url");
        mobile_config["mobileRelayE2ee"]
            .as_object_mut()
            .unwrap()
            .remove("signingKeyBase64url");
        mobile_config["mobileRelayE2ee"]
            .as_object_mut()
            .unwrap()
            .remove("signedPrekeyPrivateKeyBase64url");
        mobile_config["mobileRelayE2ee"]
            .as_object_mut()
            .unwrap()
            .remove("oneTimePrekeyPrivateKeyBase64url");
        mobile_config["mobileRelayE2ee"]
            .as_object_mut()
            .unwrap()
            .remove("oneTimeMlKem1024PrekeySeedBase64url");
        mobile_config["mobileRelayE2ee"]
            .as_object_mut()
            .unwrap()
            .remove("pairingSecretBase64url");
        mobile_config["mobileRelayE2ee"]["privateKeyMaterial"] = json!("redacted");
        mobile_config["mobileRelayE2ee"]["signingKeyMaterial"] = json!("redacted");
        mobile_config["mobileRelayE2ee"]["signedPrekeyPrivateKeyMaterial"] = json!("redacted");
        mobile_config["mobileRelayE2ee"]["oneTimePrekeyPrivateKeyMaterial"] = json!("redacted");
        mobile_config["mobileRelayE2ee"]["oneTimeMlKem1024PrekeySeedMaterial"] = json!("redacted");
        mobile_config["mobileRelayE2ee"]["pairingSecretMaterial"] = json!("redacted");
        save_config(&mut mobile_config).unwrap();

        let error = command_create_secure(&json!({
            "commandKind": "agent.message.send",
            "targetAgentId": "codex",
            "workspaceId": "default",
            "body": {
                "agentId": "codex",
                "text": "raw-runtime-override-plaintext-canary"
            },
            "secretOverrideTransport": RUNTIME_SECRET_OVERRIDE_TRANSPORT,
            "secretOverrides": {
                "mobileRelayE2ee": {
                    "privateKeyBase64url": private_key,
                    "signingKeyBase64url": signing_key,
                    "signedPrekeyPrivateKeyBase64url": signed_prekey_private_key,
                    "oneTimePrekeyPrivateKeyBase64url": one_time_prekey_private_key,
                    "oneTimeMlKem1024PrekeySeedBase64url": one_time_mlkem1024_prekey_seed,
                    "pairingSecretBase64url": pairing_secret
                }
            }
        }))
        .unwrap_err();
        assert!(
            error
                .to_string()
                .contains("raw E2EE secretOverrides are disabled")
        );

        let persisted = serde_json::to_string(&load_config().unwrap()).unwrap();
        for canary in [
            "raw-runtime-override-plaintext-canary",
            private_key.as_str(),
            signing_key.as_str(),
            signed_prekey_private_key.as_str(),
            one_time_prekey_private_key.as_str(),
            one_time_mlkem1024_prekey_seed.as_str(),
            pairing_secret.as_str(),
        ] {
            assert!(
                !persisted.contains(canary),
                "raw runtime E2EE override leaked to config: {canary}"
            );
        }
        set_portable_data_dir_override(previous);
    }

    #[test]
    fn secure_command_create_uses_mobile_relay_secret_store_override_without_raw_e2ee_json() {
        let gateway = CanonicalRelayGateway::start(1, Vec::new());
        let dir = temp_dir("mobile-relay-secure-command-secret-store-override");
        let previous = set_portable_data_dir_override(Some(dir));

        let store = Arc::new(EphemeralSecretStore::new());
        let mut pc_config = default_config();
        let mut mobile_config = default_config();
        let setup_store_override: Arc<dyn SecureMeshSecretStore> = store.clone();
        with_mobile_relay_secret_store_override(setup_store_override, || {
            pair_mobile_relay_configs(&mut pc_config, &mut mobile_config);
            Ok(())
        })
        .unwrap();
        let private_key = mobile_config["mobileRelayE2ee"]["privateKeyBase64url"]
            .as_str()
            .unwrap()
            .to_string();
        let signing_key = mobile_config["mobileRelayE2ee"]["signingKeyBase64url"]
            .as_str()
            .unwrap()
            .to_string();
        let signed_prekey_private_key =
            mobile_config["mobileRelayE2ee"]["signedPrekeyPrivateKeyBase64url"]
                .as_str()
                .unwrap()
                .to_string();
        let one_time_prekey_private_key =
            mobile_config["mobileRelayE2ee"]["oneTimePrekeyPrivateKeyBase64url"]
                .as_str()
                .unwrap()
                .to_string();
        let one_time_mlkem1024_prekey_seed =
            mobile_config["mobileRelayE2ee"]["oneTimeMlKem1024PrekeySeedBase64url"]
                .as_str()
                .unwrap()
                .to_string();
        mobile_config["pairingId"] = json!("pair_secret_store_override_gateway");
        mobile_config["mobileToken"] = json!("mobile-token-secret-store-override-canary");
        mobile_config["useCustomGateway"] = json!(true);
        mobile_config["customGatewayUrl"] = json!(gateway.url());
        persist_config_secret_material_to_secret_store(
            &mut mobile_config,
            store.as_ref(),
            MOBILE_RELAY_PLATFORM_SECRET_STORE_NAMESPACE,
        )
        .unwrap();
        save_config(&mut mobile_config).unwrap();

        let store_override: Arc<dyn SecureMeshSecretStore> = store.clone();
        let create_response = with_mobile_relay_secret_store_override(store_override, || {
            command_create_secure(&with_canonical_relay_params(json!({
                "commandKind": "agent.message.send",
                "targetAgentId": "codex",
                "workspaceId": "default",
                "body": {
                    "agentId": "codex",
                    "text": "secret-store-override-plaintext-canary"
                },
                "secretOverrideTransport": RUNTIME_SECRET_OVERRIDE_TRANSPORT,
                "secretOverrides": {
                    "mobileRelayE2eeSecretStore": {
                        "contract": "rust_secure_mesh_secret_store_handle_v1",
                        "namespace": MOBILE_RELAY_PLATFORM_SECRET_STORE_NAMESPACE,
                        "rawJsonSecretOverridesUsed": false
                    }
                }
            })))
        })
        .unwrap();
        assert_eq!(create_response["ok"], true);

        let request = gateway.request_body(0);
        assert!(serde_json::from_str::<Value>(&request).unwrap()["envelope"].is_object());
        assert!(!request.contains(SECURE_MESH_ENVELOPE_COMMAND));
        for canary in [
            "secret-store-override-plaintext-canary",
            "mobile-token-secret-store-override-canary",
            private_key.as_str(),
            signing_key.as_str(),
            signed_prekey_private_key.as_str(),
            one_time_prekey_private_key.as_str(),
            one_time_mlkem1024_prekey_seed.as_str(),
            "privateKeyBase64url",
            "signingKeyBase64url",
            "signedPrekeyPrivateKeyBase64url",
            "oneTimePrekeyPrivateKeyBase64url",
            "oneTimeMlKem1024PrekeySeedBase64url",
        ] {
            assert!(
                !request.contains(canary),
                "secret-store override request leaked {canary}"
            );
        }
        let persisted = serde_json::to_string(&load_config().unwrap()).unwrap();
        for secret in [
            private_key.as_str(),
            signing_key.as_str(),
            signed_prekey_private_key.as_str(),
            one_time_prekey_private_key.as_str(),
            one_time_mlkem1024_prekey_seed.as_str(),
        ] {
            assert!(!persisted.contains(secret));
        }

        gateway.assert_operations(&[SecureClientRelayOperation::EnvelopeSend]);
        gateway.join();
        set_portable_data_dir_override(previous);
    }

    #[test]
    fn kt_authority_reset_guard_survives_restart_and_blocks_all_old_session_paths() {
        let dir = temp_dir("mobile-relay-kt-reset-guard-crash");
        let previous = set_portable_data_dir_override(Some(dir));
        let store = Arc::new(EphemeralSecretStore::new());
        let mobile_store: Arc<dyn SecureMeshSecretStore> = store.clone();
        let pairwise_store: Arc<dyn SecureMeshSecretStore> = store.clone();

        with_mobile_relay_secret_store_override(mobile_store, || {
            with_pairwise_secret_store_override(pairwise_store, || {
                let mut pc_config = default_config();
                let mut mobile_config = default_config();
                pair_mobile_relay_configs(&mut pc_config, &mut mobile_config);
                let old_envelope = seal_mobile_relay_payload(
                    &mobile_config,
                    crate::core::secure_mesh_crypto::SecureMeshPayloadKind::ServiceAction,
                    &json!({"action": "old-session-before-authority-reset"}),
                )?;
                persist_config_secret_material_to_secret_store(
                    &mut mobile_config,
                    store.as_ref(),
                    MOBILE_RELAY_PLATFORM_SECRET_STORE_NAMESPACE,
                )?;
                save_config(&mut mobile_config)?;

                let replacement_signing_key = SigningKey::generate(&mut OsRng);
                let replacement = json!({
                    "operation": "prepare",
                    "confirmSecurityReset": "RESET_KEY_TRANSPARENCY_AUTHORITY",
                    "directoryScopeCommitment": sha256_hex(b"replacement-directory-scope"),
                    "pin": {
                        "logId": "replacement-user-configured-log",
                        "keyId": "replacement-user-configured-key",
                        "publicKeyHex": hex_encode_bytes(
                            replacement_signing_key.verifying_key().as_bytes()
                        ),
                        "provenance": "user-configured-external"
                    },
                    "maxSthAgeSeconds": 3600,
                    "maxFutureSkewSeconds": 300
                });
                let prepared = key_transparency_configure_authority(&replacement)?;
                assert_eq!(prepared["status"], "confirmation_required");
                let mut confirmation = replacement.clone();
                confirmation["operation"] = json!("confirm");
                confirmation["authorityChallengeId"] = prepared["authorityChallengeId"].clone();
                confirmation["confirmAuthorityConfiguration"] = json!(true);
                confirmation["allowInteraction"] = json!(true);
                let failpoint = set_kt_authority_reset_failpoint("after_guard_persisted");
                let failure = key_transparency_configure_authority(&confirmation)
                    .expect_err("crash failpoint must interrupt authority replacement");
                assert!(failure.to_string().contains("reset failpoint"));
                drop(failpoint);

                // A new process observes the persisted guard before hydrating any secret or
                // opening any Pairwise/MLS state.
                assert!(kt_authority_reset_in_progress()?);
                let _restarted_public_config = load_config_without_persistence()?;
                assert!(kt_authority_reset_in_progress()?);
                let seal_error = seal_mobile_relay_payload(
                    &mobile_config,
                    crate::core::secure_mesh_crypto::SecureMeshPayloadKind::ServiceAction,
                    &json!({"action": "must-not-seal-after-crash"}),
                )
                .unwrap_err()
                .to_string();
                assert!(seal_error.contains("security operations remain blocked"));
                let open_error = open_mobile_relay_payload(
                    &pc_config,
                    &old_envelope,
                    crate::core::secure_mesh_crypto::SecureMeshPayloadKind::ServiceAction,
                )
                .unwrap_err()
                .to_string();
                assert!(open_error.contains("security operations remain blocked"));
                let mls_error = crate::domain::secure_mesh_mls::dispatch(
                    "secure_mesh.mls.payload.seal",
                    &json!({}),
                )
                .unwrap_err()
                .to_string();
                assert!(mls_error.contains("security operations remain blocked"));
                let lifecycle_error = crate::ffi::secure_mesh_mobile_ffi::dispatch_json(
                    &json!({
                        "action": "secure_mesh.lifecycle.serviceAction",
                        "params": {}
                    }),
                    "unsupported",
                )
                .unwrap_err()
                .to_string();
                assert!(lifecycle_error.contains("security operations remain blocked"));
                let kt_route_error = crate::ffi::secure_mesh_mobile_ffi::dispatch_json(
                    &json!({
                        "action": "secure_mesh.kt.publicationRequest",
                        "params": {}
                    }),
                    "unsupported",
                )
                .unwrap_err()
                .to_string();
                assert!(kt_route_error.contains("security operations remain blocked"));
                let kt_status = crate::ffi::secure_mesh_mobile_ffi::dispatch_json(
                    &json!({
                        "action": "secure_mesh.kt.status",
                        "params": {}
                    }),
                    "unsupported",
                )?;
                assert_eq!(kt_status["resetInProgress"], true);
                assert_eq!(kt_status["guardValid"], true);

                let resumed = key_transparency_configure_authority(&confirmation)?;
                assert_eq!(resumed["authorityChanged"], true);
                assert!(!kt_authority_reset_in_progress()?);
                let stale_session_error = seal_mobile_relay_payload(
                    &mobile_config,
                    crate::core::secure_mesh_crypto::SecureMeshPayloadKind::ServiceAction,
                    &json!({"action": "must-repair-after-reset"}),
                )
                .unwrap_err()
                .to_string();
                assert!(
                    stale_session_error.contains("missing")
                        || stale_session_error.contains("re-pairing is required")
                );
                Ok(())
            })
        })
        .unwrap();

        set_portable_data_dir_override(previous);
    }

    #[test]
    fn kt_authority_confirmation_recovers_idempotently_after_config_commit_crash() {
        let dir = temp_dir("mobile-relay-kt-confirmation-post-commit-crash");
        let previous = set_portable_data_dir_override(Some(dir));
        let store = Arc::new(EphemeralSecretStore::new());
        let mobile_store: Arc<dyn SecureMeshSecretStore> = store.clone();
        let pairwise_store: Arc<dyn SecureMeshSecretStore> = store.clone();

        with_mobile_relay_secret_store_override(mobile_store, || {
            with_pairwise_secret_store_override(pairwise_store, || {
                let mut config = default_config();
                ensure_mobile_relay_endpoint_descriptor(&mut config, "desktop_sidecar")?;
                persist_config_secret_material_to_secret_store(
                    &mut config,
                    store.as_ref(),
                    MOBILE_RELAY_PLATFORM_SECRET_STORE_NAMESPACE,
                )?;
                save_config(&mut config)?;
                let replacement_signing_key = SigningKey::generate(&mut OsRng);
                let proposal = json!({
                    "operation": "prepare",
                    "confirmSecurityReset": "RESET_KEY_TRANSPARENCY_AUTHORITY",
                    "directoryScopeCommitment": sha256_hex(b"post-commit-replacement-scope"),
                    "pin": {
                        "logId": "post-commit-replacement-log",
                        "keyId": "post-commit-replacement-key",
                        "publicKeyHex": hex_encode_bytes(
                            replacement_signing_key.verifying_key().as_bytes()
                        ),
                        "provenance": "user-configured-external"
                    },
                    "maxSthAgeSeconds": 3600,
                    "maxFutureSkewSeconds": 300
                });
                let prepared = key_transparency_configure_authority(&proposal)?;
                assert_eq!(prepared["requiresSecurityReset"], true);
                let mut confirmation = proposal;
                confirmation["operation"] = json!("confirm");
                confirmation["authorityChallengeId"] = prepared["authorityChallengeId"].clone();
                confirmation["confirmAuthorityConfiguration"] = json!(true);
                confirmation["allowInteraction"] = json!(true);

                let failpoint =
                    set_kt_authority_reset_failpoint("after_replacement_config_persisted");
                let failure = key_transparency_configure_authority(&confirmation)
                    .unwrap_err()
                    .to_string();
                assert!(failure.contains("reset failpoint"));
                drop(failpoint);
                assert!(kt_authority_reset_in_progress()?);
                assert!(read_kt_authority_challenge()?.is_some());

                let recovered = key_transparency_configure_authority(&confirmation)?;
                assert_eq!(recovered["alreadyCommitted"], true);
                assert!(!kt_authority_reset_in_progress()?);
                assert!(read_kt_authority_challenge()?.is_none());
                Ok(())
            })
        })
        .unwrap();
        set_portable_data_dir_override(previous);
    }

    #[test]
    fn pairwise_product_blocks_withheld_peer_map_proof_and_expired_receipt_after_restart() {
        let dir = temp_dir("mobile-relay-kt-continuous-freshness");
        let previous = set_portable_data_dir_override(Some(dir));
        let store = Arc::new(EphemeralSecretStore::new());
        let mobile_store: Arc<dyn SecureMeshSecretStore> = store.clone();
        let pairwise_store: Arc<dyn SecureMeshSecretStore> = store.clone();

        with_mobile_relay_secret_store_override(mobile_store, || {
            with_pairwise_secret_store_override(pairwise_store, || {
                let mut pc_config = default_config();
                let mut mobile_config = default_config();
                pair_mobile_relay_configs(&mut pc_config, &mut mobile_config);
                let pending_for_mobile = seal_mobile_relay_payload(
                    &pc_config,
                    crate::core::secure_mesh_crypto::SecureMeshPayloadKind::ServiceAction,
                    &json!({"action": "pre-withholding-envelope"}),
                )?;
                let local_endpoint_id = descriptor_text(
                    mobile_config
                        .get("mobileRelayE2ee")
                        .ok_or_else(|| anyhow!("mobile test endpoint state is missing"))?,
                    "endpointId",
                )?;
                let mut authority =
                    open_mobile_relay_directory_authority(&mobile_config, &local_endpoint_id)?;
                let previous_tree_size = authority
                    .latest_checkpoint()?
                    .ok_or_else(|| anyhow!("mobile test KT checkpoint is missing"))?
                    .tree_size;
                let now = mobile_relay_trust_record_now_epoch()?;
                let mut unrelated: SecureMeshDirectoryLeafClaim = serde_json::from_value(
                    mobile_config["mobileRelayE2ee"]["keyTransparencyResponse"]["claim"].clone(),
                )?;
                unrelated.endpoint.endpoint_id = format!("unrelated-{}", Uuid::new_v4());
                unrelated.endpoint.identity_public_key = hex_encode_bytes(&[0x41; 32]);
                unrelated.endpoint.signing_public_key = hex_encode_bytes(&[0x42; 32]);
                unrelated.endpoint.fingerprint = sha256_hex(b"unrelated-directory-identity");
                unrelated.endpoint.rotation_epoch = 1;
                unrelated.endpoint.updated_at = now_iso();
                unrelated.key_material.signed_prekey_bundle_digest =
                    sha256_hex(b"unrelated-signed-prekey");
                unrelated.key_material.one_time_prekey_batch_digest =
                    sha256_hex(b"unrelated-one-time-prekey");
                unrelated.key_material.pairwise_prekey_version = 1;
                unrelated.key_material.mls_key_package_digest =
                    sha256_hex(b"unrelated-mls-key-package");
                unrelated.key_material.mls_key_package_version = 1;
                unrelated.directory_version = 1;
                let gossip = with_mobile_relay_test_kt_log(|log| {
                    let index = log.append_hashed_directory_leaf(
                        &unrelated.stable_label(),
                        unrelated.version(),
                        unrelated.revoked(),
                        unrelated.leaf_hash()?,
                    )?;
                    let inclusion = log.inclusion_proof_at(index, now)?;
                    Ok(
                        crate::core::secure_mesh_transparency::SecureMeshKtGossipPayload::from_sth(
                            inclusion.signed_tree_head,
                            Some(log.consistency_proof_at(previous_tree_size, now)?),
                        ),
                    )
                })?;
                authority.observe_gossip(&gossip, now)?;
                drop(authority);

                let withheld_seal = seal_mobile_relay_payload(
                    &mobile_config,
                    crate::core::secure_mesh_crypto::SecureMeshPayloadKind::ServiceAction,
                    &json!({"action": "must-refresh-peer-map"}),
                )
                .unwrap_err()
                .to_string();
                assert!(withheld_seal.contains("current accepted checkpoint"));
                let withheld_open = open_mobile_relay_payload(
                    &mobile_config,
                    &pending_for_mobile,
                    crate::core::secure_mesh_crypto::SecureMeshPayloadKind::ServiceAction,
                )
                .unwrap_err()
                .to_string();
                assert!(withheld_open.contains("current accepted checkpoint"));

                let pc_descriptor =
                    ensure_mobile_relay_endpoint_descriptor(&mut pc_config, "desktop_sidecar")?;
                apply_peer_secure_mesh_descriptor(&mut mobile_config, &pc_descriptor, true)?;
                ensure_mobile_relay_key_transparency(&mut mobile_config)?;
                let refreshed = require_current_pairwise_directory_authority(&mobile_config, now)?;
                assert!(refreshed.tree_size > previous_tree_size);
                let opened = open_mobile_relay_payload(
                    &mobile_config,
                    &pending_for_mobile,
                    crate::core::secure_mesh_crypto::SecureMeshPayloadKind::ServiceAction,
                )?;
                assert_eq!(
                    serde_json::from_slice::<Value>(&opened)?["action"],
                    "pre-withholding-envelope"
                );

                persist_config_secret_material_to_secret_store(
                    &mut mobile_config,
                    store.as_ref(),
                    MOBILE_RELAY_PLATFORM_SECRET_STORE_NAMESPACE,
                )?;
                save_config(&mut mobile_config)?;
                let future = refreshed.expires_at_epoch_seconds.saturating_add(1);
                let future_clock = set_kt_freshness_now_override(future);
                let (restarted_config, _) = load_config_with_runtime_secret_overrides(&json!({}))?;
                let expired = seal_mobile_relay_payload(
                    &restarted_config,
                    crate::core::secure_mesh_crypto::SecureMeshPayloadKind::ServiceAction,
                    &json!({"action": "must-refresh-after-expiry"}),
                )
                .unwrap_err()
                .to_string();
                assert!(!expired.is_empty());
                let status = e2ee_status(&json!({}))?;
                assert_eq!(status["keyTransparencyFresh"], false);
                assert!(status["blockers"].as_array().is_some_and(|values| {
                    values
                        .iter()
                        .any(|value| value == "key_transparency_label_refresh_required")
                }));
                drop(future_clock);
                Ok(())
            })
        })
        .unwrap();

        set_portable_data_dir_override(previous);
    }

    #[test]
    fn kt_gossip_action_is_pairwise_encrypted_and_advances_both_endpoint_authorities() {
        let dir = temp_dir("mobile-relay-kt-encrypted-gossip");
        let previous = set_portable_data_dir_override(Some(dir));
        let store = Arc::new(EphemeralSecretStore::new());
        let mobile_store: Arc<dyn SecureMeshSecretStore> = store.clone();
        let pairwise_store: Arc<dyn SecureMeshSecretStore> = store.clone();

        with_mobile_relay_secret_store_override(mobile_store, || {
            with_pairwise_secret_store_override(pairwise_store, || {
                let mut pc_config = default_config();
                let mut mobile_config = default_config();
                pair_mobile_relay_configs(&mut pc_config, &mut mobile_config);
                let mobile_endpoint_id = descriptor_text(
                    mobile_config
                        .get("mobileRelayE2ee")
                        .ok_or_else(|| anyhow!("mobile gossip endpoint state is missing"))?,
                    "endpointId",
                )?;
                let pc_endpoint_id = descriptor_text(
                    pc_config
                        .get("mobileRelayE2ee")
                        .ok_or_else(|| anyhow!("desktop gossip endpoint state is missing"))?,
                    "endpointId",
                )?;
                let mobile_authority =
                    open_mobile_relay_directory_authority(&mobile_config, &mobile_endpoint_id)?;
                let mobile_previous_tree_size = mobile_authority
                    .latest_checkpoint()?
                    .ok_or_else(|| anyhow!("mobile gossip checkpoint is missing"))?
                    .tree_size;
                drop(mobile_authority);
                let pc_authority =
                    open_mobile_relay_directory_authority(&pc_config, &pc_endpoint_id)?;
                let pc_previous_tree_size = pc_authority
                    .latest_checkpoint()?
                    .ok_or_else(|| anyhow!("desktop gossip checkpoint is missing"))?
                    .tree_size;
                drop(pc_authority);
                let now = mobile_relay_trust_record_now_epoch()?;
                let mut unrelated: SecureMeshDirectoryLeafClaim = serde_json::from_value(
                    pc_config["mobileRelayE2ee"]["keyTransparencyResponse"]["claim"].clone(),
                )?;
                unrelated.endpoint.endpoint_id = format!("gossip-{}", Uuid::new_v4());
                unrelated.endpoint.identity_public_key = hex_encode_bytes(&[0x51; 32]);
                unrelated.endpoint.signing_public_key = hex_encode_bytes(&[0x52; 32]);
                unrelated.endpoint.fingerprint = sha256_hex(b"encrypted-gossip-identity");
                unrelated.endpoint.updated_at = now_iso();
                unrelated.key_material.signed_prekey_bundle_digest =
                    sha256_hex(b"encrypted-gossip-signed-prekey");
                unrelated.key_material.one_time_prekey_batch_digest =
                    sha256_hex(b"encrypted-gossip-one-time-prekey");
                unrelated.key_material.mls_key_package_digest =
                    sha256_hex(b"encrypted-gossip-mls-key-package");
                let signed_tree_head = with_mobile_relay_test_kt_log(|log| {
                    let index = log.append_hashed_directory_leaf(
                        &unrelated.stable_label(),
                        unrelated.version(),
                        unrelated.revoked(),
                        unrelated.leaf_hash()?,
                    )?;
                    Ok(log.inclusion_proof_at(index, now)?.signed_tree_head)
                })?;

                // External directory/witness transport remains outside this client-owned
                // algorithm test. Model each endpoint independently accepting the same
                // authenticated transition, then gossip only the already accepted current
                // checkpoint. The current-checkpoint message deliberately carries no transition
                // proof and remains bound to the exact v7 issued-at value.
                for (config, endpoint_id, previous_tree_size) in [
                    (
                        &mobile_config,
                        mobile_endpoint_id.as_str(),
                        mobile_previous_tree_size,
                    ),
                    (&pc_config, pc_endpoint_id.as_str(), pc_previous_tree_size),
                ] {
                    let transition = with_mobile_relay_test_kt_log(|log| {
                        Ok(SecureMeshKtGossipPayload::from_sth(
                            signed_tree_head.clone(),
                            (previous_tree_size < signed_tree_head.tree_size)
                                .then(|| log.consistency_proof_at(previous_tree_size, now))
                                .transpose()?,
                        ))
                    })?;
                    let mut authority = open_mobile_relay_directory_authority(config, endpoint_id)?;
                    let accepted = authority.observe_gossip(&transition, now)?;
                    assert_eq!(accepted.tree_size, signed_tree_head.tree_size);
                    assert_eq!(accepted.root_hash, signed_tree_head.root_hash);
                    assert_eq!(accepted.map_root_hash, signed_tree_head.map_root_hash);
                    assert_eq!(
                        accepted.issued_at_epoch_seconds,
                        signed_tree_head.issued_at_epoch_seconds
                    );
                }
                let gossip = SecureMeshKtGossipPayload::from_sth(signed_tree_head, None);
                assert!(gossip.consistency_proof.is_none());

                persist_config_secret_material_to_secret_store(
                    &mut mobile_config,
                    store.as_ref(),
                    MOBILE_RELAY_PLATFORM_SECRET_STORE_NAMESPACE,
                )?;
                save_config(&mut mobile_config)?;
                let sealed = dispatch_key_transparency_action(
                    "secure_mesh.kt.gossip",
                    &json!({
                        "operation": "seal",
                        "gossip": gossip,
                        "allowInteraction": true
                    }),
                )?;
                let envelope = sealed["envelope"].clone();
                let wire = serde_json::to_string(&envelope)?;
                for forbidden in [
                    SECURE_MESH_KT_GOSSIP_CONTROL_TYPE,
                    gossip.signed_tree_head.root_hash.as_str(),
                    gossip.signed_tree_head.map_root_hash.as_str(),
                    gossip.signed_tree_head.signature.as_str(),
                ] {
                    assert!(!wire.contains(forbidden));
                }

                persist_config_secret_material_to_secret_store(
                    &mut pc_config,
                    store.as_ref(),
                    MOBILE_RELAY_PLATFORM_SECRET_STORE_NAMESPACE,
                )?;
                let durable_generation = load_config_without_persistence()?;
                pc_config[CONFIG_GENERATION_FIELD] =
                    durable_generation[CONFIG_GENERATION_FIELD].clone();
                pc_config[AUTHORITY_GENERATION_FIELD] =
                    durable_generation[AUTHORITY_GENERATION_FIELD].clone();
                save_config(&mut pc_config)?;
                let opened = dispatch_key_transparency_action(
                    "secure_mesh.kt.gossip",
                    &json!({
                        "operation": "open",
                        "envelope": envelope,
                        "allowInteraction": true
                    }),
                )?;
                assert_eq!(opened["treeSize"], sealed["treeSize"]);
                assert_eq!(opened["bodyRedacted"], true);
                assert!(opened.get("gossip").is_none());
                Ok(())
            })
        })
        .unwrap();

        set_portable_data_dir_override(previous);
    }

    fn secure_envelope_fixture() -> Value {
        let ciphertext = vec![9u8; 32];
        let header = vec![
                7u8;
                crate::core::secure_mesh_relay_envelope::SECURE_MESH_ENCRYPTED_HEADER_BUCKET_BYTES
            ];
        json!({
            "schema": crate::core::secure_mesh_relay_envelope::SECURE_MESH_RELAY_ENVELOPE_SCHEMA,
            "deliveryId": general_purpose::URL_SAFE_NO_PAD.encode(vec![1u8; 24]),
            "mailboxToken": general_purpose::URL_SAFE_NO_PAD.encode(vec![2u8; 32]),
            "encryptedHeader": general_purpose::URL_SAFE_NO_PAD.encode(&header),
            "ciphertextBucket": 256u64,
            "ciphertext": general_purpose::URL_SAFE_NO_PAD.encode(pad_to_bucket(&ciphertext, 256)),
        })
    }

    fn pad_to_bucket(data: &[u8], bucket: usize) -> Vec<u8> {
        let mut padded = Vec::with_capacity(bucket);
        padded.extend_from_slice(data);
        padded.resize(bucket, 0);
        padded
    }

    fn append_test_directory_state(descriptor: &mut Value, directory_state: &str) -> Result<()> {
        ensure!(
            matches!(directory_state, "active" | "revoked"),
            "test directory state is unsupported"
        );
        let response_value = descriptor
            .get("preKeyBundle")
            .and_then(|bundle| bundle.get("keyTransparency"))
            .cloned()
            .ok_or_else(|| anyhow!("test descriptor KT response is missing"))?;
        let mut response: UntrustedDirectoryResponse = serde_json::from_value(response_value)?;
        let previous_tree_size = response.inclusion.signed_tree_head.tree_size;
        response.claim.endpoint.directory_state = directory_state.to_string();
        response.claim.endpoint.updated_at = now_iso();
        response.claim.directory_version = response
            .claim
            .directory_version
            .checked_add(1)
            .ok_or_else(|| anyhow!("test directory version overflow"))?;
        let now_epoch_seconds = mobile_relay_trust_record_now_epoch()?;
        response = with_mobile_relay_test_kt_log(|log| {
            let index = log.append_hashed_directory_leaf(
                &response.claim.stable_label(),
                response.claim.version(),
                response.claim.revoked(),
                response.claim.leaf_hash()?,
            )?;
            Ok(UntrustedDirectoryResponse {
                claim: response.claim.clone(),
                inclusion: log.inclusion_proof_at(index, now_epoch_seconds)?,
                latest_map: log.map_proof_at(&response.claim.stable_label(), now_epoch_seconds)?,
                consistency: (previous_tree_size < log.tree_size())
                    .then(|| log.consistency_proof_at(previous_tree_size, now_epoch_seconds))
                    .transpose()?,
            })
        })?;
        descriptor["preKeyBundle"]["keyTransparency"] = serde_json::to_value(response)?;
        Ok(())
    }

    fn pair_mobile_relay_configs(pc_config: &mut Value, mobile_config: &mut Value) {
        let shared_delivery_secret = random_base64url(MOBILE_RELAY_KEY_BYTES);
        pc_config["mobileRelayE2ee"]["pairingSecretBase64url"] =
            json!(shared_delivery_secret.clone());
        mobile_config["mobileRelayE2ee"]["pairingSecretBase64url"] = json!(shared_delivery_secret);
        let pc_descriptor =
            ensure_mobile_relay_endpoint_descriptor(pc_config, "desktop_sidecar").unwrap();
        ensure_mobile_relay_endpoint_descriptor(mobile_config, "mobile").unwrap();
        apply_peer_secure_mesh_descriptor(mobile_config, &pc_descriptor, true).unwrap();
        let mobile_descriptor =
            ensure_mobile_relay_endpoint_descriptor(mobile_config, "mobile").unwrap();
        apply_peer_secure_mesh_descriptor(pc_config, &mobile_descriptor, true).unwrap();
        let pc_accepted_descriptor =
            ensure_mobile_relay_endpoint_descriptor(pc_config, "desktop_sidecar").unwrap();
        apply_peer_secure_mesh_descriptor(mobile_config, &pc_accepted_descriptor, true).unwrap();
        let mobile_finished_descriptor =
            ensure_mobile_relay_endpoint_descriptor(mobile_config, "mobile").unwrap();
        assert!(mobile_finished_descriptor["pairwiseFinished"].is_object());
        apply_peer_secure_mesh_descriptor(pc_config, &mobile_finished_descriptor, true).unwrap();
        let protected_payload = seal_mobile_relay_payload(
            mobile_config,
            crate::core::secure_mesh_crypto::SecureMeshPayloadKind::ServiceAction,
            &json!({"action": "pairwise_finished_confirmed"}),
        )
        .unwrap();
        let opened = open_mobile_relay_payload(
            pc_config,
            &protected_payload,
            crate::core::secure_mesh_crypto::SecureMeshPayloadKind::ServiceAction,
        )
        .unwrap();
        assert_eq!(
            serde_json::from_slice::<Value>(&opened).unwrap()["action"],
            "pairwise_finished_confirmed"
        );
    }

    fn paired_command_envelope_fixture() -> (Value, Value, Value) {
        let mut pc_config = default_config();
        let mut mobile_config = default_config();
        pair_mobile_relay_configs(&mut pc_config, &mut mobile_config);
        let mobile_endpoint = local_endpoint_state(&mobile_config).unwrap();
        let pc_endpoint = local_endpoint_state(&pc_config).unwrap();
        let command_payload = json!({
            "schema": crate::core::secure_mesh::SECURE_MESH_COMMAND_PROTOCOL_VERSION,
            "commandId": "cmd_mobile_relay_replay_fixture",
            "commandKind": "client.activity.sync",
            "senderIdentity": {
                "endpointId": mobile_endpoint.endpoint_id,
                "identityFingerprint": mobile_endpoint.fingerprint,
                "trustState": "verified",
                "endpointKind": mobile_endpoint.endpoint_kind
            },
            "targetBinding": {
                "targetEndpointId": pc_endpoint.endpoint_id,
                "targetAgentId": null,
                "workspaceId": "default"
            },
            "riskClass": "read_only",
            "requiresUserConfirmation": false,
            "idempotencyKey": "idem_mobile_relay_replay_fixture",
            "createdAt": now_iso(),
            "expiresAt": timestamp_after_seconds(MOBILE_RELAY_COMMAND_TTL_SECONDS).unwrap(),
            "body": {
                "limit": 1
            }
        });
        let envelope = seal_mobile_relay_payload(
            &mobile_config,
            crate::core::secure_mesh_crypto::SecureMeshPayloadKind::Command,
            &command_payload,
        )
        .unwrap();
        (pc_config, mobile_config, envelope)
    }

    #[test]
    fn mobile_relay_commands_sync_reuses_single_operation_auth_batch_for_secure_commands() {
        let dir = temp_dir("mobile-relay-commands-sync-single-operation-auth-batch");
        let previous = set_portable_data_dir_override(Some(dir));
        let secret_store = Arc::new(EphemeralSecretStore::new());
        let mobile_store_override: Arc<dyn SecureMeshSecretStore> = secret_store.clone();
        let pairwise_store_override: Arc<dyn SecureMeshSecretStore> = secret_store.clone();

        with_mobile_relay_secret_store_override(mobile_store_override, || {
            with_pairwise_secret_store_override(pairwise_store_override, || {
                let mut pc_config = default_config();
                let mut mobile_config = default_config();
                pair_mobile_relay_configs(&mut pc_config, &mut mobile_config);
                let mut envelopes = Vec::new();
                for index in 0..2 {
                    let payload = secure_command_payload(
                        &mobile_config,
                        "client.activity.sync",
                        None,
                        "default",
                        json!({
                            "limit": index + 1
                        }),
                    )?;
                    envelopes.push(seal_mobile_relay_payload(
                        &mobile_config,
                        crate::core::secure_mesh_crypto::SecureMeshPayloadKind::Command,
                        &payload,
                    )?);
                }
                let gateway = CanonicalRelayGateway::start(7, envelopes);
                pc_config["pairingId"] = json!("pair_commands_sync_single_auth_batch");
                pc_config["pcToken"] = json!("pc-token-commands-sync-single-auth");
                pc_config["useCustomGateway"] = json!(true);
                pc_config["customGatewayUrl"] = json!(gateway.url());
                persist_config_secret_material_to_secret_store(
                    &mut pc_config,
                    secret_store.as_ref(),
                    MOBILE_RELAY_PLATFORM_SECRET_STORE_NAMESPACE,
                )?;
                save_config(&mut pc_config)?;
                let baseline_session_count = secret_store.authorization_session_count();

                let output = commands_sync(&with_canonical_relay_params(json!({
                    "targets": [],
                    "limit": 2,
                    "allowInteraction": false
                })))?;

                assert_eq!(output["ok"], true);
                let completed = output["completed"].as_array().unwrap();
                assert_eq!(completed.len(), 2);
                assert!(completed.iter().all(|command| command["ok"] == true));
                assert_eq!(
                    secret_store.authorization_session_count(),
                    baseline_session_count + 1
                );
                assert_eq!(
                    secret_store.authorization_session_reasons()[baseline_session_count],
                    "Mobile Relay commands sync operation authorization batch"
                );
                assert!(
                    !secret_store.authorization_session_allow_interactions()
                        [baseline_session_count]
                );
                gateway.assert_operations(&[
                    SecureClientRelayOperation::EndpointChallenge,
                    SecureClientRelayOperation::EndpointRegister,
                    SecureClientRelayOperation::EnvelopeSync,
                    SecureClientRelayOperation::EnvelopeSend,
                    SecureClientRelayOperation::EnvelopeAck,
                    SecureClientRelayOperation::EnvelopeSend,
                    SecureClientRelayOperation::EnvelopeAck,
                ]);
                gateway.join();
                Ok(())
            })
        })
        .unwrap();

        set_portable_data_dir_override(previous);
    }

    #[test]
    fn mobile_relay_secure_command_execute_reuses_single_operation_auth_batch_for_open_and_result_seal()
     {
        let dir = temp_dir("mobile-relay-secure-command-single-operation-auth-batch");
        let previous = set_portable_data_dir_override(Some(dir));
        let secret_store = Arc::new(EphemeralSecretStore::new());
        let store_override: Arc<dyn SecureMeshSecretStore> = secret_store.clone();

        with_pairwise_secret_store_override(store_override, || {
            let (mut pc_config, mobile_config, envelope) = paired_command_envelope_fixture();
            save_config(&mut pc_config).unwrap();
            let baseline_session_count = secret_store.authorization_session_count();

            let result_envelope = execute_secure_envelope_command(
                &json!({
                    "type": SECURE_MESH_ENVELOPE_COMMAND,
                    "envelope": envelope
                }),
                &json!({}),
            )?;

            assert_eq!(
                secret_store.authorization_session_count(),
                baseline_session_count + 1
            );
            assert_eq!(
                secret_store.authorization_session_reasons()[baseline_session_count],
                "Mobile Relay secure command operation authorization batch"
            );
            assert_eq!(
                secret_store.authorization_session_operation_counts()[baseline_session_count],
                5
            );
            let result = opened_result_payload(&mobile_config, &result_envelope);
            assert_eq!(result["evaluation"]["code"], "execute");
            assert_eq!(result["execution"]["outcome"], "result");
            Ok(())
        })
        .unwrap();

        set_portable_data_dir_override(previous);
    }

    #[test]
    fn mobile_relay_pairwise_payload_roundtrip_reuses_single_authorization_batch_per_operation() {
        let dir = temp_dir("mobile-relay-pairwise-payload-single-auth-batch");
        let previous = set_portable_data_dir_override(Some(dir));
        let secret_store = Arc::new(EphemeralSecretStore::new());
        let store_override: Arc<dyn SecureMeshSecretStore> = secret_store.clone();

        with_pairwise_secret_store_override(store_override, || {
            let mut pc_config = default_config();
            let mut mobile_config = default_config();
            pair_mobile_relay_configs(&mut pc_config, &mut mobile_config);
            let baseline_session_count = secret_store.authorization_session_count();
            let payload = json!({
                "schema": crate::core::secure_mesh::SECURE_MESH_COMMAND_PROTOCOL_VERSION,
                "commandId": "cmd_pairwise_single_auth_batch",
                "commandKind": "client.activity.sync",
                "body": {
                    "limit": 1
                }
            });

            let envelope = seal_mobile_relay_payload(
                &mobile_config,
                crate::core::secure_mesh_crypto::SecureMeshPayloadKind::Command,
                &payload,
            )?;

            assert_eq!(
                secret_store.authorization_session_count(),
                baseline_session_count + 1
            );
            assert_eq!(
                secret_store.authorization_session_reasons()[baseline_session_count],
                "Mobile Relay pairwise payload authorization batch"
            );
            assert_eq!(
                secret_store.authorization_session_operation_counts()[baseline_session_count],
                3
            );

            let opened = open_mobile_relay_payload(
                &pc_config,
                &envelope,
                crate::core::secure_mesh_crypto::SecureMeshPayloadKind::Command,
            )?;
            let opened_payload = serde_json::from_slice::<Value>(&opened).unwrap();

            assert_eq!(
                opened_payload["commandId"],
                "cmd_pairwise_single_auth_batch"
            );
            assert_eq!(
                secret_store.authorization_session_count(),
                baseline_session_count + 2
            );
            assert_eq!(
                secret_store.authorization_session_reasons()[baseline_session_count + 1],
                "Mobile Relay pairwise payload authorization batch"
            );
            assert_eq!(
                secret_store.authorization_session_operation_counts()[baseline_session_count + 1],
                3
            );
            Ok(())
        })
        .unwrap();

        set_portable_data_dir_override(previous);
    }

    fn opened_result_payload(mobile_config: &Value, envelope: &Value) -> Value {
        let opened = open_mobile_relay_payload(
            mobile_config,
            envelope,
            crate::core::secure_mesh_crypto::SecureMeshPayloadKind::ResultPayload,
        )
        .unwrap();
        serde_json::from_slice::<Value>(&opened).unwrap()
    }

    fn temp_dir(name: &str) -> PathBuf {
        let dir = env::temp_dir().join(format!("lico-client-{}-{}", name, Uuid::new_v4()));
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[derive(Clone, Debug)]
    struct CapturedHttpRequest {
        path: String,
        body: String,
    }

    struct CanonicalRelayGateway {
        address: String,
        captured: Arc<Mutex<Vec<CapturedHttpRequest>>>,
        handle: thread::JoinHandle<()>,
    }

    impl CanonicalRelayGateway {
        fn start(expected_requests: usize, sync_envelopes: Vec<Value>) -> Self {
            Self::start_with(expected_requests, move |request| {
                canonical_relay_response(request, &sync_envelopes)
            })
        }

        fn start_with<F>(expected_requests: usize, responder: F) -> Self
        where
            F: Fn(&CapturedHttpRequest) -> Value + Send + 'static,
        {
            let listener = TcpListener::bind("127.0.0.1:0").unwrap();
            let address = listener.local_addr().unwrap().to_string();
            let captured = Arc::new(Mutex::new(Vec::<CapturedHttpRequest>::new()));
            let thread_captured = Arc::clone(&captured);
            let handle = thread::spawn(move || {
                for stream in listener.incoming().take(expected_requests) {
                    let mut stream = stream.unwrap();
                    let request = read_http_request(&mut stream);
                    let response = responder(&request);
                    thread_captured.lock().unwrap().push(request);
                    write_http_json_response(&mut stream, &response);
                }
            });
            Self {
                address,
                captured,
                handle,
            }
        }

        fn url(&self) -> String {
            format!("http://{}", self.address)
        }

        fn request_body(&self, index: usize) -> String {
            self.captured
                .lock()
                .unwrap()
                .get(index)
                .map(|request| request.body.clone())
                .unwrap_or_default()
        }

        fn request_paths(&self) -> Vec<String> {
            self.captured
                .lock()
                .unwrap()
                .iter()
                .map(|request| request.path.clone())
                .collect()
        }

        fn assert_operations(&self, operations: &[SecureClientRelayOperation]) {
            assert_eq!(
                self.request_paths(),
                operations
                    .iter()
                    .map(|operation| operation.path().to_string())
                    .collect::<Vec<_>>()
            );
        }

        fn join(self) {
            self.handle.join().unwrap();
        }
    }

    fn read_http_request(stream: &mut TcpStream) -> CapturedHttpRequest {
        let mut reader = BufReader::new(stream.try_clone().unwrap());
        let mut request_line = String::new();
        reader.read_line(&mut request_line).unwrap();
        let path = request_line
            .split_whitespace()
            .nth(1)
            .unwrap_or("/")
            .to_string();
        let mut content_length = 0usize;
        loop {
            let mut line = String::new();
            reader.read_line(&mut line).unwrap();
            let trimmed = line.trim_end();
            if trimmed.is_empty() {
                break;
            }
            if let Some((name, value)) = trimmed.split_once(':') {
                if name.eq_ignore_ascii_case("content-length") {
                    content_length = value.trim().parse::<usize>().unwrap_or(0);
                }
            }
        }
        let mut body = vec![0u8; content_length];
        reader.read_exact(&mut body).unwrap();
        CapturedHttpRequest {
            path,
            body: String::from_utf8(body).unwrap(),
        }
    }

    fn with_canonical_relay_params(mut params: Value) -> Value {
        params["relaySessionToken"] = json!("test-session-token");
        params["relayCsrfToken"] = json!("test-csrf-token");
        params["relayTenantId"] = json!("tenant-test");
        params["relayAccountId"] = json!("account-test");
        params
    }

    fn captured_body(request: &CapturedHttpRequest) -> Value {
        serde_json::from_str(&request.body).unwrap()
    }

    fn canonical_relay_response(request: &CapturedHttpRequest, sync_envelopes: &[Value]) -> Value {
        match request.path.as_str() {
            path if path == SecureClientRelayOperation::EndpointChallenge.path() => {
                canonical_challenge_response(request)
            }
            path if path == SecureClientRelayOperation::EndpointRegister.path() => {
                canonical_register_response(request)
            }
            path if path == SecureClientRelayOperation::EnvelopeSend.path() => {
                canonical_send_response(request)
            }
            path if path == SecureClientRelayOperation::EnvelopeSync.path() => {
                canonical_sync_response(request, sync_envelopes)
            }
            path if path == SecureClientRelayOperation::EnvelopeAck.path() => {
                canonical_ack_response(request)
            }
            _ => panic!("unexpected non-canonical relay operation"),
        }
    }

    fn canonical_challenge_response(request: &CapturedHttpRequest) -> Value {
        let body = captured_body(request);
        let challenge_id = "challenge-test";
        let challenge = format!(
            "{}:{challenge_id}:{}:{}:{}:2026-01-01T00:00:00Z",
            crate::platform::secure_client_relay_transport::SECURE_CLIENT_RELAY_PROTOCOL_VERSION,
            body["tenantId"].as_str().unwrap(),
            body["accountId"].as_str().unwrap(),
            body["endpointId"].as_str().unwrap(),
        );
        json!({
            "ok": true,
            "schemaVersion": "licolite.secure-mesh.store-schema.v2",
            "protocolVersion": "licolite.secure-mesh.device-trust.v2",
            "challengeId": challenge_id,
            "challenge": challenge,
            "challengeEncoding": "utf-8",
            "signatureAlgorithm": "Ed25519",
            "expiresAt": "2026-01-01T00:05:00Z"
        })
    }

    fn canonical_register_response(request: &CapturedHttpRequest) -> Value {
        let body = captured_body(request);
        let endpoint_id = body["endpointId"].as_str().unwrap_or("endpoint-test");
        json!({
            "ok": true,
            "schemaVersion": "licolite.secure-mesh.store-schema.v2",
            "protocolVersion": "licolite.secure-mesh.device-trust.v2",
            "endpoint": {
                "tenantId": body["tenantId"],
                "accountId": body["accountId"],
                "workspaceId": body.get("workspaceId").cloned().unwrap_or_else(|| json!("")),
                "endpointId": endpoint_id,
                "endpointKind": body["endpointKind"],
                "mailboxToken": body["mailboxToken"],
                "identityPublicKey": body["identityPublicKey"],
                "signingPublicKey": body["signingPublicKey"],
                "fingerprint": sha256_hex(endpoint_id.as_bytes()),
                "rotationEpoch": body.get("rotationEpoch").cloned().unwrap_or_else(|| json!(0)),
                "createdAt": "2026-01-01T00:00:00Z",
                "updatedAt": "2026-01-01T00:00:00Z",
                "revokedAt": ""
            }
        })
    }

    fn canonical_public_mailbox(request: &Value, mailbox_token: &str) -> Value {
        json!({
            "tenantId": request["tenantId"],
            "accountId": request["accountId"],
            "workspaceId": request.get("workspaceId").cloned().unwrap_or_else(|| json!("")),
            "endpointId": "endpoint-test",
            "mailboxToken": mailbox_token,
            "queueBytes": 0,
            "queuedCount": 0,
            "oldestQueuedAt": "",
            "deliverySequence": 1,
            "receiptCount": 0,
            "ackedCount": 0,
            "updatedAt": "2026-01-01T00:00:00Z"
        })
    }

    fn canonical_send_response(request: &CapturedHttpRequest) -> Value {
        let body = captured_body(request);
        let envelope = &body["envelope"];
        let mailbox_token = envelope["mailboxToken"].as_str().unwrap();
        json!({
            "ok": true,
            "schemaVersion": "licolite.secure-mesh.store-schema.v2",
            "protocolVersion": "licolite.secure-mesh.delivery.v1",
            "queued": {
                "deliverySequence": 1,
                "queuedAt": "2026-01-01T00:00:00Z",
                "transport": body.get("transport").cloned().unwrap_or_else(|| json!("mobile_relay")),
                "envelope": {
                    "schema": envelope["schema"],
                    "deliveryId": envelope["deliveryId"],
                    "mailboxToken": envelope["mailboxToken"],
                    "ciphertextBucket": envelope["ciphertextBucket"]
                },
                "opaqueSequenceLabelHash": "",
                "opaqueSequenceLabelPresent": body.get("opaqueSequenceLabel").is_some(),
                "mailbox": canonical_public_mailbox(&body, mailbox_token),
                "metadataOnly": true
            },
            "persisted": true,
            "queueMode": "offline_queue"
        })
    }

    fn canonical_leased_envelope(envelope: &Value, mailbox_token: &str, index: usize) -> Value {
        let sequence = u64::try_from(index).unwrap().saturating_add(1);
        json!({
            "schema": envelope["schema"],
            "deliveryId": envelope["deliveryId"],
            "mailboxToken": mailbox_token,
            "encryptedHeader": envelope["encryptedHeader"],
            "ciphertextBucket": envelope["ciphertextBucket"],
            "ciphertext": envelope["ciphertext"],
            "deliverySequence": sequence,
            "queuedAt": "2026-01-01T00:00:00Z",
            "transport": "mobile_relay",
            "deliveryAttempts": 1,
            "leaseId": format!("lease-test-{sequence}"),
            "leaseGeneration": 1,
            "leasedAt": "2026-01-01T00:00:01Z",
            "leaseExpiresAt": "2026-01-01T00:00:31Z",
            "opaqueSequenceLabelHash": "",
            "opaqueSequenceLabelPresent": false
        })
    }

    fn canonical_sync_response(request: &CapturedHttpRequest, envelopes: &[Value]) -> Value {
        let body = captured_body(request);
        let mailbox_token = body["mailboxToken"].as_str().unwrap();
        let leased = envelopes
            .iter()
            .enumerate()
            .map(|(index, envelope)| canonical_leased_envelope(envelope, mailbox_token, index))
            .collect::<Vec<_>>();
        let high_watermark = u64::try_from(leased.len()).unwrap();
        json!({
            "ok": true,
            "schemaVersion": "licolite.secure-mesh.store-schema.v2",
            "protocolVersion": "licolite.secure-mesh.delivery.v1",
            "queueMode": "offline_queue",
            "mailbox": canonical_public_mailbox(&body, mailbox_token),
            "cursor": {
                "afterDeliverySequence": body.get("afterDeliverySequence").and_then(Value::as_u64).unwrap_or(0),
                "nextDeliverySequence": high_watermark,
                "highWatermark": high_watermark,
                "hasMore": false
            },
            "gapRanges": [],
            "envelopes": leased
        })
    }

    fn canonical_ack_response(request: &CapturedHttpRequest) -> Value {
        let body = captured_body(request);
        let delivery_id = body["deliveryId"].as_str().unwrap();
        let mailbox_token = body["mailboxToken"].as_str().unwrap();
        json!({
            "ok": true,
            "schemaVersion": "licolite.secure-mesh.store-schema.v2",
            "protocolVersion": "licolite.secure-mesh.delivery.v1",
            "ack": {
                "deliveryId": delivery_id,
                "idempotent": false,
                "ackedAt": "2026-01-01T00:00:02Z",
                "purged": true
            },
            "receipt": {
                "deliveryId": delivery_id,
                "deliverySequence": 1,
                "receiptType": "ack",
                "acknowledgedAt": "2026-01-01T00:00:02Z",
                "purged": true
            },
            "mailbox": canonical_public_mailbox(&body, mailbox_token)
        })
    }

    fn write_http_json_response(stream: &mut TcpStream, body: &Value) {
        let serialized = serde_json::to_string(body).unwrap();
        write!(
            stream,
            "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{}",
            serialized.len(),
            serialized
        )
        .unwrap();
    }
}
