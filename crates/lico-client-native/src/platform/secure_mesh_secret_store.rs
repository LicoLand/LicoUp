use crate::core::secure_mesh_capability::{
    CapabilityEvaluation, CapabilityEvaluationReport, CapabilityEvidenceKind, CapabilityFact,
    CapabilityFactState, CustodyRestartSemantics, SecretCustodyStrategy, SecurityCapability,
    capability_catalog, mandatory_protocol_facts,
};
use anyhow::{Result, anyhow, ensure};
use serde::Serialize;
use std::collections::HashMap;
use std::sync::{
    Arc, Mutex,
    atomic::{AtomicUsize, Ordering},
};
use uuid::Uuid;
use zeroize::Zeroizing;

pub const NATIVE_SECRET_STORE_BACKEND_UNSUPPORTED: &str =
    "native_platform_secret_store_unsupported";

#[cfg(target_os = "macos")]
const NATIVE_SECRET_STORE_BACKEND: &str = "macos-keychain";
#[cfg(target_os = "linux")]
const NATIVE_SECRET_STORE_BACKEND: &str = "linux-secret-service-keyring";
#[cfg(target_os = "windows")]
const NATIVE_SECRET_STORE_BACKEND: &str = "windows-credential-manager";
#[cfg(not(any(target_os = "macos", target_os = "linux", target_os = "windows")))]
const NATIVE_SECRET_STORE_BACKEND: &str = NATIVE_SECRET_STORE_BACKEND_UNSUPPORTED;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SecretStoreHandle {
    namespace: String,
    key: String,
}

#[cfg(target_os = "macos")]
#[doc(hidden)]
pub fn set_macos_test_user_presence_disabled(disabled: bool) -> bool {
    macos_user_presence::set_test_user_presence_disabled(disabled)
}

#[derive(Debug)]
pub struct SecretClassPersistenceProof {
    pub backend: &'static str,
    pub secret_classes: Vec<String>,
    pub requested_class_count: usize,
    pub persisted_class_count: usize,
    pub deleted_class_count: usize,
    pub all_classes_persisted: bool,
    pub all_classes_deleted: bool,
    pub raw_secret_material_included: bool,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SecretStoreAuthorizationRequest {
    reason: String,
    operation_count: usize,
    allow_interaction: bool,
}

impl SecretStoreAuthorizationRequest {
    pub fn new(reason: impl Into<String>, operation_count: usize) -> Self {
        Self {
            reason: reason.into(),
            operation_count,
            allow_interaction: true,
        }
    }

    pub fn noninteractive(reason: impl Into<String>, operation_count: usize) -> Self {
        Self {
            reason: reason.into(),
            operation_count,
            allow_interaction: false,
        }
    }

    pub fn reason(&self) -> &str {
        &self.reason
    }

    pub fn operation_count(&self) -> usize {
        self.operation_count
    }

    pub fn allow_interaction(&self) -> bool {
        self.allow_interaction
    }
}

#[derive(Clone, Debug)]
pub struct SecretStoreAuthorizationSession {
    session_id: String,
    backend: &'static str,
    reason: String,
    operation_count: usize,
    allow_interaction: bool,
    shared_system_context_required: bool,
    shared_system_context_available: bool,
    system_authorization_attempt_count: usize,
    system_authorization_completed: bool,
    app_password_prompt_used: bool,
    consumed_operation_count: Arc<AtomicUsize>,
    capability_report: Option<CapabilityEvaluationReport>,
    #[cfg(target_os = "macos")]
    macos_context: Option<macos_user_presence::MacosAuthorizationContext>,
}

impl SecretStoreAuthorizationSession {
    fn new(
        backend: &'static str,
        request: &SecretStoreAuthorizationRequest,
        shared_system_context_required: bool,
        shared_system_context_available: bool,
    ) -> Self {
        Self {
            session_id: Uuid::new_v4().to_string(),
            backend,
            reason: request.reason().to_string(),
            operation_count: request.operation_count(),
            allow_interaction: request.allow_interaction(),
            shared_system_context_required,
            shared_system_context_available,
            system_authorization_attempt_count: 0,
            system_authorization_completed: false,
            app_password_prompt_used: false,
            consumed_operation_count: Arc::new(AtomicUsize::new(0)),
            capability_report: None,
            #[cfg(target_os = "macos")]
            macos_context: None,
        }
    }

    #[cfg(target_os = "macos")]
    fn with_macos_context(
        mut self,
        context: macos_user_presence::MacosAuthorizationContext,
        system_authorization_attempt_count: usize,
        system_authorization_completed: bool,
    ) -> Self {
        self.shared_system_context_available = true;
        self.system_authorization_attempt_count = system_authorization_attempt_count;
        self.system_authorization_completed = system_authorization_completed;
        self.macos_context = Some(context);
        self
    }

    pub fn session_id(&self) -> &str {
        &self.session_id
    }

    pub fn backend(&self) -> &'static str {
        self.backend
    }

    pub fn reason(&self) -> &str {
        &self.reason
    }

    pub fn operation_count(&self) -> usize {
        self.operation_count
    }

    pub fn allow_interaction(&self) -> bool {
        self.allow_interaction
    }

    pub fn shared_system_context_required(&self) -> bool {
        self.shared_system_context_required
    }

    pub fn shared_system_context_available(&self) -> bool {
        self.shared_system_context_available
    }

    pub fn system_authorization_attempt_count(&self) -> usize {
        self.system_authorization_attempt_count
    }

    pub fn system_authorization_completed(&self) -> bool {
        self.system_authorization_completed
    }

    pub fn app_password_prompt_used(&self) -> bool {
        self.app_password_prompt_used
    }

    pub fn capability_report(&self) -> Option<&CapabilityEvaluationReport> {
        self.capability_report.as_ref()
    }

    pub fn consumed_operation_count(&self) -> usize {
        self.consumed_operation_count.load(Ordering::SeqCst)
    }

    pub fn remaining_operation_count(&self) -> usize {
        self.operation_count
            .saturating_sub(self.consumed_operation_count())
    }

    pub fn authorization_batch_within_budget(&self) -> bool {
        self.consumed_operation_count() <= self.operation_count
    }

    pub fn record_secret_store_operation(&self, operation: &str) -> Result<()> {
        let mut current = self.consumed_operation_count.load(Ordering::SeqCst);
        loop {
            if current >= self.operation_count {
                return Err(anyhow!(
                    "secure mesh secret store authorization batch exceeded operation budget for {}",
                    operation
                ));
            }
            match self.consumed_operation_count.compare_exchange(
                current,
                current + 1,
                Ordering::SeqCst,
                Ordering::SeqCst,
            ) {
                Ok(_) => return Ok(()),
                Err(next) => current = next,
            }
        }
    }

    pub fn single_system_authorization_context_verified(&self) -> bool {
        self.shared_system_context_required
            && self.shared_system_context_available
            && self.system_authorization_attempt_count == 1
            && self.system_authorization_completed
            && !self.app_password_prompt_used
    }

    fn with_capability_report(mut self, capability_report: CapabilityEvaluationReport) -> Self {
        self.capability_report = Some(capability_report);
        self
    }

    #[cfg(target_os = "macos")]
    fn macos_context(&self) -> Option<&macos_user_presence::MacosAuthorizationContext> {
        self.macos_context.as_ref()
    }
}

impl PartialEq for SecretStoreAuthorizationSession {
    fn eq(&self, other: &Self) -> bool {
        self.session_id == other.session_id
            && self.backend == other.backend
            && self.reason == other.reason
            && self.operation_count == other.operation_count
            && self.allow_interaction == other.allow_interaction
            && self.shared_system_context_required == other.shared_system_context_required
            && self.shared_system_context_available == other.shared_system_context_available
            && self.system_authorization_attempt_count == other.system_authorization_attempt_count
            && self.system_authorization_completed == other.system_authorization_completed
            && self.app_password_prompt_used == other.app_password_prompt_used
            && self.consumed_operation_count() == other.consumed_operation_count()
            && self.capability_report == other.capability_report
    }
}

impl Eq for SecretStoreAuthorizationSession {}

impl SecretStoreHandle {
    pub fn new(namespace: impl Into<String>, key: impl Into<String>) -> Result<Self> {
        let namespace = namespace.into();
        let key = key.into();
        if namespace.trim().is_empty() || key.trim().is_empty() {
            return Err(anyhow!("secure mesh secret-store handle cannot be empty"));
        }
        if key.contains(':') {
            return Err(anyhow!(
                "secure mesh secret-store handle contains an invalid key separator"
            ));
        }
        Ok(Self { namespace, key })
    }

    pub fn namespace(&self) -> &str {
        &self.namespace
    }

    pub fn key(&self) -> &str {
        &self.key
    }

    fn account(&self) -> String {
        format!("{}:{}", self.namespace, self.key)
    }
}

pub trait SecureMeshSecretStore: Send + Sync {
    fn backend(&self) -> &'static str;
    fn supported(&self) -> bool;
    fn capability_facts(&self) -> Result<Vec<CapabilityFact>> {
        Ok(Vec::new())
    }
    fn capability_evaluation(&self) -> Result<CapabilityEvaluation> {
        let mut facts = mandatory_protocol_facts(CapabilityEvidenceKind::SourceContract)?;
        facts.extend(self.capability_facts()?);
        capability_catalog()?.evaluate(&facts)
    }
    fn begin_authorized_session(
        &self,
        request: &SecretStoreAuthorizationRequest,
    ) -> Result<SecretStoreAuthorizationSession> {
        Ok(
            SecretStoreAuthorizationSession::new(self.backend(), request, false, false)
                .with_capability_report(self.capability_evaluation()?.report()),
        )
    }
    fn set_secret(&self, handle: &SecretStoreHandle, secret: &str) -> Result<()>;
    fn set_secret_with_session(
        &self,
        session: &SecretStoreAuthorizationSession,
        handle: &SecretStoreHandle,
        secret: &str,
    ) -> Result<()> {
        if session.shared_system_context_required() {
            return Err(anyhow!(
                "secure mesh secret store backend {} must implement session-aware writes for {}",
                session.backend(),
                handle.key
            ));
        }
        session.record_secret_store_operation("write")?;
        self.set_secret(handle, secret)
    }
    fn get_secret(&self, handle: &SecretStoreHandle) -> Result<Option<String>>;
    fn get_secret_with_session(
        &self,
        session: &SecretStoreAuthorizationSession,
        handle: &SecretStoreHandle,
    ) -> Result<Option<String>> {
        if session.shared_system_context_required() {
            return Err(anyhow!(
                "secure mesh secret store backend {} must implement session-aware reads for {}",
                session.backend(),
                handle.key
            ));
        }
        session.record_secret_store_operation("read")?;
        self.get_secret(handle)
    }
    fn delete_secret(&self, handle: &SecretStoreHandle) -> Result<()>;
    fn delete_secret_with_session(
        &self,
        session: &SecretStoreAuthorizationSession,
        handle: &SecretStoreHandle,
    ) -> Result<()> {
        if session.shared_system_context_required() {
            return Err(anyhow!(
                "secure mesh secret store backend {} must implement session-aware deletes for {}",
                session.backend(),
                handle.key
            ));
        }
        session.record_secret_store_operation("delete")?;
        self.delete_secret(handle)
    }
}

#[derive(Clone, Copy, Debug)]
pub struct PlatformSecretStore {
    service: &'static str,
    account_prefix: &'static str,
}

impl PlatformSecretStore {
    pub const fn new(service: &'static str, account_prefix: &'static str) -> Self {
        Self {
            service,
            account_prefix,
        }
    }

    pub fn handle_for_namespace(
        &self,
        namespace: impl Into<String>,
        key: impl Into<String>,
    ) -> Result<SecretStoreHandle> {
        SecretStoreHandle::new(format!("{}:{}", self.account_prefix, namespace.into()), key)
    }

    pub fn verify_secret_class_persistence(
        &self,
        namespace: impl Into<String>,
        secret_classes: &[&str],
    ) -> Result<SecretClassPersistenceProof> {
        if !self.supported() {
            return Err(anyhow!(
                "secure mesh native secret store unsupported for shared secret class proof"
            ));
        }
        let namespace = namespace.into();
        let session = self.begin_authorized_session(&SecretStoreAuthorizationRequest::new(
            "Secure Mesh shared secret class persistence proof",
            secret_classes.len().saturating_mul(4),
        ))?;
        self.verify_secret_class_persistence_with_session(&session, namespace, secret_classes)
    }

    pub fn verify_secret_class_persistence_with_session(
        &self,
        session: &SecretStoreAuthorizationSession,
        namespace: impl Into<String>,
        secret_classes: &[&str],
    ) -> Result<SecretClassPersistenceProof> {
        let namespace = namespace.into();
        let mut persisted_class_count = 0usize;
        let mut deleted_class_count = 0usize;
        let mut handles = Vec::new();
        for secret_class in secret_classes {
            let handle = self.handle_for_namespace(&namespace, *secret_class)?;
            let proof_secret = format!(
                "secure-mesh-secret-store-proof:{}:{}",
                secret_class,
                Uuid::new_v4()
            );
            self.set_secret_with_session(session, &handle, &proof_secret)?;
            if self.get_secret_with_session(session, &handle)?.as_deref()
                == Some(proof_secret.as_str())
            {
                persisted_class_count += 1;
            }
            handles.push(handle);
        }
        for handle in &handles {
            self.delete_secret_with_session(session, handle)?;
            if self.get_secret_with_session(session, handle)?.is_none() {
                deleted_class_count += 1;
            }
        }
        Ok(SecretClassPersistenceProof {
            backend: self.backend(),
            secret_classes: secret_classes
                .iter()
                .map(|secret_class| (*secret_class).to_string())
                .collect(),
            requested_class_count: secret_classes.len(),
            persisted_class_count,
            deleted_class_count,
            all_classes_persisted: persisted_class_count == secret_classes.len(),
            all_classes_deleted: deleted_class_count == secret_classes.len(),
            raw_secret_material_included: false,
        })
    }
}

pub fn platform_native_secret_store_backend() -> &'static str {
    NATIVE_SECRET_STORE_BACKEND
}

pub fn platform_native_secret_store_supported() -> bool {
    platform_native_secret_store_runtime_state() == PlatformSecretStoreRuntimeState::Available
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum PlatformSecretStoreRuntimeState {
    Available,
    Locked,
    Unavailable,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LinuxSecretServiceProbeSnapshot {
    pub schema_version: u32,
    pub interaction: &'static str,
    pub api: &'static str,
    pub session: &'static str,
    pub default_collection: &'static str,
    pub collection: &'static str,
    pub prompt: &'static str,
    pub read: &'static str,
    pub write: &'static str,
    pub delete: &'static str,
    pub service: &'static str,
    pub ordinary_file_persistence: &'static str,
}

#[cfg(any(target_os = "linux", test))]
#[derive(Debug)]
struct RuntimeFailureMarker {
    failed: std::sync::atomic::AtomicBool,
}

#[cfg(any(target_os = "linux", test))]
impl RuntimeFailureMarker {
    const fn new() -> Self {
        Self {
            failed: std::sync::atomic::AtomicBool::new(false),
        }
    }

    fn record(&self) {
        self.failed.store(true, Ordering::SeqCst);
    }

    fn take(&self) -> bool {
        self.failed.swap(false, Ordering::SeqCst)
    }
}

#[cfg(any(target_os = "linux", test))]
fn linux_secret_service_probe_snapshot_with_evidence(
    mut snapshot: LinuxSecretServiceProbeSnapshot,
    io_round_trip_verified: bool,
    ordinary_file_persistence_absent: bool,
) -> LinuxSecretServiceProbeSnapshot {
    if io_round_trip_verified
        && snapshot.api == "available"
        && snapshot.session == "established"
        && snapshot.default_collection == "available"
        && snapshot.collection == "unlocked"
        && snapshot.prompt == "not_required"
        && snapshot.service == "stable"
    {
        snapshot.read = "supported";
        snapshot.write = "supported";
        snapshot.delete = "supported";
    }
    snapshot.ordinary_file_persistence = if ordinary_file_persistence_absent {
        "absent"
    } else {
        "detected"
    };
    snapshot
}

pub fn platform_linux_secret_service_probe_snapshot(
    io_round_trip_verified: bool,
    ordinary_file_persistence_absent: bool,
) -> Option<LinuxSecretServiceProbeSnapshot> {
    #[cfg(target_os = "linux")]
    {
        Some(linux_secret_service_probe_snapshot_with_evidence(
            linux_secret_service_probe::snapshot(),
            io_round_trip_verified,
            ordinary_file_persistence_absent,
        ))
    }
    #[cfg(not(target_os = "linux"))]
    {
        let _ = (io_round_trip_verified, ordinary_file_persistence_absent);
        None
    }
}

#[cfg(target_os = "linux")]
fn record_platform_secret_store_runtime_failure() {
    linux_secret_service_probe::record_runtime_operation_failure();
}

pub fn platform_native_secret_store_runtime_state() -> PlatformSecretStoreRuntimeState {
    #[cfg(target_os = "linux")]
    {
        return linux_secret_service_probe::runtime_state();
    }
    #[cfg(any(target_os = "macos", target_os = "windows"))]
    {
        PlatformSecretStoreRuntimeState::Available
    }
    #[cfg(not(any(target_os = "macos", target_os = "linux", target_os = "windows")))]
    {
        PlatformSecretStoreRuntimeState::Unavailable
    }
}

fn platform_secret_store_capability_facts() -> Result<Vec<CapabilityFact>> {
    #[cfg(target_os = "linux")]
    {
        let snapshot = linux_secret_service_probe::snapshot();
        return linux_secret_service_capability_facts_from_snapshot(&snapshot);
    }
    #[cfg(target_os = "macos")]
    let platform_capability = Some(SecurityCapability::AppleKeychain);
    #[cfg(not(any(target_os = "macos", target_os = "linux")))]
    let platform_capability = None;
    #[cfg(not(target_os = "linux"))]
    capability_facts_for_runtime_state(
        platform_native_secret_store_runtime_state(),
        platform_capability,
    )
}

#[cfg(any(target_os = "linux", test))]
fn linux_secret_service_capability_facts_from_snapshot(
    snapshot: &LinuxSecretServiceProbeSnapshot,
) -> Result<Vec<CapabilityFact>> {
    let unavailable = if snapshot.api == "absent" {
        Some((
            CapabilityFactState::Unsupported,
            "linux_secret_service_api_absent",
        ))
    } else if snapshot.session == "failed" {
        Some((
            CapabilityFactState::TemporarilyUnavailable,
            "linux_secret_service_session_failed",
        ))
    } else if snapshot.default_collection == "absent" {
        Some((
            CapabilityFactState::Unsupported,
            "linux_secret_service_default_collection_absent",
        ))
    } else if snapshot.collection == "locked" {
        Some((
            CapabilityFactState::TemporarilyUnavailable,
            "linux_secret_service_collection_locked",
        ))
    } else if snapshot.prompt == "required" {
        Some((
            CapabilityFactState::TemporarilyUnavailable,
            "linux_secret_service_prompt_required",
        ))
    } else if snapshot.service == "disappeared" {
        Some((
            CapabilityFactState::TemporarilyUnavailable,
            "linux_secret_service_disappeared",
        ))
    } else if snapshot.service == "temporarily_unavailable" {
        Some((
            CapabilityFactState::TemporarilyUnavailable,
            "linux_secret_service_temporarily_unavailable",
        ))
    } else if snapshot.api == "available"
        && snapshot.session == "established"
        && snapshot.default_collection == "available"
        && snapshot.collection == "unlocked"
        && snapshot.prompt == "not_required"
        && snapshot.service == "stable"
    {
        None
    } else {
        Some((
            CapabilityFactState::Unverified,
            "linux_secret_service_probe_incomplete",
        ))
    };
    let capabilities = [
        SecurityCapability::OsSecureStore,
        SecurityCapability::LinuxSecretService,
    ];
    let Some((state, reason_code)) = unavailable else {
        let evidence_kind = CapabilityEvidenceKind::RuntimeOperation;
        return Ok(capabilities
            .into_iter()
            .map(|capability| CapabilityFact::supported(capability, evidence_kind))
            .collect());
    };
    capabilities
        .into_iter()
        .map(|capability| {
            CapabilityFact::unavailable(
                capability,
                state,
                CapabilityEvidenceKind::RuntimeOperation,
                reason_code,
            )
        })
        .collect()
}

#[cfg(not(target_os = "linux"))]
fn capability_facts_for_runtime_state(
    state: PlatformSecretStoreRuntimeState,
    platform_capability: Option<SecurityCapability>,
) -> Result<Vec<CapabilityFact>> {
    let mut capabilities = vec![SecurityCapability::OsSecureStore];
    if let Some(platform_capability) = platform_capability {
        capabilities.push(platform_capability);
    }
    match state {
        PlatformSecretStoreRuntimeState::Available => Ok(capabilities
            .into_iter()
            .map(|capability| {
                CapabilityFact::supported(capability, CapabilityEvidenceKind::RuntimeOperation)
            })
            .collect()),
        PlatformSecretStoreRuntimeState::Locked => capabilities
            .into_iter()
            .map(|capability| {
                CapabilityFact::unavailable(
                    capability,
                    CapabilityFactState::TemporarilyUnavailable,
                    CapabilityEvidenceKind::RuntimeOperation,
                    "platform_secret_store_locked",
                )
            })
            .collect(),
        PlatformSecretStoreRuntimeState::Unavailable => capabilities
            .into_iter()
            .map(|capability| {
                CapabilityFact::unavailable(
                    capability,
                    CapabilityFactState::TemporarilyUnavailable,
                    CapabilityEvidenceKind::RuntimeOperation,
                    "platform_secret_store_unavailable",
                )
            })
            .collect(),
    }
}

#[cfg(any(target_os = "macos", target_os = "linux", target_os = "windows"))]
impl SecureMeshSecretStore for PlatformSecretStore {
    fn backend(&self) -> &'static str {
        platform_native_secret_store_backend()
    }

    fn supported(&self) -> bool {
        platform_native_secret_store_supported()
    }

    fn capability_facts(&self) -> Result<Vec<CapabilityFact>> {
        platform_secret_store_capability_facts()
    }

    fn begin_authorized_session(
        &self,
        request: &SecretStoreAuthorizationRequest,
    ) -> Result<SecretStoreAuthorizationSession> {
        #[cfg(target_os = "macos")]
        if request.allow_interaction() {
            ensure!(
                macos_user_presence::available(),
                "secure mesh macOS user-presence authorization is unavailable"
            );
            let mut facts = self.capability_facts()?;
            facts.extend(macos_user_presence::capability_facts());
            let mut protocol = mandatory_protocol_facts(CapabilityEvidenceKind::SourceContract)?;
            protocol.extend(facts);
            let report = capability_catalog()?.evaluate(&protocol)?.report();
            return Ok(macos_user_presence::begin_session(self.backend(), request)?
                .with_capability_report(report));
        }
        Ok(
            SecretStoreAuthorizationSession::new(self.backend(), request, false, false)
                .with_capability_report(self.capability_evaluation()?.report()),
        )
    }

    fn set_secret_with_session(
        &self,
        session: &SecretStoreAuthorizationSession,
        handle: &SecretStoreHandle,
        secret: &str,
    ) -> Result<()> {
        #[cfg(target_os = "macos")]
        if session.shared_system_context_required() {
            return macos_user_presence::set_secret(self.service, session, handle, secret);
        }
        session.record_secret_store_operation("write")?;
        self.set_secret(handle, secret)
    }

    fn get_secret_with_session(
        &self,
        session: &SecretStoreAuthorizationSession,
        handle: &SecretStoreHandle,
    ) -> Result<Option<String>> {
        #[cfg(target_os = "macos")]
        if session.shared_system_context_required() {
            return macos_user_presence::get_secret(self.service, session, handle);
        }
        session.record_secret_store_operation("read")?;
        self.get_secret(handle)
    }

    fn delete_secret_with_session(
        &self,
        session: &SecretStoreAuthorizationSession,
        handle: &SecretStoreHandle,
    ) -> Result<()> {
        #[cfg(target_os = "macos")]
        if session.shared_system_context_required() {
            return macos_user_presence::delete_secret(self.service, session, handle);
        }
        session.record_secret_store_operation("delete")?;
        self.delete_secret(handle)
    }

    fn set_secret(&self, handle: &SecretStoreHandle, secret: &str) -> Result<()> {
        #[cfg(test)]
        {
            let _ = secret;
            return Err(anyhow!(
                "real platform secret-store I/O is disabled in unit tests for {}; inject EphemeralSecretStore instead",
                handle.key
            ));
        }
        #[cfg(not(test))]
        {
            let entry = keyring::Entry::new(self.service, &handle.account()).map_err(|_| {
                anyhow!(
                    "secure mesh native secret store entry unavailable for {}",
                    handle.key
                )
            })?;
            entry.set_password(secret).map_err(|_| {
                #[cfg(target_os = "linux")]
                record_platform_secret_store_runtime_failure();
                anyhow!(
                    "secure mesh native secret store write failed for {}",
                    handle.key
                )
            })
        }
    }

    fn get_secret(&self, handle: &SecretStoreHandle) -> Result<Option<String>> {
        #[cfg(test)]
        {
            return Err(anyhow!(
                "real platform secret-store I/O is disabled in unit tests for {}; inject EphemeralSecretStore instead",
                handle.key
            ));
        }
        #[cfg(not(test))]
        {
            let entry = keyring::Entry::new(self.service, &handle.account()).map_err(|_| {
                anyhow!(
                    "secure mesh native secret store entry unavailable for {}",
                    handle.key
                )
            })?;
            match entry.get_password() {
                Ok(secret) if is_persistable_secret(&secret) => Ok(Some(secret)),
                Ok(_) | Err(keyring::Error::NoEntry) => Ok(None),
                Err(_) => {
                    #[cfg(target_os = "linux")]
                    record_platform_secret_store_runtime_failure();
                    Err(anyhow!(
                        "secure mesh native secret store read failed for {}",
                        handle.key
                    ))
                }
            }
        }
    }

    fn delete_secret(&self, handle: &SecretStoreHandle) -> Result<()> {
        #[cfg(test)]
        {
            return Err(anyhow!(
                "real platform secret-store I/O is disabled in unit tests for {}; inject EphemeralSecretStore instead",
                handle.key
            ));
        }
        #[cfg(not(test))]
        {
            let entry = keyring::Entry::new(self.service, &handle.account()).map_err(|_| {
                anyhow!(
                    "secure mesh native secret store entry unavailable for {}",
                    handle.key
                )
            })?;
            match entry.delete_credential() {
                Ok(()) | Err(keyring::Error::NoEntry) => Ok(()),
                Err(_) => {
                    #[cfg(target_os = "linux")]
                    record_platform_secret_store_runtime_failure();
                    Err(anyhow!(
                        "secure mesh native secret store delete failed for {}",
                        handle.key
                    ))
                }
            }
        }
    }
}

#[cfg(target_os = "linux")]
mod linux_secret_service_probe {
    use super::{
        LinuxSecretServiceProbeSnapshot, PlatformSecretStoreRuntimeState, RuntimeFailureMarker,
    };
    use dbus_secret_service::{EncryptionType, SecretService};

    static RUNTIME_OPERATION_FAILURE: RuntimeFailureMarker = RuntimeFailureMarker::new();

    pub fn record_runtime_operation_failure() {
        RUNTIME_OPERATION_FAILURE.record();
    }

    pub(super) fn take_runtime_operation_failure() -> bool {
        RUNTIME_OPERATION_FAILURE.take()
    }

    pub fn snapshot() -> LinuxSecretServiceProbeSnapshot {
        let Ok(service) = SecretService::connect_with_max_prompt_timeout(EncryptionType::Dh, 0)
        else {
            return LinuxSecretServiceProbeSnapshot {
                schema_version: 1,
                interaction: "noninteractive",
                api: "absent",
                session: "failed",
                default_collection: "absent",
                collection: "unverified",
                prompt: "not_attempted",
                read: "unverified",
                write: "unverified",
                delete: "unverified",
                service: "temporarily_unavailable",
                ordinary_file_persistence: "unverified",
            };
        };
        let Ok(collection) = service.get_default_collection() else {
            return LinuxSecretServiceProbeSnapshot {
                schema_version: 1,
                interaction: "noninteractive",
                api: "available",
                session: "established",
                default_collection: "absent",
                collection: "unverified",
                prompt: "not_attempted",
                read: "unverified",
                write: "unverified",
                delete: "unverified",
                service: "stable",
                ordinary_file_persistence: "unverified",
            };
        };
        let collection_state = match collection.is_locked() {
            Ok(false) => "unlocked",
            Ok(true) => "locked",
            Err(_) => "unverified",
        };
        let service_state = if take_runtime_operation_failure() {
            "disappeared"
        } else {
            "stable"
        };
        LinuxSecretServiceProbeSnapshot {
            schema_version: 1,
            interaction: "noninteractive",
            api: "available",
            session: "established",
            default_collection: "available",
            collection: collection_state,
            prompt: if collection_state == "locked" {
                "required"
            } else {
                "not_required"
            },
            read: "unverified",
            write: "unverified",
            delete: "unverified",
            service: service_state,
            ordinary_file_persistence: "unverified",
        }
    }

    pub fn runtime_state() -> PlatformSecretStoreRuntimeState {
        let snapshot = snapshot();
        if snapshot.collection == "locked" {
            PlatformSecretStoreRuntimeState::Locked
        } else if snapshot.api == "available"
            && snapshot.session == "established"
            && snapshot.default_collection == "available"
            && snapshot.collection == "unlocked"
            && snapshot.service == "stable"
        {
            PlatformSecretStoreRuntimeState::Available
        } else {
            PlatformSecretStoreRuntimeState::Unavailable
        }
    }
}

#[cfg(target_os = "macos")]
mod macos_user_presence {
    use super::*;
    use core::ffi::c_void;
    use core::fmt;
    use core::ptr;
    use core_foundation::base::{CFType, TCFType};
    use core_foundation::boolean::CFBoolean;
    use core_foundation::data::CFData;
    use core_foundation::dictionary::CFDictionary;
    use core_foundation::string::CFString;
    use core_foundation_sys::base::{CFGetTypeID, CFRelease, CFTypeRef};
    use core_foundation_sys::data::CFDataRef;
    use core_foundation_sys::string::CFStringRef;
    use objc2::rc::Retained;
    use objc2_foundation::{NSError, NSString};
    use objc2_local_authentication::LAError;
    use objc2_local_authentication::{LAContext, LAPolicy};
    use security_framework::access_control::{ProtectionMode, SecAccessControl};
    use security_framework_sys::access_control::kSecAccessControlUserPresence;
    use security_framework_sys::base::{
        errSecAuthFailed, errSecDuplicateItem, errSecItemNotFound, errSecSuccess,
    };
    use security_framework_sys::item::{
        kSecAttrAccessControl, kSecAttrAccount, kSecAttrService, kSecClass,
        kSecClassGenericPassword, kSecReturnData, kSecUseAuthenticationContext,
        kSecUseDataProtectionKeychain, kSecValueData,
    };
    use security_framework_sys::keychain_item::{
        SecItemAdd, SecItemCopyMatching, SecItemDelete, SecItemUpdate,
    };
    use std::collections::HashMap;
    use std::sync::{
        Mutex, OnceLock,
        atomic::{AtomicBool, Ordering},
        mpsc,
    };
    use std::time::{Duration, Instant};

    const MACOS_APP_AUTHORIZATION_SCOPE: &str = "app.licolite.licoarc.local-secrets";
    const MACOS_AUTHORIZATION_CACHE_TTL: Duration = Duration::from_secs(5 * 60);
    const MACOS_AUTHORIZATION_CACHE_MAX_SCOPES: usize = 8;

    #[derive(Clone)]
    struct CachedAuthorizationContext {
        context: MacosAuthorizationContext,
        authorized_at: Instant,
    }

    static AUTHORIZATION_CONTEXT_CACHE: OnceLock<
        Mutex<HashMap<String, CachedAuthorizationContext>>,
    > = OnceLock::new();
    static TEST_USER_PRESENCE_DISABLED: AtomicBool = AtomicBool::new(false);

    #[derive(Clone)]
    pub struct MacosAuthorizationContext {
        context: Retained<LAContext>,
    }

    // LAContext is retained and only passed as an immutable kSecUseAuthenticationContext
    // value to synchronous Security.framework calls; LocalAuthentication owns the prompt
    // and no app-collected password material crosses this boundary.
    unsafe impl Send for MacosAuthorizationContext {}
    unsafe impl Sync for MacosAuthorizationContext {}

    impl fmt::Debug for MacosAuthorizationContext {
        fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
            f.debug_struct("MacosAuthorizationContext")
                .field("localAuthenticationContext", &"redacted")
                .finish()
        }
    }

    pub fn available() -> bool {
        if TEST_USER_PRESENCE_DISABLED.load(Ordering::SeqCst) {
            return false;
        }
        if cfg!(test) {
            // Unit tests must never reach LocalAuthentication or the real Keychain,
            // even when the parent shell carries production environment variables.
            return false;
        }
        let context = unsafe { LAContext::new() };
        unsafe {
            context
                .canEvaluatePolicy_error(LAPolicy::DeviceOwnerAuthentication)
                .is_ok()
        }
    }

    pub fn capability_facts() -> Vec<CapabilityFact> {
        [
            SecurityCapability::DeviceBound,
            SecurityCapability::UnlockedDeviceRequired,
            SecurityCapability::OsUserPresence,
            SecurityCapability::DeviceCredential,
            SecurityCapability::DataProtectionKeychain,
        ]
        .into_iter()
        .map(|capability| {
            CapabilityFact::supported(capability, CapabilityEvidenceKind::OsAuthorization)
        })
        .collect()
    }

    pub fn set_test_user_presence_disabled(disabled: bool) -> bool {
        TEST_USER_PRESENCE_DISABLED.swap(disabled, Ordering::SeqCst)
    }

    pub fn begin_session(
        backend: &'static str,
        request: &SecretStoreAuthorizationRequest,
    ) -> Result<SecretStoreAuthorizationSession> {
        let (context, system_authorization_attempt_count, system_authorization_completed) =
            shared_authorization_context(MACOS_APP_AUTHORIZATION_SCOPE, request)?;
        Ok(
            SecretStoreAuthorizationSession::new(backend, request, true, true).with_macos_context(
                context,
                system_authorization_attempt_count,
                system_authorization_completed,
            ),
        )
    }

    fn shared_authorization_context(
        authorization_scope: &str,
        request: &SecretStoreAuthorizationRequest,
    ) -> Result<(MacosAuthorizationContext, usize, bool)> {
        let scope = authorization_scope.trim();
        if scope.is_empty() {
            return Err(anyhow!(
                "secure mesh macOS system authentication scope is unavailable"
            ));
        }
        // A background/non-interactive workflow may never inherit a prior
        // interactive workflow's authorization context. Explicit session
        // propagation is the only permitted reuse boundary.
        if !request.allow_interaction() {
            return Err(anyhow!("secure_mesh_authorization_required"));
        }
        let cache = AUTHORIZATION_CONTEXT_CACHE.get_or_init(|| Mutex::new(HashMap::new()));
        let mut entries = cache
            .lock()
            .map_err(|_| anyhow!("secure mesh macOS system authentication cache is unavailable"))?;
        let now = Instant::now();
        entries.retain(|_, entry| {
            now.saturating_duration_since(entry.authorized_at) <= MACOS_AUTHORIZATION_CACHE_TTL
        });
        if let Some(entry) = entries.get(scope) {
            // The one completed evaluation belongs to the shared LAContext itself. Every
            // authorization session that clones that context therefore observes the same
            // single system attempt instead of initiating another prompt.
            return Ok((entry.context.clone(), 1, true));
        }

        let context = unsafe { LAContext::new() };
        let reason = NSString::from_str(request.reason());
        unsafe {
            context.setLocalizedReason(&reason);
            context.setInteractionNotAllowed(!request.allow_interaction());
            context.setTouchIDAuthenticationAllowableReuseDuration(300.0);
        }
        let policy = preferred_system_authorization_policy(&context)?;
        // Keep the cache lock across evaluation. Concurrent callers for the same process
        // cannot race into multiple Touch ID/password sheets.
        evaluate_system_authorization_once(&context, policy, &reason)?;
        unsafe {
            context.setInteractionNotAllowed(true);
        }
        let shared = MacosAuthorizationContext { context };
        if entries.len() >= MACOS_AUTHORIZATION_CACHE_MAX_SCOPES {
            if let Some(oldest_scope) = entries
                .iter()
                .min_by_key(|(_, entry)| entry.authorized_at)
                .map(|(scope, _)| scope.clone())
            {
                entries.remove(&oldest_scope);
            }
        }
        entries.insert(
            scope.to_string(),
            CachedAuthorizationContext {
                context: shared.clone(),
                authorized_at: Instant::now(),
            },
        );
        Ok((shared, 1, true))
    }

    fn preferred_system_authorization_policy(context: &LAContext) -> Result<LAPolicy> {
        unsafe {
            context
                .canEvaluatePolicy_error(LAPolicy::DeviceOwnerAuthentication)
                .map_err(|_| {
                    anyhow!(
                        "secure mesh macOS system authentication is unavailable for user-presence secret store"
                    )
                })?;
        }
        Ok(LAPolicy::DeviceOwnerAuthentication)
    }

    fn evaluate_system_authorization_once(
        context: &LAContext,
        policy: LAPolicy,
        reason: &NSString,
    ) -> Result<()> {
        let (sender, receiver) = mpsc::channel();
        let reply =
            block2::RcBlock::new(move |success: objc2::runtime::Bool, error: *mut NSError| {
                let error_code = if error.is_null() {
                    None
                } else {
                    Some(unsafe { (*error).code() })
                };
                let _ = sender.send((success.as_bool(), error_code));
            });
        unsafe {
            context.evaluatePolicy_localizedReason_reply(policy, reason, &reply);
        }
        match receiver.recv_timeout(Duration::from_secs(120)) {
            Ok((true, _)) => Ok(()),
            Ok((false, error_code)) => Err(anyhow!(
                "secure mesh macOS system authentication failed closed: {}",
                local_authentication_error_category(error_code)
            )),
            Err(mpsc::RecvTimeoutError::Timeout) => {
                unsafe { context.invalidate() };
                Err(anyhow!(
                    "secure mesh macOS system authentication timed out and failed closed"
                ))
            }
            Err(_) => Err(anyhow!(
                "secure mesh macOS system authentication callback was not delivered for user-presence secret store"
            )),
        }
    }

    fn local_authentication_error_category(error_code: Option<isize>) -> &'static str {
        match error_code {
            Some(code) if code == LAError::UserCancel.0 => "user_cancelled",
            Some(code) if code == LAError::SystemCancel.0 => "system_cancelled",
            Some(code) if code == LAError::AppCancel.0 => "application_cancelled",
            Some(code) if code == LAError::BiometryLockout.0 => "biometry_locked",
            Some(code) if code == LAError::BiometryNotAvailable.0 => "biometry_unavailable",
            Some(code) if code == LAError::BiometryNotEnrolled.0 => "biometry_not_enrolled",
            Some(code) if code == LAError::PasscodeNotSet.0 => "system_credential_unavailable",
            Some(code) if code == LAError::AuthenticationFailed.0 => "authentication_failed",
            Some(code) if code == LAError::UserFallback.0 => "fallback_not_completed",
            Some(code) if code == LAError::InvalidContext.0 => "authorization_context_invalid",
            _ => "authorization_unavailable",
        }
    }

    pub fn set_secret(
        service: &str,
        session: &SecretStoreAuthorizationSession,
        handle: &SecretStoreHandle,
        secret: &str,
    ) -> Result<()> {
        let context = session_context(session, handle)?;
        session.record_secret_store_operation("write")?;
        delete_secret_item(service, context, handle)?;
        let account = handle.account();
        let access_control = SecAccessControl::create_with_protection(
            Some(ProtectionMode::AccessibleWhenUnlockedThisDeviceOnly),
            kSecAccessControlUserPresence,
        )
        .map_err(|_| {
            anyhow!(
                "secure mesh macOS user-presence access control unavailable for {}",
                handle.key
            )
        })?;
        let mut pairs = base_pairs(service, &account, context);
        pairs.push((
            unsafe { sec_key(kSecAttrAccessControl) },
            access_control.into_CFType(),
        ));
        pairs.push((
            unsafe { sec_key(kSecValueData) },
            CFData::from_buffer(secret.as_bytes()).into_CFType(),
        ));
        let add_query = CFDictionary::from_CFType_pairs(&pairs);
        let add_status = unsafe { SecItemAdd(add_query.as_concrete_TypeRef(), ptr::null_mut()) };
        if add_status == errSecSuccess {
            return Ok(());
        }
        if add_status == errSecDuplicateItem {
            let query = CFDictionary::from_CFType_pairs(&base_pairs(service, &account, context));
            let update = CFDictionary::from_CFType_pairs(&[(
                unsafe { sec_key(kSecValueData) },
                CFData::from_buffer(secret.as_bytes()).into_CFType(),
            )]);
            let update_status =
                unsafe { SecItemUpdate(query.as_concrete_TypeRef(), update.as_concrete_TypeRef()) };
            return status_result(service, "write", handle, update_status);
        }
        status_result(service, "write", handle, add_status)
    }

    pub fn get_secret(
        service: &str,
        session: &SecretStoreAuthorizationSession,
        handle: &SecretStoreHandle,
    ) -> Result<Option<String>> {
        let context = session_context(session, handle)?;
        session.record_secret_store_operation("read")?;
        let account = handle.account();
        let mut pairs = base_pairs(service, &account, context);
        pairs.push((
            unsafe { sec_key(kSecReturnData) },
            CFBoolean::from(true).into_CFType(),
        ));
        let query = CFDictionary::from_CFType_pairs(&pairs);
        let mut copied: CFTypeRef = ptr::null();
        let status = unsafe { SecItemCopyMatching(query.as_concrete_TypeRef(), &mut copied) };
        if status == errSecItemNotFound {
            return Ok(None);
        }
        status_result(service, "read", handle, status)?;
        if copied.is_null() {
            return Ok(None);
        }
        let type_id = unsafe { CFGetTypeID(copied) };
        if type_id != CFData::type_id() {
            unsafe { CFRelease(copied) };
            return Err(anyhow!(
                "secure mesh macOS user-presence secret store returned unexpected data for {}",
                handle.key
            ));
        }
        let data = unsafe { CFData::wrap_under_create_rule(copied as CFDataRef) };
        let mut bytes = Vec::new();
        bytes.extend_from_slice(data.bytes());
        let secret = String::from_utf8(bytes).map_err(|_| {
            anyhow!(
                "secure mesh macOS user-presence secret store returned non-UTF8 data for {}",
                handle.key
            )
        })?;
        if is_persistable_secret(&secret) {
            Ok(Some(secret))
        } else {
            Ok(None)
        }
    }

    pub fn delete_secret(
        service: &str,
        session: &SecretStoreAuthorizationSession,
        handle: &SecretStoreHandle,
    ) -> Result<()> {
        let context = session_context(session, handle)?;
        session.record_secret_store_operation("delete")?;
        delete_secret_item(service, context, handle)
    }

    fn delete_secret_item(
        service: &str,
        context: &MacosAuthorizationContext,
        handle: &SecretStoreHandle,
    ) -> Result<()> {
        let account = handle.account();
        let query = CFDictionary::from_CFType_pairs(&base_pairs(service, &account, context));
        let status = unsafe { SecItemDelete(query.as_concrete_TypeRef()) };
        if status == errSecItemNotFound {
            Ok(())
        } else {
            status_result(service, "delete", handle, status)
        }
    }

    fn session_context<'a>(
        session: &'a SecretStoreAuthorizationSession,
        handle: &SecretStoreHandle,
    ) -> Result<&'a MacosAuthorizationContext> {
        session.macos_context().ok_or_else(|| {
            anyhow!(
                "secure mesh macOS user-presence secret store has no shared system authorization context for {}",
                handle.key
            )
        })
    }

    fn base_pairs(
        service: &str,
        account: &str,
        context: &MacosAuthorizationContext,
    ) -> Vec<(CFString, CFType)> {
        let mut pairs = vec![
            (unsafe { sec_key(kSecClass) }, unsafe {
                sec_string_value(kSecClassGenericPassword)
            }),
            (
                unsafe { sec_key(kSecAttrService) },
                CFString::from(service).into_CFType(),
            ),
            (
                unsafe { sec_key(kSecAttrAccount) },
                CFString::from(account).into_CFType(),
            ),
            (
                unsafe { sec_key(kSecUseAuthenticationContext) },
                context.as_cf_type(),
            ),
        ];
        // Every build requires the Data Protection Keychain. A local/debug
        // build without a valid provisioning entitlement must fail closed;
        // the legacy Keychain does not reliably enforce userPresence.
        pairs.push((
            unsafe { sec_key(kSecUseDataProtectionKeychain) },
            CFBoolean::true_value().into_CFType(),
        ));
        pairs
    }

    fn status_result(
        _service: &str,
        operation: &str,
        handle: &SecretStoreHandle,
        status: i32,
    ) -> Result<()> {
        if status == errSecSuccess {
            Ok(())
        } else {
            invalidate_cached_authorization(MACOS_APP_AUTHORIZATION_SCOPE);
            if status == errSecAuthFailed || status == ERR_SEC_INTERACTION_NOT_ALLOWED {
                return Err(anyhow!("secure_mesh_authorization_required"));
            }
            Err(anyhow!(
                "secure mesh macOS user-presence secret store {} failed for {} with security status {}",
                operation,
                handle.key,
                status
            ))
        }
    }

    // Security.framework does not expose this constant through every Rust SDK
    // binding version supported by the client toolchain.
    const ERR_SEC_INTERACTION_NOT_ALLOWED: i32 = -25308;

    fn invalidate_cached_authorization(authorization_scope: &str) {
        let Some(cache) = AUTHORIZATION_CONTEXT_CACHE.get() else {
            return;
        };
        if let Ok(mut entries) = cache.lock() {
            entries.remove(authorization_scope);
        }
    }

    unsafe fn sec_key(value: CFStringRef) -> CFString {
        unsafe { CFString::wrap_under_get_rule(value) }
    }

    unsafe fn sec_string_value(value: CFStringRef) -> CFType {
        unsafe { sec_key(value) }.into_CFType()
    }

    impl MacosAuthorizationContext {
        fn as_cf_type(&self) -> CFType {
            let pointer = (&*self.context as *const LAContext).cast::<c_void>() as CFTypeRef;
            unsafe { CFType::wrap_under_get_rule(pointer) }
        }
    }
}

#[cfg(not(any(target_os = "macos", target_os = "linux", target_os = "windows")))]
impl SecureMeshSecretStore for PlatformSecretStore {
    fn backend(&self) -> &'static str {
        platform_native_secret_store_backend()
    }

    fn supported(&self) -> bool {
        false
    }

    fn set_secret(&self, handle: &SecretStoreHandle, _secret: &str) -> Result<()> {
        Err(anyhow!(
            "secure mesh native secret store unsupported for {}",
            handle.key
        ))
    }

    fn get_secret(&self, _handle: &SecretStoreHandle) -> Result<Option<String>> {
        Ok(None)
    }

    fn delete_secret(&self, _handle: &SecretStoreHandle) -> Result<()> {
        Ok(())
    }
}

fn is_persistable_secret(value: &str) -> bool {
    let trimmed = value.trim();
    !trimmed.is_empty() && trimmed != "redacted" && trimmed != "***" && trimmed != "********"
}

pub struct EphemeralSecretStore {
    secrets: Mutex<HashMap<String, Zeroizing<String>>>,
    capability_facts: Mutex<Vec<CapabilityFact>>,
    #[cfg(test)]
    authorization_sessions: Mutex<Vec<SecretStoreAuthorizationSession>>,
}

impl Default for EphemeralSecretStore {
    fn default() -> Self {
        Self {
            secrets: Mutex::new(HashMap::new()),
            capability_facts: Mutex::new(Vec::new()),
            #[cfg(test)]
            authorization_sessions: Mutex::new(Vec::new()),
        }
    }
}

impl EphemeralSecretStore {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn with_unavailable_platform_facts(capability_facts: Vec<CapabilityFact>) -> Result<Self> {
        ensure!(
            capability_facts
                .iter()
                .all(|fact| fact.state != CapabilityFactState::Supported),
            "ephemeral custody cannot claim a supported persistent-store capability"
        );
        Ok(Self {
            capability_facts: Mutex::new(capability_facts),
            ..Self::default()
        })
    }

    pub fn set_unavailable_platform_facts(
        &self,
        capability_facts: Vec<CapabilityFact>,
    ) -> Result<()> {
        ensure!(
            capability_facts
                .iter()
                .all(|fact| fact.state != CapabilityFactState::Supported),
            "ephemeral custody cannot claim a supported persistent-store capability"
        );
        *self
            .capability_facts
            .lock()
            .map_err(|_| anyhow!("secure mesh ephemeral capability state is unavailable"))? =
            capability_facts;
        Ok(())
    }

    #[cfg(test)]
    pub fn authorization_session_count(&self) -> usize {
        self.authorization_sessions
            .lock()
            .map(|sessions| sessions.len())
            .unwrap_or_default()
    }

    #[cfg(test)]
    pub fn authorization_session_reasons(&self) -> Vec<String> {
        self.authorization_sessions
            .lock()
            .map(|sessions| {
                sessions
                    .iter()
                    .map(|session| session.reason().to_string())
                    .collect()
            })
            .unwrap_or_default()
    }

    #[cfg(test)]
    pub fn authorization_session_operation_counts(&self) -> Vec<usize> {
        self.authorization_sessions
            .lock()
            .map(|sessions| {
                sessions
                    .iter()
                    .map(SecretStoreAuthorizationSession::operation_count)
                    .collect()
            })
            .unwrap_or_default()
    }

    #[cfg(test)]
    pub fn authorization_session_allow_interactions(&self) -> Vec<bool> {
        self.authorization_sessions
            .lock()
            .map(|sessions| {
                sessions
                    .iter()
                    .map(SecretStoreAuthorizationSession::allow_interaction)
                    .collect()
            })
            .unwrap_or_default()
    }

    #[cfg(test)]
    pub fn authorization_session_consumed_operation_counts(&self) -> Vec<usize> {
        self.authorization_sessions
            .lock()
            .map(|sessions| {
                sessions
                    .iter()
                    .map(SecretStoreAuthorizationSession::consumed_operation_count)
                    .collect()
            })
            .unwrap_or_default()
    }
}

impl SecureMeshSecretStore for EphemeralSecretStore {
    fn backend(&self) -> &'static str {
        "memory-only-ephemeral"
    }

    fn supported(&self) -> bool {
        true
    }

    fn capability_facts(&self) -> Result<Vec<CapabilityFact>> {
        Ok(self
            .capability_facts
            .lock()
            .map_err(|_| anyhow!("secure mesh ephemeral capability state is unavailable"))?
            .clone())
    }

    fn begin_authorized_session(
        &self,
        request: &SecretStoreAuthorizationRequest,
    ) -> Result<SecretStoreAuthorizationSession> {
        let session = SecretStoreAuthorizationSession::new(self.backend(), request, false, false)
            .with_capability_report(self.capability_evaluation()?.report());
        #[cfg(test)]
        self.authorization_sessions
            .lock()
            .map_err(|_| anyhow!("secure mesh ephemeral secret store state is unavailable"))?
            .push(session.clone());
        Ok(session)
    }

    fn set_secret(&self, handle: &SecretStoreHandle, secret: &str) -> Result<()> {
        ensure!(
            is_persistable_secret(secret),
            "secure mesh ephemeral secret value is invalid"
        );
        self.secrets
            .lock()
            .map_err(|_| anyhow!("secure mesh ephemeral secret store state is unavailable"))?
            .insert(handle.account(), Zeroizing::new(secret.to_string()));
        Ok(())
    }

    fn get_secret(&self, handle: &SecretStoreHandle) -> Result<Option<String>> {
        Ok(self
            .secrets
            .lock()
            .map_err(|_| anyhow!("secure mesh ephemeral secret store state is unavailable"))?
            .get(&handle.account())
            .map(|secret| secret.to_string()))
    }

    fn delete_secret(&self, handle: &SecretStoreHandle) -> Result<()> {
        self.secrets
            .lock()
            .map_err(|_| anyhow!("secure mesh ephemeral secret store state is unavailable"))?
            .remove(&handle.account());
        Ok(())
    }
}

pub struct SecureMeshSecretStoreSelection {
    store: Arc<dyn SecureMeshSecretStore>,
    capability_evaluation: CapabilityEvaluation,
}

impl SecureMeshSecretStoreSelection {
    pub fn select(os_store: Option<Arc<dyn SecureMeshSecretStore>>) -> Result<Self> {
        let mut unavailable_platform_facts = Vec::new();
        if let Some(store) = os_store {
            unavailable_platform_facts = store.capability_facts()?;
            if store.supported() {
                let capability_evaluation = store.capability_evaluation()?;
                if capability_evaluation
                    .custody()
                    .map(|selection| selection.strategy)
                    == Some(SecretCustodyStrategy::OsSecureStore)
                {
                    return Ok(Self {
                        store,
                        capability_evaluation,
                    });
                }
            }
        }
        let store: Arc<dyn SecureMeshSecretStore> = Arc::new(
            EphemeralSecretStore::with_unavailable_platform_facts(unavailable_platform_facts)?,
        );
        let capability_evaluation = store.capability_evaluation()?;
        Ok(Self {
            store,
            capability_evaluation,
        })
    }

    pub fn store(&self) -> Arc<dyn SecureMeshSecretStore> {
        Arc::clone(&self.store)
    }

    pub fn capability_evaluation(&self) -> &CapabilityEvaluation {
        &self.capability_evaluation
    }

    pub fn strategy(&self) -> SecretCustodyStrategy {
        self.capability_evaluation
            .custody()
            .map(|selection| selection.strategy)
            .unwrap_or(SecretCustodyStrategy::MemoryOnlyEphemeral)
    }

    pub fn restart_semantics(&self) -> CustodyRestartSemantics {
        self.capability_evaluation
            .custody()
            .map(|selection| selection.restart_semantics)
            .unwrap_or(CustodyRestartSemantics::RePairRekeyAfterRestart)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn unlocked_linux_probe_fixture() -> LinuxSecretServiceProbeSnapshot {
        LinuxSecretServiceProbeSnapshot {
            schema_version: 1,
            interaction: "noninteractive",
            api: "available",
            session: "established",
            default_collection: "available",
            collection: "unlocked",
            prompt: "not_required",
            read: "unverified",
            write: "unverified",
            delete: "unverified",
            service: "stable",
            ordinary_file_persistence: "unverified",
        }
    }

    fn assert_linux_probe_unavailable(
        snapshot: LinuxSecretServiceProbeSnapshot,
        state: CapabilityFactState,
        reason_code: &str,
    ) {
        let facts = linux_secret_service_capability_facts_from_snapshot(&snapshot).unwrap();
        assert_eq!(facts.len(), 2);
        assert!(facts.iter().all(|fact| fact.state == state));
        assert!(
            facts
                .iter()
                .all(|fact| fact.reason_code.as_deref() == Some(reason_code))
        );
        assert!(
            facts
                .iter()
                .any(|fact| { fact.capability == SecurityCapability::OsSecureStore })
        );
        assert!(
            facts
                .iter()
                .any(|fact| { fact.capability == SecurityCapability::LinuxSecretService })
        );
        assert!(
            !facts
                .iter()
                .any(|fact| { fact.capability == SecurityCapability::SoftwareBacked })
        );
    }

    #[test]
    fn linux_probe_api_missing_is_an_independent_unsupported_fact() {
        let mut snapshot = unlocked_linux_probe_fixture();
        snapshot.api = "absent";
        assert_linux_probe_unavailable(
            snapshot,
            CapabilityFactState::Unsupported,
            "linux_secret_service_api_absent",
        );
    }

    #[test]
    fn linux_probe_session_failure_is_independently_temporarily_unavailable() {
        let mut snapshot = unlocked_linux_probe_fixture();
        snapshot.session = "failed";
        assert_linux_probe_unavailable(
            snapshot,
            CapabilityFactState::TemporarilyUnavailable,
            "linux_secret_service_session_failed",
        );
    }

    #[test]
    fn linux_probe_default_collection_missing_is_independently_unsupported() {
        let mut snapshot = unlocked_linux_probe_fixture();
        snapshot.default_collection = "absent";
        assert_linux_probe_unavailable(
            snapshot,
            CapabilityFactState::Unsupported,
            "linux_secret_service_default_collection_absent",
        );
    }

    #[test]
    fn linux_probe_locked_collection_is_independently_temporarily_unavailable() {
        let mut snapshot = unlocked_linux_probe_fixture();
        snapshot.collection = "locked";
        snapshot.prompt = "not_attempted";
        assert_linux_probe_unavailable(
            snapshot,
            CapabilityFactState::TemporarilyUnavailable,
            "linux_secret_service_collection_locked",
        );
    }

    #[test]
    fn linux_probe_prompt_required_is_independently_temporarily_unavailable() {
        let mut snapshot = unlocked_linux_probe_fixture();
        snapshot.prompt = "required";
        assert_linux_probe_unavailable(
            snapshot,
            CapabilityFactState::TemporarilyUnavailable,
            "linux_secret_service_prompt_required",
        );
    }

    #[test]
    fn linux_probe_unlocked_crud_enables_only_exact_os_store_capabilities() {
        let snapshot = linux_secret_service_probe_snapshot_with_evidence(
            unlocked_linux_probe_fixture(),
            true,
            true,
        );
        assert_eq!(snapshot.read, "supported");
        assert_eq!(snapshot.write, "supported");
        assert_eq!(snapshot.delete, "supported");
        assert_eq!(snapshot.ordinary_file_persistence, "absent");
        let facts = linux_secret_service_capability_facts_from_snapshot(&snapshot).unwrap();
        assert_eq!(facts.len(), 2);
        assert!(
            facts
                .iter()
                .all(|fact| fact.state == CapabilityFactState::Supported)
        );
        assert!(
            !facts
                .iter()
                .any(|fact| { fact.capability == SecurityCapability::SoftwareBacked })
        );
    }

    #[test]
    fn linux_probe_running_service_disappearance_is_independently_unavailable() {
        let mut snapshot = unlocked_linux_probe_fixture();
        snapshot.service = "disappeared";
        assert_linux_probe_unavailable(
            snapshot,
            CapabilityFactState::TemporarilyUnavailable,
            "linux_secret_service_disappeared",
        );
    }

    #[test]
    fn linux_runtime_failure_marker_is_consumed_once_before_service_recovery() {
        let marker = RuntimeFailureMarker::new();
        marker.record();
        assert!(marker.take());
        assert!(!marker.take());

        #[cfg(target_os = "linux")]
        {
            record_platform_secret_store_runtime_failure();
            assert!(linux_secret_service_probe::take_runtime_operation_failure());
            assert!(!linux_secret_service_probe::take_runtime_operation_failure());
        }
    }

    #[test]
    fn secret_store_handle_rejects_empty_or_key_separator_values() {
        assert!(SecretStoreHandle::new("", "privateKeyBase64url").is_err());
        assert!(SecretStoreHandle::new("mobileRelayE2ee", "").is_err());
        assert!(SecretStoreHandle::new("mobileRelayE2ee", "private:key").is_err());
    }

    #[test]
    fn platform_store_builds_opaque_account_handle() {
        let store = PlatformSecretStore::new("app.licolite.test", "mobileRelayE2ee");
        assert_eq!(store.service, "app.licolite.test");
        let handle = store
            .handle_for_namespace("namespace", "privateKeyBase64url")
            .unwrap();
        assert_eq!(
            handle.account(),
            "mobileRelayE2ee:namespace:privateKeyBase64url"
        );
    }

    #[test]
    fn platform_store_unit_test_io_is_noninteractive_and_fail_closed() {
        let store = PlatformSecretStore::new("app.licolite.test", "unitTestSecret");
        let handle = store
            .handle_for_namespace("noninteractive", "proof")
            .unwrap();
        let error = store.get_secret(&handle).unwrap_err();
        assert!(error.to_string().contains("disabled in unit tests"));
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn macos_local_authentication_is_never_enabled_inside_unit_tests() {
        assert!(!macos_user_presence::available());
        let store = PlatformSecretStore::new("app.licolite.test", "macosFailClosed");
        let error = store
            .begin_authorized_session(&SecretStoreAuthorizationRequest::new(
                "macOS user-presence fail-closed test",
                1,
            ))
            .unwrap_err();
        assert!(
            error
                .to_string()
                .contains("user-presence authorization is unavailable")
        );
    }

    #[test]
    fn class_persistence_report_shape_is_redacted() {
        let report = SecretClassPersistenceProof {
            backend: "test-backend",
            secret_classes: vec!["pairwiseSessionSnapshot".to_string()],
            requested_class_count: 1,
            persisted_class_count: 1,
            deleted_class_count: 1,
            all_classes_persisted: true,
            all_classes_deleted: true,
            raw_secret_material_included: false,
        };
        assert!(report.all_classes_persisted);
        assert!(report.all_classes_deleted);
        assert!(!report.raw_secret_material_included);
    }

    #[test]
    fn single_system_authorization_context_requires_one_completed_system_attempt() {
        let request = SecretStoreAuthorizationRequest::new("test batch", 3);
        let baseline = SecretStoreAuthorizationSession::new("macos-keychain", &request, true, true);
        assert!(!baseline.single_system_authorization_context_verified());

        let verified = SecretStoreAuthorizationSession {
            system_authorization_attempt_count: 1,
            system_authorization_completed: true,
            ..baseline.clone()
        };
        assert!(verified.single_system_authorization_context_verified());

        let repeated_prompt = SecretStoreAuthorizationSession {
            system_authorization_attempt_count: 2,
            ..verified.clone()
        };
        assert!(!repeated_prompt.single_system_authorization_context_verified());

        let app_password_prompt = SecretStoreAuthorizationSession {
            app_password_prompt_used: true,
            ..verified
        };
        assert!(!app_password_prompt.single_system_authorization_context_verified());
    }

    #[test]
    fn authorization_session_enforces_operation_budget_across_clones() {
        let request = SecretStoreAuthorizationRequest::new("budgeted batch", 2);
        let session = SecretStoreAuthorizationSession::new("macos-keychain", &request, true, true);
        let clone = session.clone();

        session.record_secret_store_operation("read").unwrap();
        clone.record_secret_store_operation("write").unwrap();

        assert_eq!(session.consumed_operation_count(), 2);
        assert_eq!(clone.remaining_operation_count(), 0);
        assert!(session.authorization_batch_within_budget());
        assert!(clone.record_secret_store_operation("delete").is_err());
        assert_eq!(session.consumed_operation_count(), 2);
    }

    #[test]
    fn default_session_methods_reject_required_shared_system_context() {
        struct SessionRequiredStore;

        impl SecureMeshSecretStore for SessionRequiredStore {
            fn backend(&self) -> &'static str {
                "session-required-test-store"
            }

            fn supported(&self) -> bool {
                true
            }

            fn set_secret(&self, _handle: &SecretStoreHandle, _secret: &str) -> Result<()> {
                Ok(())
            }

            fn get_secret(&self, _handle: &SecretStoreHandle) -> Result<Option<String>> {
                Ok(Some("secret".to_string()))
            }

            fn delete_secret(&self, _handle: &SecretStoreHandle) -> Result<()> {
                Ok(())
            }
        }

        let request = SecretStoreAuthorizationRequest::new("required auth", 1);
        let session = SecretStoreAuthorizationSession::new(
            "session-required-test-store",
            &request,
            true,
            true,
        );
        let handle = SecretStoreHandle::new("namespace", "key").unwrap();
        let store = SessionRequiredStore;

        assert!(
            store
                .set_secret_with_session(&session, &handle, "secret")
                .is_err()
        );
        assert!(store.get_secret_with_session(&session, &handle).is_err());
        assert!(store.delete_secret_with_session(&session, &handle).is_err());
    }

    #[test]
    fn ephemeral_strategy_zeroizing_store_has_explicit_restart_repair_semantics() {
        let store = EphemeralSecretStore::new();
        let handle = SecretStoreHandle::new("ephemeral", "identity-key").unwrap();
        let request = SecretStoreAuthorizationRequest::noninteractive("ephemeral operation", 3);
        let session = store.begin_authorized_session(&request).unwrap();
        store
            .set_secret_with_session(&session, &handle, "secret-value")
            .unwrap();
        assert_eq!(
            store
                .get_secret_with_session(&session, &handle)
                .unwrap()
                .as_deref(),
            Some("secret-value")
        );
        store.delete_secret_with_session(&session, &handle).unwrap();
        assert_eq!(session.remaining_operation_count(), 0);
        assert_eq!(
            session
                .capability_report()
                .and_then(|report| report.custody.as_ref())
                .map(|selection| selection.strategy),
            Some(SecretCustodyStrategy::MemoryOnlyEphemeral)
        );
        assert_eq!(
            session
                .capability_report()
                .and_then(|report| report.custody.as_ref())
                .map(|selection| selection.restart_semantics),
            Some(CustodyRestartSemantics::RePairRekeyAfterRestart)
        );

        let restarted_store = EphemeralSecretStore::new();
        assert!(restarted_store.get_secret(&handle).unwrap().is_none());
    }

    #[test]
    fn selector_accepts_safe_software_os_storage_without_hardware_claims() {
        struct SoftwareOsStore(EphemeralSecretStore);

        impl SecureMeshSecretStore for SoftwareOsStore {
            fn backend(&self) -> &'static str {
                "software-os-store-test"
            }

            fn supported(&self) -> bool {
                true
            }

            fn capability_facts(&self) -> Result<Vec<CapabilityFact>> {
                Ok(vec![
                    CapabilityFact::supported(
                        SecurityCapability::OsSecureStore,
                        CapabilityEvidenceKind::TestFixture,
                    ),
                    CapabilityFact::supported(
                        SecurityCapability::SoftwareBacked,
                        CapabilityEvidenceKind::TestFixture,
                    ),
                ])
            }

            fn set_secret(&self, handle: &SecretStoreHandle, secret: &str) -> Result<()> {
                self.0.set_secret(handle, secret)
            }

            fn get_secret(&self, handle: &SecretStoreHandle) -> Result<Option<String>> {
                self.0.get_secret(handle)
            }

            fn delete_secret(&self, handle: &SecretStoreHandle) -> Result<()> {
                self.0.delete_secret(handle)
            }
        }

        let selection = SecureMeshSecretStoreSelection::select(Some(Arc::new(SoftwareOsStore(
            EphemeralSecretStore::new(),
        ))))
        .unwrap();
        assert_eq!(selection.strategy(), SecretCustodyStrategy::OsSecureStore);
        assert_eq!(
            selection.restart_semantics(),
            CustodyRestartSemantics::PersistentStateAvailable
        );
        assert!(
            selection
                .capability_evaluation()
                .enabled()
                .contains(&SecurityCapability::SoftwareBacked)
        );
        assert!(
            !selection
                .capability_evaluation()
                .enabled()
                .contains(&SecurityCapability::HardwareBacked)
        );
    }

    #[test]
    fn selector_falls_back_only_to_memory_and_defines_no_unsafe_strategy() {
        struct UnsupportedStore;

        impl SecureMeshSecretStore for UnsupportedStore {
            fn backend(&self) -> &'static str {
                "unsupported-test-store"
            }

            fn supported(&self) -> bool {
                false
            }

            fn set_secret(&self, _handle: &SecretStoreHandle, _secret: &str) -> Result<()> {
                unreachable!()
            }

            fn get_secret(&self, _handle: &SecretStoreHandle) -> Result<Option<String>> {
                unreachable!()
            }

            fn delete_secret(&self, _handle: &SecretStoreHandle) -> Result<()> {
                unreachable!()
            }
        }

        let selection =
            SecureMeshSecretStoreSelection::select(Some(Arc::new(UnsupportedStore))).unwrap();
        assert_eq!(
            selection.strategy(),
            SecretCustodyStrategy::MemoryOnlyEphemeral
        );
        assert_eq!(
            selection.restart_semantics(),
            CustodyRestartSemantics::RePairRekeyAfterRestart
        );
        let strategies = serde_json::to_string(&[
            SecretCustodyStrategy::MemoryOnlyEphemeral,
            SecretCustodyStrategy::OsSecureStore,
        ])
        .unwrap();
        assert!(!strategies.contains("plaintext"));
        assert!(!strategies.contains("portable"));
        assert!(!strategies.contains("ordinary_file"));
    }

    #[test]
    fn locked_or_unavailable_os_store_facts_select_memory_without_losing_reasons() {
        struct LockedLinuxStore;

        impl SecureMeshSecretStore for LockedLinuxStore {
            fn backend(&self) -> &'static str {
                "linux-secret-service-keyring"
            }

            fn supported(&self) -> bool {
                false
            }

            fn capability_facts(&self) -> Result<Vec<CapabilityFact>> {
                let mut snapshot = unlocked_linux_probe_fixture();
                snapshot.collection = "locked";
                snapshot.prompt = "not_attempted";
                linux_secret_service_capability_facts_from_snapshot(&snapshot)
            }

            fn set_secret(&self, _handle: &SecretStoreHandle, _secret: &str) -> Result<()> {
                unreachable!()
            }

            fn get_secret(&self, _handle: &SecretStoreHandle) -> Result<Option<String>> {
                unreachable!()
            }

            fn delete_secret(&self, _handle: &SecretStoreHandle) -> Result<()> {
                unreachable!()
            }
        }

        let selection =
            SecureMeshSecretStoreSelection::select(Some(Arc::new(LockedLinuxStore))).unwrap();
        assert_eq!(
            selection.strategy(),
            SecretCustodyStrategy::MemoryOnlyEphemeral
        );
        assert_eq!(
            selection
                .capability_evaluation()
                .reasons()
                .get(&SecurityCapability::LinuxSecretService)
                .map(String::as_str),
            Some("linux_secret_service_collection_locked")
        );
        assert!(
            selection
                .capability_evaluation()
                .unavailable()
                .contains(&SecurityCapability::OsSecureStore)
        );
        assert!(
            selection
                .capability_evaluation()
                .unavailable()
                .contains(&SecurityCapability::LinuxSecretService)
        );
    }
}
