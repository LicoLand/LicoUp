use anyhow::{Result, anyhow, bail, ensure};
use sha2::{Digest, Sha256};

use crate::core::secure_mesh::SECURE_MESH_PROTOCOL_VERSION;
use crate::core::secure_mesh_crypto::{
    OpenedSecureMeshPayload, SecureMeshContentContext, SecureMeshPayloadKind, SecureMeshPlaintext,
};
use crate::core::secure_mesh_pairwise::SecureMeshPairwiseSession;
use crate::core::secure_mesh_relay_envelope::SecureMeshRelayEnvelope;

pub const SECURE_MESH_ACP_ENVELOPE_PROTOCOL: &str = "licolite.secure-mesh.acp-envelope.v1";
pub const SECURE_MESH_ACP_STATUS: &str = "acp_protected_envelope_aad_available_plaintext_protected_payload_relay_blocked_independent_review_pending_pqxdh_mlkem1024_triple_ratchet";

const ACP_AAD_MAGIC: &[u8] = b"LCOSM-ACP-AAD-v1";
const MAX_FIELD_BYTES: usize = 4096;
const MAX_DIGEST_HEX_BYTES: usize = 128;

/// ACP agent-conversation payload classes that must be sealed before relay.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum SecureMeshAcpPayloadClass {
    Prompt,
    Update,
    Reasoning,
    ToolArguments,
    ToolResult,
    FilesystemContent,
    TerminalContent,
    PermissionPayload,
    ApprovalDecision,
    Artifact,
    ArchiveLayer,
    Receipt,
}

impl SecureMeshAcpPayloadClass {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Prompt => "prompt",
            Self::Update => "update",
            Self::Reasoning => "reasoning",
            Self::ToolArguments => "tool_arguments",
            Self::ToolResult => "tool_result",
            Self::FilesystemContent => "filesystem_content",
            Self::TerminalContent => "terminal_content",
            Self::PermissionPayload => "permission_payload",
            Self::ApprovalDecision => "approval_decision",
            Self::Artifact => "artifact",
            Self::ArchiveLayer => "archive_layer",
            Self::Receipt => "receipt",
        }
    }

    pub fn is_protected(self) -> bool {
        !matches!(self, Self::Receipt)
    }

    pub fn content_type(self) -> &'static str {
        match self {
            Self::Prompt => "application/licolite.secure-mesh.acp.prompt.v1",
            Self::Update => "application/licolite.secure-mesh.acp.update.v1",
            Self::Reasoning => "application/licolite.secure-mesh.acp.reasoning.v1",
            Self::ToolArguments => "application/licolite.secure-mesh.acp.tool-arguments.v1",
            Self::ToolResult => "application/licolite.secure-mesh.acp.tool-result.v1",
            Self::FilesystemContent => "application/licolite.secure-mesh.acp.filesystem.v1",
            Self::TerminalContent => "application/licolite.secure-mesh.acp.terminal.v1",
            Self::PermissionPayload => "application/licolite.secure-mesh.acp.permission.v1",
            Self::ApprovalDecision => "application/licolite.secure-mesh.acp.approval.v1",
            Self::Artifact => "application/licolite.secure-mesh.acp.artifact.v1",
            Self::ArchiveLayer => "application/licolite.secure-mesh.acp.archive.v1",
            Self::Receipt => "application/licolite.secure-mesh.acp.receipt.v1",
        }
    }

    fn from_str(value: &str) -> Result<Self> {
        match value {
            "prompt" => Ok(Self::Prompt),
            "update" => Ok(Self::Update),
            "reasoning" => Ok(Self::Reasoning),
            "tool_arguments" => Ok(Self::ToolArguments),
            "tool_result" => Ok(Self::ToolResult),
            "filesystem_content" => Ok(Self::FilesystemContent),
            "terminal_content" => Ok(Self::TerminalContent),
            "permission_payload" => Ok(Self::PermissionPayload),
            "approval_decision" => Ok(Self::ApprovalDecision),
            "artifact" => Ok(Self::Artifact),
            "archive_layer" => Ok(Self::ArchiveLayer),
            "receipt" => Ok(Self::Receipt),
            _ => bail!("secure mesh ACP payload class is unsupported"),
        }
    }
}

/// Cryptographic AAD binding for ACP protected envelopes (REQ-E2EE-014).
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SecureMeshAcpEnvelopeBinding {
    pub payload_class: SecureMeshAcpPayloadClass,
    pub source_endpoint_id: String,
    pub target_endpoint_id: String,
    pub acp_session_id: String,
    pub relay_session_id: String,
    pub relay_turn_id: String,
    pub message_sequence: u64,
    pub operation_id: Option<String>,
    pub mcp_child_operation_id: Option<String>,
    pub tool_call_id: Option<String>,
    pub permission_request_id: Option<String>,
    pub artifact_id: Option<String>,
    pub terminal_request_id: Option<String>,
    pub idempotency_key: Option<String>,
    pub retry_counter: Option<u32>,
    pub expires_at: Option<String>,
    pub policy_revision: Option<String>,
    pub grant_id: Option<String>,
    pub parent_transcript_digest: Option<String>,
    pub previous_envelope_digest: Option<String>,
}

impl SecureMeshAcpEnvelopeBinding {
    pub fn new(
        payload_class: SecureMeshAcpPayloadClass,
        source_endpoint_id: impl Into<String>,
        target_endpoint_id: impl Into<String>,
        acp_session_id: impl Into<String>,
        relay_session_id: impl Into<String>,
        relay_turn_id: impl Into<String>,
        message_sequence: u64,
    ) -> Result<Self> {
        let binding = Self {
            payload_class,
            source_endpoint_id: source_endpoint_id.into(),
            target_endpoint_id: target_endpoint_id.into(),
            acp_session_id: acp_session_id.into(),
            relay_session_id: relay_session_id.into(),
            relay_turn_id: relay_turn_id.into(),
            message_sequence,
            operation_id: None,
            mcp_child_operation_id: None,
            tool_call_id: None,
            permission_request_id: None,
            artifact_id: None,
            terminal_request_id: None,
            idempotency_key: None,
            retry_counter: None,
            expires_at: None,
            policy_revision: None,
            grant_id: None,
            parent_transcript_digest: None,
            previous_envelope_digest: None,
        };
        binding.validate()?;
        Ok(binding)
    }

    pub fn validate(&self) -> Result<()> {
        require_text("source_endpoint_id", &self.source_endpoint_id)?;
        require_text("target_endpoint_id", &self.target_endpoint_id)?;
        require_text("acp_session_id", &self.acp_session_id)?;
        require_text("relay_session_id", &self.relay_session_id)?;
        require_text("relay_turn_id", &self.relay_turn_id)?;
        optional_text("operation_id", self.operation_id.as_deref())?;
        optional_text(
            "mcp_child_operation_id",
            self.mcp_child_operation_id.as_deref(),
        )?;
        optional_text("tool_call_id", self.tool_call_id.as_deref())?;
        optional_text(
            "permission_request_id",
            self.permission_request_id.as_deref(),
        )?;
        optional_text("artifact_id", self.artifact_id.as_deref())?;
        optional_text("terminal_request_id", self.terminal_request_id.as_deref())?;
        optional_text("idempotency_key", self.idempotency_key.as_deref())?;
        optional_text("expires_at", self.expires_at.as_deref())?;
        optional_text("policy_revision", self.policy_revision.as_deref())?;
        optional_text("grant_id", self.grant_id.as_deref())?;
        optional_digest(
            "parent_transcript_digest",
            self.parent_transcript_digest.as_deref(),
        )?;
        optional_digest(
            "previous_envelope_digest",
            self.previous_envelope_digest.as_deref(),
        )?;
        Ok(())
    }
}

/// Encode the ACP envelope AAD binding used as additional AEAD associated data.
pub fn encode_acp_envelope_aad(binding: &SecureMeshAcpEnvelopeBinding) -> Result<Vec<u8>> {
    binding.validate()?;
    let mut out = Vec::new();
    out.extend_from_slice(ACP_AAD_MAGIC);
    append_len_prefixed_bytes(&mut out, SECURE_MESH_ACP_ENVELOPE_PROTOCOL.as_bytes())?;
    append_len_prefixed_bytes(&mut out, SECURE_MESH_PROTOCOL_VERSION.as_bytes())?;
    append_len_prefixed_bytes(&mut out, binding.payload_class.as_str().as_bytes())?;
    append_len_prefixed_bytes(&mut out, binding.source_endpoint_id.as_bytes())?;
    append_len_prefixed_bytes(&mut out, binding.target_endpoint_id.as_bytes())?;
    append_len_prefixed_bytes(&mut out, binding.acp_session_id.as_bytes())?;
    append_len_prefixed_bytes(&mut out, binding.relay_session_id.as_bytes())?;
    append_len_prefixed_bytes(&mut out, binding.relay_turn_id.as_bytes())?;
    out.extend_from_slice(&binding.message_sequence.to_be_bytes());
    append_optional_text(&mut out, binding.operation_id.as_deref())?;
    append_optional_text(&mut out, binding.mcp_child_operation_id.as_deref())?;
    append_optional_text(&mut out, binding.tool_call_id.as_deref())?;
    append_optional_text(&mut out, binding.permission_request_id.as_deref())?;
    append_optional_text(&mut out, binding.artifact_id.as_deref())?;
    append_optional_text(&mut out, binding.terminal_request_id.as_deref())?;
    append_optional_text(&mut out, binding.idempotency_key.as_deref())?;
    match binding.retry_counter {
        Some(value) => {
            out.push(1);
            out.extend_from_slice(&value.to_be_bytes());
        }
        None => out.push(0),
    }
    append_optional_text(&mut out, binding.expires_at.as_deref())?;
    append_optional_text(&mut out, binding.policy_revision.as_deref())?;
    append_optional_text(&mut out, binding.grant_id.as_deref())?;
    append_optional_text(&mut out, binding.parent_transcript_digest.as_deref())?;
    append_optional_text(&mut out, binding.previous_envelope_digest.as_deref())?;
    Ok(out)
}

pub fn acp_envelope_aad_digest(binding: &SecureMeshAcpEnvelopeBinding) -> Result<String> {
    let encoded = encode_acp_envelope_aad(binding)?;
    Ok(hex_sha256(&encoded))
}

/// Production ACP protected payloads must never be relayed as plaintext.
pub fn reject_plaintext_acp_protected_payload_relay(
    payload_class: SecureMeshAcpPayloadClass,
) -> Result<()> {
    ensure!(
        payload_class.is_protected(),
        "secure mesh ACP receipt class is metadata-only and must not use the protected-payload seal path"
    );
    bail!(
        "secure mesh ACP plaintext protected-payload relay is not a production path for class {}",
        payload_class.as_str()
    );
}

pub fn classify_acp_payload_class(label: &str) -> Result<SecureMeshAcpPayloadClass> {
    SecureMeshAcpPayloadClass::from_str(label)
}

pub fn seal_acp_protected_payload(
    session: &mut SecureMeshPairwiseSession,
    context: &SecureMeshContentContext,
    binding: &SecureMeshAcpEnvelopeBinding,
    body: &[u8],
) -> Result<SecureMeshRelayEnvelope> {
    ensure!(
        binding.payload_class.is_protected(),
        "secure mesh ACP receipt class cannot be sealed as a protected payload"
    );
    ensure!(
        context.sender_endpoint_id == binding.source_endpoint_id,
        "secure mesh ACP source endpoint mismatch"
    );
    ensure!(
        context.recipient_endpoint_id == binding.target_endpoint_id,
        "secure mesh ACP target endpoint mismatch"
    );
    let plaintext = SecureMeshPlaintext::new(SecureMeshPayloadKind::ServiceAction, body)
        .with_content_type(binding.payload_class.content_type());
    let acp_aad = encode_acp_envelope_aad(binding)?;
    session.seal_payload_envelope_with_extra_aad(context, &plaintext, &acp_aad)
}

pub fn open_acp_protected_payload(
    session: &mut SecureMeshPairwiseSession,
    context: &SecureMeshContentContext,
    envelope: &SecureMeshRelayEnvelope,
    binding: &SecureMeshAcpEnvelopeBinding,
) -> Result<OpenedSecureMeshPayload> {
    ensure!(
        binding.payload_class.is_protected(),
        "secure mesh ACP receipt class cannot be opened as a protected payload"
    );
    ensure!(
        context.sender_endpoint_id == binding.source_endpoint_id,
        "secure mesh ACP source endpoint mismatch"
    );
    ensure!(
        context.recipient_endpoint_id == binding.target_endpoint_id,
        "secure mesh ACP target endpoint mismatch"
    );
    let acp_aad = encode_acp_envelope_aad(binding)?;
    let opened = session.open_payload_envelope_with_extra_aad(
        envelope,
        SecureMeshPayloadKind::ServiceAction,
        &acp_aad,
    )?;
    ensure!(
        opened.content_type.as_deref() == Some(binding.payload_class.content_type()),
        "secure mesh ACP content type mismatch"
    );
    Ok(opened)
}

fn require_text(label: &str, value: &str) -> Result<()> {
    ensure!(!value.trim().is_empty(), "secure mesh ACP {label} is empty");
    ensure!(
        value.len() <= MAX_FIELD_BYTES,
        "secure mesh ACP {label} is too large"
    );
    Ok(())
}

fn optional_text(label: &str, value: Option<&str>) -> Result<()> {
    if let Some(text) = value {
        require_text(label, text)?;
    }
    Ok(())
}

fn optional_digest(label: &str, value: Option<&str>) -> Result<()> {
    if let Some(text) = value {
        require_text(label, text)?;
        ensure!(
            text.len() <= MAX_DIGEST_HEX_BYTES,
            "secure mesh ACP {label} digest is too large"
        );
    }
    Ok(())
}

fn append_optional_text(out: &mut Vec<u8>, value: Option<&str>) -> Result<()> {
    match value {
        Some(text) => {
            out.push(1);
            append_len_prefixed_bytes(out, text.as_bytes())?;
        }
        None => out.push(0),
    }
    Ok(())
}

fn append_len_prefixed_bytes(out: &mut Vec<u8>, value: &[u8]) -> Result<()> {
    let len =
        u32::try_from(value.len()).map_err(|_| anyhow!("secure mesh ACP field is too large"))?;
    out.extend_from_slice(&len.to_be_bytes());
    out.extend_from_slice(value);
    Ok(())
}

fn hex_sha256(bytes: &[u8]) -> String {
    let digest = Sha256::digest(bytes);
    digest.iter().map(|byte| format!("{byte:02x}")).collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::core::secure_mesh_crypto::{
        ContentKey, SecureMeshContentContext, SecureMeshPayloadKind, SecureMeshPlaintext,
        open_payload_with_aad_binding, seal_payload_with_aad_binding,
    };
    use crate::core::secure_mesh_pairwise::{
        SecureMeshPairwisePrivateKey, SecureMeshPairwiseSession,
    };
    use crate::core::secure_mesh_pqxdh::SecureMeshMlKem1024PreKeySeed;
    use crate::core::secure_mesh_prekey::{
        SecureMeshPairwisePreKeyBundle, SecureMeshPreKeyKind, SecureMeshPreKeyValidationPolicy,
        authorize_test_pairwise_prekey_bundle, sign_prekey_record,
    };
    use crate::core::secure_mesh_relay_envelope::SecureMeshRelayEnvelope;
    use crate::core::secure_mesh_trust::{DeviceTrustPublicIdentity, DeviceTrustState};
    use base64::{Engine, engine::general_purpose};
    use ed25519_dalek::SigningKey;
    use rand::rngs::OsRng;
    use time::OffsetDateTime;

    fn binding_fixture(class: SecureMeshAcpPayloadClass) -> SecureMeshAcpEnvelopeBinding {
        let mut binding = SecureMeshAcpEnvelopeBinding::new(
            class,
            "agent-source",
            "agent-target",
            "acp-session-1",
            "relay-session-1",
            "relay-turn-1",
            7,
        )
        .unwrap();
        binding.operation_id = Some("op-1".to_string());
        binding.tool_call_id = Some("tool-1".to_string());
        binding.permission_request_id = Some("perm-1".to_string());
        binding.idempotency_key = Some("idem-1".to_string());
        binding.retry_counter = Some(0);
        binding.expires_at = Some("2026-01-01T00:10:00.000Z".to_string());
        binding.policy_revision = Some("policy-rev-1".to_string());
        binding.grant_id = Some("grant-1".to_string());
        binding.parent_transcript_digest =
            Some("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa".to_string());
        binding.previous_envelope_digest =
            Some("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb".to_string());
        binding
    }

    fn context_fixture(session_id: &str) -> SecureMeshContentContext {
        SecureMeshContentContext::new(
            general_purpose::URL_SAFE_NO_PAD.encode(&Sha256::digest(b"env-acp-1")[..24]),
            "msg-acp-1",
            general_purpose::URL_SAFE_NO_PAD.encode(Sha256::digest(b"mailbox-acp-1")),
            "agent-source",
            "agent-target",
            session_id,
            "2026-01-01T00:00:00.000Z",
            "2026-01-01T00:10:00.000Z",
        )
    }

    struct EndpointFixture {
        identity: DeviceTrustPublicIdentity,
        identity_secret: SecureMeshPairwisePrivateKey,
        signing_key: SigningKey,
    }

    fn endpoint(endpoint_id: &str) -> EndpointFixture {
        let identity_secret = SecureMeshPairwisePrivateKey::generate();
        let signing_key = SigningKey::generate(&mut OsRng);
        let identity = DeviceTrustPublicIdentity::new(
            endpoint_id,
            identity_secret.public_key(),
            signing_key.verifying_key().to_bytes(),
            1,
        )
        .unwrap();
        EndpointFixture {
            identity,
            identity_secret,
            signing_key,
        }
    }

    fn paired_sessions() -> (SecureMeshPairwiseSession, SecureMeshPairwiseSession) {
        let alice = endpoint("agent-source");
        let bob = endpoint("agent-target");
        let signed_secret = SecureMeshPairwisePrivateKey::generate();
        let one_time_secret = SecureMeshPairwisePrivateKey::generate();
        let one_time_mlkem1024_prekey_seed = SecureMeshMlKem1024PreKeySeed::generate();
        let signed_prekey = sign_prekey_record(
            &bob.signing_key,
            &bob.identity,
            SecureMeshPreKeyKind::SignedPreKey,
            "spk-acp-1",
            signed_secret.public_key(),
            "2026-01-01T00:00:00.000Z",
            "2026-02-01T00:00:00.000Z",
        )
        .unwrap();
        let one_time_prekey = sign_prekey_record(
            &bob.signing_key,
            &bob.identity,
            SecureMeshPreKeyKind::OneTimePreKey,
            "otpk-acp-1",
            one_time_secret.public_key(),
            "2026-01-01T00:00:00.000Z",
            "2026-02-01T00:00:00.000Z",
        )
        .unwrap();
        let one_time_mlkem1024_prekey = sign_prekey_record(
            &bob.signing_key,
            &bob.identity,
            SecureMeshPreKeyKind::OneTimeMlKem1024PreKey,
            "pqotpk-acp-1",
            one_time_mlkem1024_prekey_seed.public_key(),
            "2026-01-01T00:00:00.000Z",
            "2026-02-01T00:00:00.000Z",
        )
        .unwrap();
        let bundle = SecureMeshPairwisePreKeyBundle {
            endpoint_identity: bob.identity.clone(),
            trust_state: DeviceTrustState::Verified,
            signed_prekey,
            one_time_prekey: Some(one_time_prekey),
            one_time_mlkem1024_prekey,
            prekey_publication_version: 1,
        };
        let directory_authorization = authorize_test_pairwise_prekey_bundle(&bundle);
        let now = OffsetDateTime::parse(
            "2026-01-01T00:00:01.000Z",
            &time::format_description::well_known::Rfc3339,
        )
        .unwrap();
        let (mut alice_session, intro) = SecureMeshPairwiseSession::initiate(
            &alice.identity,
            &alice.identity_secret,
            &alice.signing_key,
            &bundle,
            &directory_authorization,
            &SecureMeshPreKeyValidationPolicy::default(),
            &crate::core::secure_mesh_pairwise::secure_mesh_pairwise_test_capability_evaluation()
                .unwrap(),
            now,
        )
        .unwrap();
        let (mut bob_session, accepted) = SecureMeshPairwiseSession::accept(
            &bob.identity,
            &bob.identity_secret,
            &bob.signing_key,
            &alice.identity,
            &signed_secret,
            Some(&one_time_secret),
            &one_time_mlkem1024_prekey_seed,
            &intro,
            &crate::core::secure_mesh_pairwise::secure_mesh_pairwise_test_capability_evaluation()
                .unwrap(),
            now,
            &mut crate::core::secure_mesh_session_negotiation::CapabilityProofReplayGuard::default(
            ),
        )
        .unwrap();
        let finished = alice_session
            .complete_initiator_handshake(
                &alice.identity,
                &bob.identity,
                &accepted,
                now,
                &mut crate::core::secure_mesh_session_negotiation::CapabilityProofReplayGuard::default(),
            )
            .unwrap();
        bob_session.complete_responder_handshake(&finished).unwrap();
        (alice_session, bob_session)
    }

    #[test]
    fn secure_mesh_acp_envelope_aad_has_stable_digest_vector() {
        let binding = binding_fixture(SecureMeshAcpPayloadClass::Prompt);
        let digest = acp_envelope_aad_digest(&binding).unwrap();
        assert_eq!(digest.len(), 64);
        assert_eq!(
            digest,
            "9b480021174177f0d48517e3a5f4ea9ba207153d3d6a0f8dc6cd6aca9ec8e993"
        );
    }

    #[test]
    fn secure_mesh_acp_envelope_aad_field_mutation_fails_open() {
        let binding = binding_fixture(SecureMeshAcpPayloadClass::ToolArguments);
        let mut tampered = binding.clone();
        tampered.relay_turn_id = "relay-turn-tampered".to_string();
        let key = ContentKey::from_bytes([41u8; 32]);
        let context = context_fixture("session-acp-aad");
        let plaintext = SecureMeshPlaintext::new(
            SecureMeshPayloadKind::ServiceAction,
            br#"{"tool":"fs.write"}"#,
        )
        .with_content_type(binding.payload_class.content_type());
        let sealed = seal_payload_with_aad_binding(
            &key,
            &context,
            &plaintext,
            &encode_acp_envelope_aad(&binding).unwrap(),
        )
        .unwrap();
        let opened = open_payload_with_aad_binding(
            &key,
            &context,
            &sealed,
            SecureMeshPayloadKind::ServiceAction,
            &encode_acp_envelope_aad(&binding).unwrap(),
        )
        .unwrap();
        assert_eq!(opened.body, br#"{"tool":"fs.write"}"#);
        let err = open_payload_with_aad_binding(
            &key,
            &context,
            &sealed,
            SecureMeshPayloadKind::ServiceAction,
            &encode_acp_envelope_aad(&tampered).unwrap(),
        )
        .unwrap_err();
        let message = format!("{err:#}");
        assert!(
            message.contains("authentication")
                || message.contains("decrypt")
                || message.contains("aead")
                || message.contains("secure mesh"),
            "expected AAD mismatch failure, got {message}"
        );
    }

    #[test]
    fn secure_mesh_acp_pairwise_protected_payload_round_trip() {
        let (mut alice, mut bob) = paired_sessions();
        let binding = binding_fixture(SecureMeshAcpPayloadClass::Prompt);
        let context = context_fixture(&alice.session_id);
        let sealed =
            seal_acp_protected_payload(&mut alice, &context, &binding, b"prompt-body").unwrap();
        let opened = open_acp_protected_payload(&mut bob, &context, &sealed, &binding).unwrap();
        assert_eq!(opened.body, b"prompt-body");
        assert_eq!(
            opened.content_type.as_deref(),
            Some(SecureMeshAcpPayloadClass::Prompt.content_type())
        );
    }

    #[test]
    fn secure_mesh_acp_plaintext_protected_payload_relay_is_blocked() {
        let err = reject_plaintext_acp_protected_payload_relay(SecureMeshAcpPayloadClass::Prompt)
            .unwrap_err();
        assert!(format!("{err:#}").contains("plaintext protected-payload relay"));
        assert!(format!("{err:#}").contains("not a production path"));
    }

    fn acp_canary_variants(canary: &str) -> Vec<String> {
        let utf8 = canary.as_bytes();
        let base64 = general_purpose::STANDARD.encode(utf8);
        let base64url = general_purpose::URL_SAFE_NO_PAD.encode(utf8);
        let hex = utf8
            .iter()
            .map(|byte| format!("{byte:02x}"))
            .collect::<String>();
        vec![
            canary.to_string(),
            base64,
            base64url,
            hex,
            utf8.iter()
                .map(|byte| format!("\\u{byte:04x}"))
                .collect::<String>(),
        ]
    }

    fn relay_visible_envelope_text(envelope: &SecureMeshRelayEnvelope) -> String {
        format!(
            "{}|{}|{}|{}|{}|{}",
            envelope.schema(),
            envelope.delivery_id(),
            envelope.mailbox_token(),
            envelope.encrypted_header(),
            envelope.ciphertext_bucket(),
            envelope.ciphertext()
        )
    }

    #[test]
    fn secure_mesh_acp_sealed_payloads_hide_raw_and_encoded_canaries() {
        let protected_classes = [
            SecureMeshAcpPayloadClass::Prompt,
            SecureMeshAcpPayloadClass::Update,
            SecureMeshAcpPayloadClass::Reasoning,
            SecureMeshAcpPayloadClass::ToolArguments,
            SecureMeshAcpPayloadClass::ToolResult,
            SecureMeshAcpPayloadClass::FilesystemContent,
            SecureMeshAcpPayloadClass::TerminalContent,
            SecureMeshAcpPayloadClass::PermissionPayload,
            SecureMeshAcpPayloadClass::ApprovalDecision,
            SecureMeshAcpPayloadClass::Artifact,
            SecureMeshAcpPayloadClass::ArchiveLayer,
        ];
        for class in protected_classes {
            let (mut alice, mut bob) = paired_sessions();
            let binding = binding_fixture(class);
            let context = context_fixture(&alice.session_id);
            let canary = format!(
                "acp-{}-hostile-canary-{}-must-not-relay",
                class.as_str(),
                "PRIVATE"
            );
            let sealed =
                seal_acp_protected_payload(&mut alice, &context, &binding, canary.as_bytes())
                    .unwrap();
            let opened = open_acp_protected_payload(&mut bob, &context, &sealed, &binding).unwrap();
            assert_eq!(opened.body, canary.as_bytes());
            let visible = relay_visible_envelope_text(&sealed);
            for variant in acp_canary_variants(&canary) {
                assert!(
                    !visible.contains(&variant),
                    "ACP {} relay-visible envelope leaked canary variant",
                    class.as_str()
                );
            }
            // Ratchet-structure markers must not appear as recoverable plaintext fields.
            for marker in ["rootKey", "chainKey", "messageKey", "sending_chain_key"] {
                assert!(
                    !visible.contains(marker),
                    "ACP {} relay-visible envelope leaked ratchet marker {marker}",
                    class.as_str()
                );
            }
        }
    }

    #[test]
    fn secure_mesh_acp_payload_classes_cover_protected_taxonomy() {
        for class in [
            SecureMeshAcpPayloadClass::Prompt,
            SecureMeshAcpPayloadClass::Update,
            SecureMeshAcpPayloadClass::Reasoning,
            SecureMeshAcpPayloadClass::ToolArguments,
            SecureMeshAcpPayloadClass::ToolResult,
            SecureMeshAcpPayloadClass::FilesystemContent,
            SecureMeshAcpPayloadClass::TerminalContent,
            SecureMeshAcpPayloadClass::PermissionPayload,
            SecureMeshAcpPayloadClass::ApprovalDecision,
            SecureMeshAcpPayloadClass::Artifact,
            SecureMeshAcpPayloadClass::ArchiveLayer,
        ] {
            assert!(class.is_protected());
            assert!(
                classify_acp_payload_class(class.as_str())
                    .unwrap()
                    .is_protected()
            );
        }
        assert!(!SecureMeshAcpPayloadClass::Receipt.is_protected());
    }

    #[test]
    fn secure_mesh_acp_status_remains_independent_review_blocked() {
        assert!(SECURE_MESH_ACP_STATUS.contains("independent_review_pending"));
        assert!(SECURE_MESH_ACP_STATUS.contains("pqxdh_mlkem1024_triple_ratchet"));
        assert!(SECURE_MESH_ACP_STATUS.contains("plaintext_protected_payload_relay_blocked"));
        assert!(SECURE_MESH_ACP_STATUS.contains("acp_protected_envelope_aad_available"));
    }
}
