use std::sync::OnceLock;

use serde_json::Value;

use super::contract::{
    SECURE_CLIENT_RELAY_CORE_CONTRACT, SecureClientRelayHttpError, SecureClientRelayOperation,
};

static CORE_CONTRACT_VALUE: OnceLock<Value> = OnceLock::new();

pub(super) fn project_http_error(
    operation: SecureClientRelayOperation,
    status: u16,
    code: String,
    retry_after_seconds: Option<u64>,
) -> SecureClientRelayHttpError {
    let (retryable, retry_strategy) =
        core_error_policy(operation, &code, status, retry_after_seconds.is_some());
    SecureClientRelayHttpError {
        operation: operation.key(),
        status,
        code,
        retryable,
        retry_strategy,
        retry_after_seconds,
    }
}

fn core_error_policy(
    operation: SecureClientRelayOperation,
    code: &str,
    status: u16,
    has_retry_after: bool,
) -> (bool, String) {
    let contract = CORE_CONTRACT_VALUE.get_or_init(|| {
        serde_json::from_str(SECURE_CLIENT_RELAY_CORE_CONTRACT)
            .expect("embedded Secure Client Relay core contract must be valid JSON")
    });
    let policy =
        contract["contract"]["coreOperations"][operation.key()]["errors"][code].as_object();
    if let Some(policy) = policy {
        if policy["status"].as_u64() == Some(u64::from(status)) {
            let retry = &policy["retry"];
            return (
                retry["retryable"].as_bool().unwrap_or(false),
                retry["strategy"]
                    .as_str()
                    .unwrap_or("do_not_retry")
                    .to_string(),
            );
        }
    }
    if status == 429 && has_retry_after {
        return (true, "retry_after_header".to_string());
    }
    (false, "do_not_retry".to_string())
}
