//! Authentication as a conversation between the host and a provider package.
//!
//! The provider owns its authentication protocol: it offers a challenge — a
//! device code, a URL the host opens with its own primitive, or a request for a
//! secret the host collects through its own input control — and it answers with a
//! `credential:` handle once authorized. The host never draws a permission page
//! of its own and never receives key material: [`AuthChallenge`] is data about
//! what to show, [`SecretInputHandle`] is an opaque reference to input the host
//! already collected, and the authorized result is a handle the host stores as a
//! scope ([`crate::CredentialVault`]).
//!
//! The verification URI a challenge carries is checked to be an `http`/`https`
//! URL before it can reach an open-url primitive: a plugin does not get to name
//! a `file:` or `javascript:` target.

use licoup_application::{ApplicationFailure, RecoveryAction};
use licoup_extension_contracts::profile::{
    METHOD_AUTH_BEGIN, METHOD_AUTH_CONTINUE, METHOD_AUTH_REFRESH, METHOD_AUTH_REVOKE,
};
use licoup_extension_contracts::provider::{CredentialScope, credential_ref_is_handle};
use serde_json::{Value, json};
use std::fmt;

use crate::plugin::ProviderPlugin;
use crate::refusal;

const STAGE: &str = "model-provider/auth";

/// What the user is asked to do.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum AuthChallenge {
    /// The host shows a code and opens the verification URI with its own
    /// primitive.
    DeviceCode {
        verification_uri: String,
        user_code: String,
        expires_in_seconds: Option<u64>,
    },
    /// The host opens a URL with its own primitive.
    OpenUrl { url: String },
    /// The host collects a secret with its own control and passes the handle
    /// back; the secret itself never enters this runtime.
    SecretInput { label: String },
}

/// An opaque handle to secret input the host collected.
#[derive(Clone, PartialEq, Eq)]
pub struct SecretInputHandle(String);

impl SecretInputHandle {
    pub fn new(token: impl Into<String>) -> Self {
        Self(token.into())
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl fmt::Debug for SecretInputHandle {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("SecretInputHandle(<opaque>)")
    }
}

/// Where an authentication flow stands.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum AuthStage {
    AwaitingUser { challenge: AuthChallenge },
    Pending,
    Authorized { scope: CredentialScope },
    Denied { code: String },
    Revoked,
}

impl AuthStage {
    fn machine_state(&self) -> crate::state_machine::provider_auth::State {
        use crate::state_machine::provider_auth::State;
        match self {
            Self::AwaitingUser { .. } => State::AwaitingUser,
            Self::Pending => State::Pending,
            Self::Authorized { .. } => State::Authorized,
            Self::Denied { .. } => State::Denied,
            Self::Revoked => State::Revoked,
        }
    }
}

/// One authentication flow.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AuthFlow {
    pub flow_id: String,
    pub provider_id: String,
    pub origin: String,
    pub stage: AuthStage,
}

impl AuthFlow {
    /// The scope an authorized flow produced.
    pub fn credential_scope(&self) -> Option<&CredentialScope> {
        match &self.stage {
            AuthStage::Authorized { scope } => Some(scope),
            _ => None,
        }
    }

    fn from_response(
        value: Value,
        provider_id: &str,
        origin: &str,
    ) -> Result<Self, ApplicationFailure> {
        let flow_id = value
            .get("flowId")
            .and_then(Value::as_str)
            .ok_or_else(|| {
                refusal::new("provider_auth_response_invalid", STAGE).with_field("flowId")
            })?
            .to_owned();
        Ok(Self {
            flow_id,
            provider_id: provider_id.to_owned(),
            origin: origin.to_owned(),
            stage: advance_stage(
                crate::state_machine::provider_auth::INITIAL,
                &value,
                provider_id,
                origin,
            )?,
        })
    }
}

/// What the host sends when continuing a flow.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum AuthInput {
    /// The user finished the browser or device step.
    UserConfirmed,
    /// A poll for a device-code flow.
    PollDeviceCode,
    /// The user entered a secret through a host control; only the handle moves.
    Secret { handle: SecretInputHandle },
}

/// Drives one provider package's authentication conversation.
pub struct AuthDriver<'a> {
    plugin: &'a mut ProviderPlugin,
    provider_id: String,
    origin: String,
}

impl<'a> AuthDriver<'a> {
    pub fn new(
        plugin: &'a mut ProviderPlugin,
        provider_id: impl Into<String>,
        origin: impl Into<String>,
    ) -> Self {
        Self {
            plugin,
            provider_id: provider_id.into(),
            origin: origin.into(),
        }
    }

    /// Start a flow. A package that did not declare `auth.begin` is refused with
    /// an actionable refusal instead of being asked to improvise.
    pub fn begin(&mut self) -> Result<AuthFlow, ApplicationFailure> {
        if !self.plugin.implements(METHOD_AUTH_BEGIN) {
            return Err(refusal::actionable(
                "provider_auth_unsupported",
                STAGE,
                "auth.begin",
                RecoveryAction::InstallOrRetryRuntime,
            )
            .with_presentation_arg("providerId", &self.provider_id));
        }
        let result = self.plugin.request(
            METHOD_AUTH_BEGIN,
            json!({"providerId": self.provider_id, "origin": self.origin}),
        )?;
        AuthFlow::from_response(result, &self.provider_id, &self.origin)
    }

    /// Continue a flow with the user's answer.
    pub fn continue_with(
        &mut self,
        flow: &mut AuthFlow,
        input: AuthInput,
    ) -> Result<(), ApplicationFailure> {
        if crate::state_machine::provider_auth::terminal(flow.stage.machine_state()) {
            return Err(
                refusal::new("provider_auth_transition_invalid", STAGE).with_field("stage")
            );
        }
        if !self.plugin.implements(METHOD_AUTH_CONTINUE) {
            return Err(refusal::actionable(
                "provider_auth_unsupported",
                STAGE,
                "auth.continue",
                RecoveryAction::InstallOrRetryRuntime,
            ));
        }
        let input = match input {
            AuthInput::UserConfirmed => json!({"kind": "user-confirmed"}),
            AuthInput::PollDeviceCode => json!({"kind": "device-code-poll"}),
            AuthInput::Secret { handle } => {
                json!({"kind": "secret-input", "secretHandle": handle.as_str()})
            }
        };
        let result = self.plugin.request(
            METHOD_AUTH_CONTINUE,
            json!({"flowId": flow.flow_id, "input": input}),
        )?;
        flow.stage = advance_stage(
            flow.stage.machine_state(),
            &result,
            &flow.provider_id,
            &flow.origin,
        )?;
        Ok(())
    }

    /// Refresh an authorized flow's handle.
    pub fn refresh(&mut self, flow: &mut AuthFlow) -> Result<(), ApplicationFailure> {
        let Some(scope) = flow.credential_scope().cloned() else {
            return Err(refusal::new("provider_auth_not_authorized", STAGE).with_field("stage"));
        };
        if !self.plugin.implements(METHOD_AUTH_REFRESH) {
            return Err(refusal::actionable(
                "provider_auth_unsupported",
                STAGE,
                "auth.refresh",
                RecoveryAction::InstallOrRetryRuntime,
            ));
        }
        let result = self.plugin.request(
            METHOD_AUTH_REFRESH,
            json!({"credentialRef": scope.reference}),
        )?;
        flow.stage = advance_stage(
            flow.stage.machine_state(),
            &result,
            &flow.provider_id,
            &flow.origin,
        )?;
        Ok(())
    }

    /// Revoke the handle a flow produced.
    pub fn revoke(&mut self, flow: &mut AuthFlow) -> Result<bool, ApplicationFailure> {
        let Some(scope) = flow.credential_scope().cloned() else {
            return Err(refusal::new("provider_auth_not_authorized", STAGE).with_field("stage"));
        };
        if !self.plugin.implements(METHOD_AUTH_REVOKE) {
            return Err(refusal::actionable(
                "provider_auth_unsupported",
                STAGE,
                "auth.revoke",
                RecoveryAction::InstallOrRetryRuntime,
            ));
        }
        let result = self.plugin.request(
            METHOD_AUTH_REVOKE,
            json!({"credentialRef": scope.reference}),
        )?;
        let revoked = result
            .get("revoked")
            .and_then(Value::as_bool)
            .unwrap_or(false);
        if revoked {
            flow.stage = apply_stage_transition(
                flow.stage.machine_state(),
                AuthStage::Revoked,
                crate::state_machine::provider_auth::Event::ObserveRevoked,
            )?;
        }
        Ok(revoked)
    }
}

#[cfg(test)]
fn parse_stage(
    value: &Value,
    provider_id: &str,
    origin: &str,
) -> Result<AuthStage, ApplicationFailure> {
    advance_stage(
        crate::state_machine::provider_auth::INITIAL,
        value,
        provider_id,
        origin,
    )
}

fn advance_stage(
    current: crate::state_machine::provider_auth::State,
    value: &Value,
    provider_id: &str,
    origin: &str,
) -> Result<AuthStage, ApplicationFailure> {
    use crate::state_machine::provider_auth::Event;
    let (stage, event) = match value.get("stage").and_then(Value::as_str) {
        Some("awaiting-user") => {
            let challenge = value.get("challenge").ok_or_else(|| {
                refusal::new("provider_auth_response_invalid", STAGE).with_field("challenge")
            })?;
            (
                AuthStage::AwaitingUser {
                    challenge: parse_challenge(challenge)?,
                },
                Event::ObserveAwaitingUser,
            )
        }
        Some("pending") => (AuthStage::Pending, Event::ObservePending),
        Some("authorized") => {
            let reference = value
                .get("credentialRef")
                .and_then(Value::as_str)
                .ok_or_else(|| {
                    refusal::new("provider_auth_response_invalid", STAGE)
                        .with_field("credentialRef")
                })?;
            if !credential_ref_is_handle(reference) {
                // A provider that answers with key material, or with something
                // that is not a handle, is refused before it reaches a record.
                return Err(refusal::new("provider_auth_credential_invalid", STAGE)
                    .with_field("credentialRef"));
            }
            (
                AuthStage::Authorized {
                    scope: CredentialScope {
                        reference: reference.to_owned(),
                        provider_id: provider_id.to_owned(),
                        origin: origin.to_owned(),
                    },
                },
                Event::ObserveAuthorized,
            )
        }
        Some("denied") => (
            AuthStage::Denied {
                code: value
                    .get("code")
                    .and_then(Value::as_str)
                    .unwrap_or("denied")
                    .to_owned(),
            },
            Event::ObserveDenied,
        ),
        Some("expired") => (
            AuthStage::Denied {
                code: "expired".to_owned(),
            },
            Event::ObserveDenied,
        ),
        Some("revoked") => (AuthStage::Revoked, Event::ObserveRevoked),
        _ => {
            return Err(refusal::new("provider_auth_response_invalid", STAGE).with_field("stage"));
        }
    };
    apply_stage_transition(current, stage, event)
}

fn apply_stage_transition(
    current: crate::state_machine::provider_auth::State,
    stage: AuthStage,
    event: crate::state_machine::provider_auth::Event,
) -> Result<AuthStage, ApplicationFailure> {
    let target =
        crate::state_machine::provider_auth::transition(current, event).ok_or_else(|| {
            refusal::new("provider_auth_transition_invalid", STAGE).with_field("stage")
        })?;
    if target != stage.machine_state() {
        return Err(refusal::new("provider_auth_transition_invalid", STAGE).with_field("stage"));
    }
    Ok(stage)
}

fn parse_challenge(value: &Value) -> Result<AuthChallenge, ApplicationFailure> {
    let kind = value
        .get("kind")
        .and_then(Value::as_str)
        .ok_or_else(|| refusal::new("provider_auth_challenge_invalid", STAGE).with_field("kind"))?;
    match kind {
        "device-code" => {
            let verification_uri = required_string(value, "verificationUri")?;
            host_openable_url(&verification_uri)?;
            let user_code = required_string(value, "userCode")?;
            Ok(AuthChallenge::DeviceCode {
                verification_uri,
                user_code,
                expires_in_seconds: value.get("expiresInSeconds").and_then(Value::as_u64),
            })
        }
        "open-url" => {
            let url = required_string(value, "url")?;
            host_openable_url(&url)?;
            Ok(AuthChallenge::OpenUrl { url })
        }
        "secret-input" => Ok(AuthChallenge::SecretInput {
            label: value
                .get("label")
                .and_then(Value::as_str)
                .unwrap_or("credential")
                .to_owned(),
        }),
        _ => {
            Err(refusal::new("provider_auth_challenge_invalid", STAGE).with_field("challenge.kind"))
        }
    }
}

fn required_string(value: &Value, field: &str) -> Result<String, ApplicationFailure> {
    value
        .get(field)
        .and_then(Value::as_str)
        .filter(|text| !text.is_empty())
        .map(str::to_owned)
        .ok_or_else(|| {
            refusal::new("provider_auth_challenge_invalid", STAGE)
                .with_field(format!("challenge.{field}"))
        })
}

/// A URL the host may hand to an open-url primitive: HTTP(S) only.
fn host_openable_url(candidate: &str) -> Result<(), ApplicationFailure> {
    let parsed = url::Url::parse(candidate).map_err(|_| {
        refusal::new("provider_auth_challenge_invalid", STAGE)
            .with_field("challenge.verificationUri")
    })?;
    if !matches!(parsed.scheme(), "http" | "https") {
        return Err(refusal::new("provider_auth_challenge_invalid", STAGE)
            .with_field("challenge.verificationUri"));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_device_code_challenge_is_data_the_host_can_show() {
        let stage = parse_stage(
            &json!({
                "stage": "awaiting-user",
                "challenge": {
                    "kind": "device-code",
                    "verificationUri": "https://auth.example.invalid/device",
                    "userCode": "ABCD-1234",
                    "expiresInSeconds": 600
                }
            }),
            "synthetic.example",
            "http://127.0.0.1:8099",
        )
        .unwrap();
        let AuthStage::AwaitingUser { challenge } = stage else {
            panic!("expected a challenge");
        };
        assert_eq!(
            challenge,
            AuthChallenge::DeviceCode {
                verification_uri: "https://auth.example.invalid/device".to_owned(),
                user_code: "ABCD-1234".to_owned(),
                expires_in_seconds: Some(600),
            }
        );
    }

    #[test]
    fn a_challenge_url_must_be_http_not_a_local_scheme() {
        for refused in [
            "javascript:alert(1)",
            "file:///etc/passwd",
            "data:text/html,x",
        ] {
            let failure = parse_challenge(&json!({"kind": "open-url", "url": refused}))
                .expect_err("not host-openable");
            assert_eq!(failure.code, "provider_auth_challenge_invalid");
        }
    }

    #[test]
    fn a_secret_input_challenge_is_a_label_not_a_secret() {
        let AuthChallenge::SecretInput { label } =
            parse_challenge(&json!({"kind": "secret-input", "label": "Provider key"})).unwrap()
        else {
            panic!("expected a secret-input challenge");
        };
        assert_eq!(label, "Provider key");
    }

    #[test]
    fn key_material_is_not_a_credential_handle() {
        let failure = parse_stage(
            &json!({"stage": "authorized", "credentialRef": "sk-live-example"}),
            "synthetic.example",
            "http://127.0.0.1:8099",
        )
        .expect_err("raw key material");
        assert_eq!(failure.code, "provider_auth_credential_invalid");

        let stage = parse_stage(
            &json!({"stage": "authorized", "credentialRef": "credential:synthetic-device"}),
            "synthetic.example",
            "http://127.0.0.1:8099",
        )
        .unwrap();
        let AuthStage::Authorized { scope } = stage else {
            panic!("expected authorization");
        };
        assert_eq!(scope.provider_id, "synthetic.example");
        assert_eq!(scope.origin, "http://127.0.0.1:8099");
    }

    #[test]
    fn a_terminal_auth_result_cannot_be_reopened() {
        let failure = apply_stage_transition(
            crate::state_machine::provider_auth::State::Revoked,
            AuthStage::Pending,
            crate::state_machine::provider_auth::Event::ObservePending,
        )
        .expect_err("revocation is terminal");
        assert_eq!(failure.code, "provider_auth_transition_invalid");
    }
}
