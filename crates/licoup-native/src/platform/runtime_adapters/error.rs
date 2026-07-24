use crate::ffi::generated::client_error::{
    ClientError, ClientErrorCode, ClientErrorComponent, ClientErrorRecovery, ClientErrorStage,
};
use std::fmt;

// The generated ClientError carries code, stage, component, retryable,
// recovery, and presentationArgs as one immutable source-selected value.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum RuntimeAdapterError {
    AgentIdentifierMissing,
    MessageMissing,
    MessageInputLimit,
    UnsupportedAdapter { agent_label: String },
    RuntimeProfileUnavailable,
    ExecutableUnavailable,
    ConversationDispatchFailed,
}

impl RuntimeAdapterError {
    pub fn client_error(&self) -> ClientError {
        match self {
            Self::AgentIdentifierMissing => ClientError::new(
                ClientErrorCode::AgentIdentifierMissing,
                ClientErrorStage::RequestValidation,
                ClientErrorComponent::RuntimeAdapter,
                false,
                ClientErrorRecovery::CorrectRequest,
            )
            .with_presentation_arg("field", "agent"),
            Self::MessageMissing => ClientError::new(
                ClientErrorCode::AgentMessageMissing,
                ClientErrorStage::RequestValidation,
                ClientErrorComponent::RuntimeAdapter,
                false,
                ClientErrorRecovery::CorrectRequest,
            )
            .with_presentation_arg("field", "message"),
            Self::MessageInputLimit => ClientError::new(
                ClientErrorCode::AgentMessageInputLimit,
                ClientErrorStage::RequestValidation,
                ClientErrorComponent::RuntimeAdapter,
                false,
                ClientErrorRecovery::CorrectRequest,
            )
            .with_presentation_arg("field", "message"),
            Self::UnsupportedAdapter { agent_label } => ClientError::new(
                ClientErrorCode::AgentRuntimeUnsupported,
                ClientErrorStage::DiscoveryAdapter,
                ClientErrorComponent::RuntimeAdapter,
                false,
                ClientErrorRecovery::SelectSupportedAdapter,
            )
            .with_presentation_arg("agentLabel", agent_label),
            Self::RuntimeProfileUnavailable => ClientError::new(
                ClientErrorCode::NativeAgentRuntimeProfileUnavailable,
                ClientErrorStage::DiscoveryDriver,
                ClientErrorComponent::RuntimeAdapter,
                true,
                ClientErrorRecovery::InstallOrRetryRuntime,
            ),
            Self::ExecutableUnavailable => ClientError::new(
                ClientErrorCode::NativeAgentExecutableUnavailable,
                ClientErrorStage::ProcessLaunch,
                ClientErrorComponent::RuntimeProcess,
                true,
                ClientErrorRecovery::InstallOrRetryRuntime,
            ),
            Self::ConversationDispatchFailed => ClientError::new(
                ClientErrorCode::AgentConversationDispatchFailed,
                ClientErrorStage::ConversationDispatch,
                ClientErrorComponent::ConversationRuntime,
                true,
                ClientErrorRecovery::PreserveDraftAndRetry,
            ),
        }
    }
}

impl fmt::Display for RuntimeAdapterError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(match self {
            Self::AgentIdentifierMissing => {
                "agent conversation request requires an agent identifier"
            }
            Self::MessageMissing => "agent message request requires message text",
            Self::MessageInputLimit => "agent message request exceeds the input limit",
            Self::UnsupportedAdapter { .. } => "unsupported runtime adapter",
            Self::RuntimeProfileUnavailable => "native agent runtime profile is unavailable",
            Self::ExecutableUnavailable => "native agent executable is unavailable",
            Self::ConversationDispatchFailed => "agent conversation dispatch failed",
        })
    }
}

impl std::error::Error for RuntimeAdapterError {}
