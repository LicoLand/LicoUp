//! Fresh, operation-scoped platform user-presence authorization.
//!
//! This port deliberately has no domain or secret-store dependency. Security
//! consumers receive a new OS context for every exact operation; contexts are
//! never cached globally or inherited by background work.

#[cfg(target_os = "macos")]
use anyhow::ensure;
use anyhow::{Result, anyhow};

#[cfg(target_os = "macos")]
mod macos {
    use super::*;
    use core::ffi::c_void;
    use core_foundation::base::{CFType, TCFType};
    use core_foundation_sys::base::CFTypeRef;
    use objc2::rc::Retained;
    use objc2_foundation::{NSError, NSString};
    use objc2_local_authentication::{LAContext, LAError, LAPolicy};
    use std::sync::mpsc;
    use std::time::Duration;

    #[derive(Clone)]
    pub(crate) struct Session {
        context: Retained<LAContext>,
    }

    // SAFETY: the retained context is immutable after authorization and is
    // passed only to synchronous Security.framework calls.
    unsafe impl Send for Session {}
    // SAFETY: no shared reference mutates LAContext after construction.
    unsafe impl Sync for Session {}

    impl Session {
        pub(crate) fn as_cf_type(&self) -> CFType {
            let pointer = (&*self.context as *const LAContext).cast::<c_void>() as CFTypeRef;
            // SAFETY: `self.context` retains the object; get-rule wrapping does
            // not consume it.
            unsafe { CFType::wrap_under_get_rule(pointer) }
        }
    }

    pub(crate) fn available() -> bool {
        if cfg!(test) {
            return false;
        }
        // SAFETY: LAContext::new returns a retained initialized context.
        let context = unsafe { LAContext::new() };
        // SAFETY: the context is live and the policy is SDK-defined.
        unsafe {
            context
                .canEvaluatePolicy_error(LAPolicy::DeviceOwnerAuthentication)
                .is_ok()
        }
    }

    pub(crate) fn authorize(reason: &str, scope: &str) -> Result<Session> {
        ensure!(
            reason == reason.trim()
                && !reason.is_empty()
                && reason.len() <= 768
                && !reason.chars().any(char::is_control)
                && scope == scope.trim()
                && !scope.is_empty()
                && scope.len() <= 2_048
                && !scope.chars().any(char::is_control),
            "user_presence_authorization_scope_invalid"
        );
        // SAFETY: LAContext::new returns a retained initialized context.
        let context = unsafe { LAContext::new() };
        let reason = NSString::from_str(reason);
        // A zero reuse window and a fresh context forbid inheritance from any
        // previous authorization.
        unsafe {
            context.setLocalizedReason(&reason);
            context.setInteractionNotAllowed(false);
            context.setTouchIDAuthenticationAllowableReuseDuration(0.0);
        }
        let policy = unsafe {
            context
                .canEvaluatePolicy_error(LAPolicy::DeviceOwnerAuthentication)
                .map_err(|_| anyhow!("user_presence_authorization_unavailable"))?;
            LAPolicy::DeviceOwnerAuthentication
        };
        let (sender, receiver) = mpsc::channel();
        let reply =
            block2::RcBlock::new(move |success: objc2::runtime::Bool, error: *mut NSError| {
                let error_code = if error.is_null() {
                    None
                } else {
                    // SAFETY: LocalAuthentication owns the NSError for the
                    // callback duration; only its scalar code is copied.
                    Some(unsafe { (*error).code() })
                };
                let _ = sender.send((success.as_bool(), error_code));
            });
        // SAFETY: the retained context, reason, and reply remain live through
        // submission; the block retains its captured channel sender.
        unsafe { context.evaluatePolicy_localizedReason_reply(policy, &reason, &reply) };
        match receiver.recv_timeout(Duration::from_secs(120)) {
            Ok((true, _)) => {}
            Ok((false, code)) => {
                return Err(anyhow!(
                    "user_presence_authorization_failed:{}",
                    error_category(code)
                ));
            }
            Err(mpsc::RecvTimeoutError::Timeout) => {
                // SAFETY: invalidate is the documented cancellation operation.
                unsafe { context.invalidate() };
                return Err(anyhow!("user_presence_authorization_timed_out"));
            }
            Err(_) => return Err(anyhow!("user_presence_authorization_callback_missing")),
        }
        // Keychain calls may use this already-authorized context but may never
        // open another interactive prompt.
        unsafe { context.setInteractionNotAllowed(true) };
        Ok(Session { context })
    }

    fn error_category(code: Option<isize>) -> &'static str {
        match code {
            Some(value) if value == LAError::UserCancel.0 => "user_cancelled",
            Some(value) if value == LAError::SystemCancel.0 => "system_cancelled",
            Some(value) if value == LAError::AppCancel.0 => "application_cancelled",
            Some(value) if value == LAError::BiometryLockout.0 => "biometry_locked",
            Some(value) if value == LAError::BiometryNotAvailable.0 => "biometry_unavailable",
            Some(value) if value == LAError::BiometryNotEnrolled.0 => "biometry_not_enrolled",
            Some(value) if value == LAError::PasscodeNotSet.0 => "credential_unavailable",
            Some(value) if value == LAError::AuthenticationFailed.0 => "authentication_failed",
            _ => "authorization_unavailable",
        }
    }
}

#[cfg(target_os = "macos")]
pub(crate) use macos::Session as UserPresenceSession;

#[cfg(not(target_os = "macos"))]
#[derive(Clone)]
pub(crate) struct UserPresenceSession;

pub(crate) fn available() -> bool {
    #[cfg(target_os = "macos")]
    {
        macos::available()
    }
    #[cfg(not(target_os = "macos"))]
    {
        false
    }
}

pub(crate) fn authorize(reason: &str, scope: &str) -> Result<UserPresenceSession> {
    #[cfg(target_os = "macos")]
    {
        macos::authorize(reason, scope)
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = (reason, scope);
        Err(anyhow!("user_presence_authorization_unavailable"))
    }
}
