use std::io::Read;

use anyhow::{Context, Result, ensure};
use serde_json::Value;

use super::contract::{
    MAX_HTTP_ERROR_RESPONSE_BYTES, MAX_HTTP_RESPONSE_BYTES, SecureClientRelayOperation,
};
use super::response_schema::{validate_error_response, validate_success_response};

pub(super) fn decode_success_response(
    operation: SecureClientRelayOperation,
    content_type: Option<&str>,
    reader: impl Read,
) -> Result<Value> {
    ensure_json_content_type(content_type)?;
    let body = read_json_response(reader, MAX_HTTP_RESPONSE_BYTES)?;
    validate_success_response(operation, &body)?;
    Ok(body)
}

pub(super) fn decode_error_code(content_type: Option<&str>, reader: impl Read) -> Result<String> {
    ensure_json_content_type(content_type)?;
    let body = read_json_response(reader, MAX_HTTP_ERROR_RESPONSE_BYTES)?;
    Ok(validate_error_response(&body)?.to_string())
}

fn ensure_json_content_type(content_type: Option<&str>) -> Result<()> {
    ensure!(
        content_type.is_some_and(|value| {
            value.split(';').next().is_some_and(|media_type| {
                media_type.trim().eq_ignore_ascii_case("application/json")
            })
        }),
        "secure client relay response content type is invalid"
    );
    Ok(())
}

fn read_json_response(mut reader: impl Read, maximum_bytes: usize) -> Result<Value> {
    let mut bytes = Vec::new();
    reader
        .by_ref()
        .take((maximum_bytes + 1) as u64)
        .read_to_end(&mut bytes)
        .context("secure client relay response read failed")?;
    ensure!(
        bytes.len() <= maximum_bytes,
        "secure client relay response body is too large"
    );
    serde_json::from_slice(&bytes).context("secure client relay response JSON is invalid")
}
