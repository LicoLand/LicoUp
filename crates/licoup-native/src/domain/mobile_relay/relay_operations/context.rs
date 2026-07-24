use crate::domain::mobile_relay::support::{effective_gateway_url, text_param};
use crate::platform::secure_client_relay::{
    SecureClientRelayAuth, SecureClientRelayScope, SecureClientRelayTransport,
};
use anyhow::{Result, anyhow, ensure};
use serde_json::{Value, json};

pub(in crate::domain::mobile_relay) struct CanonicalRelayContext {
    pub(super) transport: SecureClientRelayTransport,
    pub(super) scope: SecureClientRelayScope,
}

pub(in crate::domain::mobile_relay) fn canonical_relay_context(
    params: &Value,
    config: &Value,
) -> Result<CanonicalRelayContext> {
    ensure!(
        config
            .get("relayEnabled")
            .and_then(Value::as_bool)
            .unwrap_or(false),
        "mobile relay is disabled"
    );
    let tenant_id = relay_scope_value(params, config, "relayTenantId")
        .ok_or_else(|| anyhow!("secure client relay tenant id is missing"))?;
    let account_id = relay_scope_value(params, config, "relayAccountId")
        .ok_or_else(|| anyhow!("secure client relay account id is missing"))?;
    let workspace_id = relay_scope_value(params, config, "relayWorkspaceId");
    let session_token = text_param(params, &["relaySessionToken"])
        .filter(|value| !value.is_empty())
        .ok_or_else(|| anyhow!("secure client relay session token is missing"))?;
    let csrf_token = text_param(params, &["relayCsrfToken"])
        .filter(|value| !value.is_empty())
        .ok_or_else(|| anyhow!("secure client relay CSRF token is missing"))?;
    let auth = SecureClientRelayAuth::new(session_token, csrf_token)?;
    let scope = SecureClientRelayScope::new(tenant_id, account_id, workspace_id)?;
    let transport = SecureClientRelayTransport::new(effective_gateway_url(config)?, auth)?;
    Ok(CanonicalRelayContext { transport, scope })
}

pub(in crate::domain::mobile_relay) fn relay_scope_value(
    params: &Value,
    config: &Value,
    key: &str,
) -> Option<String> {
    text_param(params, &[key])
        .or_else(|| {
            config
                .get(key)
                .and_then(Value::as_str)
                .map(str::trim)
                .filter(|value| !value.is_empty())
                .map(str::to_string)
        })
        .filter(|value| !value.is_empty())
}

pub(in crate::domain::mobile_relay) fn remember_relay_scope(
    config: &mut Value,
    scope: &SecureClientRelayScope,
) {
    config["relayTenantId"] = json!(scope.tenant_id);
    config["relayAccountId"] = json!(scope.account_id);
    config["relayWorkspaceId"] = json!(scope.workspace_id.clone().unwrap_or_default());
}
