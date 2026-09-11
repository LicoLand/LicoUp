//! Normalized failure and recovery model.
//!
//! The product already publishes three failure vocabularies: the MCP
//! application error, the runtime adapter failure, and the client (CLI/stdio)
//! error. They agree on `code`, `stage`, and `retryable`, and differ in how they
//! describe what to do next. This module owns the neutral description both
//! interfaces project from, so the same failure cannot be reported differently
//! by the CLI and the MCP for the same cause.
//!
//! The one invariant worth enforcing in the type is effect certainty. A failure
//! that happened *after* an effect was attempted must be reconciled, never
//! blindly retried; [`ApplicationFailure::with_effect`] therefore refuses to
//! build an uncertain failure that says otherwise.

use serde::{Deserialize, Serialize};

/// How much is known about whether the operation took effect.
#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum EffectCertainty {
    /// No effect was attempted, or the failure happened before one could.
    NotAttempted,
    /// The effect is known to have happened.
    Applied,
    /// The effect may or may not have happened. Callers must reconcile against
    /// the durable record before retrying.
    Uncertain,
}

/// What a caller should do about a failure, in neutral terms. Each interface
/// projects this onto its own vocabulary with [`RecoveryAction::cli_wire`] and
/// [`RecoveryAction::mcp_wire`].
#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum RecoveryAction {
    /// The request itself was wrong; fix it before retrying.
    CorrectRequest,
    /// The caller needs the command surface to pick a valid shape.
    UseHelp,
    /// A command argument was wrong.
    CorrectArguments,
    /// A JSON argument did not parse.
    ProvideValidJson,
    /// Too many arguments, or one was too large.
    ReduceArguments,
    /// No adapter can serve this target.
    SelectSupportedAdapter,
    /// The provider is not installed or not reachable yet.
    InstallOrRetryRuntime,
    /// The user's own work is safe; the operation can be retried.
    PreserveDraftAndRetry,
    /// The outcome needs a human read before anything else happens.
    ReviewTerminalResult,
    /// Retry, or read the result first if the caller wants certainty.
    RetryOrReviewRequest,
    /// The dependency is temporarily unhealthy; retry after it recovers.
    RetryAfterRecovery,
    /// Reconcile against the durable record, then decide.
    ReconcileBeforeRetry,
}

impl RecoveryAction {
    /// The value the client (CLI/stdio) vocabulary publishes.
    ///
    /// That vocabulary has no reconcile value: an uncertain effect surfaces
    /// there as a result to review, which is what the CLI already does.
    pub const fn cli_wire(self) -> &'static str {
        match self {
            Self::CorrectRequest => "correct_request",
            Self::UseHelp => "use_cli_help",
            Self::CorrectArguments => "correct_command_arguments",
            Self::ProvideValidJson => "provide_valid_json",
            Self::ReduceArguments => "reduce_command_arguments",
            Self::SelectSupportedAdapter => "select_supported_adapter",
            Self::InstallOrRetryRuntime => "install_or_retry_runtime",
            Self::PreserveDraftAndRetry => "preserve_draft_and_retry",
            Self::ReviewTerminalResult | Self::ReconcileBeforeRetry => "review_terminal_result",
            Self::RetryOrReviewRequest | Self::RetryAfterRecovery => "retry_or_review_request",
        }
    }

    /// The value the MCP vocabulary publishes.
    pub const fn mcp_wire(self) -> &'static str {
        match self {
            Self::CorrectRequest
            | Self::UseHelp
            | Self::CorrectArguments
            | Self::ProvideValidJson
            | Self::ReduceArguments
            | Self::SelectSupportedAdapter => "correct_request_and_retry",
            Self::InstallOrRetryRuntime
            | Self::PreserveDraftAndRetry
            | Self::RetryAfterRecovery => "retry_after_recovery",
            Self::ReviewTerminalResult | Self::RetryOrReviewRequest => "retry_or_review_request",
            Self::ReconcileBeforeRetry => "reconcile_before_retry",
        }
    }

    /// Recovery that demands reconciliation before any retry.
    pub const fn requires_reconciliation(self) -> bool {
        matches!(self, Self::ReconcileBeforeRetry)
    }
}

/// One normalized failure.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct ApplicationFailure {
    /// Stable reason code, identical through either interface.
    pub code: String,
    /// Where it happened, in the existing `area/action` vocabulary.
    pub stage: String,
    pub retryable: bool,
    pub effect: EffectCertainty,
    pub recovery: RecoveryAction,
    /// The offending field when the failure is about one.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub field: Option<String>,
}

impl ApplicationFailure {
    /// A failure the caller cannot fix by retrying.
    pub fn permanent(code: impl Into<String>, stage: impl Into<String>) -> Self {
        Self {
            code: code.into(),
            stage: stage.into(),
            retryable: false,
            effect: EffectCertainty::NotAttempted,
            recovery: RecoveryAction::CorrectRequest,
            field: None,
        }
    }

    /// A failure that is expected to clear on its own.
    pub fn retryable(code: impl Into<String>, stage: impl Into<String>) -> Self {
        Self {
            code: code.into(),
            stage: stage.into(),
            retryable: true,
            effect: EffectCertainty::NotAttempted,
            recovery: RecoveryAction::RetryAfterRecovery,
            field: None,
        }
    }

    /// A failure whose effect may or may not have happened.
    ///
    /// This is the constructor the product's existing rules require for
    /// post-effect failures: uncertain implies retryable *and* reconcile.
    pub fn uncertain(code: impl Into<String>, stage: impl Into<String>) -> Self {
        Self {
            code: code.into(),
            stage: stage.into(),
            retryable: true,
            effect: EffectCertainty::Uncertain,
            recovery: RecoveryAction::ReconcileBeforeRetry,
            field: None,
        }
    }

    /// A request-shape failure, carrying the field that was wrong.
    pub fn invalid_request(field: impl Into<String>) -> Self {
        Self {
            code: "invalid_request".to_owned(),
            stage: "schema/validate".to_owned(),
            retryable: false,
            effect: EffectCertainty::NotAttempted,
            recovery: RecoveryAction::CorrectRequest,
            field: Some(field.into()),
        }
    }

    pub fn with_recovery(mut self, recovery: RecoveryAction) -> Self {
        self.recovery = recovery;
        self
    }

    /// Record what is known about the effect.
    ///
    /// An uncertain effect forces reconcile-before-retry, because the durable
    /// record — not this failure — is what decides whether a retry is safe.
    pub fn with_effect(mut self, effect: EffectCertainty) -> Self {
        self.effect = effect;
        if effect == EffectCertainty::Uncertain {
            self.retryable = true;
            self.recovery = RecoveryAction::ReconcileBeforeRetry;
        }
        self
    }

    /// Whether this failure tells the caller to reconcile first.
    pub fn requires_reconciliation(&self) -> bool {
        self.effect == EffectCertainty::Uncertain || self.recovery.requires_reconciliation()
    }

    /// True when the failure may be retried without reconciling.
    pub fn safe_to_retry(&self) -> bool {
        self.retryable && self.effect != EffectCertainty::Uncertain
    }
}

/// A failure described in neutral terms, before it is projected.
///
/// Callers that already hold a native failure build one of these and let
/// [`FailureNormalization::into_failure`] apply the product's rules, rather than
/// each interface inventing its own `retryable`/`recovery` pairing.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct FailureNormalization {
    pub retryable: bool,
    pub uncertain_effect: bool,
}

impl FailureNormalization {
    pub const PERMANENT: Self = Self {
        retryable: false,
        uncertain_effect: false,
    };
    pub const RETRYABLE: Self = Self {
        retryable: true,
        uncertain_effect: false,
    };
    pub const UNCERTAIN: Self = Self {
        retryable: true,
        uncertain_effect: true,
    };

    /// The default recovery for this shape, before a caller overrides it.
    pub const fn default_recovery(self) -> RecoveryAction {
        if self.uncertain_effect {
            RecoveryAction::ReconcileBeforeRetry
        } else if self.retryable {
            RecoveryAction::RetryAfterRecovery
        } else {
            RecoveryAction::CorrectRequest
        }
    }

    pub fn into_failure(
        self,
        code: impl Into<String>,
        stage: impl Into<String>,
    ) -> ApplicationFailure {
        ApplicationFailure {
            code: code.into(),
            stage: stage.into(),
            retryable: self.retryable,
            effect: if self.uncertain_effect {
                EffectCertainty::Uncertain
            } else {
                EffectCertainty::NotAttempted
            },
            recovery: self.default_recovery(),
            field: None,
        }
    }
}

impl From<FailureNormalization> for ApplicationFailure {
    fn from(normalization: FailureNormalization) -> Self {
        normalization.into_failure("operation_failed", "operation/execute")
    }
}

impl std::fmt::Display for ApplicationFailure {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(&self.code)
    }
}

impl std::error::Error for ApplicationFailure {}
