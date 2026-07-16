use anyhow::{Result, anyhow};

use crate::core::secure_mesh_capability::{
    CapabilityEvidenceKind, CapabilityFact, SecurityCapability,
};

use crate::core::secure_mesh_secret_store::{
    SecretStoreAuthorizationRequest, SecretStoreAuthorizationSession,
};
use crate::core::secure_mesh_secret_store::{SecretStoreHandle, is_persistable_secret};

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
    kSecAttrAccessControl, kSecAttrAccount, kSecAttrService, kSecClass, kSecClassGenericPassword,
    kSecReturnData, kSecUseAuthenticationContext, kSecUseDataProtectionKeychain, kSecValueData,
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

macro_rules! security_framework_static {
    ($value:expr, $wrapper:ident) => {{
        // SAFETY: every invocation passes a Security.framework SDK-exported static CFString.
        // Reading that extern static is safe for the process lifetime; the wrapper applies
        // Core Foundation get-rule ownership without consuming the immortal object.
        unsafe { $wrapper($value) }
    }};
}

const MACOS_APP_AUTHORIZATION_SCOPE: &str = "app.licolite.licoarc.local-secrets";
const MACOS_AUTHORIZATION_CACHE_TTL: Duration = Duration::from_secs(5 * 60);
const MACOS_AUTHORIZATION_CACHE_MAX_SCOPES: usize = 8;

#[derive(Clone)]
struct CachedAuthorizationContext {
    context: MacosAuthorizationContext,
    authorized_at: Instant,
}

static AUTHORIZATION_CONTEXT_CACHE: OnceLock<Mutex<HashMap<String, CachedAuthorizationContext>>> =
    OnceLock::new();
static TEST_USER_PRESENCE_DISABLED: AtomicBool = AtomicBool::new(false);

#[derive(Clone)]
pub struct MacosAuthorizationContext {
    context: Retained<LAContext>,
}

// SAFETY: Retained<LAContext> keeps the Objective-C object alive, and this wrapper only shares
// immutable references with synchronous Security.framework calls. Prompt lifecycle and mutable
// authentication state remain owned by LocalAuthentication.
unsafe impl Send for MacosAuthorizationContext {}
// SAFETY: The same retained, immutable-use invariant applies to shared references; all cache
// mutation is serialized by AUTHORIZATION_CONTEXT_CACHE and no Rust alias mutates LAContext.
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
    // SAFETY: objc2 marks Objective-C constructors unsafe; LAContext::new returns a retained,
    // initialized context and no raw pointer escapes this scope.
    let context = unsafe { LAContext::new() };
    // SAFETY: context is a live retained LAContext and the policy enum is an SDK-defined value.
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
        SecretStoreAuthorizationSession::new(backend, request, true, true).with_platform_context(
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

    // SAFETY: LAContext::new returns a retained, initialized Objective-C object.
    let context = unsafe { LAContext::new() };
    let reason = NSString::from_str(request.reason());
    // SAFETY: context and reason are retained for every Objective-C call in this block; the
    // supplied reuse duration and interaction flag are ordinary value parameters.
    unsafe {
        context.setLocalizedReason(&reason);
        context.setInteractionNotAllowed(!request.allow_interaction());
        context.setTouchIDAuthenticationAllowableReuseDuration(300.0);
    }
    let policy = preferred_system_authorization_policy(&context)?;
    // Keep the cache lock across evaluation. Concurrent callers for the same process
    // cannot race into multiple Touch ID/password sheets.
    evaluate_system_authorization_once(&context, policy, &reason)?;
    // SAFETY: context remains retained in this function and disabling interaction is a
    // synchronous Objective-C property update.
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
    // SAFETY: context is borrowed from a live Retained<LAContext>; the policy value is defined by
    // LocalAuthentication and the error object is managed by objc2.
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
    let reply = block2::RcBlock::new(move |success: objc2::runtime::Bool, error: *mut NSError| {
        let error_code = if error.is_null() {
            None
        } else {
            // SAFETY: LocalAuthentication supplies NSError or null for the callback lifetime;
            // the null case is handled above and only the scalar code is copied.
            Some(unsafe { (*error).code() })
        };
        let _ = sender.send((success.as_bool(), error_code));
    });
    // SAFETY: context, reason, and reply block remain alive until this synchronous submission
    // returns; RcBlock retains the callback state for LocalAuthentication.
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
            // SAFETY: context remains a valid retained LAContext; invalidate is the documented
            // cancellation operation after a timed-out evaluation.
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
    let account = handle.account();
    let query = CFDictionary::from_CFType_pairs(&base_pairs(service, &account, context));
    let update = CFDictionary::from_CFType_pairs(&[(
        security_framework_static!(kSecValueData, sec_key),
        CFData::from_buffer(secret.as_bytes()).into_CFType(),
    )]);
    // Update first so a failed replacement leaves the committed Keychain item
    // intact. Only a verified not-found result may create a new item.
    let update_status =
        unsafe { SecItemUpdate(query.as_concrete_TypeRef(), update.as_concrete_TypeRef()) };
    match keychain_update_transition(update_status) {
        KeychainUpdateTransition::Complete => return Ok(()),
        KeychainUpdateTransition::AddNew => {}
        KeychainUpdateTransition::Fail(status) => {
            return status_result(service, "write", handle, status);
        }
    }

    let access_control = SecAccessControl::create_with_protection(
        Some(ProtectionMode::AccessibleWhenUnlockedThisDeviceOnly),
        kSecAccessControlUserPresence,
    )
    .map_err(|_| {
        anyhow!(
            "secure mesh macOS user-presence access control unavailable for {}",
            handle.key()
        )
    })?;
    let mut pairs = base_pairs(service, &account, context);
    pairs.push((
        security_framework_static!(kSecAttrAccessControl, sec_key),
        access_control.into_CFType(),
    ));
    pairs.push((
        security_framework_static!(kSecValueData, sec_key),
        CFData::from_buffer(secret.as_bytes()).into_CFType(),
    ));
    let add_query = CFDictionary::from_CFType_pairs(&pairs);
    // SAFETY: add_query owns all referenced CF values for the duration of the synchronous
    // Security.framework call; no result pointer is requested.
    let add_status = unsafe { SecItemAdd(add_query.as_concrete_TypeRef(), ptr::null_mut()) };
    if add_status == errSecSuccess {
        return Ok(());
    }
    if add_status == errSecDuplicateItem {
        // Resolve an insert race with another atomic update. Failure still
        // preserves whichever value is already committed.
        // SAFETY: query and update own valid CF dictionaries and remain alive throughout the
        // synchronous update call.
        let retry_status =
            unsafe { SecItemUpdate(query.as_concrete_TypeRef(), update.as_concrete_TypeRef()) };
        return status_result(service, "write", handle, retry_status);
    }
    status_result(service, "write", handle, add_status)
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum KeychainUpdateTransition {
    Complete,
    AddNew,
    Fail(i32),
}

fn keychain_update_transition(status: i32) -> KeychainUpdateTransition {
    if status == errSecSuccess {
        KeychainUpdateTransition::Complete
    } else if status == errSecItemNotFound {
        KeychainUpdateTransition::AddNew
    } else {
        KeychainUpdateTransition::Fail(status)
    }
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
        security_framework_static!(kSecReturnData, sec_key),
        CFBoolean::from(true).into_CFType(),
    ));
    let query = CFDictionary::from_CFType_pairs(&pairs);
    let mut copied: CFTypeRef = ptr::null();
    // SAFETY: query is a live CFDictionary and copied is a valid out-pointer initialized to null;
    // Security.framework transfers a +1 object only on success.
    let status = unsafe { SecItemCopyMatching(query.as_concrete_TypeRef(), &mut copied) };
    if status == errSecItemNotFound {
        return Ok(None);
    }
    status_result(service, "read", handle, status)?;
    if copied.is_null() {
        return Ok(None);
    }
    // SAFETY: copied was checked non-null after a successful SecItemCopyMatching call.
    let type_id = unsafe { CFGetTypeID(copied) };
    if type_id != CFData::type_id() {
        // SAFETY: SecItemCopyMatching returned copied at +1 ownership and it has not been released.
        unsafe { CFRelease(copied) };
        return Err(anyhow!(
            "secure mesh macOS user-presence secret store returned unexpected data for {}",
            handle.key()
        ));
    }
    // SAFETY: type identity was verified as CFData and +1 ownership is transferred to CFData.
    let data = unsafe { CFData::wrap_under_create_rule(copied as CFDataRef) };
    let mut bytes = Vec::new();
    bytes.extend_from_slice(data.bytes());
    let secret = String::from_utf8(bytes).map_err(|_| {
        anyhow!(
            "secure mesh macOS user-presence secret store returned non-UTF8 data for {}",
            handle.key()
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
    // SAFETY: query owns valid CF key/value pairs and remains alive during the synchronous delete.
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
    session.platform_context::<MacosAuthorizationContext>().ok_or_else(|| {
        anyhow!(
            "secure mesh macOS user-presence secret store has no shared system authorization context for {}",
            handle.key()
        )
    })
}

fn base_pairs(
    service: &str,
    account: &str,
    context: &MacosAuthorizationContext,
) -> Vec<(CFString, CFType)> {
    let mut pairs = vec![
        (
            security_framework_static!(kSecClass, sec_key),
            security_framework_static!(kSecClassGenericPassword, sec_string_value),
        ),
        (
            security_framework_static!(kSecAttrService, sec_key),
            CFString::from(service).into_CFType(),
        ),
        (
            security_framework_static!(kSecAttrAccount, sec_key),
            CFString::from(account).into_CFType(),
        ),
        (
            security_framework_static!(kSecUseAuthenticationContext, sec_key),
            context.as_cf_type(),
        ),
    ];
    // Every build requires the Data Protection Keychain. A local/debug
    // build without a valid provisioning entitlement must fail closed;
    // the legacy Keychain does not reliably enforce userPresence.
    pairs.push((
        security_framework_static!(kSecUseDataProtectionKeychain, sec_key),
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
            handle.key(),
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

fn sec_key(value: CFStringRef) -> CFString {
    // SAFETY: callers pass SDK-exported static CFString constants. The get-rule wrapper borrows
    // that immortal object and does not consume ownership.
    unsafe { CFString::wrap_under_get_rule(value) }
}

fn sec_string_value(value: CFStringRef) -> CFType {
    sec_key(value).into_CFType()
}

impl MacosAuthorizationContext {
    fn as_cf_type(&self) -> CFType {
        let pointer = (&*self.context as *const LAContext).cast::<c_void>() as CFTypeRef;
        // SAFETY: self.context retains the Objective-C object for the returned wrapper lifetime;
        // get-rule wrapping neither releases nor assumes ownership of the pointer.
        unsafe { CFType::wrap_under_get_rule(pointer) }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn update_failure_never_falls_through_to_add() {
        assert_eq!(
            keychain_update_transition(errSecAuthFailed),
            KeychainUpdateTransition::Fail(errSecAuthFailed)
        );
        assert_eq!(
            keychain_update_transition(ERR_SEC_INTERACTION_NOT_ALLOWED),
            KeychainUpdateTransition::Fail(ERR_SEC_INTERACTION_NOT_ALLOWED)
        );
    }

    #[test]
    fn add_is_reached_only_after_verified_not_found() {
        assert_eq!(
            keychain_update_transition(errSecSuccess),
            KeychainUpdateTransition::Complete
        );
        assert_eq!(
            keychain_update_transition(errSecItemNotFound),
            KeychainUpdateTransition::AddNew
        );
    }
}
