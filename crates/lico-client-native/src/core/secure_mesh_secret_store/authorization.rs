use std::any::Any;
use std::fmt;
use std::sync::{
    Arc,
    atomic::{AtomicUsize, Ordering},
};

use anyhow::{Result, anyhow};
use uuid::Uuid;

use crate::core::secure_mesh_capability::CapabilityEvaluationReport;

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

#[derive(Clone)]
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
    platform_context: Option<Arc<dyn Any + Send + Sync>>,
}

impl SecretStoreAuthorizationSession {
    pub(crate) fn new(
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
            platform_context: None,
        }
    }

    pub(crate) fn with_platform_context<T>(
        mut self,
        context: T,
        system_authorization_attempt_count: usize,
        system_authorization_completed: bool,
    ) -> Self
    where
        T: Any + Send + Sync,
    {
        self.shared_system_context_available = true;
        self.system_authorization_attempt_count = system_authorization_attempt_count;
        self.system_authorization_completed = system_authorization_completed;
        self.platform_context = Some(Arc::new(context));
        self
    }

    pub(crate) fn platform_context<T>(&self) -> Option<&T>
    where
        T: Any + Send + Sync,
    {
        self.platform_context.as_deref()?.downcast_ref::<T>()
    }

    #[cfg(test)]
    pub(crate) fn with_test_system_authorization_outcome(
        mut self,
        attempt_count: usize,
        completed: bool,
        app_password_prompt_used: bool,
    ) -> Self {
        self.system_authorization_attempt_count = attempt_count;
        self.system_authorization_completed = completed;
        self.app_password_prompt_used = app_password_prompt_used;
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

    pub(crate) fn with_capability_report(
        mut self,
        capability_report: CapabilityEvaluationReport,
    ) -> Self {
        self.capability_report = Some(capability_report);
        self
    }
}

impl fmt::Debug for SecretStoreAuthorizationSession {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("SecretStoreAuthorizationSession")
            .field("backend", &self.backend)
            .field("operation_count", &self.operation_count)
            .field("allow_interaction", &self.allow_interaction)
            .field(
                "shared_system_context_required",
                &self.shared_system_context_required,
            )
            .field(
                "shared_system_context_available",
                &self.shared_system_context_available,
            )
            .field("consumed_operation_count", &self.consumed_operation_count())
            .field(
                "platform_context",
                &self.platform_context.as_ref().map(|_| "redacted"),
            )
            .finish()
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
