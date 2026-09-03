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
    LegacyLaunchConfiguration,
    InvalidRuntimeSetting { field: &'static str },
    AttachmentUnsupportedForAdapter { agent_label: String },
    AttachmentListExceeded,
    AttachmentInvalid,
    AttachmentRemoteUnsupported,
    AttachmentMediaUnsupported,
    AttachmentSymlinkRejected,
    AttachmentFileUnavailable,
    AttachmentSizeLimit,
    AttachmentSignatureMismatch,
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
            Self::LegacyLaunchConfiguration => ClientError::new(
                ClientErrorCode::InvalidRequest,
                ClientErrorStage::RequestValidation,
                ClientErrorComponent::RuntimeAdapter,
                false,
                ClientErrorRecovery::CorrectRequest,
            )
            .with_presentation_arg("field", "launch"),
            Self::InvalidRuntimeSetting { field } => ClientError::new(
                ClientErrorCode::InvalidRequest,
                ClientErrorStage::RequestValidation,
                ClientErrorComponent::RuntimeAdapter,
                false,
                ClientErrorRecovery::CorrectRequest,
            )
            .with_presentation_arg("field", *field),
            Self::AttachmentUnsupportedForAdapter { agent_label } => ClientError::new(
                ClientErrorCode::AgentRuntimeUnsupported,
                ClientErrorStage::DiscoveryAdapter,
                ClientErrorComponent::RuntimeAdapter,
                false,
                ClientErrorRecovery::SelectSupportedAdapter,
            )
            .with_presentation_arg("agentLabel", agent_label),
            Self::AttachmentListExceeded => ClientError::new(
                ClientErrorCode::AgentMessageInputLimit,
                ClientErrorStage::RequestValidation,
                ClientErrorComponent::RuntimeAdapter,
                false,
                ClientErrorRecovery::CorrectRequest,
            )
            .with_presentation_arg("field", "attachments")
            .with_presentation_arg("limit", "4"),
            Self::AttachmentInvalid => ClientError::new(
                ClientErrorCode::InvalidRequest,
                ClientErrorStage::RequestValidation,
                ClientErrorComponent::RuntimeAdapter,
                false,
                ClientErrorRecovery::CorrectRequest,
            )
            .with_presentation_arg("field", "attachments"),
            Self::AttachmentRemoteUnsupported => ClientError::new(
                ClientErrorCode::InvalidRequest,
                ClientErrorStage::RequestValidation,
                ClientErrorComponent::RuntimeAdapter,
                false,
                ClientErrorRecovery::CorrectRequest,
            )
            .with_presentation_arg("field", "attachments"),
            Self::AttachmentMediaUnsupported => ClientError::new(
                ClientErrorCode::InvalidRequest,
                ClientErrorStage::RequestValidation,
                ClientErrorComponent::RuntimeAdapter,
                false,
                ClientErrorRecovery::CorrectRequest,
            )
            .with_presentation_arg("field", "mediaType"),
            Self::AttachmentSymlinkRejected => ClientError::new(
                ClientErrorCode::InvalidRequest,
                ClientErrorStage::RequestValidation,
                ClientErrorComponent::RuntimeAdapter,
                false,
                ClientErrorRecovery::CorrectRequest,
            )
            .with_presentation_arg("field", "attachments"),
            Self::AttachmentFileUnavailable => ClientError::new(
                ClientErrorCode::AgentConversationDispatchFailed,
                ClientErrorStage::ConversationDispatch,
                ClientErrorComponent::ConversationRuntime,
                true,
                ClientErrorRecovery::PreserveDraftAndRetry,
            ),
            Self::AttachmentSizeLimit => ClientError::new(
                ClientErrorCode::AgentMessageInputLimit,
                ClientErrorStage::RequestValidation,
                ClientErrorComponent::RuntimeAdapter,
                false,
                ClientErrorRecovery::CorrectRequest,
            )
            .with_presentation_arg("field", "attachments"),
            Self::AttachmentSignatureMismatch => ClientError::new(
                ClientErrorCode::InvalidRequest,
                ClientErrorStage::RequestValidation,
                ClientErrorComponent::RuntimeAdapter,
                false,
                ClientErrorRecovery::CorrectRequest,
            )
            .with_presentation_arg("field", "mediaType"),
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
            Self::LegacyLaunchConfiguration => {
                "legacy command and argument launch configuration is not supported"
            }
            Self::InvalidRuntimeSetting { .. } => {
                "agent conversation request contains an invalid runtime setting"
            }
            Self::AttachmentUnsupportedForAdapter { .. } => {
                "image attachments are not supported by this runtime adapter"
            }
            Self::AttachmentListExceeded => {
                "agent message request exceeds the image attachment limit"
            }
            Self::AttachmentInvalid => "agent message request contains an invalid image attachment",
            Self::AttachmentRemoteUnsupported => {
                "image attachments must be local files, not remote URLs"
            }
            Self::AttachmentMediaUnsupported => "image attachment media type is not supported",
            Self::AttachmentSymlinkRejected => {
                "image attachment must be a regular file, not a symbolic link"
            }
            Self::AttachmentFileUnavailable => "image attachment file is unavailable",
            Self::AttachmentSizeLimit => "image attachment exceeds the size limit",
            Self::AttachmentSignatureMismatch => {
                "image attachment content does not match its declared media type"
            }
            Self::UnsupportedAdapter { .. } => "unsupported runtime adapter",
            Self::RuntimeProfileUnavailable => "native agent runtime profile is unavailable",
            Self::ExecutableUnavailable => "native agent executable is unavailable",
            Self::ConversationDispatchFailed => "agent conversation dispatch failed",
        })
    }
}

impl std::error::Error for RuntimeAdapterError {}
