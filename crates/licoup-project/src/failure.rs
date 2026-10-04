//! Typed refusals.
//!
//! Every refusal this owner makes is a code both interfaces can report, because
//! "the project was not registered" and "why" are two different answers. The
//! codes are stable strings, not display text: a caller that reacts to
//! `project_identity_duplicate` must not have to match a sentence.

use std::fmt;

/// Where an identity that could not be parsed was refused.
pub const IDENTITY_STAGE: &str = "project/identity";
/// Where a registration that could not be admitted was refused.
pub const REGISTRATION_STAGE: &str = "project/register";
/// Where a dependency that could not be admitted was refused.
pub const DEPENDENCY_STAGE: &str = "project/dependency";
/// Where a durable store operation failed.
pub const STORE_STAGE: &str = "project/store";
/// Where a plan document that could not be admitted was refused.
pub const IMPORT_STAGE: &str = "project/import";

/// One refusal, with the owner's own code and the stage that produced it.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ProjectFailure {
    code: &'static str,
    stage: &'static str,
    detail: Option<String>,
}

impl ProjectFailure {
    pub const fn new(code: &'static str, stage: &'static str) -> Self {
        Self {
            code,
            stage,
            detail: None,
        }
    }

    /// A refusal raised while parsing a declared identifier.
    pub const fn identity(code: &'static str) -> Self {
        Self::new(code, IDENTITY_STAGE)
    }

    /// A refusal raised while admitting one registration.
    pub const fn registration(code: &'static str) -> Self {
        Self::new(code, REGISTRATION_STAGE)
    }

    /// A refusal raised while admitting one declared dependency.
    pub const fn dependency(code: &'static str) -> Self {
        Self::new(code, DEPENDENCY_STAGE)
    }

    /// A refusal raised while admitting one canonical plan document.
    pub const fn import(code: &'static str) -> Self {
        Self::new(code, IMPORT_STAGE)
    }

    /// A refusal raised by the durable store itself.
    pub fn store(code: &'static str) -> Self {
        Self::new(code, STORE_STAGE)
    }

    /// Attach the underlying cause for diagnostics.
    ///
    /// The code stays the identity a caller branches on; the detail exists so a
    /// store failure is debuggable without a second log channel.
    pub fn with_detail(mut self, detail: impl Into<String>) -> Self {
        let detail = detail.into();
        self.detail = (!detail.is_empty()).then_some(detail);
        self
    }

    pub const fn code(&self) -> &'static str {
        self.code
    }

    pub const fn stage(&self) -> &'static str {
        self.stage
    }

    pub fn detail(&self) -> Option<&str> {
        self.detail.as_deref()
    }
}

impl fmt::Display for ProjectFailure {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match &self.detail {
            Some(detail) => write!(formatter, "{} ({detail})", self.code),
            None => formatter.write_str(self.code),
        }
    }
}

impl std::error::Error for ProjectFailure {}
